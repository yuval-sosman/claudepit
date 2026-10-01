#if DEBUG
import SwiftUI
import AppKit
import ClaudepitCore

/// Developer tool, DEBUG builds only: drive the Plans, Specs and Memory lists with synthetic clicks and
/// keys in an offscreen key window (the Sessions harness's `Driver`) and check what they do —
/// click, ↑/↓, ↓ from the search box into the results, a click never scrolling the list, deep-link
/// reveals, and log links. Real files, read only; nothing on disk changes.
///
///     .build/debug/ClaudepitApp --snapshot-pages plans|specs|memory|worktrees --interaction-test [--project p]
/// Claims key status outright. A click into a window that isn't key only makes it key — the
/// content never sees it — and this offscreen window didn't reliably become key (the harness
/// must never activate the app to get there: that would steal the user's focus).
private final class AlwaysKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
}

@MainActor
enum DevPagesInteraction {
    private static var failures = 0

    private static func expect(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL")  \(what)")
        if !ok { failures += 1 }
    }

    private static func makeDriver<V: View>(_ view: V, width: CGFloat = 324, height: CGFloat = 700) -> (Driver, FrameBox) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let frames = FrameBox()
        let host = NSHostingView(rootView: view
            .environment(\.debugFrameReporter, { id, rect in frames.map[id] = rect })
            .environment(\.colorScheme, .dark))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = AlwaysKeyWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        window.makeKey()
        let d = Driver(window: window, host: host, frames: frames)
        d.settle(1.0)
        return (d, frames)
    }

    // MARK: Plans and Specs

    final class DocumentsProbe: ObservableObject {
        @Published var selection: URL?
        @Published var query = ""
        @Published var filter: TimeFilter = .all
        @Published var reveal: URL?
    }

    private struct DocumentsHost: View {
        let kind: DocumentKind
        let docs: [MarkdownDoc]
        @ObservedObject var probe: DocumentsProbe
        var body: some View {
            GlassCard {
                DocumentListView(kind: kind, docs: docs, now: Date(), selection: $probe.selection,
                                 query: $probe.query, timeFilter: $probe.filter, revealRequest: $probe.reveal,
                                 onTrash: kind == .plan ? { _ in } : nil, onOpenFolder: {})
            }
            .frame(width: 300, height: 676)
            .padding(12)
            .background(Color(red: 0.11, green: 0.115, blue: 0.13))
        }
    }

    /// The Plans and Specs lists are one view; this drives whichever `kind` it is given. Specs are
    /// fewer (one per task), so the checks that need a long list are skipped below six.
    static func runDocuments(_ kind: DocumentKind, _ docs: [MarkdownDoc]) -> Bool {
        guard docs.count >= 3 else { print("need at least 3 \(kind.noun)s, found \(docs.count)"); return false }
        let probe = DocumentsProbe()
        let (d, _) = makeDriver(DocumentsHost(kind: kind, docs: docs, probe: probe))
        // List order is newest first — the order the date sections draw.
        let o = docs.sorted { $0.modifiedAt > $1.modifiedAt }
        func row(_ doc: MarkdownDoc) -> String { "\(kind.noun)-row-\(doc.tag)" }

        d.click(row(o[1]))
        expect(probe.selection == o[1].id, "click selects a \(kind.noun)")
        d.key(.down)
        expect(probe.selection == o[2].id, "↓ moves to the next \(kind.noun)")
        d.key(.up); d.key(.up)
        expect(probe.selection == o[0].id, "↑↑ moves back two")
        d.key(.up)
        expect(probe.selection == o[0].id, "↑ at the top stays on the first \(kind.noun)")

        let before = d.scrollOffset()
        d.click(row(o[2]))
        expect(abs(d.scrollOffset() - before) < 1 && probe.selection == o[2].id, "a click selects without scrolling")

        // ⌥⌘F, not a click: a click on the field starts AppKit's text-tracking loop, which waits
        // for a mouse-up from the real event queue that a synthetic event never reaches.
        let target = o[o.count - 1]
        let word = target.title.split(separator: " ").map(String.init).first { $0.count >= 5 } ?? target.tag
        let matches = o.filter { $0.matches(word) }
        d.key(.char("f"), [.command, .option])
        d.type(word)
        expect(probe.query == word, "⌥⌘F focuses search and typing filters (“\(word)”)")
        d.key(.down)
        expect(probe.selection == matches.first?.id, "↓ from the search box selects the first match")
        if matches.count > 1 {
            d.key(.down)
            expect(probe.selection == matches[1].id, "…and ↓ then moves through the matches")
        }
        probe.query = ""
        d.settle(0.4)

        // A deep link scrolls a far document into view — only meaningful when the list overflows.
        if docs.count >= 6 {
            let far = o[o.count - 1]
            probe.selection = far.id
            probe.reveal = far.id
            d.settle(0.8)
            expect(probe.reveal == nil && d.scrollOffset() > 1, "a reveal request scrolls the linked \(kind.noun) into view")
        } else {
            print("SKIP  reveal scroll — \(docs.count) \(kind.noun)s fit without scrolling")
        }
        return failures == 0
    }

    // MARK: Memory

    final class MemoryProbe: ObservableObject {
        @Published var selection: MemorySelection = .graph
        @Published var query = ""
        @Published var reveal: MemorySelection?
    }

    private struct MemoryHost: View {
        let context: MemoryListContext
        @ObservedObject var probe: MemoryProbe
        var body: some View {
            GlassCard {
                MemoryListView(context: context, selection: $probe.selection, query: $probe.query,
                               revealRequest: $probe.reveal, actions: MemoryListActions(openFolder: {}),
                               expandLog: true)
            }
            .frame(width: 300, height: 1076)
            .padding(12)
            .background(Color(red: 0.11, green: 0.115, blue: 0.13))
        }
    }

    static func runMemory(_ graph: MemoryGraph, log: [MemoryLogEntry]) -> Bool {
        // The list's order follows the stored sort preference — read it, never write it: this
        // process shares the app's defaults.
        let sort = MemorySort(rawValue: UserDefaults.standard.string(forKey: "memoryListSort") ?? "") ?? .name
        let topics = graph.nodes.filter { !$0.isRoot && !$0.isOrphan }.sorted { a, b in
            sort == .name ? a.title.localizedStandardCompare(b.title) == .orderedAscending
                          : (a.modifiedAt ?? .distantPast) > (b.modifiedAt ?? .distantPast)
        }
        guard topics.count >= 3, graph.nodes.contains(where: \.isRoot) else {
            print("need MEMORY.md and at least 3 linked topics"); return false
        }
        let probe = MemoryProbe()
        let context = MemoryListContext(nodes: graph.nodes, edgeCount: graph.edges.count, log: log)
        let (d, frames) = makeDriver(MemoryHost(context: context, probe: probe), height: 1100)

        expect(probe.selection == .graph, "the graph is selected on arrival")
        d.click(MemoryListView.frameID(.file("MEMORY.md")))
        expect(probe.selection == .file("MEMORY.md"), "click selects the index")
        d.key(.down)
        expect(probe.selection == .file(topics[0].id), "↓ moves to the first topic")
        d.key(.up); d.key(.up)
        expect(probe.selection == .graph, "↑↑ climbs back to the graph")

        let before = d.scrollOffset()
        d.click(MemoryListView.frameID(.file(topics[1].id)))
        expect(abs(d.scrollOffset() - before) < 1 && probe.selection == .file(topics[1].id),
               "a click selects without scrolling")

        // Search reads bodies: pick a word from a topic's body that its title doesn't contain.
        let target = topics[2]
        let word = target.body.split(whereSeparator: { !$0.isLetter }).map(String.init)
            .first { $0.count >= 7 && !target.title.localizedCaseInsensitiveContains($0) } ?? target.title
        let ordered = graph.nodes.filter { $0.matches(word) }
        d.key(.char("f"), [.command, .option])
        d.type(word)
        expect(probe.query == word && !ordered.isEmpty, "typing searches every line (“\(word)”, \(ordered.count) files)")
        d.key(.down)
        if case .file(let id) = probe.selection {
            expect(graph.nodes.first { $0.id == id }?.matches(word) == true, "↓ from the search box selects a match")
        } else {
            expect(false, "↓ from the search box selects a match")
        }
        probe.query = ""
        d.settle(0.4)

        // A log entry's file link opens that file and scrolls it into view.
        // The newest entries are open; take a link that exists as a file and is on screen.
        let logged = log.prefix(2).flatMap(\.displayChanges).map(\.file)
            .filter { f in graph.nodes.contains { $0.id == f || ($0.id as NSString).lastPathComponent == (f as NSString).lastPathComponent } }
            .first { f in frames.map["log-file-\(f)"].map { $0.maxY < d.host.bounds.height - 8 && $0.height > 0 } ?? false }
        if let logged {
            d.click("log-file-\(logged)")
            if case .file(let id) = probe.selection {
                expect((id as NSString).lastPathComponent == (logged as NSString).lastPathComponent,
                       "a log entry's file link opens that file (\(logged))")
            } else {
                expect(false, "a log entry's file link opens that file (\(logged))")
            }
        } else {
            print("SKIP  no visible file link in the two newest log entries")
        }

        // A deep link to the last topic scrolls it into view.
        // Back to the top first, by a reveal: a click never scrolls, and the log link above may
        // have opened this very file (it is the newest *and* the last topic often enough).
        let last = topics[topics.count - 1]
        probe.selection = .graph
        probe.reveal = .graph
        d.settle(0.8)
        let top = d.scrollOffset()
        probe.selection = .file(last.id)
        probe.reveal = .file(last.id)
        d.settle(0.8)
        expect(probe.reveal == nil && d.scrollOffset() > top, "a reveal request scrolls the linked file into view")
        return failures == 0
    }

    // MARK: Worktrees

    final class WorktreesProbe: ObservableObject {
        @Published var selection: String?
        @Published var query = ""
        @Published var reveal: String?
        var refreshed = 0
        var sourceControl: String?
        var removed: String?
    }

    private struct WorktreesHost: View {
        let worktrees: [WorktreeInfo]
        let context: WorktreePageContext
        @ObservedObject var probe: WorktreesProbe
        var body: some View {
            GlassCard {
                WorktreeListView(worktrees: worktrees, context: context, selection: $probe.selection,
                                 query: $probe.query, revealRequest: $probe.reveal,
                                 actions: WorktreeActions(refresh: { probe.refreshed += 1 }))
            }
            .frame(width: 300, height: 676)
            .padding(12)
            .background(Color(red: 0.11, green: 0.115, blue: 0.13))
        }
    }

    private struct WorktreeDetailHost: View {
        let wt: WorktreeInfo
        let context: WorktreePageContext
        @ObservedObject var probe: WorktreesProbe
        var body: some View {
            WorktreeDetailView(wt: wt, context: context,
                               actions: WorktreeActions(sourceControl: { probe.sourceControl = $0.path },
                                                        remove: { probe.removed = $0.path })) { EmptyView() }
                .frame(width: 900, height: 676)
                .padding(12)
                .background(Color(red: 0.11, green: 0.115, blue: 0.13))
        }
    }

    /// The real worktrees plus made-up ones (the list reads no git), so there is always a list long
    /// enough to scroll and one of each group.
    static func runWorktrees(_ real: [WorktreeInfo], context: WorktreePageContext) -> Bool {
        var all = real
        all.append(WorktreeInfo(name: "demo-merging", path: "/tmp/demo/.claude/worktrees/demo-merging",
                                branch: "demo-merging", head: "aaaaaaa", isLocked: false, dirtyCount: 2, aheadCount: 1,
                                trackedDirtyCount: 2, baseBranch: "main", baseRef: "main",
                                mergeInProgress: true, conflictedFiles: ["a.swift"]))
        all.append(WorktreeInfo(name: "demo-live", path: "/tmp/demo/.claude/worktrees/demo-live",
                                branch: "demo-live", head: "bbbbbbb", isLocked: false, dirtyCount: 0, aheadCount: 0,
                                ownerSessionID: "s-live", isActive: true))
        for i in all.count..<14 {
            all.append(WorktreeInfo(name: "demo-idle-\(i)", path: "/tmp/demo/.claude/worktrees/demo-idle-\(i)",
                                    branch: "demo-idle-\(i)", head: "ccccccc", isLocked: false,
                                    dirtyCount: i % 3, aheadCount: 0, ownerSessionID: "s-\(i)"))
        }
        let probe = WorktreesProbe()
        let (d, _) = makeDriver(WorktreesHost(worktrees: all, context: context, probe: probe))
        let o = WorktreeListing.sections(all, taskNames: context.taskNames, liveAgents: context.liveAgents)
            .flatMap(\.items)
        func row(_ wt: WorktreeInfo) -> String { "worktree-row-\(wt.name)" }

        expect(o.first?.name == "demo-merging", "a merge in progress is listed first, under Needs attention")
        d.click(row(o[1]))
        expect(probe.selection == o[1].path, "click selects a worktree")
        d.key(.down)
        expect(probe.selection == o[2].path, "↓ moves to the next worktree, across a section header")
        d.key(.up); d.key(.up)
        expect(probe.selection == o[0].path, "↑↑ moves back two")
        d.key(.up)
        expect(probe.selection == o[0].path, "↑ at the top stays on the first worktree")

        let before = d.scrollOffset()
        d.click(row(o[3]))
        expect(abs(d.scrollOffset() - before) < 1 && probe.selection == o[3].path, "a click selects without scrolling")

        d.click("worktree-refresh")
        expect(probe.refreshed == 1, "the refresh button rescans")

        let word = "idle-12"
        d.key(.char("f"), [.command, .option])
        d.type(word)
        expect(probe.query == word, "⌥⌘F focuses search and typing filters (“\(word)”)")
        d.key(.down)
        expect(probe.selection == "/tmp/demo/.claude/worktrees/demo-idle-12", "↓ from the search box selects the match")
        probe.query = ""
        d.settle(0.4)

        let far = o[o.count - 1]
        d.click(row(o[0]))
        let top = d.scrollOffset()
        probe.selection = far.path
        probe.reveal = far.path
        d.settle(0.8)
        expect(probe.reveal == nil && d.scrollOffset() > top, "a reveal request scrolls the linked worktree into view")

        // The detail card's own buttons reach the page's actions.
        let target = all[all.count - 1]
        let (dd, _) = makeDriver(WorktreeDetailHost(wt: target, context: context, probe: probe), width: 924, height: 700)
        dd.click("worktree-source-control")
        expect(probe.sourceControl == target.path, "the header's Source Control button opens Source Control")
        dd.click("worktree-remove")
        expect(probe.removed == target.path, "Remove Worktree… asks to remove this worktree")
        return failures == 0
    }
}
// MARK: - Loops

