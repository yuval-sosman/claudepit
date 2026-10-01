import Foundation

/// The Sessions page's left list, as pure functions over `SessionSummary` — what the Recent and
/// Groups tabs show, in what order, and what a row says about the session. The view only draws it.

// MARK: - Live status

/// The one live indicator a row shows. herdr's agent state wins when the session runs in a herdr
/// pane (it knows the difference between "working" and "waiting on you"); otherwise a transcript
/// written in the last minute reads as working.
public enum SessionLiveStatus: Equatable, Sendable {
    case working
    /// herdr reports `blocked`: the turn ended, or Claude asked a question.
    case waiting
    /// Open in a herdr pane, idle at its prompt.
    case open
    case none

    public static func resolve(herdrStatus: String?, modifiedAt: Date, now: Date,
                               activeWindow: TimeInterval = SessionScanner.activeWindow) -> SessionLiveStatus {
        switch herdrStatus {
        case "working"?: return .working
        case "blocked"?: return .waiting
        case .some: return .open
        case nil:
            let age = now.timeIntervalSince(modifiedAt)
            return age <= activeWindow && age >= -5 ? .working : .none
        }
    }

    /// Something still holds the transcript open — it must not be moved to the Trash.
    public var isLive: Bool { self != .none }
}

// MARK: - Per-session numbers

/// Prompts and cost for one session (subagents included), from the same digest Home counts with,
/// so a row's figures and the Session Report can never disagree.
public struct SessionStat: Equatable, Sendable {
    public var prompts: Int
    public var cost: Double

    public init(prompts: Int, cost: Double) { self.prompts = prompts; self.cost = cost }

    public static func table(from digest: TranscriptDigest) -> [String: SessionStat] {
        var out: [String: SessionStat] = [:]
        for call in digest.calls.values {
            out[call.sessionID, default: SessionStat(prompts: 0, cost: 0)].cost += call.cost.total
        }
        for (session, times) in digest.prompts {
            out[session, default: SessionStat(prompts: 0, cost: 0)].prompts = times.count
        }
        return out
    }
}

public enum SessionListing {

    // MARK: Recent — date sections

    public struct DateSection: Identifiable {
        public let id: String
        public let title: String
        public var sessions: [SessionSummary]
    }

    /// Today · Yesterday · Previous 7 Days · Previous 30 Days, then one section per month
    /// ("August", or "August 2025" outside the current year). Sessions keep their incoming order
    /// within a section; sections run newest first.
    public static func dateSections(_ sessions: [SessionSummary], now: Date,
                                    calendar: Calendar = .current) -> [DateSection] {
        var order: [String] = []
        var byID: [String: DateSection] = [:]
        let today = calendar.startOfDay(for: now)
        let bounds = [1, 7, 30].map { calendar.date(byAdding: .day, value: -$0, to: today)! }
        for s in sessions.sorted(by: { $0.modifiedAt > $1.modifiedAt }) {
            let id = bucketID(for: s.modifiedAt, today: today, bounds: bounds, calendar: calendar)
            if byID[id] == nil {
                order.append(id)
                byID[id] = DateSection(id: id, title: title(of: id, date: s.modifiedAt, now: now, calendar: calendar),
                                       sessions: [])
            }
            byID[id]!.sessions.append(s)
        }
        return order.compactMap { byID[$0] }
    }

    /// Cheap per session; the (formatter-built) title is made once per section.
    private static func bucketID(for date: Date, today: Date, bounds: [Date], calendar: Calendar) -> String {
        if date >= today { return "today" }
        if date >= bounds[0] { return "yesterday" }
        if date >= bounds[1] { return "week" }
        if date >= bounds[2] { return "month" }
        let c = calendar.dateComponents([.year, .month], from: date)
        return "m\(c.year ?? 0)-\(c.month ?? 0)"
    }

    private static func title(of id: String, date: Date, now: Date, calendar: Calendar) -> String {
        switch id {
        case "today": return "Today"
        case "yesterday": return "Yesterday"
        case "week": return "Previous 7 Days"
        case "month": return "Previous 30 Days"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            let f = DateFormatter()
            f.calendar = calendar
            f.locale = calendar.locale ?? .current
            f.timeZone = calendar.timeZone
            f.setLocalizedDateFormatFromTemplate(sameYear ? "MMMM" : "MMMM y")
            return f.string(from: date)
        }
    }

    // MARK: Search

