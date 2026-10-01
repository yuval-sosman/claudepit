#if DEBUG
import SwiftUI
import AppKit
import WebKit
import ClaudepitCore

/// Developer tool, DEBUG builds only: render the Plans, Specs, Memory, Worktrees or Loops page
/// offscreen to PNG from real files — no window, no `AppState`, and no writes. (Loops' own options
/// are in `DevLoopsSnapshot`.)
///
///     .build/debug/ClaudepitApp --snapshot-pages plans|specs|memory|worktrees|loops --out <dir> [options]
///
///   --project path        the project whose memory, specs or worktrees to show (default: the cwd)
///   --memory-dir path     read memory from this folder instead (memory)
///   --plans-dir path      read plans from here instead of ~/.claude/plans (plans)
///   --width N --height N  page size (default 1280 × 820)
///   --query text          search the list
///   --select id           select a plan (slug), spec (task id), memory file (id, or "graph") or
///                         worktree (folder name)
///   --ask                 open the Ask panel on the detail card
///   --empty               render as if there were nothing to list
///   --log-open            expand the newest memory log entries (memory)
///   --interaction-test    drive the list with synthetic clicks and keys (DevPagesInteraction)
///   --time-scan           scan the worktrees twice and print both times (worktrees)
///   --source-control      also render the selected worktree's Source Control sheet (worktrees)
///   --print-cwdmap        print the transcript-mention fallback owner of each worktree (worktrees)
@MainActor
enum DevPagesSnapshot {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot-pages"), i + 1 < args.count else { return false }
        func value(_ flag: String) -> String? {
            guard let j = args.firstIndex(of: flag), j + 1 < args.count else { return nil }
            return args[j + 1]
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let outDir = URL(fileURLWithPath: value("--out") ?? FileManager.default.currentDirectoryPath)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let size = CGSize(width: Double(value("--width") ?? "") ?? 1280, height: Double(value("--height") ?? "") ?? 820)
        let query = value("--query") ?? ""
        let empty = args.contains("--empty")

        switch args[i + 1] {
        case "plans", "specs":
            let kind: DocumentKind = args[i + 1] == "plans" ? .plan : .spec
            let t0 = Date()
            let docs: [MarkdownDoc]
            if empty {
                docs = []
            } else if kind == .plan {
                docs = MarkdownDocLoader().loadPlans(dir: value("--plans-dir").map { URL(filePath: $0) } ?? Paths.plansRoot)
            } else {
                let project = URL(filePath: value("--project") ?? FileManager.default.currentDirectoryPath)
                let root = Paths.tasksRoot(projectSlug: Paths.slug(for: project))
                docs = MarkdownDocLoader().loadSpecs(tasksRoot: root, taskNames: taskNames(in: root))
            }
            print("loaded \(docs.count) \(kind.noun)s in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            if args.contains("--interaction-test") { exit(DevPagesInteraction.runDocuments(kind, docs) ? 0 : 1) }
            let selected = value("--select").flatMap { s in docs.first { $0.tag == s } }
                ?? docs.first { $0.matches(query) }
            let page = DocumentsSnapshotPage(kind: kind, docs: docs, selection: selected?.id, query: query,
                                             ask: args.contains("--ask"))
            write(page, size: size, to: outDir.appending(path: "\(args[i + 1]).png"))
        case "memory":
            let project = URL(filePath: value("--project") ?? FileManager.default.currentDirectoryPath)
            let slug = Paths.slug(for: project)
            let t0 = Date()
            let memoryDir = value("--memory-dir").map { URL(filePath: $0) } ?? Paths.memoryDir(projectSlug: slug)
            let graph = empty ? MemoryGraph.empty : MemoryLoader.load(dir: memoryDir)
            let log = empty ? [] : MemoryLog.load(projectSlug: slug)
            print("loaded \(graph.nodes.count) memory files, \(graph.edges.count) links, \(log.count) log entries in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            for n in graph.nodes where n.isOrphan { print("  not in MEMORY.md: \(n.id)") }
            if args.contains("--interaction-test") { exit(DevPagesInteraction.runMemory(graph, log: log) ? 0 : 1) }
            let select = value("--select") ?? "graph"
            let selection: MemorySelection = select == "graph" ? .graph : .file(select)
            let page = MemorySnapshotPage(graph: graph, log: log, selection: selection, query: query,
                                          ask: args.contains("--ask"), logOpen: args.contains("--log-open"))
            write(page, size: size, to: outDir.appending(path: "memory.png"))
            if selection == .graph, !graph.nodes.isEmpty {
                writeGraph(graph, size: CGSize(width: size.width - 372, height: size.height - 150),
                           to: outDir.appending(path: "graph.png"))
            }
        case "worktrees":
            let project = URL(filePath: value("--project") ?? FileManager.default.currentDirectoryPath)
            let t0 = Date()
            let worktrees = empty ? [] : scanWorktrees(project)
            print("scanned \(worktrees.count) worktrees in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            if args.contains("--time-scan") {
                let t1 = Date()
                _ = scanWorktrees(project)
                print("rescanned (warm caches) in \(Int(Date().timeIntervalSince(t1) * 1000))ms")
            }
            let tasks = loadTasks(Paths.tasksRoot(projectSlug: Paths.slug(for: project)))
            var context = WorktreePageContext(herdrAvailable: true, hasProject: true)
            for wt in worktrees {
                let refs = WorktreeListing.tasks(in: wt.path, from: tasks).map(WorktreeTaskRef.init)
                if !refs.isEmpty { context.tasks[wt.path] = refs }
            }
            context.colorSlots = WorktreeColors.assign(live: worktrees.map(\.name), previous: [:],
                                                       paletteSize: WorktreePalette.colors.count)
            for wt in worktrees {
                print("  \(wt.name) [owner \(wt.ownerSessionID ?? "none")\(wt.ownerSubagentID.map { "/\($0)" } ?? "")]: "
                      + "\(WorktreeListing.group(of: wt).title) · \(context.activity(wt).label) · "
                      + "\(WorktreeListing.facts(of: wt).joined(separator: ", "))")
            }
            if args.contains("--interaction-test") { exit(DevPagesInteraction.runWorktrees(worktrees, context: context) ? 0 : 1) }
            let selected = value("--select").flatMap { s in worktrees.first { $0.name == s } }
                ?? worktrees.first { WorktreeListing.matches($0, query: query, taskName: context.taskNames[$0.path]) }
            let page = WorktreesSnapshotPage(worktrees: worktrees, context: context, selection: selected?.path,
                                             query: query)
            write(page, size: size, to: outDir.appending(path: "worktrees.png"), settle: 3.0)
            if args.contains("--source-control"), let wt = selected {
                // Read only: the sheet loads status and the first file's diff; nothing is clicked.
                let sheet = ReviewChangesSheet(source: GitChangeSource(worktreePath: wt.path, title: context.title(wt))) {}
                write(sheet, size: CGSize(width: size.width * 0.92, height: size.height * 0.92),
                      to: outDir.appending(path: "source-control.png"), settle: 3.0)
            }
        case "loops":
            DevLoopsSnapshot.run(args: args, outDir: outDir, size: size, query: query)
        default:
            print("unknown page \(args[i + 1]) — use plans, specs, memory, worktrees or loops")
        }
        exit(0)
    }

    /// A web view draws out of process, so `cacheDisplay` leaves the graph blank: render the same
    /// page `D3GraphView` loads, feed it the graph, and take the web view's own snapshot.
    static func writeGraph(_ graph: MemoryGraph, size: CGSize, to url: URL) {
        final class Sink: NSObject, WKScriptMessageHandler {
            func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {}
        }
        let wv = D3GraphView.makeWebView(handler: Sink())
        wv.frame = CGRect(origin: .zero, size: size)
        wv.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: wv.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = wv
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        var ready = false
        for _ in 0..<50 where !ready {
            wv.evaluateJavaScript("typeof window.loadGraph") { r, _ in ready = (r as? String) == "function" }
            spin(0.1)
        }
        guard ready else { print("graph page never loaded"); return }
        wv.evaluateJavaScript("window.loadGraph(\(D3GraphView.graphJSON(graph)))") { _, error in
            if let error { print("loadGraph failed: \(error)") }
        }
        spin(1.2)
        var image: NSImage?
        wv.takeSnapshot(with: nil) { img, _ in image = img }
        for _ in 0..<50 where image == nil { spin(0.1) }
        guard let image else { print("no graph snapshot"); return }
        let out = NSImage(size: size)
        out.lockFocus()
        NSColor(red: 0.13, green: 0.135, blue: 0.15, alpha: 1).setFill()
        CGRect(origin: .zero, size: size).fill()
        image.draw(in: CGRect(origin: .zero, size: size))
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("wrote \(url.path)")
        }
        window.orderOut(nil)
    }

    /// The project's worktrees as `AppState.reloadWorktrees` builds them — the same scan and the
    /// same merge with the session listing — awaited on the main run loop. Read only (no fetch).
    static func scanWorktrees(_ project: URL) -> [WorktreeInfo] {
        final class Box: @unchecked Sendable { var raw: WorktreeScanner.RawScan?; var done = false }
        let box = Box()
        Task.detached {
            box.raw = await WorktreeScanner().scanRaw(activePath: project)
            box.done = true
        }
        while !box.done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let raw = box.raw else { return [] }
        if CommandLine.arguments.contains("--print-cwdmap") {
            for (path, sid) in raw.cwdMap.sorted(by: { $0.key < $1.key }) {
                print("cwdmap \((path as NSString).lastPathComponent) -> \(sid)")
            }
        }
        let sessions = SessionScanner().listing(activePath: project).sessions
        return WorktreeScanner.merge(parsed: raw.parsed, dirty: raw.dirty, trackedDirty: raw.trackedDirty,
                                     ahead: raw.ahead, behind: raw.behind,
                                     merging: raw.mergeInProgress, conflicted: raw.conflicted,
                                     baseBranch: raw.baseBranch, baseRef: raw.baseRef,
                                     sessions: sessions, cwdMap: raw.cwdMap)
    }

    /// Every task, decoded straight from its task.json — no `TaskStore`, which may heal and write back.
    static func loadTasks(_ tasksRoot: URL) -> [ProjectTask] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: tasksRoot.path)) ?? []
        return ids.compactMap { id in
            guard let data = try? Data(contentsOf: tasksRoot.appending(path: id).appending(path: "task.json")) else { return nil }
            return try? JSONDecoder().decode(ProjectTask.self, from: data)
        }
    }

    /// Task names by id, read straight from each task.json — no `TaskStore`, which may heal a
    /// record on load and write it back.
    static func taskNames(in tasksRoot: URL) -> [String: String] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: tasksRoot.path)) ?? []
        var out: [String: String] = [:]
        for id in ids {
            guard let data = try? Data(contentsOf: tasksRoot.appending(path: id).appending(path: "task.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = json["name"] as? String else { continue }
            out[id] = name
        }
        return out
    }

    static func write<V: View>(_ view: V, size: CGSize, to url: URL, settle: Double = 1.5) {
        let root = view
            .padding(24)
            .frame(width: size.width, height: size.height)
            .background(Color(red: 0.11, green: 0.115, blue: 0.13))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        for _ in 0..<max(1, Int(settle / 0.15)) { RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path) \(rep.pixelsWide)×\(rep.pixelsHigh)")
        window.orderOut(nil)
    }
}

