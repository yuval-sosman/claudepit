import Foundation

/// Everything the Loops page shows, gathered in one pass.
public struct LoopSnapshot: Equatable, Sendable {
    public var records: [LoopRecord] = []
    public var capabilities = LoopCapabilities()
    /// Claude Code processes running in the scope — the only places a session loop can fire.
    public var liveSessions: [LiveSession] = []
    public var projectLoopFile: LoopFile?
    public var userLoopFile: LoopFile?
    public var durableFile: URL?
    public var lock: SchedulerLock?
    public var lockHolderAlive = false
    /// Each session's `/goal`, by session id.
    public var goals: [String: GoalSummary] = [:]
    /// Transcripts read for this snapshot (recent or live ones).
    public var scannedTranscripts = 0
    public var scannedAt: Date?

    public init() {}
    public static let empty = LoopSnapshot()

    /// The file a bare `/loop` would use here: the project's, else the user's.
    public var activeLoopFile: LoopFile? { projectLoopFile ?? userLoopFile }

    public var activeCount: Int { records.filter(\.state.isActive).count }

    /// The soonest fire of any loop that can fire — not one whose session waits on a prompt, which
    /// fires nothing until someone answers it.
    public var nextFire: (record: LoopRecord, at: Date)? {
        records.compactMap { r in r.state.isActive && r.state != .blocked ? r.nextFire.map { (r, $0) } : nil }
            .min { $0.1 < $1.1 }
    }

    /// Loops whose session stopped on a permission prompt or a question.
    public var blocked: [LoopRecord] { records.filter { $0.state == .blocked } }

    /// The most recent fires across every loop, newest first — fires in a transcript only.
    public func recentFires(limit: Int, within window: TimeInterval, now: Date) -> [(record: LoopRecord, fire: LoopFire)] {
        records.flatMap { r in
            r.fires.filter { $0.offset >= 0 && $0.time <= now && now.timeIntervalSince($0.time) <= window }
                .map { (record: r, fire: $0) }
        }
        .sorted { $0.fire.time > $1.fire.time }
        .prefix(limit).map { $0 }
    }

    /// Fires across all loops in the last `window` seconds.
    public func fireCount(within window: TimeInterval, now: Date) -> Int {
        records.reduce(0) { $0 + $1.fires.filter { now.timeIntervalSince($0.time) <= window && $0.offset >= 0 }.count }
    }

    public func liveSession(_ id: String?) -> LiveSession? {
        guard let id else { return nil }
        return liveSessions.first { $0.sessionID == id }
    }
}

/// Builds `LoopSnapshot`s, keeping what it read: each transcript's `LoopLog` (only appended bytes are
/// read again) and the CLI's flag cache (re-parsed only when `~/.claude.json` changes — the file
/// runs to megabytes and the page refreshes every few seconds).
public final class LoopScanner: @unchecked Sendable {
    public let logs = LoopLogCache()
    private var capabilitiesCache: (modified: Date, size: Int, caps: LoopCapabilities)?
    private let lock = NSLock()

    /// Session loops expire after 7 days, so older transcripts can only hold ended ones; two weeks
    /// keeps a little history without reading every transcript the project ever had.
    public static let historyWindow: TimeInterval = 14 * 86_400

    public init() {}

    public struct Sources: Sendable {
        public var claudeJSON = Paths.globalClaudeJson
        public var liveDirectory = LiveSessionRegistry.directory
        public var desktopRoot = DesktopScheduledTask.root
        public var isAlive: @Sendable (LiveSession) -> Bool = { LiveSessionRegistry.processMatches($0) }
        public init() {}
    }

