import SwiftUI
import ClaudepitCore

enum SessionListTab: String, Codable { case recent, groups }

/// The list's persisted view options (one `@AppStorage` key, JSON).
struct SessionListPrefs: Codable, Equatable, RawRepresentable {
    var tab: SessionListTab = .recent
    /// Task-agent sessions are a third of a busy project's list; this hides them everywhere.
    var showTaskSessions = true
    /// The first summary bullet under each title.
    var showSummaries = true
    /// File task-phase sessions under one automatic group per task in the Groups tab.
    var automaticTaskGroups = true
    /// Automatic task groups start folded; these are the ones the reader opened.
    var expandedTaskGroups: Set<String> = []
    var ungroupedCollapsed = false

    init() {}

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let v = try? JSONDecoder().decode(SessionListPrefs.self, from: data) else { return nil }
        self = v
    }

    var rawValue: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private enum CodingKeys: String, CodingKey {
        case tab, showTaskSessions, showSummaries, automaticTaskGroups, expandedTaskGroups, ungroupedCollapsed
    }

    // Written out: for a String-backed RawRepresentable the standard library's default
    // `encode(to:)` encodes `rawValue` — which encodes `self` — and recurses forever.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tab, forKey: .tab)
        try c.encode(showTaskSessions, forKey: .showTaskSessions)
        try c.encode(showSummaries, forKey: .showSummaries)
        try c.encode(automaticTaskGroups, forKey: .automaticTaskGroups)
        try c.encode(expandedTaskGroups, forKey: .expandedTaskGroups)
        try c.encode(ungroupedCollapsed, forKey: .ungroupedCollapsed)
    }

    // Decode field by field so a key added later doesn't reset everything else.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tab = (try? c.decode(SessionListTab.self, forKey: .tab)) ?? .recent
        showTaskSessions = (try? c.decode(Bool.self, forKey: .showTaskSessions)) ?? true
        showSummaries = (try? c.decode(Bool.self, forKey: .showSummaries)) ?? true
        automaticTaskGroups = (try? c.decode(Bool.self, forKey: .automaticTaskGroups)) ?? true
        expandedTaskGroups = (try? c.decode(Set<String>.self, forKey: .expandedTaskGroups)) ?? []
        ungroupedCollapsed = (try? c.decode(Bool.self, forKey: .ungroupedCollapsed)) ?? false
    }
}

/// Live facts about the sessions that come from elsewhere in the app (herdr, worktrees, tasks,
/// usage), as plain data — so the list renders without `AppState`, offscreen snapshots included.
struct SessionListContext {
    var now = Date()
    /// nil = listing every project (rows then name their project).
    var projectKey: String?
    var groups: [String: ProjectGroups] = [:]
    var herdrStatus: [String: String] = [:]
    var stats: [String: SessionStat] = [:]
    /// Live task names by task id (a task renamed after its phase ran shows its current name).
    var taskNames: [String: String] = [:]
    /// Worktree name by the session id it is bound to.
    var boundWorktrees: [String: String] = [:]
    var herdrAvailable = false

    func status(of s: SessionSummary) -> SessionLiveStatus {
        SessionLiveStatus.resolve(herdrStatus: herdrStatus[s.id], modifiedAt: s.modifiedAt, now: now)
    }

    func group(of s: SessionSummary) -> SessionGroup? { groups[s.groupKey]?.group(s.groupID) }

    func title(of s: SessionSummary) -> String {
        if let ref = s.task, let live = taskNames[ref.taskID] { return live }
        return s.title
    }
}

/// What the list draws: its sections, in order, and the ids in display order. Built once per
/// render from the sessions, the view options and the search.
struct SessionListModel {
    enum Header {
        case date(String)
        case group(key: String, group: SessionGroup, count: Int, projectName: String?, isFirst: Bool, isLast: Bool)
        case caption(String)
        case taskGroup(taskID: String, name: String, count: Int)
        case ungrouped(count: Int)
    }

    struct Section: Identifiable {
        let id: String
        let header: Header
        var sessions: [SessionSummary]
        var collapsed = false
        /// Drawn when the section is open and empty.
        var placeholder: String?
        /// Dropping sessions here files them under this group (nil key: removes them from theirs).
        var dropGroup: (key: String, id: String)?
        var dropUngroups = false
    }

    var sections: [Section] = []
    /// Selectable ids in display order: sessions, and the subagents of expanded ones.
    var order: [String] = []
    /// Sessions passing the search and filters (either tab).
    var matching: [SessionSummary] = []
    var hasManualGroups = false
    let isSearching: Bool

    init(sessions: [SessionSummary], context: SessionListContext, prefs: SessionListPrefs,
         query: String, includeDate: (Date) -> Bool, expanded: Set<String>) {
        let q = query.trimmingCharacters(in: .whitespaces)
        isSearching = !q.isEmpty
        matching = sessions.filter { s in
            guard includeDate(s.modifiedAt), prefs.showTaskSessions || s.task == nil else { return false }
            var extra: [String] = []
            if let g = context.group(of: s) { extra.append(g.name) }
            if let ref = s.task, let n = context.taskNames[ref.taskID] { extra.append(n) }
            return SessionListing.matches(s, query: q, extra: extra)
        }

        switch prefs.tab {
        case .recent:
            sections = SessionListing.dateSections(matching, now: context.now).map {
                Section(id: "date-\($0.id)", header: .date($0.title), sessions: $0.sessions)
            }
        case .groups:
            buildGroups(all: sessions, context: context, prefs: prefs)
        }

        for section in sections where !section.collapsed {
            for s in section.sessions {
                order.append(s.id)
                if expanded.contains(s.id) {
                    order += s.subagents.map { SessionListModel.subagentID(parent: s.id, sub: $0.id) }
                }
            }
        }
    }

