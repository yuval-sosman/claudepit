#if DEBUG
import SwiftUI
import AppKit
import ClaudepitCore

/// Developer tool, DEBUG builds only: drive the Sessions list with synthetic clicks and keys in an
/// offscreen key window and check what it does — selection, keyboard, multi-select, groups,
/// inline naming, trash confirmation. Real transcripts; groups and every action are in memory,
/// so nothing on disk changes.
///
///     .build/debug/ClaudepitApp --snapshot-sessions <project path> --interaction-test [--out dir]
@MainActor
enum DevSessionsInteraction {
    static func run(sessions: [SessionSummary], key: String, outDir: URL?) -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = InteractionModel(sessions: sessions, key: key)
        let state = SessionListState()
        let frames = FrameBox()
        let host = NSHostingView(rootView: InteractionHost(model: model, state: state)
            .environment(\.debugFrameReporter, { id, rect in frames.map[id] = rect })
            .environment(\.colorScheme, .dark))
        host.frame = CGRect(x: 0, y: 0, width: 324, height: 924)
        let window = KeyableWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        window.makeKey()
        let d = Driver(window: window, host: host, frames: frames)
        d.settle(1.0)

        var failures = 0
        func expect(_ ok: Bool, _ what: String) {
            print("\(ok ? "PASS" : "FAIL")  \(what)")
            if !ok { failures += 1 }
        }
        func order() -> [String] {
            SessionListModel(sessions: model.sessions, context: model.context, prefs: model.prefs,
                             query: state.query, includeDate: state.timeFilter.includes, expanded: state.expanded,
                             worktree: state.worktreeFilter).order
        }
        func snap(_ name: String) {
            guard let outDir else { return }
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            d.capture(to: outDir.appending(path: "\(name).png"))
        }

        let o = order().filter { !$0.contains("/") }
        guard o.count >= 6 else { print("need at least 6 sessions"); return false }

        // Selection follows the first row on arrival.
        expect(state.primaryID == order().first, "first row selected on appear")

        // Click, then arrows.
        d.click("session-row-\(o[2])")
        expect(state.selection == [o[2]] && state.primaryID == o[2], "click selects one row")
        d.key(.down)
        expect(state.selection == [o[3]], "↓ moves the selection")
        d.key(.up); d.key(.up)
        expect(state.selection == [o[1]], "↑↑ moves back two")
        d.key(.down, [.shift]); d.key(.down, [.shift])
        expect(state.selection == Set(o[1...3]) && state.primaryID == o[3], "⇧↓⇧↓ extends a range")
        snap("range")
        d.key(.escape)
        expect(state.selection == [o[3]], "Esc collapses to the focused row")

        // Modifier clicks.
        d.click("session-row-\(o[0])", [.command])
        expect(state.selection == [o[0], o[3]], "⌘-click adds a row")
        d.click("session-row-\(o[3])", [.command])
        expect(state.selection == [o[0]], "⌘-click removes a row")
        d.click("session-row-\(o[2])", [.shift])
        expect(state.selection == Set(o[0...2]), "⇧-click selects the range from the anchor")
        d.key(.char("a"), [.command])
        expect(state.selection == Set(order().filter { !$0.contains("/") }), "⌘A selects every visible session")

        // Trash asks first, and never for a live session.
        d.click("session-row-\(o[1])")
        d.key(.delete)   // the physical Delete key: U+007F, keyCode 51
        expect(state.pendingTrash?.map(\.id) == [o[1]], "⌫ asks to trash the selection")
        state.pendingTrash = nil
        d.settle(0.3)
        expect(model.log.filter { $0.hasPrefix("trash") }.isEmpty, "nothing trashed without confirming")

        // Subagents: → opens, ← closes.
        if let parent = model.sessions.first(where: { !$0.subagents.isEmpty && o.prefix(12).contains($0.id) }) {
            d.click("session-row-\(parent.id)")
            d.key(.right)
            expect(state.expanded.contains(parent.id), "→ shows subagents")
            d.key(.down)
            expect(state.primaryID?.hasPrefix(parent.id + "/") == true, "↓ steps into the first subagent")
            d.key(.left)
            expect(state.primaryID == parent.id, "← from a subagent returns to its session")
            d.key(.left)
            expect(!state.expanded.contains(parent.id), "← again hides the subagents")
        } else {
            print("SKIP  no session with subagents near the top")
        }

