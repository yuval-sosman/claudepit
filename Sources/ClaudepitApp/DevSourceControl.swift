#if DEBUG
import SwiftUI
import AppKit
import ClaudepitCore

/// Developer tool, DEBUG builds only: render the Source Control sheet offscreen to PNG, and drive
/// it with synthetic clicks and keys, checking what git says after each action.
///
///     .build/debug/ClaudepitApp --snapshot-source-control <repo | demo | demo-merge> --out <dir>
///         [--select list/path,…] [--width N] [--height N] [--interaction-test]
///
/// `demo` builds a throwaway repo holding one of every kind of change — partly staged, renamed,
/// deleted, untracked, binary; `demo-merge` one stopped on merge conflicts. `--select` takes
/// `staged/<path>`, `changes/<path>` or `conflicts/<path>` and writes one PNG per selection.
/// `brainstorm-demo` renders a task's brainstorm suggestions, the sheet's other source (an
/// in-memory stand-in with `BrainstormChangeSource`'s diff shape). A real repo is only ever
/// rendered: `--interaction-test` stages, discards and commits, so it runs on fresh demo repos
/// and refuses anything else.
@MainActor
enum DevSourceControl {
    private static var failures = 0

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot-source-control"), i + 1 < args.count else { return false }
        func value(_ flag: String) -> String? {
            guard let j = args.firstIndex(of: flag), j + 1 < args.count else { return nil }
            return args[j + 1]
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let target = args[i + 1]
        if args.contains("--interaction-test") {
            guard target == "demo" else { print("--interaction-test builds its own repos; pass `demo`"); exit(2) }
            exit(runInteraction() ? 0 : 1)
        }
        let outDir = URL(fileURLWithPath: value("--out") ?? FileManager.default.currentDirectoryPath)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let size = CGSize(width: Double(value("--width") ?? "") ?? 1180, height: Double(value("--height") ?? "") ?? 760)
        let source: ChangeSource
        switch target {
        case "demo": source = GitChangeSource(worktreePath: makeDemoRepo().path, title: "Demo task")
        case "demo-merge": source = GitChangeSource(worktreePath: makeMergeRepo().path, title: "Demo task")
        case "brainstorm-demo": source = BrainstormStub()
        default: source = GitChangeSource(worktreePath: target, title: URL(filePath: target).lastPathComponent)
        }
        if let git = source as? GitChangeSource { print("repo: \(git.worktreePath)") }
        let probe = ProbeBox()
        let d = host(source, size: size, probe: probe)
        waitIdle(d, probe)
        let selections = value("--select")?.split(separator: ",").map(String.init) ?? []
        if selections.isEmpty {
            d.capture(to: outDir.appending(path: "source-control.png"))
            print("wrote \(outDir.appending(path: "source-control.png").path)")
        }
        for (n, sel) in selections.enumerated() {
            d.click("sc-row-\(sel.replacingOccurrences(of: "/", with: "-", options: [], range: sel.range(of: "/")))")
            waitIdle(d, probe)
            let url = outDir.appending(path: "source-control-\(n + 1).png")
            d.capture(to: url)
            print("wrote \(url.path) (\(sel))")
        }
        exit(0)
    }

    // MARK: Hosting

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    final class ProbeBox: @unchecked Sendable {
        var state: SourceControlProbeState?
        var confirmations: [String] = []
    }

    private static var windows: [NSWindow] = []