/// The Memory page as `MemorySection` lays it out (the graph itself goes to graph.png).
private struct MemorySnapshotPage: View {
    let graph: MemoryGraph
    let log: [MemoryLogEntry]
    @State var selection: MemorySelection
    @State var query: String
    let ask: Bool
    let logOpen: Bool
    @State private var reveal: MemorySelection?

    var body: some View {
        MasterDetailLayout(listWidth: 300) {
            GlassCard {
                MemoryListView(context: MemoryListContext(nodes: graph.nodes, edgeCount: graph.edges.count, log: log,
                                                          herdrAvailable: true),
                               selection: $selection, query: $query, revealRequest: $reveal,
                               actions: MemoryListActions(openFolder: {}), expandLog: logOpen)
            }
        } detail: {
            if case .file(let id) = selection, let node = graph.nodes.first(where: { $0.id == id }) {
                MemoryFileView(node: node, document: .load(node), cwd: nil, herdrAvailable: true,
                               openSession: { _ in }, initiallyAsking: ask)
            } else {
                MemoryGraphPanel(graph: graph, cwd: nil, initiallyAsking: ask)
            }
        }
    }
}

/// The Worktrees page as `WorktreesSection` lays it out. The base-sync control needs `AppState`, so
/// its slot draws a stand-in with the control's pills and state line.
private struct WorktreesSnapshotPage: View {
    let worktrees: [WorktreeInfo]
    let context: WorktreePageContext
    @State var selection: String?
    @State var query: String
    @State private var reveal: String?