        // Clicking a row never scrolls the list.
        let before = d.scrollOffset()
        d.click("session-row-\(o[5])")
        expect(abs(d.scrollOffset() - before) < 1, "a click leaves the list where it is")

        // Groups: create inline from a selection, reject a duplicate, rename, fold.
        model.prefs.tab = .groups
        state.select(o[0])
        d.settle(0.5)
        expect(d.exists("header-ungrouped") || d.exists("header-caption-tasks"), "Groups tab shows its sections")
        state.newGroup = .init(key: key, sessionIDs: [o[0], o[1]])
        d.settle(0.5)
        d.type("Alpha"); d.key(.return)
        let alpha = model.groups[key]?.groups.first { $0.name == "Alpha" }
        expect(alpha != nil && state.newGroup == nil, "typing a name + Return creates the group")
        expect(model.sessions.filter { $0.groupID == alpha?.id }.count == 2, "…and files the selected sessions in it")
        snap("group-created")
        state.newGroup = .init(key: key, sessionIDs: [])
        d.settle(0.5)
        d.type("alpha"); d.key(.return)
        expect(state.newGroup != nil && model.groups[key]?.groups.count == 1, "a duplicate name is refused, editor stays open")
        snap("duplicate")
        d.key(.escape)
        expect(state.newGroup == nil, "Esc cancels the editor")
        if let alpha {
            d.click("group-name-\(alpha.id)", count: 2, after: 0.6)
            expect(state.renamingGroupID == alpha.id, "double-clicking the name starts a rename")
            d.selectAll(); d.type("Beta"); d.key(.return)
            expect(model.groups[key]?.groups.first?.name == "Beta" && state.renamingGroupID == nil, "Return renames")
            expect(model.groups[key]?.groups.first?.isCollapsed == false, "the double-click did not fold the group")
            d.click("header-group-\(alpha.id)", after: 0.8)
            expect(model.groups[key]?.groups.first?.isCollapsed == true, "clicking the header folds the group")
            d.click("header-group-\(alpha.id)", after: 0.8)
            expect(model.groups[key]?.groups.first?.isCollapsed == false, "…and again unfolds it")
        }

