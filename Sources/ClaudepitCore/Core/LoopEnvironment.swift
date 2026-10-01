import Foundation

// What decides whether a loop can run on this machine, read from the CLI's own files: its cached
// feature flags, the settings that switch the scheduler off, the `loop.md` that replaces the
// default prompt, the durable task file and its lock, and the Desktop app's scheduled tasks.
// Read only — except `DurableTaskStore`'s add/remove, which write the file the CLI itself writes.

// MARK: - Capabilities

/// The scheduling features this CLI has switched on. Claude Code gates them behind remote flags and
/// caches the last values it fetched in `~/.claude.json` (`cachedGrowthBookFeatures`), so the app
/// can say "durable tasks are off for you" instead of writing a file that will never run.
public struct LoopCapabilities: Equatable, Sendable {
    public enum Flag: Equatable, Sendable {
        case on, off
        /// No cached value: the CLI uses its built-in default.
        case unknown(defaultOn: Bool)

        public var isOn: Bool {
            switch self { case .on: return true; case .off: return false; case .unknown(let d): return d }
        }
        public var isKnownOff: Bool { self == .off }
    }

    /// The scheduler itself — CronCreate and `/loop` (`tengu_kairos_cron`).
    public var cron: Flag = .unknown(defaultOn: true)
    /// `durable: true` tasks in `.claude/scheduled_tasks.json` (`tengu_kairos_cron_durable`).
    public var durable: Flag = .unknown(defaultOn: true)
    /// Self-paced `/loop` via ScheduleWakeup (`tengu_kairos_loop_dynamic`).
    public var selfPaced: Flag = .unknown(defaultOn: true)
    /// Bare `/loop` running the built-in maintenance prompt (`tengu_kairos_loop_prompt`).
    public var maintenancePrompt: Flag = .unknown(defaultOn: true)
    /// The jitter/expiry config (`tengu_kairos_cron_config`), else the CLI defaults.
    public var jitter: CronJitter = .cliDefault
    /// When the CLI last refreshed its flag cache.
    public var flagsFetchedAt: Date?
    /// Settings files whose `env` sets `CLAUDE_CODE_DISABLE_CRON` — any one switches loops off.
    public var disabledBy: [URL] = []
    /// `Skill` rules in the settings layers' `permissions.deny`: a fire hands a denied skill to
    /// Claude as plain text (docs, "Run a prompt repeatedly with /loop").
    public var skillDenyRules: [SkillRule] = []

    public struct SkillRule: Equatable, Sendable {
        /// As written: `Skill`, `Skill(deploy)`, `Skill(deploy *)`, `Skill(skill:deploy)`.
        public let rule: String
        public let file: URL
        public init(rule: String, file: URL) { self.rule = rule; self.file = file }

        /// Whether it blocks the skill `/name` (or `name`). Per the skills docs: bare `Skill` blocks
        /// them all; `Skill(x)` and `Skill(x *)` (any arguments) block `x`, and an unqualified `x` also
        /// blocks a namespaced `ns:x`; the parameter form `Skill(skill:x)` names `x`.
        public func blocks(_ name: String) -> Bool {
            let skill = name.hasPrefix("/") ? String(name.dropFirst()) : name
            guard rule != "Skill" else { return true }
            guard rule.hasPrefix("Skill("), rule.hasSuffix(")") else { return false }
            var named = String(rule.dropFirst(6).dropLast()).trimmingCharacters(in: .whitespaces)
            for suffix in [" *", ":*"] where named.hasSuffix(suffix) { named = String(named.dropLast(suffix.count)) }
            if named.hasPrefix("skill:") { named = String(named.dropFirst(6)) }
            guard !named.isEmpty else { return false }
            return skill == named || (!named.contains(":") && skill.hasSuffix(":" + named))
        }
    }

    /// The first deny rule that blocks `name`.
    public func skillDenyRule(for name: String) -> SkillRule? { skillDenyRules.first { $0.blocks(name) } }

    public init() {}

    /// The scheduler is usable at all.
    public var schedulerOn: Bool { cron.isOn && disabledBy.isEmpty }