extension DevPagesInteraction {
    final class LoopsProbe: ObservableObject {
        @Published var selection: LoopSelection = .overview
        @Published var query = ""
        @Published var reveal: String?
        var newLoops: [LoopDraft?] = []
        var refreshed = 0
        var stopped: [String] = []
        var resumed: [String] = []
        var submitted: [LoopDraft] = []
        var savedLoopFiles: [(scope: LoopFile.Scope, text: String, base: String?)] = []
        var trashedLoopFiles: [LoopFile.Scope] = []
    }

    private struct LoopFileHost: View {
        let project: LoopFile?
        let user: LoopFile?
        let actions: LoopActions
        var body: some View {
            LoopFileSection(project: project, user: user, projectName: "demo", actions: actions)
                .frame(width: 880)
                .frame(height: 676, alignment: .top)
                .padding(12)
                .background(Color(red: 0.11, green: 0.115, blue: 0.13))
        }
    }

    private struct LoopsHost: View {
        let context: LoopPageContext
        let actions: LoopActions
        @ObservedObject var probe: LoopsProbe
        var body: some View {
            GlassCard {
                LoopListView(context: context, selection: $probe.selection, query: $probe.query,
                             revealRequest: $probe.reveal, actions: actions)
            }
            .frame(width: 320, height: 676)
            .padding(12)
            .background(Color(red: 0.11, green: 0.115, blue: 0.13))
        }
    }

