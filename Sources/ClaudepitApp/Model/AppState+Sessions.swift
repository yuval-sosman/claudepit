import Foundation
import ClaudepitCore

/// Where the Sessions page was, so returning to it finds the same place.
struct SessionsPageMemory {
    /// The project this memory belongs to; switching projects starts fresh.
    var projectPath: URL?
    var selection: Set<String> = []
    var primaryID: String?
    var expanded: Set<String> = []
    var search = ""
    var timeFilter: TimeFilter = .all
}

/// The Sessions list's actions: group edits, trash, liveness and per-session numbers.
///
/// Every group edit writes through `GroupStore`, then `applyGroups(key:)` re-reads that one file
/// and re-stamps the sessions in place. The page used to keep its own copy of the groups that
/// refreshed only when the session *count* changed — so a group created from a row's menu was
/// missing from the Groups tab, and the session just filed into it was listed nowhere.
extension AppState {

    // MARK: Groups

    @discardableResult
    func createSessionGroup(named raw: String, key: String, color: GroupColor? = nil,
                            assigning ids: [String] = []) -> Result<SessionGroup, GroupNameError> {
        let existing = sessionGroups[key]?.groups ?? GroupStore.shared.load(projectSlug: key).groups
        switch SessionGroup.validatedName(raw, among: existing) {
        case .failure(let e):
            return .failure(e)
        case .success(let name):
            let c = color ?? GroupColor.next(after: existing)
            guard let g = try? GroupStore.shared.createGroup(name: name, color: c, assigning: ids, projectSlug: key)
            else { return .failure(.empty) }
            applyGroups(key: key)
            return .success(g)
        }
    }

    /// nil on success, else why the name was refused.
    func renameSessionGroup(_ id: String, to raw: String, key: String) -> GroupNameError? {
        let existing = sessionGroups[key]?.groups ?? []
        switch SessionGroup.validatedName(raw, among: existing, excluding: id) {
        case .failure(let e): return e
        case .success(let name):
            try? GroupStore.shared.renameGroup(id: id, name: name, projectSlug: key)
            applyGroups(key: key)
            return nil
        }
    }

    func recolorSessionGroup(_ id: String, _ color: GroupColor, key: String) {
        try? GroupStore.shared.recolorGroup(id: id, color: color, projectSlug: key)
        applyGroups(key: key)
    }

    func deleteSessionGroup(_ id: String, key: String) {
        try? GroupStore.shared.deleteGroup(id: id, projectSlug: key)
        applyGroups(key: key)
    }

    func moveSessionGroup(_ id: String, by offset: Int, key: String) {
        try? GroupStore.shared.moveGroup(id: id, by: offset, projectSlug: key)
        applyGroups(key: key)
    }

    func setSessionGroupCollapsed(_ id: String, _ collapsed: Bool, key: String) {
        try? GroupStore.shared.setCollapsed(id: id, collapsed: collapsed, projectSlug: key)
        applyGroups(key: key)
    }

    /// File `ids` under `groupID`. Only sessions whose group file is `key` can join — a group
    /// belongs to one project.
    func assignSessions(_ ids: [String], to groupID: String, key: String) {
        let eligible = ids.filter { id in sessions.contains { $0.id == id && $0.groupKey == key } }
        guard !eligible.isEmpty else { return }
        try? GroupStore.shared.assign(sessionIDs: eligible, groupID: groupID, projectSlug: key)
        applyGroups(key: key)
    }

    func unassignSessions(_ ids: [String]) {
        let byKey = Dictionary(grouping: sessions.filter { ids.contains($0.id) && $0.groupID != nil }, by: \.groupKey)
        for (key, members) in byKey {
            try? GroupStore.shared.unassign(sessionIDs: members.map(\.id), projectSlug: key)
            applyGroups(key: key)
        }
    }

    /// Re-read one group file and re-stamp its sessions, in one publish.
    func applyGroups(key: String) {
        let pg = GroupStore.shared.load(projectSlug: key)
        if sessionGroups[key] != pg { sessionGroups[key] = pg }
        var updated = sessions
        var changed = false
        for i in updated.indices where updated[i].groupKey == key {
            let gid = pg.validGroupID(for: updated[i].id)
            if updated[i].groupID != gid { updated[i].groupID = gid; changed = true }
        }
        if changed { sessions = updated }
    }

    // MARK: Trash

    /// Move sessions to the Trash (see `SessionTrash`) and drop them from the list at once,
    /// rather than waiting for the rescan. Returns the ids that could not be moved.
    @discardableResult
    func trashSessions(_ targets: [SessionSummary]) -> [String] {
        let failed = SessionTrash.live.trash(targets)
        let gone = Set(targets.map(\.id)).subtracting(failed)
        sessions.removeAll { gone.contains($0.id) }
        for key in Set(targets.map(\.groupKey)) { applyGroups(key: key) }
        reloadSessions()
        return failed
    }

    // MARK: Liveness

    /// Re-stat the listed transcripts and re-read herdr's agents, updating dates and the live
    /// flag in place. The FileWatcher watches *folders*, which don't change when a transcript is
    /// appended to — so after a session's last write its green dot and "9 sec ago" stayed put
    /// until something else triggered a rescan. The Sessions page calls this on a timer while
    /// it is showing.
    func refreshSessionLiveness() {
        refreshHerdrAgents()
        let files = sessions.map { ($0.id, $0.fileURL) }
        Task { [weak self] in
            let stamps = await Task.detached(priority: .utility) { () -> [String: (Date, Int)] in
                var out: [String: (Date, Int)] = [:]
                for (id, url) in files {
                    guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                          let m = v.contentModificationDate else { continue }
                    out[id] = (m, v.fileSize ?? 0)
                }
                return out
            }.value
            guard let self else { return }
            let now = Date()
            var updated = self.sessions
            var changed = false, grew = false
            for i in updated.indices {
                // Only ever forward: a rescan that landed while these stats ran has newer facts.
                if let (m, size) = stamps[updated[i].id], m > updated[i].modifiedAt {
                    updated[i].modifiedAt = m
                    updated[i].fileSize = size
                    changed = true; grew = true
                }
                let age = now.timeIntervalSince(updated[i].modifiedAt)
                let active = age <= SessionScanner.activeWindow && age >= -5
                if updated[i].isActive != active { updated[i].isActive = active; changed = true }
            }
            if changed { self.sessions = updated.sorted { $0.modifiedAt > $1.modifiedAt } }
            if grew { self.reloadSessionStats() }
        }
    }

    // MARK: Per-session numbers

    /// Prompts and cost per session, from the same scanner (and per-file cache) as Home's Usage
    /// card and over the same window, so the two never re-parse each other's files or disagree.
    /// Coalesced like `reloadProjectUsage`.
    func reloadSessionStats() {
        if isScanningSessionStats {
            sessionStatsRescanPending = true
            return
        }
        isScanningSessionStats = true
        let base = activePath
        let scanner = projectUsageScanner
        Task { [weak self] in
            let table = await Task.detached(priority: .utility) {
                let now = Date()
                let since = UsagePeriod.allCases.map { $0.window(now: now).start }.min() ?? now
                return SessionStat.table(from: scanner.digest(for: base, since: since))
            }.value
            guard let self else { return }
            self.isScanningSessionStats = false
            let stale = self.activePath != base
            if !stale, table != self.sessionStats { self.sessionStats = table }
            if stale || self.sessionStatsRescanPending {
                self.sessionStatsRescanPending = false
                self.reloadSessionStats()
            }
        }
    }
}