    /// Parse the flag cache out of `~/.claude.json`'s contents.
    public static func parse(claudeJSON data: Data?) -> LoopCapabilities {
        var caps = LoopCapabilities()
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flags = root["cachedGrowthBookFeatures"] as? [String: Any] else { return caps }
        func flag(_ key: String) -> Flag {
            guard let v = flags[key] as? Bool else { return .unknown(defaultOn: true) }
            return v ? .on : .off
        }
        caps.cron = flag("tengu_kairos_cron")
        caps.durable = flag("tengu_kairos_cron_durable")
        caps.selfPaced = flag("tengu_kairos_loop_dynamic")
        caps.maintenancePrompt = flag("tengu_kairos_loop_prompt")
        caps.jitter = CronJitter(config: flags["tengu_kairos_cron_config"] as? [String: Any])
        if let at = (root["cachedGrowthBookFeaturesAt"] as? NSNumber)?.doubleValue {
            caps.flagsFetchedAt = Date(timeIntervalSince1970: at > 1e12 ? at / 1000 : at)
        }
        return caps
    }

    /// `CLAUDE_CODE_DISABLE_CRON` in a settings file's `env`, truthy the way the CLI reads env flags.
    public static func disablesCron(settings data: Data?) -> Bool {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = root["env"] as? [String: Any], let raw = env["CLAUDE_CODE_DISABLE_CRON"] else { return false }
        let value = "\(raw)".trimmingCharacters(in: .whitespaces).lowercased()
        return !value.isEmpty && !["0", "false", "no", "off"].contains(value)
    }

    /// The `Skill…` entries of a settings file's `permissions.deny`.
    public static func skillDenyRules(settings data: Data?) -> [String] {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deny = (root["permissions"] as? [String: Any])?["deny"] as? [String] else { return [] }
        return deny.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0 == "Skill" || $0.hasPrefix("Skill(") }
    }

    /// Every settings layer that can carry the switch, most specific last.
    public static func settingsFiles(project: URL?) -> [URL] {
        var out = [Paths.globalSettings,
                   URL(filePath: "/Library/Application Support/ClaudeCode/managed-settings.json")]
        if let project {
            out.append(Paths.projectClaude(project).appending(path: "settings.json"))
            out.append(Paths.projectClaude(project).appending(path: "settings.local.json"))
        }
        return out
    }
}

// MARK: - loop.md

/// The file that replaces the built-in maintenance prompt for a bare `/loop` (and `/loop <interval>`
/// with no prompt). The project's wins over the user's; the CLI reads it at every fire, so an edit
/// lands on the next iteration, and anything past 25,000 bytes is cut.
public struct LoopFile: Equatable, Sendable {
    public enum Scope: String, Sendable { case project, user }
    public static let byteLimit = 25_000
    /// Read in full up to here, so the page can show and edit it; past it only the head is kept and
    /// the page sends you to an editor. A real loop.md is a few hundred bytes.
    public static let readLimit = 1_000_000

    public let scope: Scope
    public let url: URL
    public let size: Int
    public let modifiedAt: Date?
    /// The file's text — all of it, unless it runs past `readLimit` (`isComplete` false).
    public let text: String

    public init(scope: Scope, url: URL, size: Int, modifiedAt: Date?, text: String) {
        self.scope = scope; self.url = url; self.size = size; self.modifiedAt = modifiedAt; self.text = text
    }

    public var isTruncated: Bool { size > Self.byteLimit }
    /// `text` is the whole file, so it can be edited in place.
    public var isComplete: Bool { size <= Self.readLimit }
    /// The first part of the file, for a short preview.
    public var preview: String { String(text.prefix(4096)) }
    /// What a fire actually gets: the first `byteLimit` bytes (all of it when it fits).
    public var deliveredText: String { String(text[..<Self.cutIndex(text)]) }
    /// The part past the cut, which no fire sees ("" when nothing is cut).
    public var cutText: String { String(text[Self.cutIndex(text)...]) }