    private static func host(_ source: ChangeSource, size: CGSize, probe: ProbeBox) -> Driver {
        NSApplication.shared.setActivationPolicy(.accessory)
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        let frames = FrameBox()
        let view = ReviewChangesSheet(source: source) {}
            .frame(width: size.width, height: size.height)
            .background(Color(red: 0.11, green: 0.115, blue: 0.13))
            .environment(\.debugFrameReporter, { id, rect in frames.map[id] = rect })
            .environment(\.sourceControlProbe, { probe.state = $0 })
            .environment(\.sourceControlAutoConfirm, { probe.confirmations.append($0) })
            .environment(\.colorScheme, .dark)
        let hostView = NSHostingView(rootView: view)
        hostView.frame = CGRect(origin: .zero, size: size)
        let window = KeyWindow(contentRect: hostView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hostView
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        window.makeKey()
        windows.append(window)
        let d = Driver(window: window, host: hostView, frames: frames)
        d.settle(0.5)
        return d
    }

    /// Until the sheet has loaded, isn't running a git command, and its diff is the selection's.
    private static func waitIdle(_ d: Driver, _ probe: ProbeBox, timeout: Double = 8) {
        let until = Date().addingTimeInterval(timeout)
        d.settle(0.25)
        while Date() < until {
            if let s = probe.state, !s.busy, s.focused == nil || s.diffRef == s.focused { break }
            d.settle(0.05)
        }
        d.settle(0.3)
    }

    // MARK: Demo repos

    @discardableResult
    private static func git(_ repo: URL, _ args: [String]) -> String {
        Subprocess.runSync("/usr/bin/env", ["git", "-C", repo.path] + args)?.stdout ?? ""
    }

    private static func write(_ repo: URL, _ path: String, _ text: String) {
        let url = repo.appending(path: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func read(_ repo: URL, _ path: String) -> String? {
        try? String(contentsOf: repo.appending(path: path), encoding: .utf8)
    }

    private static func porcelain(_ repo: URL) -> Set<String> {
        Set(git(repo, ["status", "--porcelain", "--untracked-files=all"]).split(separator: "\n").map(String.init))
    }

    private static func png(_ repo: URL, _ path: String, hue: CGFloat) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 96, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: 80, height: 80), xRadius: 18, yRadius: 18).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 32, y: 32, width: 32, height: 32)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let url = repo.appending(path: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static let modelBase = """
    import Foundation

    /// A to-do item.
    struct Item: Identifiable, Codable {
        let id: UUID
        var title: String
        var done: Bool
    }

    final class Store {
        private(set) var items: [Item] = []

        func add(_ title: String) {
            items.append(Item(id: UUID(), title: title, done: false))
        }

        func toggle(_ id: UUID) {
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            items[i].done.toggle()
        }

        func remove(_ id: UUID) {
            items.removeAll { $0.id == id }
        }

        var remaining: Int {
            items.filter { !$0.done }.count
        }
    }

    """

    static let viewBase = """
    import SwiftUI

    struct ItemRow: View {
        let item: Item
        var body: some View {
            HStack {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                Text(item.title)
            }
        }
    }

    """

    private static func baseRepo() -> URL {
        let repo = FileManager.default.temporaryDirectory.appending(path: "claudepit-sc-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        git(repo, ["init", "-q", "-b", "main"])
        git(repo, ["config", "user.email", "demo@example.com"])
        git(repo, ["config", "user.name", "Demo"])
        write(repo, "Sources/App/Model.swift", modelBase)
        write(repo, "Sources/App/View.swift", viewBase)
        write(repo, "README.md", "# Todo\n\nA small to-do app.\n\n## Build\n\n    swift build\n")
        write(repo, "old-name.txt", "notes\nline two\nline three\n")
        write(repo, "remove-me.txt", "temporary\n")
        png(repo, "assets/logo.png", hue: 0.58)
        git(repo, ["add", "-A"])
        git(repo, ["commit", "-qm", "Initial commit"])
        return repo
    }

    /// One of every kind of change: Model.swift partly staged (one block of two), View.swift
    /// staged, a staged rename with an edit, README edited, a deletion, two new files, and an
    /// edited image.
    static func makeDemoRepo() -> URL {
        let repo = baseRepo()
        write(repo, "Sources/App/Model.swift", modelBase.replacingOccurrences(of: "    var done: Bool\n", with: "    var done: Bool\n    var priority: Int = 0\n"))
        git(repo, ["add", "Sources/App/Model.swift"])
        write(repo, "Sources/App/Model.swift", modelBase
            .replacingOccurrences(of: "    var done: Bool\n", with: "    var done: Bool\n    var priority: Int = 0\n")
            .replacingOccurrences(of: "        items.filter { !$0.done }.count\n    }\n", with: "        items.filter { !$0.done }.count\n    }\n\n    var completed: Int {\n        items.count - remaining\n    }\n"))
        write(repo, "Sources/App/View.swift", viewBase.replacingOccurrences(of: "Text(item.title)", with: "Text(item.title)\n                .strikethrough(item.done)"))
        git(repo, ["add", "Sources/App/View.swift"])
        // `git mv` won't create the destination folder.
        try? FileManager.default.createDirectory(at: repo.appending(path: "docs"), withIntermediateDirectories: true)
        git(repo, ["mv", "old-name.txt", "docs/new-name.txt"])
        write(repo, "docs/new-name.txt", "notes\nline two\nline three\nline four\n")
        git(repo, ["add", "docs/new-name.txt"])
        write(repo, "README.md", "# Todo\n\nA small, fast to-do app.\n\n## Build\n\n    swift build\n\n## Test\n\n    swift test\n")
        try? FileManager.default.removeItem(at: repo.appending(path: "remove-me.txt"))
        write(repo, "Sources/App/Feature.swift", "import Foundation\n\n/// Sorts items, open ones first.\nenum Sorting {\n    static func sorted(_ items: [Item]) -> [Item] {\n        items.sorted { !$0.done && $1.done }\n    }\n}\n")
        write(repo, "notes/todo.md", "- [ ] ship it\n")
        png(repo, "assets/logo.png", hue: 0.08)
        return repo
    }

    /// `feature/sorting` stopped merging `main`: Model.swift conflicts in two places, README merged
    /// cleanly (staged), and View.swift edited since (unstaged).
    static func makeMergeRepo() -> URL {
        let repo = baseRepo()
        git(repo, ["checkout", "-qb", "feature/sorting"])
        write(repo, "Sources/App/Model.swift", modelBase
            .replacingOccurrences(of: "items.append(Item(id: UUID(), title: title, done: false))",
                                  with: "items.insert(Item(id: UUID(), title: title, done: false), at: 0)")
            .replacingOccurrences(of: "items.filter { !$0.done }.count", with: "items.lazy.filter { !$0.done }.count"))
        git(repo, ["commit", "-qam", "Newest first"])
        git(repo, ["checkout", "-q", "main"])
        write(repo, "Sources/App/Model.swift", modelBase
            .replacingOccurrences(of: "items.append(Item(id: UUID(), title: title, done: false))",
                                  with: "items.append(Item(id: UUID(), title: title.trimmingCharacters(in: .whitespaces), done: false))")
            .replacingOccurrences(of: "items.filter { !$0.done }.count", with: "items.reduce(0) { $0 + ($1.done ? 0 : 1) }"))
        write(repo, "README.md", "# Todo\n\nA small to-do app.\n\n## Build\n\n    swift build -c release\n")
        git(repo, ["commit", "-qam", "Trim titles"])
        git(repo, ["checkout", "-q", "feature/sorting"])
        git(repo, ["merge", "--no-edit", "main"])
        write(repo, "Sources/App/View.swift", viewBase.replacingOccurrences(of: "Text(item.title)", with: "Text(item.title).bold()"))
        return repo
    }

    /// `BrainstormChangeSource`'s shape — one "file" whose blocks are suggestions named by their
    /// `@@` heading, "Done" for its commit, no message — held in memory, so nothing is written.
    private struct BrainstormStub: ChangeSource {
        var title: String { "Add image attachments" }
        var commitVerb: String { "Done" }
        var needsCommitMessage: Bool { false }
        private var file: String { "\(title) — brainstorm" }
        func status() async -> [StagedFile] {
            [StagedFile(path: file, change: .modified, staged: false, unstaged: true, untracked: false)]
        }
        func diff(path: String, staged: Bool, untracked: Bool) async -> String {
            """
            diff --git a/\(file) b/\(file)
            --- a/\(file)
            +++ b/\(file)
            @@ -1,0 +1,1 @@ Requirements · r1
            +Pasting an image into the description attaches it to the task
            @@ -1,0 +1,1 @@ Requirements · r2
            +Attachments show as removable pills under the editor
            @@ -1,1 +1,2 @@ Description · d1
            -Let people attach images.
            +Let people attach screenshots and diagrams to a task, by paste or drag,
            +so the agent sees them with the description.
            @@ -1,0 +1,1 @@ Labels · t1
            +ui

            """
        }
        func stageFile(path: String) async -> (ok: Bool, message: String) { (true, "") }
        func unstageFile(path: String) async -> (ok: Bool, message: String) { (true, "") }
        func discardFile(path: String, untracked: Bool) async -> (ok: Bool, message: String) { (true, "") }
        func applyHunk(patch: String, reverse: Bool, cached: Bool) async -> (ok: Bool, message: String) { (true, "") }
        func commit(message: String) async -> (ok: Bool, message: String) { (true, "") }
    }

    // MARK: Interaction

    private static func expect(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL")  \(what)")
        if !ok { failures += 1 }
    }

    private static func sel(_ list: ChangeList, _ path: String, untracked: Bool = false) -> ChangeSelection {
        ChangeSelection(path: path, staged: list == .staged, untracked: untracked, conflicted: list == .conflicts)
    }

    static func runInteraction() -> Bool {
        workingTreeChecks()
        commitAllChecks()
        mergeChecks()
        mergeShortcutChecks()
        print(failures == 0 ? "all source control interaction checks passed" : "\(failures) failed")
        return failures == 0
    }

    private static func workingTreeChecks() {
        let repo = makeDemoRepo()
        let key = repo.path
        CommitDrafts.store[key] = "Add priorities and a sorting helper"
        let probe = ProbeBox()
        let d = host(GitChangeSource(worktreePath: repo.path, title: "Demo task"), size: CGSize(width: 1180, height: 760), probe: probe)
        waitIdle(d, probe)
        let model = "Sources/App/Model.swift"
        expect(probe.state?.focused == sel(.staged, model) && probe.state?.hunks == 1,
               "opens on the first file, with its diff")
        expect(probe.state?.commitMessage == "Add priorities and a sorting helper", "an unsent message is restored")

        d.click("sc-row-staged-\(model)"); waitIdle(d, probe)
        d.key(.down); waitIdle(d, probe)
        expect(probe.state?.focused == sel(.staged, "Sources/App/View.swift"), "↓ moves to the next file")
        d.key(.up); waitIdle(d, probe)
        expect(probe.state?.focused == sel(.staged, model), "↑ moves back")

        d.click("sc-side-unstaged"); waitIdle(d, probe)
        expect(probe.state?.focused == sel(.changes, model) && probe.state?.hunks == 1,
               "a partly staged file switches to its unstaged half")
        d.click("sc-hunk-0-stage"); waitIdle(d, probe)
        expect(porcelain(repo).contains("M  \(model)"), "Stage Block stages the rest of the file")
        expect(probe.state?.focused == sel(.staged, model), "the selection follows the file into Staged")

        let feature = "Sources/App/Feature.swift"
        d.click("sc-row-changes-\(feature)"); waitIdle(d, probe)
        d.click("sc-hunk-0-stage"); waitIdle(d, probe)
        let afterStage = porcelain(repo)
        expect(afterStage.contains("A  \(feature)"), "Stage Block on a new file stages it")
        expect(!afterStage.contains { $0.contains("private/") || $0.contains("var/folders") },
               "…and nothing at its absolute path")

        let view = "Sources/App/View.swift"
        d.click("sc-row-staged-\(view)"); waitIdle(d, probe)
        d.click("sc-row-discard-staged-\(view)"); waitIdle(d, probe)
        expect(probe.confirmations.last == "Discard all changes to View.swift?", "Discard on a staged row asks first")
        expect(!porcelain(repo).contains { $0.hasSuffix(view) } && read(repo, view) == viewBase,
               "…and puts the file back to the last commit")

        expect(probe.state?.files.first { $0.path == "docs/new-name.txt" }?.origPath == "old-name.txt",
               "a staged rename is listed with its old path")
        d.click("sc-row-staged-docs/new-name.txt"); waitIdle(d, probe)
        d.key(.char(" ")); waitIdle(d, probe)

        let afterUnstage = porcelain(repo)
        expect(afterUnstage.contains(" D old-name.txt") && afterUnstage.contains("?? docs/new-name.txt")
               && !afterUnstage.contains("D  old-name.txt"),
               "Space unstages a rename — both of its paths")

        d.click("sc-row-changes-README.md"); waitIdle(d, probe)
        d.key(.delete); waitIdle(d, probe)
        expect(probe.confirmations.last == "Discard changes to README.md?", "⌫ asks to discard")
        expect(!porcelain(repo).contains(" M README.md"), "…and discards")

        d.click("sc-row-changes-assets/logo.png"); waitIdle(d, probe)
        expect(probe.state?.diffRef == sel(.changes, "assets/logo.png") && probe.state?.hunks == 0,
               "a binary file shows no blocks")
        expect(probe.state?.images == 2, "an edited image shows its before and after")

        // Something else edits the tree while the sheet is open: ⌘R, and the poll, pick it up.
        write(repo, "late.txt", "late\n")
        d.key(.char("r"), [.command]); waitIdle(d, probe)
        expect(probe.state?.files.contains { $0.path == "late.txt" } == true, "⌘R refreshes")
        write(repo, "later.txt", "later\n")
        d.settle(5); waitIdle(d, probe)
        expect(probe.state?.files.contains { $0.path == "later.txt" } == true, "the sheet refreshes on its own")

        d.click("sc-commit"); waitIdle(d, probe)
        let subject = git(repo, ["log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines)
        expect(subject == "Add priorities and a sorting helper", "⌘↩'s button commits the staged files")
        expect(probe.state?.notice?.hasPrefix("Committed ") == true && probe.state?.files.isEmpty == false,
               "with changes left, it stays open and says what it committed")
        expect(probe.state?.commitMessage == "" && CommitDrafts.store[key] == nil, "…and clears the message and its draft")
        try? FileManager.default.removeItem(at: repo)
    }

    private static func commitAllChecks() {
        let repo = makeDemoRepo()
        git(repo, ["reset", "-q"])
        CommitDrafts.store[repo.path] = "Everything"
        let probe = ProbeBox()
        let d = host(GitChangeSource(worktreePath: repo.path, title: "Demo task"), size: CGSize(width: 1180, height: 760), probe: probe)
        waitIdle(d, probe)
        expect(probe.state?.files.allSatisfy { !$0.staged } == true, "nothing staged to start")
        d.click("sc-commit"); waitIdle(d, probe)
        expect(porcelain(repo).isEmpty && git(repo, ["log", "-1", "--format=%s"]).hasPrefix("Everything"),
               "with nothing staged, the button stages everything and commits it")
        try? FileManager.default.removeItem(at: repo)
    }

    private static func mergeChecks() {
        let repo = makeMergeRepo()
        let probe = ProbeBox()
        let d = host(GitChangeSource(worktreePath: repo.path, title: "Demo task"), size: CGSize(width: 1180, height: 760), probe: probe)
        waitIdle(d, probe)
        let model = "Sources/App/Model.swift"
        expect(probe.state?.focused == sel(.conflicts, model) && probe.state?.conflicts == 2,
               "a merge opens on its conflicted file, with both conflicts")
        expect(probe.state?.merging == true && probe.state?.commitMessage == "Merge branch 'main' into feature/sorting",
               "the commit message is git's merge message")
        expect(porcelain(repo).contains("M  README.md"), "the clean part of the merge is staged")

        let head = git(repo, ["rev-parse", "HEAD"])
        d.click("sc-commit"); waitIdle(d, probe)
        expect(git(repo, ["rev-parse", "HEAD"]) == head, "no commit while a conflict is open")

        d.click("sc-conflict-0-incoming"); waitIdle(d, probe)
        expect(probe.state?.conflicts == 1 && read(repo, model)?.contains("title.trimmingCharacters(in: .whitespaces)") == true,
               "Accept Incoming resolves one conflict")
        d.click("sc-conflict-0-current"); waitIdle(d, probe)
        expect(probe.state?.conflicts == 0 && read(repo, model)?.contains("items.lazy.filter") == true,
               "Accept Current resolves the other")
        expect(probe.confirmations.isEmpty, "…without asking")
        d.click("sc-mark-resolved"); waitIdle(d, probe)
        expect(porcelain(repo).contains("M  \(model)") && probe.confirmations.isEmpty,
               "Mark Resolved stages it — no question when no markers are left")
        expect(probe.state?.focused == sel(.staged, model), "the selection follows it into Staged")

        d.click("sc-commit"); waitIdle(d, probe)
        let parents = git(repo, ["log", "-1", "--format=%P"]).split(separator: " ").count
        expect(parents == 2, "Commit Merge makes the merge commit")
        expect(probe.state?.merging == false && probe.state?.notice?.hasPrefix("Committed ") == true,
               "…and the sheet stays on the edit that is left")
        try? FileManager.default.removeItem(at: repo)
    }

    private static func mergeShortcutChecks() {
        let repo = makeMergeRepo()
        let probe = ProbeBox()
        let d = host(GitChangeSource(worktreePath: repo.path, title: "Demo task"), size: CGSize(width: 1180, height: 760), probe: probe)
        waitIdle(d, probe)
        let model = "Sources/App/Model.swift"
        d.click("sc-conflict-all-incoming"); waitIdle(d, probe)
        expect(probe.state?.conflicts == 0 && read(repo, model)?.contains("items.reduce(0)") == true,
               "Accept All Incoming resolves every conflict")
        d.click("sc-take-current"); waitIdle(d, probe)
        let ours = git(repo, ["show", "HEAD:\(model)"])
        expect(probe.confirmations.last == "Replace Model.swift with the current version?", "Use Current asks first")
        expect(read(repo, model) == ours, "…then puts this branch's whole file back")
        d.click("sc-abort-merge"); waitIdle(d, probe)
        expect(probe.confirmations.last == "Abort the merge?", "Abort Merge asks first")
        expect(probe.state?.merging == false && read(repo, model) == ours, "…and aborts it")
        try? FileManager.default.removeItem(at: repo)

        let repo2 = makeMergeRepo()
        let probe2 = ProbeBox()
        let d2 = host(GitChangeSource(worktreePath: repo2.path, title: "Demo task"), size: CGSize(width: 1180, height: 760), probe: probe2)
        waitIdle(d2, probe2)
        d2.click("sc-row-primary-conflicts-\(model)"); waitIdle(d2, probe2)
        expect(probe2.confirmations.last == "Model.swift still has conflict markers",
               "marking a file with markers resolved asks first")
        expect(porcelain(repo2).contains("M  \(model)"), "…then stages it as it is")
        try? FileManager.default.removeItem(at: repo2)
    }
}
#endif
