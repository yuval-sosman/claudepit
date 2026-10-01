import SwiftUI
import AppKit
import ClaudepitCore

/// One item of a list menu, as data. The row's "…" menu and its right-click menu render the same
/// entries (`MenuEntriesView`), and the interaction harness reads and invokes them directly —
/// a SwiftUI `Menu` can't be opened offscreen, but what it would show and do can be checked.
enum MenuEntry {
    case button(String, icon: String? = nil, checked: Bool = false, enabled: Bool = true,
                destructive: Bool = false, action: () -> Void)
    case submenu(String, [MenuEntry])
    /// A disabled line of text: a heading, or why an action isn't offered.
    case note(String)
    case divider

    var title: String? {
        switch self {
        case .button(let t, _, _, _, _, _), .submenu(let t, _), .note(let t): return t
        case .divider: return nil
        }
    }
}

extension Array where Element == MenuEntry {
    /// The entry titled `title`, searching submenus too.
    func entry(_ title: String) -> MenuEntry? {
        for e in self {
            if e.title == title { return e }
            if case .submenu(_, let children) = e, let hit = children.entry(title) { return hit }
        }
        return nil
    }
}

struct MenuEntriesView: View {
    let entries: [MenuEntry]

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case let .button(title, icon, checked, enabled, destructive, action):
                Button(role: destructive ? .destructive : nil, action: action) {
                    if checked { Label(title, systemImage: "checkmark") }
                    else if let icon { Label(title, systemImage: icon) }
                    else { Text(title) }
                }
                .disabled(!enabled)
            case let .submenu(title, children):
                // AnyView breaks the recursive opaque type.
                Menu(title) { AnyView(MenuEntriesView(entries: children)) }
            case .note(let text):
                Text(text)
            case .divider:
                Divider()
            }
        }
    }
}

/// What the list's menus offer and what a drop does — built from the same data the list draws.
@MainActor
struct SessionListMenus {
    let sessions: [SessionSummary]
    let context: SessionListContext
    let state: SessionListState
    let actions: SessionListActions
    /// Opens the inline new-group editor (switching to the Groups tab) for these sessions.
    let startNewGroup: ([String]) -> Void
    var copy: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The sessions a menu or drag acts on: the whole selection when the row is part of it,
    /// otherwise just the row (Finder's rule).
    func targets(for s: SessionSummary) -> [SessionSummary] {
        let ids = state.selectedSessionIDs
        guard ids.count > 1, ids.contains(s.id) else { return [s] }
        return sessions.filter { state.selection.contains($0.id) }
    }

    func session(_ targets: [SessionSummary]) -> [MenuEntry] {
        guard let s = targets.first else { return [] }
        if targets.count == 1 {
            var out: [MenuEntry] = [
                .button("Open Transcript", icon: Icon.openFile) { actions.openTranscript(s) },
                .button("Reveal in Finder", icon: Icon.revealInFinder) { actions.reveal(s) },
                .button("Copy Path", icon: Icon.copyPath) { copy(s.fileURL.path) },
                .divider,
            ]
            out += grouping(targets)
            out.append(.divider)
            if let resume = actions.resume {
                let open = context.herdrStatus[s.id] != nil
                out.append(.button(open ? "Focus in herdr" : "Resume in herdr", icon: open ? "terminal" : "play.circle") { resume(s) })
            }
            if let ref = s.task, let openTask = actions.openTask {
                out.append(.button("Open Task", icon: "checklist") { openTask(ref.taskID) })
            }
            out += [
                .button("Copy Session ID") { copy(s.id) },
                .button("Copy Resume Command") { copy("claude --resume \(s.id)") },
                .divider,
                trash(targets),
            ]
            return out
        }
        return [.note("\(targets.count) Sessions")] + grouping(targets) + [
            .divider,
            .button("Copy Session IDs") { copy(targets.map(\.id).joined(separator: "\n")) },
            .divider,
            trash(targets),
        ]
    }

    private func grouping(_ targets: [SessionSummary]) -> [MenuEntry] {
        let keys = Set(targets.map(\.groupKey))
        let ids = targets.map(\.id)
        var out: [MenuEntry] = []
        if keys.count == 1, let key = keys.first {
            let groups = context.groups[key]?.groups ?? []
            var items: [MenuEntry] = groups.map { g in
                let allIn = targets.allSatisfy { $0.groupID == g.id }
                return .button(g.name, checked: allIn, enabled: !allIn) { actions.assign(ids, g.id, key) }
            }
            if !items.isEmpty { items.append(.divider) }
            items.append(.button(targets.count == 1 ? "New Group…" : "New Group from Selection…") { startNewGroup(ids) })
            out.append(.submenu("Move to Group", items))
        } else {
            out.append(.note("Sessions from different projects can't share a group"))
        }
        if targets.contains(where: { $0.groupID != nil }) {
            out.append(.button(targets.count == 1 ? "Remove from Group" : "Remove from Groups") { actions.unassign(ids) })
        }
        return out
    }

    private func trash(_ targets: [SessionSummary]) -> MenuEntry {
        let movable = targets.filter { !context.status(of: $0).isLive }
        if movable.isEmpty {
            return .note(targets.count == 1 ? "Can't Trash a Running Session" : "Can't Trash Running Sessions")
        }
        return .button(targets.count == 1 ? "Move to Trash…" : "Move \(movable.count) to Trash…",
                       icon: Icon.delete, destructive: true) { state.pendingTrash = movable }
    }

    func group(key: String, group: SessionGroup, count: Int, isFirst: Bool, isLast: Bool) -> [MenuEntry] {
        [
            .button("Rename…") { state.renamingGroupID = group.id },
            .submenu("Color", GroupColor.allCases.map { c in
                .button(c.rawValue.capitalized, checked: c == group.color) { actions.recolorGroup(group.id, c, key) }
            }),
            .button(group.isCollapsed ? "Expand" : "Collapse") { actions.setGroupCollapsed(group.id, !group.isCollapsed, key) },
            .divider,
            .button("Move Up", enabled: !isFirst) { actions.moveGroup(group.id, -1, key) },
            .button("Move Down", enabled: !isLast) { actions.moveGroup(group.id, 1, key) },
            .divider,
            .button("Delete Group…", icon: Icon.delete, destructive: true) {
                state.pendingGroupDelete = .init(key: key, group: group, count: count)
            },
        ]
    }

    func taskGroup(taskID: String, collapsed: Bool, toggle: @escaping () -> Void) -> [MenuEntry] {
        var out: [MenuEntry] = []
        if let open = actions.openTask { out.append(.button("Open Task", icon: "checklist") { open(taskID) }) }
        out.append(.button(collapsed ? "Expand" : "Collapse", action: toggle))
        return out
    }

    /// What dropping dragged items on a section does: file the sessions under its group, take
    /// them out of their groups (Ungrouped), or nothing. Returns whether the drop was accepted.
    static func drop(_ items: [String], into section: SessionListModel.Section, actions: SessionListActions) -> Bool {
        let ids = SessionDragPayload.decode(items)
        guard !ids.isEmpty else { return false }
        if let target = section.dropGroup {
            actions.assign(ids, target.id, target.key)
        } else if section.dropUngroups {
            actions.unassign(ids)
        } else {
            return false
        }
        return true
    }
}