    var body: some View {
        MasterDetailLayout(listWidth: 300) {
            GlassCard {
                WorktreeListView(worktrees: worktrees, context: context, selection: $selection, query: $query,
                                 revealRequest: $reveal, actions: WorktreeActions(openFolder: {}, resumeSession: { _ in },
                                                                                   openInHerdr: { _ in }))
            }
        } detail: {
            if let wt = worktrees.first(where: { $0.path == selection }) {
                WorktreeDetailView(wt: wt, context: context,
                                   session: WorktreeSessionBrief(title: "Stand-in session",
                                                                 bullets: ["Stand-in bullet one, as the summary hook writes them.",
                                                                           "Stand-in bullet two."]),
                                   actions: WorktreeActions(resumeSession: { _ in }, openInHerdr: { _ in })) {
                    VStack(alignment: .leading, spacing: 6) {
                        FlowLayout(spacing: 8) {   // as the real control lays its pills out
                            PillButton(title: "Update from \(wt.baseBranch)", icon: "arrow.down.circle",
                                       disabled: !wt.canUpdateFromBase) {}
                            if wt.trackedDirtyCount > 0 {
                                PillButton(title: "Stash & update", icon: "archivebox.circle") {}
                            }
                            PillButton(title: "Merge with Claude", icon: "sparkles") {}
                        }
                        Text(wt.isBehindBase ? "\(wt.behindCount) commits behind \(wt.baseBranch)" : "Up to date with \(wt.baseBranch)")
                            .font(.caption).foregroundStyle(wt.isBehindBase ? .orange : .secondary)
                    }
                }
            } else {
                GlassCard { PageListEmptyState(icon: "arrow.triangle.branch", title: "Select a worktree", detail: "") }
            }
        }
    }
}

/// The Plans or Specs page as `DocumentsPage` lays it out, with the state the flags asked for.
private struct DocumentsSnapshotPage: View {
    let kind: DocumentKind
    let docs: [MarkdownDoc]
    @State var selection: URL?
    @State var query: String
    let ask: Bool
    @State private var filter: TimeFilter = .all
    @State private var reveal: URL?

    var body: some View {
        MasterDetailLayout(listWidth: 300) {
            GlassCard {
                DocumentListView(kind: kind, docs: docs, now: Date(), selection: $selection, query: $query,
                                 timeFilter: $filter, revealRequest: $reveal,
                                 onTrash: kind == .plan ? { _ in } : nil, onOpenFolder: {})
            }
        } detail: {
            if let doc = docs.first(where: { $0.id == selection }) {
                DocumentDetailView(kind: kind, doc: doc, cwd: nil,
                                   openTask: kind == .spec ? {} : nil,
                                   onTrash: kind == .plan ? {} : nil,
                                   brainstorm: { _ in },
                                   initiallyAsking: ask)
            } else {
                GlassCard { PageListEmptyState(icon: kind.emptyIcon, title: "Select a \(kind.noun)", detail: "") }
            }
        }
    }
}
#endif