    private mutating func buildGroups(all: [SessionSummary], context: SessionListContext, prefs: SessionListPrefs) {
        let keyOrder = SessionListing.groupKeyOrder(sessions: all, groups: context.groups, projectKey: context.projectKey)
        let layout = SessionListing.groupLayout(matching, groups: context.groups, keyOrder: keyOrder,
                                                taskNames: context.taskNames,
                                                automaticTaskGroups: prefs.automaticTaskGroups)
        hasManualGroups = !layout.manual.isEmpty
        let projectNames = Dictionary(all.map { ($0.groupKey, $0.projectName) }, uniquingKeysWith: { a, _ in a })
        for m in layout.manual {
            if isSearching && m.sessions.isEmpty { continue }
            let siblings = context.groups[m.key]?.groups ?? []
            sections.append(Section(
                id: "group-\(m.group.id)",
                header: .group(key: m.key, group: m.group, count: m.sessions.count,
                               projectName: context.projectKey == nil ? projectNames[m.key] : nil,
                               isFirst: siblings.first?.id == m.group.id, isLast: siblings.last?.id == m.group.id),
                sessions: m.sessions,
                collapsed: m.group.isCollapsed && !isSearching,
                placeholder: "Drag sessions here",
                dropGroup: (m.key, m.group.id)))
        }
        if !layout.tasks.isEmpty {
            sections.append(Section(id: "caption-tasks", header: .caption("From Tasks"), sessions: []))
            for t in layout.tasks {
                sections.append(Section(
                    id: "task-\(t.taskID)",
                    header: .taskGroup(taskID: t.taskID, name: t.name, count: t.sessions.count),
                    sessions: t.sessions,
                    collapsed: !prefs.expandedTaskGroups.contains(t.taskID) && !isSearching))
            }
        }
        if !layout.ungrouped.isEmpty || (hasManualGroups && !isSearching) {
            sections.append(Section(
                id: "ungrouped",
                header: .ungrouped(count: layout.ungrouped.count),
                sessions: layout.ungrouped,
                collapsed: prefs.ungroupedCollapsed && !isSearching,
                placeholder: hasManualGroups ? "Every session is in a group" : nil,
                dropUngroups: true))
        }
    }

    static func subagentID(parent: String, sub: String) -> String { "\(parent)/\(sub)" }

    /// The section holding a session (for revealing it).
    func section(containing id: String) -> Section? {
        let sessionID = id.split(separator: "/").first.map(String.init) ?? id
        return sections.first { $0.sessions.contains { $0.id == sessionID } }
    }
}

/// One drag's payload: session ids, one per line, behind a marker so a drop of ordinary text
/// is never mistaken for sessions.
enum SessionDragPayload {
    private static let marker = "claudepit-sessions"

    static func encode(_ ids: [String]) -> String { ([marker] + ids).joined(separator: "\n") }

    static func decode(_ items: [String]) -> [String] {
        items.flatMap { item -> [String] in
            let lines = item.split(separator: "\n").map(String.init)
            guard lines.first == marker else { return [] }
            return Array(lines.dropFirst())
        }
    }
}

/// The page's working state: selection, expansion, search and the in-flight edits. One object
/// so the list, the detail card and the keyboard all read the same selection.
@MainActor
final class SessionListState: ObservableObject {
    @Published var selection: Set<String> = []
    /// The row the detail card shows and the keyboard moves from.
    @Published var primaryID: String?
    /// Where a shift-extension starts.
    var anchorID: String?
    @Published var expanded: Set<String> = []
    @Published var query = ""
    @Published var timeFilter: TimeFilter = .all
    /// An inline "new group" editor at the top of the Groups tab, filing these sessions on commit.
    @Published var newGroup: NewGroupDraft?
    @Published var renamingGroupID: String?
    /// A one-shot "show this row" (deep links, keyboard moves): `center` for jumps from
    /// elsewhere, minimal scroll otherwise.
    @Published var scrollRequest: ScrollRequest?
    /// A one-shot "make this row visible, whatever hides it" (deep links).
    @Published var revealRequest: String?
    @Published var pendingTrash: [SessionSummary]?
    @Published var pendingGroupDelete: PendingGroupDelete?

    struct NewGroupDraft: Equatable {
        var key: String
        var sessionIDs: [String]
    }

    struct ScrollRequest: Equatable {
        let id: String
        let center: Bool
        let token = UUID()
    }

    struct PendingGroupDelete: Identifiable {
        let key: String
        let group: SessionGroup
        let count: Int
        var id: String { group.id }
    }

    /// Selected *sessions* (subagent rows are never part of a group or trash action).
    var selectedSessionIDs: [String] { selection.filter { !$0.contains("/") }.sorted() }

    func select(_ id: String) {
        selection = [id]; primaryID = id; anchorID = id
    }
}
