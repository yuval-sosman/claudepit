import Foundation

/// A running Claude Code process, as it registers itself in `~/.claude/sessions/<pid>.json`.
///
/// This is the only reliable answer to "is this loop running right now": `/loop` tasks live in the
/// process's memory, fire only while it is open and idle, and die with it. A transcript that was
/// written a minute ago says nothing about whether its process still exists, and a process can
/// move on to another session id (`/clear`, `/resume`), so the registry's *current* session id is
/// what a loop's session is matched against.
public struct LiveSession: Equatable, Sendable, Identifiable {
    public let pid: Int32
    public let sessionID: String
    public let cwd: String
    public let startedAt: Date?
    /// `ps -o lstart`-style start time the CLI records, used to tell a recycled pid from ours.
    public let procStart: String?
    public let version: String?
    /// `interactive`, or another kind of host (background sessions, SDK).
    public let kind: String?
    public let entrypoint: String?
    /// The display name (`-n`, `/rename`, or one derived from the folder).
    public let name: String?
    /// `busy` while a turn runs, `idle` at the prompt, `waiting` when it needs the person — the
    /// state that decides whether a due task can fire.
    public let status: String?
    public let statusUpdatedAt: Date?
    /// With `waiting`: what for ("permission prompt", …).
    public let waitingFor: String?
    /// A background session's short id (`claude --bg` prints it; `attach`/`logs`/`stop` take it).
    public let jobID: String?

    public var id: Int32 { pid }
    /// Hosted by the CLI's background supervisor (`kind: "bg"`): no terminal, no herdr pane.
    public var isBackground: Bool { kind == "bg" || kind == "background" }
    public var isBusy: Bool { status == "busy" }
    public var isIdle: Bool { status == "idle" }
    /// Stopped on a question or a permission prompt: nothing fires until someone answers.
    public var isWaiting: Bool { status == "waiting" }

    public init(pid: Int32, sessionID: String, cwd: String, startedAt: Date? = nil, procStart: String? = nil,
                version: String? = nil, kind: String? = nil, entrypoint: String? = nil, name: String? = nil,
                status: String? = nil, statusUpdatedAt: Date? = nil, waitingFor: String? = nil, jobID: String? = nil) {
        self.pid = pid; self.sessionID = sessionID; self.cwd = cwd; self.startedAt = startedAt
        self.procStart = procStart; self.version = version; self.kind = kind; self.entrypoint = entrypoint
        self.name = name; self.status = status; self.statusUpdatedAt = statusUpdatedAt; self.waitingFor = waitingFor
        self.jobID = jobID
    }
}

public enum LiveSessionRegistry {
    public static var directory: URL { Paths.globalClaude.appending(path: "sessions") }

    /// One registry file. nil when it isn't a session record.
    public static func parse(_ data: Data) -> LiveSession? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (o["pid"] as? NSNumber)?.int32Value, pid > 0,
              let sid = o["sessionId"] as? String, !sid.isEmpty else { return nil }
        func date(_ key: String) -> Date? {
            (o[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }
        return LiveSession(pid: pid, sessionID: sid, cwd: o["cwd"] as? String ?? "",
                           startedAt: date("startedAt"), procStart: o["procStart"] as? String,
                           version: o["version"] as? String, kind: o["kind"] as? String,
                           entrypoint: o["entrypoint"] as? String, name: o["name"] as? String,
                           status: o["status"] as? String, statusUpdatedAt: date("statusUpdatedAt"),
                           waitingFor: o["waitingFor"] as? String, jobID: o["jobId"] as? String)
    }

    /// Every registered session whose process is still the one that registered. Files of dead
    /// processes linger (the CLI doesn't always clean up), so liveness is checked, not assumed.
    public static func load(directory: URL = directory,
                            isAlive: (LiveSession) -> Bool = processMatches) -> [LiveSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap(parse) }
            .filter(isAlive)
            .sorted { $0.pid < $1.pid }
    }

    /// The process exists and — when its recorded start time can be read — started then. Without
    /// the start-time check a pid the system handed to some other program would keep a dead
    /// session "running" forever.
    public static func processMatches(_ s: LiveSession) -> Bool {
        guard s.pid > 0, kill(s.pid, 0) == 0 || errno == EPERM else { return false }
        guard let recorded = s.procStart.flatMap(procStartCandidates), !recorded.isEmpty,
              let actual = processStartTime(pid: s.pid) else { return true }
        return recorded.contains { abs($0.timeIntervalSince(actual)) < 3 }
    }

    /// The CLI writes `procStart` like `ps -o lstart` ("Thu Oct  1 14:09:14 2026") — observed in
    /// UTC, but read both ways so a CLI that switches to local time still matches.
    static func procStartCandidates(_ text: String) -> [Date] {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return [TimeZone(identifier: "UTC"), TimeZone.current].compactMap { tz in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = tz
            f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            return f.date(from: collapsed)
        }
    }

    /// The process's start time from the kernel (`sysctl KERN_PROC_PID`) — no subprocess, so safe
    /// from anywhere (`Executable.find`'s rule).
    static func processStartTime(pid: Int32) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }
}
