import Foundation

/// A Claudepit task phase a session ran, read off the phase prompt `TaskRunner.phasePrompt`
/// types into the agent:
///
///     /claudepit-task-review
///
///     You are running the **Code Review** phase (step 5 of 5) of Claudepit task `e433a56e`.
///     …
///     ## Task
///     Let worktrees merge the latest base
public struct SessionTaskRef: Equatable, Sendable, Hashable {
    public let taskID: String
    /// The command's suffix: `brainstorm`, `spec`, `plan`, `implement`, `review`, `fix`, `merge`.
    public let command: String
    /// The task's name as the prompt carried it (the live task may have been renamed since).
    public let taskName: String?

    public init(taskID: String, command: String, taskName: String?) {
        self.taskID = taskID; self.command = command; self.taskName = taskName
    }

    /// Short label for the row's phase pill.
    public var phaseLabel: String {
        switch command {
        case "spec": return "Spec"
        case "review": return "Review"
        default: return command.prefix(1).uppercased() + command.dropFirst()
        }
    }
}

/// What a transcript's first user records say about the session — enough to title it.
///
/// The CLI records a typed slash command as `<command-name>/goal</command-name>…<command-args>…`
/// and its output as `<local-command-stdout>`, both as ordinary user records, plus `isMeta`
/// caveats. The old title rule skipped anything starting with `<`, so a session opened with
/// `/clear` → `/model` → `/goal …` had no title at all and showed as its UUID.
public struct SessionOpening: Equatable, Sendable {
    /// The first prompt the person typed (first non-empty line, whitespace collapsed).
    public var prompt: String?
    /// The first slash command that carried arguments (`/goal review the panel`), else the first
    /// bare one (`/model`) — a title only when nothing better exists.
    public var command: String?
    public var commandHasArgs = false
    public var cwd: String?
    public var task: SessionTaskRef?
    /// At least one user record exists. A transcript with none is a stub the CLI writes when a
    /// session is resumed elsewhere (`last-prompt`, `mode`, `bridge-session` only) — nothing to show.
    public var hasConversation = false

    public init() {}

    /// Nothing later in the file can improve on this, so a rescan need not re-read it.
    public var isSettled: Bool { prompt != nil || task != nil }

    public static func parse<S: StringProtocol>(userLines: [S]) -> SessionOpening {
        var o = SessionOpening()
        for line in userLines {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "user" else { continue }
            o.hasConversation = true
            if o.cwd == nil, let cwd = obj["cwd"] as? String, !cwd.isEmpty { o.cwd = cwd }
            if obj["isMeta"] as? Bool == true || obj["isSidechain"] as? Bool == true { continue }
            guard let message = obj["message"] as? [String: Any] else { continue }
            let text: String?
            if let s = message["content"] as? String {
                text = s
            } else if let blocks = message["content"] as? [[String: Any]] {
                text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String
            } else { text = nil }
            guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }

            if raw.hasPrefix("<command-name>") || raw.hasPrefix("<command-message>") {
                guard let name = tag("command-name", in: raw) else { continue }
                let args = clean(tag("command-args", in: raw) ?? "")
                if !args.isEmpty, !o.commandHasArgs {
                    o.command = "\(name) \(args)"; o.commandHasArgs = true
                } else if o.command == nil {
                    o.command = name
                }
                continue
            }
            if raw.hasPrefix("<") || raw.hasPrefix("{") { continue }   // stdout, caveats, hook echoes
            if raw.hasPrefix("[Request interrupted") { continue }      // the CLI's own marker, not a prompt
            if o.task == nil, let ref = taskRef(in: raw) { o.task = ref }
            if o.prompt == nil { o.prompt = clean(raw) }
            if o.isSettled { break }
        }
        return o
    }

    /// The text between `<name>` and `</name>`.
    static func tag(_ name: String, in s: String) -> String? {
        guard let a = s.range(of: "<\(name)>"),
              let b = s.range(of: "</\(name)>", range: a.upperBound..<s.endIndex) else { return nil }
        return String(s[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First non-empty line, whitespace collapsed, capped — a title, not the prompt.
    static func clean(_ s: String) -> String {
        let first = s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let collapsed = first.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > 200 ? String(collapsed.prefix(200)) + "…" : collapsed
    }

    static func taskRef(in text: String) -> SessionTaskRef? {
        let prefix = "/claudepit-task-"
        guard text.hasPrefix(prefix) else { return nil }
        let command = String(text.dropFirst(prefix.count).prefix { $0.isLetter || $0 == "-" })
        guard !command.isEmpty,
              let open = text.range(of: "Claudepit task `"),
              let close = text.range(of: "`", range: open.upperBound..<text.endIndex) else { return nil }
        let id = String(text[open.upperBound..<close.lowerBound])
        guard !id.isEmpty, id.allSatisfy(\.isHexDigit) else { return nil }
        var name: String?
        if let header = text.range(of: "\n## Task\n") {
            name = text[header.upperBound...].split(separator: "\n", maxSplits: 1).first
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if name?.isEmpty == true { name = nil }
        }
        return SessionTaskRef(taskID: id, command: command, taskName: name)
    }
}

public enum SessionTitle {
    /// The best title available, in order: a task phase's task name, the CLI's own `ai-title`,
    /// the first prompt, the first slash command that carried arguments, any slash command,
    /// and only then the session id.
    public static func resolve(aiTitle: String?, opening: SessionOpening, fallback: String) -> String {
        if let name = opening.task?.taskName { return name }
        if let t = aiTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        if let p = opening.prompt { return p }
        if let c = opening.command { return c }
        return fallback
    }
}