        // Menus: what each would show, and what each item does. (A SwiftUI Menu can't be opened
        // offscreen; the "…" and right-click menus both render exactly these entries.)
        var copied: [String] = []
        var newGroupFor: [[String]] = []
        func menus() -> SessionListMenus {
            var m = SessionListMenus(sessions: model.sessions, context: model.context, state: state,
                                     actions: model.actions, startNewGroup: { newGroupFor.append($0) })
            m.copy = { copied.append($0) }
            return m
        }
        func s(_ id: String) -> SessionSummary { model.sessions.first { $0.id == id }! }
        func run(_ e: MenuEntry?) { if case let .button(_, _, _, _, _, action)? = e { action() }; d.settle(0.2) }
        func enabled(_ e: MenuEntry?) -> Bool { if case let .button(_, _, _, on, _, _)? = e { return on }; return false }
        func checked(_ e: MenuEntry?) -> Bool { if case let .button(_, _, c, _, _, _)? = e { return c }; return false }
        func children(_ e: MenuEntry?) -> [MenuEntry] { if case let .submenu(_, c)? = e { return c }; return [] }
        if let group = model.groups[key]?.groups.first {
            state.select(o[0])
            var menu = menus().session([s(o[0])])
            let move = menu.entry("Move to Group")
            expect(checked(children(move).entry(group.name)) && !enabled(children(move).entry(group.name)),
                   "menu: the current group is checked and not offered again")
            expect(menu.entry("Open Transcript") != nil && menu.entry("Remove from Group") != nil,
                   "menu: a grouped session offers Open Transcript and Remove from Group")
            run(menu.entry("Copy Session ID"))
            expect(copied.last == o[0], "menu: Copy Session ID copies the id")
            run(menu.entry("New Group…"))
            expect(newGroupFor.last == [o[0]], "menu: New Group… opens the editor for this session")
            run(menu.entry("Remove from Group"))
            expect(s(o[0]).groupID == nil, "menu: Remove from Group ungroups it")
            menu = menus().session([s(o[0])])
            run(children(menu.entry("Move to Group")).entry(group.name))
            expect(s(o[0]).groupID == group.id, "menu: Move to Group files it")
            // A session that isn't running (the newest is often this very session, live).
            if let quiet = o.first(where: { model.context.status(of: s($0)) == .none }) {
                run(menus().session([s(quiet)]).entry("Move to Trash…"))
                expect(state.pendingTrash?.map(\.id) == [quiet], "menu: Move to Trash… asks first")
                state.pendingTrash = nil
            }

            model.herdr[o[2]] = "working"
            d.settle(0.2)
            menu = menus().session([s(o[2])])
            expect(menu.entry("Move to Trash…") == nil && menu.entry("Can't Trash a Running Session") != nil,
                   "menu: a running session can't be trashed, and says why")
            model.herdr = [:]

            state.selection = [o[0], o[3]]; state.primaryID = o[3]
            let both = menus().targets(for: s(o[0]))
            expect(Set(both.map(\.id)) == [o[0], o[3]], "menu: a row in the selection acts on the whole selection")
            expect(menus().targets(for: s(o[5])).map(\.id) == [o[5]], "menu: a row outside it acts on just that row")
            menu = menus().session(both)
            let movable = both.filter { model.context.status(of: $0) == .none }.count
            expect(menu.first?.title == "2 Sessions" && menu.entry("Move \(movable) to Trash…") != nil,
                   "menu: a multi-selection says so, counting only sessions that can go")
            run(children(menu.entry("Move to Group")).entry("New Group from Selection…"))
            expect(Set(newGroupFor.last ?? []) == [o[0], o[3]], "menu: New Group from Selection takes them all")

            let only = model.groups[key]!.groups.first!
            let gmenu = menus().group(key: key, group: only, count: 1, isFirst: true, isLast: true)
            expect(!enabled(gmenu.entry("Move Up")) && !enabled(gmenu.entry("Move Down")), "group menu: a lone group can't move")
            expect(children(gmenu.entry("Color")).count == GroupColor.allCases.count &&
                   checked(children(gmenu.entry("Color")).entry(only.color.rawValue.capitalized)),
                   "group menu: every colour, the current one checked")
            run(children(gmenu.entry("Color")).entry("Purple"))
            expect(model.groups[key]?.groups.first?.color == .purple, "group menu: Color recolours")
            run(gmenu.entry("Rename…"))
            expect(state.renamingGroupID == only.id, "group menu: Rename… starts the inline rename")
            d.key(.escape)
            run(gmenu.entry("Delete Group…"))
            expect(state.pendingGroupDelete?.group.id == only.id, "group menu: Delete Group… asks first")
            state.pendingGroupDelete = nil

            // Drops: the logic behind `.dropDestination` on each section.
            model.prefs.tab = .groups
            d.settle(0.3)
            let sections = SessionListModel(sessions: model.sessions, context: model.context, prefs: model.prefs,
                                            query: "", includeDate: { _ in true }, expanded: []).sections
            let payload = [SessionDragPayload.encode([o[4]])]
            if let target = sections.first(where: { $0.dropGroup?.id == only.id }) {
                expect(SessionListMenus.drop(payload, into: target, actions: model.actions) && s(o[4]).groupID == only.id,
                       "drop: onto a group files the dragged sessions")
            } else { expect(false, "drop: the group section accepts drops") }
            if let ungrouped = sections.first(where: { $0.dropUngroups }) {
                expect(SessionListMenus.drop(payload, into: ungrouped, actions: model.actions) && s(o[4]).groupID == nil,
                       "drop: onto Ungrouped takes them out of their group")
                expect(!SessionListMenus.drop(["plain text"], into: ungrouped, actions: model.actions),
                       "drop: plain text is refused")
            } else { expect(false, "drop: Ungrouped accepts drops") }
            var recent = model.prefs; recent.tab = .recent
            if let day = SessionListModel(sessions: model.sessions, context: model.context, prefs: recent, query: "",
                                          includeDate: { _ in true }, expanded: []).sections.first {
                expect(!SessionListMenus.drop(payload, into: day, actions: model.actions), "drop: a date section takes none")
            }
        }