    private struct LoopDetailHost: View {
        let record: LoopRecord
        let context: LoopPageContext
        let actions: LoopActions
        var body: some View {
            LoopDetailView(record: record, context: context, actions: actions)
                .frame(width: 900, height: 676)
                .padding(12)
                .background(Color(red: 0.11, green: 0.115, blue: 0.13))
        }
    }

    static func runLoops(_ base: LoopPageContext) -> Bool {
        var context = base
        let probe = LoopsProbe()
        var actions = LoopActions()
        actions.newLoop = { probe.newLoops.append($0) }
        actions.refresh = { probe.refreshed += 1 }
        actions.stop = { probe.stopped.append($0.id) }
        actions.resume = { probe.resumed.append($0.id) }
        actions.copy = { _ in }
        actions.saveLoopFile = { scope, text, base, _ in probe.savedLoopFiles.append((scope, text, base)) }
        actions.trashLoopFile = { probe.trashedLoopFiles.append($0.scope) }
        let order = LoopListing.sections(context.records).flatMap(\.items)
        guard order.count >= 4 else { print("need at least 4 loops"); return false }
        func row(_ r: LoopRecord) -> String { "loop-row-\(r.id)" }

        // The list.
        let (d, _) = makeDriver(LoopsHost(context: context, actions: actions, probe: probe))
        expect(d.exists("loop-row-overview"), "the overview entry is listed")
        d.click(row(order[1]))
        expect(probe.selection == .loop(order[1].id), "click selects a loop")
        d.key(.down)
        expect(probe.selection == .loop(order[2].id), "↓ moves to the next loop, across a section header")
        d.key(.up); d.key(.up); d.key(.up)
        expect(probe.selection == .overview, "↑ past the first loop reaches the overview")
        let before = d.scrollOffset()
        d.click(row(order[3]))
        expect(abs(d.scrollOffset() - before) < 1 && probe.selection == .loop(order[3].id), "a click selects without scrolling")
        d.click("loop-new")
        expect(probe.newLoops.count == 1 && probe.newLoops[0] == nil, "the + button opens New Loop, empty")
        d.click("loop-refresh")
        expect(probe.refreshed == 1, "the refresh button rescans")
        let target = order.first { $0.kind == .selfPaced } ?? order[0]
        let word = String(target.title.split(separator: " ").first ?? "x")
        d.key(.char("f"), [.command, .option])
        d.type(word)
        expect(probe.query == word, "⌥⌘F focuses search and typing filters (“\(word)”)")
        d.key(.down)
        let firstMatch = LoopListing.sections(context.records, query: word).first?.items.first
        expect(firstMatch.map { probe.selection == .loop($0.id) } ?? false, "↓ from the search box selects the first match")
        probe.query = ""
        d.settle(0.4)
        let far = order[order.count - 1]
        d.click("loop-row-overview")
        let top = d.scrollOffset()
        probe.selection = .loop(far.id)
        probe.reveal = far.id
        d.settle(0.8)
        expect(probe.reveal == nil && d.scrollOffset() > top, "a reveal request scrolls the linked loop into view")

        // The detail card's header.
        let active = order.first { $0.state.isActive && $0.sessionID != nil }!
        context.herdrTargets[active.sessionID!] = "w3:p9"
        let (dd, _) = makeDriver(LoopDetailHost(record: active, context: context, actions: actions), width: 924, height: 700)
        dd.click("loop-run-again")
        let seed = probe.newLoops.last ?? nil
        expect(seed?.taskText == LoopDraft(record: active).taskText && seed != nil, "Duplicate opens New Loop filled from this loop")
        dd.click("loop-stop")
        expect(probe.stopped == [active.id], "Stop asks to stop this loop when its session is in herdr")
        if let paused = order.first(where: { $0.state == .paused }) {
            let (dp, _) = makeDriver(LoopDetailHost(record: paused, context: context, actions: actions), width: 924, height: 700)
            expect(!dp.exists("loop-stop"), "a paused loop offers no Stop")
            dp.click("loop-resume")
            expect(probe.resumed == [paused.id], "Resume resumes a paused loop's session")
            if case .maintenance = paused.promptKind {
                // Not clicked: it sits below the fold, where a synthetic click lands on selectable
                // prompt text and AppKit's tracking loop waits forever for a mouse-up.
                expect(dp.exists("loop-manage-loopfile"), "a maintenance loop's card links to the overview's loop.md card")
            }
        }

        // The overview's loop.md card: start, delete, edit/cancel, and writing a new one.
        let template = LoopFile.template + "\n"
        let projectFile = LoopFile(scope: .project, url: URL(filePath: "/demo/.claude/loop.md"), size: template.utf8.count,
                                   modifiedAt: Date(), text: template)
        let (dl, _) = makeDriver(LoopFileHost(project: projectFile, user: nil, actions: actions), width: 904, height: 700)
        dl.click("loopfile-start")
        expect((probe.newLoops.last ?? nil)?.task == .defaultPrompt, "Start Loop opens New Loop for a bare /loop")
        dl.click("loopfile-delete")
        expect(probe.trashedLoopFiles == [.project], "Delete asks to move this project's loop.md to the Trash")
        // Frames are reported on appear and never withdrawn, so each step forgets the others first:
        // what `exists` sees afterwards is what's on screen now.
        func step(_ id: String) {
            let r = dl.frames.map[id]
            dl.frames.map.removeAll()
            dl.frames.map[id] = r
            dl.click(id)
        }
        step("loopfile-edit")
        expect(dl.exists("loopfile-editor") && !dl.exists("loopfile-ask"), "Edit opens the editor in place")
        dl.click("loopfile-save")
        expect(probe.savedLoopFiles.isEmpty, "Save is off while nothing changed")
        step("loopfile-cancel")
        expect(!dl.exists("loopfile-editor") && dl.exists("loopfile-ask"), "Cancel closes the editor, writing nothing")
        step("loopfile-ask")
        expect(dl.exists("loopfile-ask-done") && !dl.exists("loopfile-edit"), "Ask opens the questions panel in place")
        step("loopfile-ask-done")
        expect(dl.exists("loopfile-edit"), "Done closes it")

        let (dn, _) = makeDriver(LoopFileHost(project: nil, user: nil, actions: actions), width: 904, height: 700)
        expect(!dn.exists("loopfile-delete") && !dn.exists("loopfile-start"), "no file: nothing to delete or start")
        dn.click("loopfile-write")
        dn.click("loopfile-save")
        let wrote = probe.savedLoopFiles.last
        expect(wrote?.scope == .project && wrote?.text == template && wrote?.base == nil,
               "Write One… then Create writes the template as a new project loop.md (got \(String(describing: wrote)))")

        // The New Loop dialog: type, pick with chips and fixes, choose where, submit.
        let ctx = NewLoopContext(capabilities: context.snapshot.capabilities, herdrAvailable: true,
                                 targets: [("w3:p1", "claudepit-ca", "idle")], hasProject: true, projectName: "demo")
        let submit: (LoopDraft) async -> Bool = { draft in probe.submitted.append(draft); return true }
        let (ds, _) = makeDriver(NewLoopSheet(context: ctx, onSubmit: submit), width: 1040, height: 820)
        ds.click("loop-submit")
        expect(probe.submitted.isEmpty, "submit is off with no prompt")
        ds.type("watch the deploy")
        ds.click("loop-chip-5m")
        ds.click("loop-dest-copy")
        ds.click("loop-submit", after: 0.6)
        let first = probe.submitted.last
        expect(first?.message() == "/loop 5m watch the deploy" && first?.destination == .copy,
               "typing, a 5m chip and Copy submit “/loop 5m watch the deploy” (got \(first?.message() ?? "nothing"))")

        var uneven = LoopDraft()
        uneven.task = .prompt("check CI")
        uneven.cadence = .interval(LoopInterval(7, .m))
        let (du, _) = makeDriver(NewLoopSheet(context: ctx, seed: uneven, onSubmit: submit), width: 1040, height: 700)
        du.click("loop-fix-10m")
        du.click("loop-submit", after: 0.6)
        expect(probe.submitted.last?.message() == "/loop 10m check CI", "the uneven-interval fix picks 10m")

        var pitfall = LoopDraft()
        pitfall.task = .prompt("run the tests every 5 minutes")
        pitfall.cadence = .selfPaced
        let (dpf, _) = makeDriver(NewLoopSheet(context: ctx, seed: pitfall, onSubmit: submit), width: 1040, height: 700)
        dpf.click("loop-fix-Use every 5m")
        dpf.click("loop-submit", after: 0.6)
        expect(probe.submitted.last.map { if case .interval(let i) = $0.cadence { return i == LoopInterval(5, .m) }; return false } == true,
               "a self-paced prompt ending in “every 5 minutes” is offered the interval")

        var manual = LoopDraft()
        manual.task = .prompt("sweep")
        manual.permissionMode = "manual"
        let (dm, _) = makeDriver(NewLoopSheet(context: ctx, seed: manual, onSubmit: submit), width: 1040, height: 700)
        dm.click("loop-fix-Use Auto")
        dm.click("loop-submit", after: 0.6)
        expect(probe.submitted.last?.permissionMode == "auto" && probe.submitted.last?.destination == .newSession,
               "the permission fix switches a new session to Auto")

        // Agents: a mention's fix hands each fire to the agent; the guard is a checkbox; a session
        // run as an agent without CronCreate can't start until it runs as no agent.
        let agentCtx = NewLoopContext(capabilities: context.snapshot.capabilities, herdrAvailable: true,
                                      agents: [LoopAgent(name: "code-reviewer", model: "sonnet", tools: ["Read", "Grep"], scope: "project"),
                                               LoopAgent(name: "pr-watcher", tools: ["Read", "Bash"], scope: "user")],
                                      targets: [("w3:p1", "claudepit-ca", "idle")], hasProject: true, projectName: "demo")
        var mention = LoopDraft()
        mention.task = .prompt("@agent-code-reviewer look at the auth changes")
        let (dme, _) = makeDriver(NewLoopSheet(context: agentCtx, seed: mention, onSubmit: submit), width: 1040, height: 700)
        dme.click("loop-fix-Hand each fire to code-reviewer")
        dme.click("loop-submit", after: 0.6)
        expect(probe.submitted.last?.task == .agent(name: "code-reviewer", task: "look at the auth changes", skipWhileRunning: true),
               "the mention's fix hands each fire to the agent (got \(String(describing: probe.submitted.last?.task)))")

        var delegating = LoopDraft()
        delegating.task = .agent(name: "code-reviewer", task: "review the diff", skipWhileRunning: true)
        let (dag, _) = makeDriver(NewLoopSheet(context: agentCtx, seed: delegating, onSubmit: submit), width: 1040, height: 700)
        dag.click("loop-agent-skip")
        dag.click("loop-submit", after: 0.6)
        expect(probe.submitted.last?.message() == "/loop 10m Use the code-reviewer subagent to review the diff.",
               "unticking the guard drops it from the message (got \(probe.submitted.last?.message() ?? "nothing"))")

        var runAs = LoopDraft()
        runAs.task = .prompt("check CI")
        runAs.sessionAgent = "pr-watcher"
        let (dra, _) = makeDriver(NewLoopSheet(context: agentCtx, seed: runAs, onSubmit: submit), width: 1040, height: 700)
        let sent = probe.submitted.count
        dra.click("loop-submit", after: 0.4)
        expect(probe.submitted.count == sent, "a session agent without CronCreate blocks Start")
        dra.click("loop-fix-Run as no agent")
        dra.click("loop-submit", after: 0.6)
        expect(probe.submitted.count == sent + 1 && probe.submitted.last?.sessionAgent == nil
               && probe.submitted.last?.claudeArguments(sessionID: "s").contains("--agent") == false,
               "its fix runs the session as no agent")

        var background = LoopDraft()
        background.task = .prompt("check CI")
        background.destination = .copy
        let (dbg, _) = makeDriver(NewLoopSheet(context: agentCtx, seed: background, onSubmit: submit), width: 1040, height: 760)
        dbg.click("loop-dest-background")
        dbg.click("loop-submit", after: 0.6)
        expect(probe.submitted.last?.destination == .background
               && probe.submitted.last?.backgroundArguments(message: "m").first == "--bg",
               "the background row submits a claude --bg launch (got \(String(describing: probe.submitted.last?.destination)))")
        print(failures == 0 ? "all loops interaction checks passed" : "\(failures) loops interaction check(s) failed")
        return failures == 0
    }
}
#endif