    /// Where `byteLimit` UTF-8 bytes end in `text`, moved back to a character boundary.
    public static func cutIndex(_ text: String) -> String.Index {
        guard text.utf8.count > byteLimit else { return text.endIndex }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: byteLimit)
        while end > text.startIndex, String.Index(end, within: text) == nil { end = text.utf8.index(before: end) }
        return end
    }

    public static func url(_ scope: Scope, project: URL?) -> URL? {
        switch scope {
        case .project: return project.map { Paths.projectClaude($0).appending(path: "loop.md") }
        case .user: return Paths.globalClaude.appending(path: "loop.md")
        }
    }

    public static func read(_ scope: Scope, project: URL?) -> LoopFile? {
        url(scope, project: project).flatMap { read(at: $0, scope: scope) }
    }

    public static func read(at url: URL, scope: Scope) -> LoopFile? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType != .typeDirectory,
              let size = attrs[.size] as? Int else { return nil }
        let head = (try? FileHandle(forReadingFrom: url)).flatMap { h -> Data? in
            defer { try? h.close() }
            return try? h.read(upToCount: readLimit)
        } ?? Data()
        return LoopFile(scope: scope, url: url, size: size, modifiedAt: attrs[.modificationDate] as? Date,
                        text: String(decoding: head, as: UTF8.self))
    }

    /// Why a save was refused.
    public enum SaveError: LocalizedError, Equatable {
        /// The file isn't what the edit started from: something else wrote (or removed) it since.
        case changedOnDisk
        /// Creating a file that already exists.
        case exists

        public var errorDescription: String? {
            switch self {
            case .changedOnDisk: "loop.md changed on disk since you started editing — reload it, or overwrite it."
            case .exists: "loop.md already exists here."
            }
        }
    }

    /// Write `text` to `url`. `base` is the text the edit started from: the save is refused when the
    /// file no longer holds it (an agent or another editor wrote it meanwhile). A nil `base` creates
    /// the file and is refused when one exists. `force` skips both checks.
    public static func save(_ text: String, to url: URL, base: String?, force: Bool = false) throws {
        let current: String? = (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
        if !force {
            if let base, current != base { throw SaveError.changedOnDisk }
            if base == nil, current != nil { throw SaveError.exists }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Which file a bare `/loop` started in `project` would use: the project's, else the user's.
    public static func active(project: URL?) -> LoopFile? {
        read(.project, project: project) ?? read(.user, project: project)
    }

    /// A starting point for a new loop.md, in the shape the docs describe: plain instructions,
    /// written as if typed after `/loop`.
    public static let template = """
        Check this branch's pull request. If CI failed, read the failing job's log, find the cause and
        fix it locally — ask before pushing anything. If new review comments arrived, address each one
        the same way. If everything is green and quiet, say so in one line and do nothing else.
        """
}

// MARK: - Durable tasks

/// One task in `.claude/scheduled_tasks.json` — the CLI's durable store (`xLt`/`ddn`). Field for
/// field what the CLI reads; note `recurring` is only ever written when true, so an absent key
/// means a one-shot.
public struct DurableTask: Equatable, Sendable, Identifiable {
    public let id: String
    public var cron: String
    public var prompt: String
    public var createdAt: Date
    public var lastFiredAt: Date?
    public var recurring: Bool
    /// Never ages out (the 7-day expiry is skipped).
    public var permanent: Bool
    public var createdBySessionID: String?
    public var createdByPID: Int?
    public var createdInProject: String?

    public init(id: String, cron: String, prompt: String, createdAt: Date, lastFiredAt: Date? = nil,
                recurring: Bool, permanent: Bool = false, createdBySessionID: String? = nil,
                createdByPID: Int? = nil, createdInProject: String? = nil) {
        self.id = id; self.cron = cron; self.prompt = prompt; self.createdAt = createdAt
        self.lastFiredAt = lastFiredAt; self.recurring = recurring; self.permanent = permanent
        self.createdBySessionID = createdBySessionID; self.createdByPID = createdByPID
        self.createdInProject = createdInProject
    }
}

/// `.claude/scheduled_tasks.lock`: the one session per folder that runs the durable tasks.
public struct SchedulerLock: Equatable, Sendable {
    public let sessionID: String
    public let pid: Int32
    public let procStart: String?
    public let acquiredAt: Date?
}

public enum DurableTaskStore {
    public static func file(project: URL) -> URL { Paths.projectClaude(project).appending(path: "scheduled_tasks.json") }
    public static func lockFile(project: URL) -> URL { Paths.projectClaude(project).appending(path: "scheduled_tasks.lock") }

    /// The tasks, skipping malformed entries the way the CLI does (missing fields, unparseable cron).
    public static func parse(_ data: Data?) -> [DurableTask] {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tasks = root["tasks"] as? [[String: Any]] else { return [] }
        return tasks.compactMap { t in
            guard let id = t["id"] as? String, let cron = t["cron"] as? String, let prompt = t["prompt"] as? String,
                  let created = (t["createdAt"] as? NSNumber)?.doubleValue,
                  CronExpression(cron) != nil else { return nil }
            return DurableTask(
                id: id, cron: cron, prompt: prompt, createdAt: Date(timeIntervalSince1970: created / 1000),
                lastFiredAt: (t["lastFiredAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
                recurring: t["recurring"] as? Bool == true, permanent: t["permanent"] as? Bool == true,
                createdBySessionID: t["createdBySessionId"] as? String,
                createdByPID: (t["createdByPid"] as? NSNumber)?.intValue,
                createdInProject: t["createdInProject"] as? String)
        }
    }

    public static func load(project: URL) -> [DurableTask] { parse(try? Data(contentsOf: file(project: project))) }

    public static func parseLock(_ data: Data?) -> SchedulerLock? {
        guard let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = o["sessionId"] as? String, let pid = (o["pid"] as? NSNumber)?.int32Value else { return nil }
        return SchedulerLock(sessionID: sid, pid: pid, procStart: o["procStart"] as? String,
                             acquiredAt: (o["acquiredAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) })
    }

    public static func loadLock(project: URL) -> SchedulerLock? { parseLock(try? Data(contentsOf: lockFile(project: project))) }

    public enum WriteError: Error, Equatable, LocalizedError {
        case symlink(String)
        case invalidCron(String)
        case io(String)
        public var errorDescription: String? {
            switch self {
            case .symlink(let p): return "\(p) is a symlink — Claude Code refuses to schedule into it, so the app does too."
            case .invalidCron(let c): return "“\(c)” isn't a cron expression Claude Code accepts."
            case .io(let m): return m
            }
        }
    }

    /// Add a task the way the CLI's `durable: true` path does: an 8-hex id, `createdAt` in
    /// milliseconds, `recurring` only when true. Keys the app can't vouch for (`createdBySessionId`
    /// — no session created it) are left out. Returns the new id.
    @discardableResult
    public static func add(cron: String, prompt: String, recurring: Bool, project: URL, now: Date = Date()) throws -> String {
        guard CronExpression(cron) != nil else { throw WriteError.invalidCron(cron) }
        let id = String(UUID().uuidString.lowercased().filter(\.isHexDigit).prefix(8))
        var task: [String: Any] = ["id": id, "cron": cron, "prompt": prompt,
                                   "createdAt": (now.timeIntervalSince1970 * 1000).rounded()]
        if recurring { task["recurring"] = true }
        try mutate(project: project) { $0.append(task) }
        return id
    }

    public static func remove(id: String, project: URL) throws {
        try mutate(project: project) { tasks in tasks.removeAll { ($0 as? [String: Any])?["id"] as? String == id } }
    }

    /// Read-modify-write that keeps unknown keys, other tasks — and entries it can't read — exactly
    /// as they were. A file it can't parse is refused, never replaced: rewriting it would drop
    /// every task in it.
    private static func mutate(project: URL, _ change: (inout [Any]) -> Void) throws {
        let dir = Paths.projectClaude(project)
        let url = file(project: project)
        for p in [dir, url] where (try? FileManager.default.destinationOfSymbolicLink(atPath: p.path)) != nil {
            throw WriteError.symlink(p.path)
        }
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["tasks"] == nil || obj["tasks"] is [Any] else {
                throw WriteError.io("\(url.path(percentEncoded: false)) isn't a task file the app can read — fix or remove it first; it wasn't touched.")
            }
            root = obj
        }
        var tasks = root["tasks"] as? [Any] ?? []
        change(&tasks)
        root["tasks"] = tasks
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            data.append(0x0A)
            try data.write(to: url, options: .atomic)
        } catch {
            throw WriteError.io(error.localizedDescription)
        }
    }
}

// MARK: - Desktop scheduled tasks

/// A task the Claude Desktop app schedules on this machine (`~/.claude/scheduled-tasks/<name>/SKILL.md`).
/// Only its name, description and prompt live in the file — schedule, folder, model and on/off are
/// kept by the Desktop app — so these are listed for what they are, read only.
public struct DesktopScheduledTask: Equatable, Sendable, Identifiable {
    public let name: String
    public let description: String
    public let prompt: String
    public let url: URL
    public let modifiedAt: Date?
    public var id: String { url.path }

    public init(name: String, description: String, prompt: String, url: URL, modifiedAt: Date?) {
        self.name = name; self.description = description; self.prompt = prompt; self.url = url; self.modifiedAt = modifiedAt
    }

    public static var root: URL { Paths.globalClaude.appending(path: "scheduled-tasks") }

    public static func load(root: URL = root) -> [DesktopScheduledTask] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return dirs.compactMap { dir in
            let url = dir.appending(path: "SKILL.md")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let (meta, body) = frontmatter(text)
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            return DesktopScheduledTask(name: meta["name"] ?? dir.lastPathComponent,
                                        description: meta["description"] ?? "",
                                        prompt: body.trimmingCharacters(in: .whitespacesAndNewlines),
                                        url: url, modifiedAt: modified)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `---\nkey: value\n---\nbody` — flat keys only, quotes stripped.
    static func frontmatter(_ text: String) -> ([String: String], String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return ([:], text) }
        var meta: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { meta[key] = value }
        }
        return (meta, lines[(end + 1)...].joined(separator: "\n"))
    }
}