        // A worktree pill filters the list to that worktree; a second click clears it.
        model.prefs.tab = .recent
        d.settle(0.4)
        if let wtSession = model.sessions.first(where: { model.context.worktree(of: $0) != nil && d.exists("worktree-pill-\($0.id)") }),
           let wt = model.context.worktree(of: wtSession) {
            d.click("worktree-pill-\(wtSession.id)")
            let shown = order().filter { !$0.contains("/") }
            expect(state.worktreeFilter == wt, "clicking a worktree pill filters to that worktree")
            expect(!shown.isEmpty && shown.allSatisfy { id in model.context.worktree(of: model.sessions.first { $0.id == id }!) == wt },
                   "…and only that worktree's sessions are listed (\(shown.count))")
            d.click("worktree-pill-\(wtSession.id)")
            expect(state.worktreeFilter == nil, "clicking it again shows everything")
        } else {
            print("SKIP  no worktree session on screen")
        }

        // The + button opens the inline editor.
        model.prefs.tab = .groups
        d.settle(0.3)
        d.click("new-group-button")
        expect(state.newGroup != nil, "+ opens a new-group editor")
        d.key(.escape)

        // ⌥⌘F → search; typing filters; ↓ moves into the results.
        model.prefs.tab = .recent
        state.select(o[0])
        d.settle(0.3)
        d.key(.char("f"), [.command, .option])
        let word = model.sessions.first { $0.id == o[3] }?.title.split(separator: " ").first.map(String.init) ?? "a"
        d.type(word)
        expect(state.query == word, "⌥⌘F focuses search and typing fills it")
        d.key(.down)
        let firstMatch = order().first
        expect(firstMatch != nil && state.primaryID == firstMatch, "↓ from the search field selects the first match")
        state.query = ""
        d.settle(0.3)

        // Drag payloads round-trip, and plain text is never read as sessions.
        expect(SessionDragPayload.decode([SessionDragPayload.encode([o[0], o[1]])]) == [o[0], o[1]], "drag payload round-trips")
        expect(SessionDragPayload.decode(["just some text\nmore"]).isEmpty, "a plain-text drop is ignored")

        // A deep link reveals a row hidden by a search.
        model.prefs.tab = .recent
        state.query = "zzzz-no-such-session"
        d.settle(0.4)
        state.revealRequest = o[4]
        d.settle(0.6)
        expect(state.query.isEmpty && state.primaryID == o[4], "a deep link clears the search that hid its row")

        print(failures == 0 ? "interaction: all passed" : "interaction: \(failures) failed")
        return failures == 0
    }
}

/// In-memory stand-in for `AppState`'s session and group state.
@MainActor
private final class InteractionModel: ObservableObject {
    @Published var sessions: [SessionSummary]
    @Published var groups: [String: ProjectGroups] = [:]
    @Published var prefs = SessionListPrefs()
    @Published var herdr: [String: String] = [:]
    let key: String
    var log: [String] = []

    init(sessions: [SessionSummary], key: String) {
        self.sessions = sessions.map { var s = $0; s.groupKey = key; s.groupID = nil; return s }
        self.key = key
        groups[key] = ProjectGroups()
    }

    var context: SessionListContext {
        var c = SessionListContext()
        c.projectKey = key
        c.groups = groups
        c.herdrStatus = herdr
        return c
    }

    private func edit(_ change: (inout ProjectGroups) -> Void) {
        var pg = groups[key] ?? ProjectGroups()
        change(&pg)
        groups[key] = pg
        for i in sessions.indices { sessions[i].groupID = pg.validGroupID(for: sessions[i].id) }
    }

    var actions: SessionListActions {
        var a = SessionListActions()
        a.openTranscript = { [unowned self] in self.log.append("open \($0.id)") }
        a.createGroup = { [unowned self] name, _, ids in
            switch SessionGroup.validatedName(name, among: self.groups[self.key]?.groups ?? []) {
            case .failure(let e): return .failure(e)
            case .success(let n):
                let g = SessionGroup(id: UUID().uuidString, name: n, color: .blue, createdAt: 0)
                self.edit { pg in pg.groups.append(g); for id in ids { pg.assignments[id] = g.id } }
                self.log.append("create \(n)")
                return .success(g)
            }
        }
        a.renameGroup = { [unowned self] id, name, _ in
            switch SessionGroup.validatedName(name, among: self.groups[self.key]?.groups ?? [], excluding: id) {
            case .failure(let e): return e
            case .success(let n):
                self.edit { pg in if let i = pg.groups.firstIndex(where: { $0.id == id }) { pg.groups[i].name = n } }
                return nil
            }
        }
        a.setGroupCollapsed = { [unowned self] id, collapsed, _ in
            self.edit { pg in if let i = pg.groups.firstIndex(where: { $0.id == id }) { pg.groups[i].collapsed = collapsed } }
        }
        a.recolorGroup = { [unowned self] id, color, _ in
            self.edit { pg in if let i = pg.groups.firstIndex(where: { $0.id == id }) { pg.groups[i].color = color } }
        }
        a.assign = { [unowned self] ids, gid, _ in self.edit { pg in for id in ids { pg.assignments[id] = gid } } }
        a.unassign = { [unowned self] ids in self.edit { pg in for id in ids { pg.assignments.removeValue(forKey: id) } } }
        a.trash = { [unowned self] in self.log.append("trash \($0.map(\.id))") }
        return a
    }
}