    /// Every word of `query` appears somewhere in the session: its title, id, project or
    /// worktree, task and phase, summary bullets, or `extra` (its group's name, the live task
    /// name). Empty query matches everything.
    public static func matches(_ s: SessionSummary, query: String, extra: [String] = []) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        var fields = [s.title, s.id, s.projectName]
        if let w = s.worktreeName { fields.append(w) }
        if let t = s.task { fields.append(t.phaseLabel); if let n = t.taskName { fields.append(n) } }
        fields += s.bulletSummary?.bullets ?? []
        fields += s.subagents.flatMap { [$0.agentType, $0.description] }
        fields += extra
        let haystack = fields.joined(separator: "\n")
        return words.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
    }

    // MARK: Groups tab

    public struct GroupLayout {
        public struct Manual: Identifiable {
            public let key: String
            public let group: SessionGroup
            public var sessions: [SessionSummary]
            public var id: String { group.id }
        }
        /// An automatic group: every session a Claudepit task's phases ran in.
        public struct TaskBucket: Identifiable {
            public let taskID: String
            public let name: String
            public var sessions: [SessionSummary]
            public var id: String { taskID }
            public var latest: Date { sessions.map(\.modifiedAt).max() ?? .distantPast }
        }
        public var manual: [Manual] = []
        public var tasks: [TaskBucket] = []
        public var ungrouped: [SessionSummary] = []
    }

    /// Manual groups first (in each file's own order, files in `keyOrder`), then one automatic
    /// group per task for task-phase sessions nobody filed by hand, then the rest. A session is
    /// listed exactly once: a manual group wins over its task, and an assignment to a group that
    /// no longer exists falls through rather than hiding the session.
    public static func groupLayout(_ sessions: [SessionSummary], groups: [String: ProjectGroups],
                                   keyOrder: [String], taskNames: [String: String] = [:],
                                   automaticTaskGroups: Bool = true) -> GroupLayout {
        var layout = GroupLayout()
        let sorted = sessions.sorted { $0.modifiedAt > $1.modifiedAt }
        var placed = Set<String>()
        for key in keyOrder {
            guard let pg = groups[key] else { continue }
            for g in pg.groups {
                let members = sorted.filter { $0.groupKey == key && $0.groupID == g.id }
                placed.formUnion(members.map(\.id))
                layout.manual.append(.init(key: key, group: g, sessions: members))
            }
        }
        var buckets: [String: GroupLayout.TaskBucket] = [:]
        for s in sorted where !placed.contains(s.id) {
            if automaticTaskGroups, let ref = s.task {
                let name = taskNames[ref.taskID] ?? ref.taskName ?? "Task \(ref.taskID)"
                buckets[ref.taskID, default: .init(taskID: ref.taskID, name: name, sessions: [])].sessions.append(s)
            } else {
                layout.ungrouped.append(s)
            }
        }
        layout.tasks = buckets.values.sorted { $0.latest > $1.latest }
        return layout
    }

    /// Group files in the order the Groups tab lists them: the open project's alone, or — across
    /// all projects — every file that has groups, most recently active project first.
    public static func groupKeyOrder(sessions: [SessionSummary], groups: [String: ProjectGroups],
                                     projectKey: String?) -> [String] {
        if let projectKey { return [projectKey] }
        let latest = Dictionary(sessions.map { ($0.groupKey, $0.modifiedAt) }, uniquingKeysWith: max)
        return groups.filter { !$0.value.groups.isEmpty }.keys.sorted {
            let a = latest[$0] ?? .distantPast, b = latest[$1] ?? .distantPast
            return a != b ? a > b : $0 < $1
        }
    }

    // MARK: Keyboard / range selection

    /// The ids strictly between and including `anchor` and `target` in display order — a
    /// shift-click or shift-arrow selection. Unknown anchor → just the target.
    public static func range(from anchor: String?, to target: String, in order: [String]) -> [String] {
        guard let anchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: target) else {
            return [target]
        }
        return Array(order[min(a, b)...max(a, b)])
    }

    /// The id `step` rows away from `current` (clamped), or the first/last row when nothing is
    /// selected yet.
    public static func neighbor(of current: String?, step: Int, in order: [String]) -> String? {
        guard !order.isEmpty else { return nil }
        guard let current, let i = order.firstIndex(of: current) else {
            return step >= 0 ? order.first : order.last
        }
        return order[max(0, min(order.count - 1, i + step))]
    }
}

// MARK: - Worktree label

/// How a worktree reads in the Sessions list: a short name for its pill, and a colour slot that
/// stays the same for the same worktree on every launch (so all its sessions share it).
public enum WorktreeLabel {
    /// `task-56cf65b6-close-the-previous-phase…` → `56cf65b6` (the task id the app shows
    /// everywhere else); any other name as it is.
    public static func short(_ name: String) -> String {
        let parts = name.split(separator: "-", maxSplits: 2)
        if parts.count >= 2, parts[0] == "task", parts[1].count == 8, parts[1].allSatisfy(\.isHexDigit) {
            return String(parts[1])
        }
        return name
    }

    /// FNV-1a over the name — `String.hashValue` is seeded per process, so it would recolour
    /// every worktree on each launch.
    public static func colorIndex(for name: String, paletteSize: Int) -> Int {
        guard paletteSize > 0 else { return 0 }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Int(hash % UInt64(paletteSize))
    }
}

/// Which colour each *existing* worktree wears. Hashing names straight into a handful of colours
/// made two live worktrees share one as soon as there were a few — and colour is what the eye
/// scans by. Instead a worktree keeps the slot it already has, a new one takes its hashed slot if
/// that is free (else the first free one), and two share only when every slot is taken.
/// Worktrees that no longer exist get no slot: their sessions draw neutral and free the colour.
public enum WorktreeColors {
    /// Slots for `live`, honouring `previous` (which may also hold worktrees gone or from other
    /// projects — those are kept by the caller but never block a slot here).
    public static func assign(live: [String], previous: [String: Int], paletteSize: Int) -> [String: Int] {
        guard paletteSize > 0 else { return [:] }
        var out: [String: Int] = [:]
        var used = Set<Int>()
        for name in Set(live).sorted() {
            if let slot = previous[name], (0..<paletteSize).contains(slot), !used.contains(slot) {
                out[name] = slot
                used.insert(slot)
            }
        }
        for name in Set(live).sorted() where out[name] == nil {
            let preferred = WorktreeLabel.colorIndex(for: name, paletteSize: paletteSize)
            let slot = !used.contains(preferred) ? preferred
                : (0..<paletteSize).first { !used.contains($0) } ?? preferred
            out[name] = slot
            used.insert(slot)
        }
        return out
    }
}
