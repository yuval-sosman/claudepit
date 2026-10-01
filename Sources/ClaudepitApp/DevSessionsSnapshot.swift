#if DEBUG
import SwiftUI
import AppKit
import ClaudepitCore

/// Developer tool, DEBUG builds only: render the Sessions page's list card offscreen to PNG from
/// a real project's transcripts — no window, no `AppState`, and no writes (demo groups and live
/// states are made up in memory).
///
///     .build/debug/ClaudepitApp --snapshot-sessions <project path | all> --out <dir> [options]
///
///   --tab recent|groups   which tab (default recent)
///   --query text          search
///   --width N --height N  card size (default 300 × 900)
///   --demo-groups         file a few sessions under made-up groups (in memory only)
///   --demo-live           mark the newest sessions working / waiting / open
///   --select a,b          select these session ids (several → also renders the selection panel)
///   --expand id           show this session's subagents
///   --collapse name       fold this demo group
///   --hide-tasks          hide task sessions
///   --worktree name       show only this worktree's sessions (as a pill click does)
///   --no-summaries        hide the summary line
///   --new-group           show the inline new-group editor
///   --empty               render as if the project had no sessions
///   --time-scan           print cold and warm listing times and exit
///   --interaction-test    drive the list with synthetic clicks and keys (DevSessionsInteraction)
@MainActor
enum DevSessionsSnapshot {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot-sessions"), i + 1 < args.count else { return false }
        func value(_ flag: String) -> String? {
            guard let j = args.firstIndex(of: flag), j + 1 < args.count else { return nil }
            return args[j + 1]
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let base: URL? = args[i + 1] == "all" ? nil : URL(filePath: args[i + 1])
        let outDir = URL(fileURLWithPath: value("--out") ?? FileManager.default.currentDirectoryPath)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let width = CGFloat(Double(value("--width") ?? "") ?? 300)
        let height = CGFloat(Double(value("--height") ?? "") ?? 900)

        if args.contains("--time-scan") {
            var t = Date()
            _ = SessionScanner().listing(activePath: base)
            print("cold listing: \(Int(Date().timeIntervalSince(t) * 1000))ms")
            t = Date(); _ = SessionScanner().listing(activePath: base)
            print("warm listing: \(Int(Date().timeIntervalSince(t) * 1000))ms")
            exit(0)
        }
        if args.contains("--interaction-test") {
            let listing = SessionScanner().listing(activePath: base)
            let key = base.map { SessionScanner.storageKey(forPath: ProjectFolders.normalizedPath($0)) } ?? "all"
            let ok = DevSessionsInteraction.run(sessions: listing.sessions, key: key,
                                                outDir: value("--out").map { URL(fileURLWithPath: $0) })
            exit(ok ? 0 : 1)
        }
        let t0 = Date()
        var listing = SessionScanner().listing(activePath: base)
        if args.contains("--empty") { listing.sessions = [] }
        print("listed \(listing.sessions.count) sessions in \(Int(Date().timeIntervalSince(t0) * 1000))ms")

        var context = SessionListContext()
        context.projectKey = base.map { SessionScanner.storageKey(forPath: ProjectFolders.normalizedPath($0)) }
        context.groups = listing.groups
        let since = Date().addingTimeInterval(-90 * 86_400)
        context.stats = SessionStat.table(from: ProjectUsageScanner().digest(for: base, since: since))
        context.taskNames = [:]
        context.herdrAvailable = Herdr.available()
        // Live worktrees: the folders under <project>/.claude/worktrees that still exist.
        let live = base.map { b in
            ((try? FileManager.default.contentsOfDirectory(atPath: b.appending(path: ".claude/worktrees").path)) ?? [])
        } ?? []
        context.worktreeSlots = WorktreeColors.assign(live: live, previous: [:], paletteSize: WorktreePalette.colors.count)

        var sessions = listing.sessions
        if args.contains("--demo-groups"), let key = context.projectKey ?? sessions.first?.groupKey {
            let plain = sessions.filter { $0.task == nil }
            let a = SessionGroup(id: "demo-a", name: "Sessions page", color: .blue, createdAt: 0,
                                 collapsed: value("--collapse") == "Sessions page")
            let b = SessionGroup(id: "demo-b", name: "Usage & Home", color: .orange, createdAt: 0,
                                 collapsed: value("--collapse") == "Usage & Home")
            let c = SessionGroup(id: "demo-c", name: "Experiments", color: .purple, createdAt: 0)
            var pg = ProjectGroups(groups: [a, b, c])
            for s in plain.prefix(3) { pg.assignments[s.id] = a.id }
            for s in plain.dropFirst(3).prefix(2) { pg.assignments[s.id] = b.id }
            context.groups[key] = pg
            for idx in sessions.indices where sessions[idx].groupKey == key {
                sessions[idx].groupID = pg.validGroupID(for: sessions[idx].id)
            }
        }
        if args.contains("--demo-live") {
            let states = ["working", "blocked", "idle"]
            for (n, s) in sessions.prefix(3).enumerated() { context.herdrStatus[s.id] = states[n] }
        }

        var prefs = SessionListPrefs()
        prefs.tab = value("--tab") == "groups" ? .groups : .recent
        if args.contains("--hide-tasks") { prefs.showTaskSessions = false }
        if args.contains("--no-summaries") { prefs.showSummaries = false }

        let state = SessionListState()
        state.query = value("--query") ?? ""
        let selected = (value("--select") ?? "").split(separator: ",").map(String.init)
        if let first = selected.first {
            state.selection = Set(selected)
            state.primaryID = first
        }
        if let e = value("--expand") { state.expanded = [e] }
        state.worktreeFilter = value("--worktree")
        if args.contains("--new-group"), let key = context.projectKey ?? sessions.first?.groupKey {
            state.newGroup = .init(key: key, sessionIDs: [])
        }

        let card = GlassCard {
            SessionListView(sessions: sessions, context: context, prefs: .constant(prefs),
                            state: state, actions: SessionListActions())
        }
        .frame(width: width, height: height)
        .padding(12)
        .background(Color(red: 0.11, green: 0.115, blue: 0.13))
        write(card, size: CGSize(width: width + 24, height: height + 24), to: outDir.appending(path: "list.png"))

        if selected.count > 1 {
            let picked = sessions.filter { state.selection.contains($0.id) }
            let panel = GlassCard {
                SessionSelectionPanel(sessions: picked, context: context, onAssign: { _, _ in }, onNewGroup: {},
                                      onUngroup: {}, onTrash: {}, onOpen: { _ in }, onClear: {})
                    .padding(20)
            }
            .frame(width: 760, height: 560)
            .padding(12)
            .background(Color(red: 0.11, green: 0.115, blue: 0.13))
            write(panel, size: CGSize(width: 784, height: 584), to: outDir.appending(path: "selection.png"))
        }
        exit(0)
    }

    private static func write<V: View>(_ view: V, size: CGSize, to url: URL) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path) \(rep.pixelsWide)×\(rep.pixelsHigh)")
        window.orderOut(nil)
    }
}
#endif