private struct InteractionHost: View {
    @ObservedObject var model: InteractionModel
    @ObservedObject var state: SessionListState

    var body: some View {
        GlassCard {
            SessionListView(sessions: model.sessions, context: model.context, prefs: $model.prefs,
                            state: state, actions: model.actions)
        }
        .frame(width: 300, height: 900)
        .padding(12)
        .background(Color(red: 0.11, green: 0.115, blue: 0.13))
    }
}

/// A borderless window refuses key status by default; key events need it.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Synthetic input against an offscreen window, targeting views by the frames they report.
/// Row frames as the views report them (always on the main thread).
private final class FrameBox: @unchecked Sendable { var map: [String: CGRect] = [:] }

@MainActor
private struct Driver {
    let window: NSWindow
    let host: NSView
    let frames: FrameBox

    enum Key {
        case up, down, left, right, delete, escape, `return`, char(Character)
        var code: UInt16 {
            switch self {
            case .up: return 126; case .down: return 125; case .left: return 123; case .right: return 124
            case .delete: return 51; case .escape: return 53; case .return: return 36; case .char: return 0
            }
        }
        var chars: String {
            func scalar(_ v: Int) -> String { String(Character(UnicodeScalar(v)!)) }
            switch self {
            case .up: return scalar(NSUpArrowFunctionKey); case .down: return scalar(NSDownArrowFunctionKey)
            case .left: return scalar(NSLeftArrowFunctionKey); case .right: return scalar(NSRightArrowFunctionKey)
            case .delete: return "\u{7F}"; case .escape: return "\u{1B}"; case .return: return "\r"
            case .char(let c): return String(c)
            }
        }
    }

    func settle(_ seconds: Double = 0.25) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }

    func key(_ k: Key, _ flags: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: k.chars, charactersIgnoringModifiers: k.chars,
                                           isARepeat: false, keyCode: k.code) else { continue }
            deliver(e)
        }
        settle(0.2)
    }

    func type(_ text: String) { for c in text { key(.char(c)) } }

    func selectAll() { key(.char("a"), [.command]) }

    func exists(_ id: String) -> Bool { frames.map[id] != nil }

    /// `frame(in: .global)` is top-left origin within the window; events want bottom-left.
    func click(_ id: String, _ flags: NSEvent.ModifierFlags = [], count: Int = 1, after: Double = 0.35) {
        guard let r = frames.map[id], r.height > 0 else {
            print("  (no element \(id) on screen)")
            return
        }
        let p = NSPoint(x: r.midX, y: host.bounds.height - r.midY)
        for n in 1...count {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags,
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: n, pressure: 1) else { continue }
                deliver(e)
            }
            settle(0.05)
        }
        settle(after)
    }

    /// Straight to the window. (Posting to the app queue and pumping `nextEvent` delivered
    /// nothing to this offscreen, never-activated window.)
    func deliver(_ e: NSEvent) { window.sendEvent(e) }

    func clickAt(_ id: String, xFraction: CGFloat, after: Double) {
        guard let r = frames.map[id] else { print("  (no element \(id))"); return }
        let p = NSPoint(x: r.minX + r.width * xFraction, y: host.bounds.height - r.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            deliver(e)
        }
        settle(after)
    }

    /// The list's scroll offset (the first scroll view under the host).
    func scrollOffset() -> CGFloat {
        func find(_ v: NSView) -> NSScrollView? {
            if let s = v as? NSScrollView, s.documentView != nil { return s }
            for sub in v.subviews { if let s = find(sub) { return s } }
            return nil
        }
        return find(host)?.contentView.bounds.origin.y ?? -1
    }

    func capture(to url: URL) {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