    /// `sessions` is everything the Sessions page lists for the scope; transcripts untouched for
    /// longer than `historyWindow` are skipped unless their session is running.
    public func snapshot(sessions: [LoopBuilder.SessionRef], project: URL?, now: Date = Date(),
                         sources: Sources = Sources(), calendar: Calendar = .cron) -> LoopSnapshot {
        var snap = LoopSnapshot()
        snap.scannedAt = now
        var caps = capabilities(from: sources.claudeJSON)
        for file in LoopCapabilities.settingsFiles(project: project) {
            let data = try? Data(contentsOf: file)
            if LoopCapabilities.disablesCron(settings: data) { caps.disabledBy.append(file) }
            caps.skillDenyRules += LoopCapabilities.skillDenyRules(settings: data).map { .init(rule: $0, file: file) }
        }
        snap.capabilities = caps

        let known = Set(sessions.map(\.id))
        let projectPath = project?.path(percentEncoded: false).trimmingSuffix("/")
        let live = LiveSessionRegistry.load(directory: sources.liveDirectory, isAlive: sources.isAlive)
        snap.liveSessions = live.filter { s in
            if known.contains(s.sessionID) { return true }
            guard let projectPath else { return true }
            return s.cwd == projectPath || s.cwd.hasPrefix(projectPath + "/")
        }
        let liveByID = Dictionary(snap.liveSessions.map { ($0.sessionID, $0) }, uniquingKeysWith: { a, _ in a })

        var scanned: Set<String> = []
        for ref in sessions where now.timeIntervalSince(ref.modifiedAt) <= Self.historyWindow || liveByID[ref.id] != nil {
            scanned.insert(ref.transcript.path)
            let log = logs.log(for: ref.transcript)
            guard !log.isEmpty else { continue }
            snap.records += LoopBuilder.records(from: log, session: ref, live: liveByID[ref.id], now: now,
                                                jitter: caps.jitter, calendar: calendar)
            if let goal = LoopBuilder.goal(from: log) { snap.goals[ref.id] = goal }
        }
        logs.prune(keeping: scanned)
        snap.scannedTranscripts = scanned.count

        if let project {
            let file = DurableTaskStore.file(project: project)
            let tasks = DurableTaskStore.load(project: project)
            snap.durableFile = file
            snap.lock = DurableTaskStore.loadLock(project: project)
            if let lock = snap.lock {
                snap.lockHolderAlive = sources.isAlive(LiveSession(pid: lock.pid, sessionID: lock.sessionID, cwd: "",
                                                                   procStart: lock.procStart))
            }
            // The folder's own sessions only: one in a task worktree has that worktree as its project
            // and runs (or ignores) the worktree's copy of the file.
            let inProject = snap.liveSessions.filter { s in
                guard let projectPath else { return false }
                return s.cwd == projectPath
                    || (s.cwd.hasPrefix(projectPath + "/") && !s.cwd.hasPrefix(projectPath + "/.claude/worktrees/"))
            }
            snap.records += LoopBuilder.durableRecords(tasks, file: file, capabilities: caps, liveInProject: inProject,
                                                       lock: snap.lock, lockHolderAlive: snap.lockHolderAlive,
                                                       knownSessionIDs: known, now: now, calendar: calendar)
            snap.projectLoopFile = LoopFile.read(.project, project: project)
        }
        snap.userLoopFile = LoopFile.read(.user, project: project)
        snap.records += LoopBuilder.desktopRecords(DesktopScheduledTask.load(root: sources.desktopRoot))
        return snap
    }

    private func capabilities(from url: URL) -> LoopCapabilities {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attrs?[.modificationDate] as? Date ?? .distantPast
        let size = attrs?[.size] as? Int ?? 0
        lock.lock()
        if let c = capabilitiesCache, c.modified == modified, c.size == size { lock.unlock(); return c.caps }
        lock.unlock()
        let caps = LoopCapabilities.parse(claudeJSON: try? Data(contentsOf: url))
        lock.lock()
        capabilitiesCache = (modified, size, caps)
        lock.unlock()
        return caps
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) && count > suffix.count ? String(dropLast(suffix.count)) : self
    }
}
