import Foundation

/// Turns the CLI's context attachments — what it injects into the model's context that nobody
/// typed — into `ContextItem`s with a readable title, a one-line summary and titled bodies.
///
/// The attachment shapes were catalogued from real transcripts (CLI 2.1.236–2.1.285). Anything
/// unknown still surfaces: with a `rendered` text it becomes a generic item, and without one the
/// parser keeps it as a raw `Attachment`. Nothing the model saw is silently dropped except
/// `skipped`, which is bookkeeping.
enum ContextItemBuilder {
    /// Records that never reach the model, or repeat on every API call and say nothing new:
    /// the remaining-token counter, the deferred-tool schema cache, the org id, the
    /// thinking-block cache diagnostics. `prompt_snapshot`, `queued_command` and `hook_*` are
    /// parsed elsewhere.
    static let skipped: Set<String> = [
        "total_tokens_reminder", "deferred_tools_record", "credential_org", "thinking_drop",
    ]

    static func make(type t: String, attachment att: [String: Any], rendered: String?,
                     role: String?, time: TimeInterval?) -> ContextItem? {
        func str(_ k: String) -> String? {
            guard let v = att[k] as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return v
        }
        func strs(_ k: String) -> [String] { att[k] as? [String] ?? [] }
        var item = ContextItem(type: t, time: time, title: humanize(t), summary: "",
                               rendered: rendered, role: role)
        switch t {
        case "instructions":
            let files = att["files"] as? [[String: Any]] ?? []
            item.title = "Instructions"
            item.sections = files.map { f in
                let path = f["path"] as? String ?? ""
                return .init(title: fileName(path), subtitle: instructionKind(f["type"] as? String),
                             body: f["content"] as? String ?? "", path: path)
            }
            item.summary = item.sections.map(\.title).joined(separator: " · ")

        case "nested_memory":
            let content = att["content"] as? [String: Any]
            let path = (content?["path"] as? String) ?? str("path") ?? ""
            item.title = "Instructions"
            item.sections = [.init(title: str("displayPath") ?? fileName(path),
                                   subtitle: instructionKind(content?["type"] as? String),
                                   body: content?["content"] as? String ?? "", path: path)]
            item.summary = "\(str("displayPath") ?? fileName(path)) (nested)"

        case "environment":
            let snap = att["snapshot"] as? [String: Any] ?? [:]
            let labels: [(String, String)] = [
                ("workingDirectory", "Working directory"), ("isGitRepo", "Git repository"),
                ("isWorktree", "Worktree"), ("platform", "Platform"), ("shell", "Shell"),
                ("osVersion", "OS"), ("scratchpadDirectory", "Scratchpad"),
                ("additionalWorkingDirectories", "Extra directories"),
            ]
            var lines: [String] = []
            for (key, label) in labels {
                guard let v = snap[key] else { continue }
                if let a = v as? [Any], a.isEmpty { continue }
                lines.append("\(label): \(display(v))")
            }
            item.title = "Environment"
            item.sections = [.init(title: "Environment", body: lines.joined(separator: "\n"))]
            let cwd = (snap["workingDirectory"] as? String).map(abbreviateHome)
            item.summary = [cwd, snap["platform"] as? String, snap["shell"] as? String]
                .compactMap { $0 }.joined(separator: " · ")

        case "session_context":
            let ctx = att["context"] as? [String: Any] ?? [:]
            item.title = "Session context"
            item.sections = ctx.keys.sorted().map { .init(title: humanizeKey($0), body: display(ctx[$0] ?? "")) }
            item.summary = ctx.keys.sorted().map(humanizeKey).joined(separator: " · ")

        case "date":
            item.title = "Date"
            item.summary = str("date") ?? ""
        case "date_change":
            item.title = "Date changed"
            item.summary = str("newDate") ?? ""

        case "model":
            let id = att["identity"] as? [String: Any] ?? [:]
            item.title = "Model identity"
            item.summary = [id["marketingName"] as? String, id["modelId"] as? String,
                            (id["knowledgeCutoff"] as? String).map { "cutoff \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")

        case "skill_listing":
            let count = att["skillCount"] as? Int ?? strs("names").count
            item.title = "Skills"
            item.summary = "\(count) available" + ((att["isInitial"] as? Bool) == false ? " (updated)" : "")
            if let c = str("content") { item.sections = [.init(title: "Skills", body: c)] }

        case "dynamic_skill":
            let names = strs("skillNames")
            item.title = "Skills discovered"
            item.summary = names.joined(separator: ", ") + (str("displayPath").map { " in \($0)" } ?? "")

        case "invoked_skills":
            let skills = att["skills"] as? [[String: Any]] ?? []
            item.title = "Skills carried over"
            item.sections = skills.map { .init(title: $0["name"] as? String ?? "?",
                                               subtitle: $0["path"] as? String,
                                               body: $0["content"] as? String ?? "") }
            item.summary = item.sections.map(\.title).joined(separator: ", ")

        case "agent_listing_delta":
            let added = strs("addedTypes"), removed = strs("removedTypes")
            item.title = "Agent types"
            item.summary = delta(added: added, removed: removed)
            if !strs("addedLines").isEmpty {
                item.sections = [.init(title: "Agent types", body: strs("addedLines").joined(separator: "\n"))]
            }

        case "mcp_instructions_delta":
            let names = strs("addedNames")
            item.title = "MCP instructions"
            item.summary = delta(added: names, removed: strs("removedNames"))
            let blocks = strs("addedBlocks")
            item.sections = blocks.enumerated().map { i, block in
                var lines = block.components(separatedBy: "\n")
                var title = i < names.count ? names[i] : "Server \(i + 1)"
                if let first = lines.first, first.hasPrefix("## ") {
                    title = String(first.dropFirst(3)); lines.removeFirst()
                }
                return .init(title: title, body: lines.joined(separator: "\n"))
            }

        case "deferred_tools_delta":
            let added = strs("addedNames"), surfaced = strs("surfacedNames")
            item.title = "Tools"
            var parts: [String] = []
            if !added.isEmpty { parts.append("\(added.count) deferred") }
            if !surfaced.isEmpty { parts.append("\(surfaced.count) loaded") }
            if !strs("removedNames").isEmpty { parts.append("\(strs("removedNames").count) removed") }
            item.summary = parts.joined(separator: " · ")
            var sections: [ContextItem.Section] = []
            if !surfaced.isEmpty { sections.append(.init(title: "Loaded", body: surfaced.joined(separator: "\n"))) }
            if !added.isEmpty { sections.append(.init(title: "Deferred (load via ToolSearch)", body: added.joined(separator: "\n"))) }
            if !strs("removedNames").isEmpty { sections.append(.init(title: "Removed", body: strs("removedNames").joined(separator: "\n"))) }
            item.sections = sections

        case "auto_mode":
            item.title = "Auto mode"
            item.summary = "on"
        case "auto_mode_exit":
            item.title = "Auto mode"
            item.summary = "off"

        case "plan_mode":
            item.title = "Plan mode"
            item.summary = "on" + (str("planFilePath").map { " · \(fileName($0))" } ?? "")
            item.path = str("planFilePath")
        case "plan_mode_exit":
            item.title = "Plan mode"
            item.summary = "exited" + (str("planFilePath").map { " · \(fileName($0))" } ?? "")
            item.path = str("planFilePath")
        case "plan_mode_reentry":
            item.title = "Plan mode"
            item.summary = "re-entered" + (str("planFilePath").map { " · \(fileName($0))" } ?? "")
            item.path = str("planFilePath")
        case "plan_file_reference":
            let path = str("planFilePath") ?? ""
            item.title = "Plan file"
            item.summary = fileName(path)
            item.path = path.isEmpty ? nil : path
            if let c = str("planContent") { item.sections = [.init(title: fileName(path), body: c, path: path)] }

        case "remote_session_change":
            item.title = "Attribution"
            item.summary = "commit and PR trailers"
            var sections: [ContextItem.Section] = []
            if let c = str("commit") { sections.append(.init(title: "Commit trailer", body: c)) }
            if let p = str("pr") { sections.append(.init(title: "Pull request footer", body: p)) }
            item.sections = sections

        case "silent_turn_reminder":
            item.title = "Reminder"
            item.summary = str("text") ?? "give the user a status update"
        case "task_reminder":
            item.title = "Reminder"
            item.summary = "task tools haven't been used recently"

        case "read_truncation_notice":
            item.title = "Read truncated"
            item.summary = firstLine(str("banner") ?? "")
            if let b = str("banner") { item.sections = [.init(title: "Notice", body: b)] }

        case "file":
            let content = (att["content"] as? [String: Any])?["file"] as? [String: Any]
            let path = str("filename") ?? (content?["filePath"] as? String) ?? ""
            item.title = "File attached"
            item.summary = str("displayPath") ?? fileName(path)
            if let body = content?["content"] as? String {
                item.sections = [.init(title: fileName(path), body: body, path: path)]
            }
        case "compact_file_reference":
            item.title = "File reference"
            item.summary = str("displayPath") ?? fileName(str("filename") ?? "")

        case "edited_text_file":
            let path = str("filename") ?? ""
            item.title = "File changed on disk"
            item.summary = fileName(path)
            if let s = str("snippet") { item.sections = [.init(title: fileName(path), body: s, path: path)] }

        case "diagnostics":
            let files = att["files"] as? [[String: Any]] ?? []
            var errors = 0, warnings = 0
            item.sections = files.map { f in
                let path = f["uri"] as? String ?? ""
                let diags = f["diagnostics"] as? [[String: Any]] ?? []
                let lines: [String] = diags.map { d in
                    let sev = d["severity"] as? String ?? ""
                    if sev.lowercased().hasPrefix("err") { errors += 1 } else { warnings += 1 }
                    let line = ((d["range"] as? [String: Any])?["start"] as? [String: Any])?["line"] as? Int
                    return "\(line.map { "L\($0 + 1)" } ?? "?")  \(sev): \(d["message"] as? String ?? "")"
                }
                return .init(title: fileName(path), body: lines.joined(separator: "\n"), path: path)
            }
            item.title = "Diagnostics"
            var parts: [String] = []
            if errors > 0 { parts.append("\(errors) error\(errors == 1 ? "" : "s")") }
            if warnings > 0 { parts.append("\(warnings) warning\(warnings == 1 ? "" : "s")") }
            let names = item.sections.map(\.title).joined(separator: ", ")
            item.summary = parts.joined(separator: ", ") + (names.isEmpty ? "" : " in \(names)")

        case "goal_status":
            item.title = "Goal"
            let met = att["met"] as? Bool ?? false
            item.summary = (met ? "met · " : "active · ") + firstLine(str("condition") ?? "")
            if let c = str("condition") { item.sections = [.init(title: "Condition", body: c)] }

        case "command_permissions":
            let tools = strs("allowedTools")
            guard !tools.isEmpty else { return nil }
            item.title = "Command permissions"
            item.summary = tools.joined(separator: ", ")

        default:
            // Unknown, but the model saw it: show it by what it said.
            guard let rendered, !rendered.isEmpty else { return nil }
            item.summary = firstLine(stripReminderTags(rendered))
        }
        return item
    }

    // MARK: - Helpers

    static func humanize(_ type: String) -> String {
        let words = type.split(separator: "_").map(String.init)
        guard let first = words.first else { return type }
        return ([first.capitalized] + words.dropFirst()).joined(separator: " ")
    }

    /// `gitStatus` → `Git status`, `userEmail` → `User email`.
    static func humanizeKey(_ key: String) -> String {
        var out = ""
        for (i, c) in key.enumerated() {
            // uppercased()/lowercased() can return more than one character (ß → SS).
            if c.isUppercase && i > 0 { out += " " + c.lowercased() }
            else { out += i == 0 ? c.uppercased() : String(c) }
        }
        return out
    }

    static func instructionKind(_ kind: String?) -> String? {
        switch kind {
        case "Project": return "Project instructions"
        case "User": return "User instructions"
        case "Local": return "Local instructions"
        case "AutoMem": return "Auto-memory index"
        case "Managed": return "Managed policy"
        case let k?: return k
        case nil: return nil
        }
    }

    static func fileName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    static func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func firstLine(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.components(separatedBy: "\n").first ?? t
    }

    /// The `<system-reminder>` envelope the CLI wraps injected context in.
    static func stripReminderTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<system-reminder>", with: "")
            .replacingOccurrences(of: "</system-reminder>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func delta(added: [String], removed: [String]) -> String {
        var parts: [String] = []
        if !added.isEmpty { parts.append(added.joined(separator: ", ")) }
        if !removed.isEmpty { parts.append("removed " + removed.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private static func display(_ v: Any) -> String {
        switch v {
        case let b as Bool: return b ? "yes" : "no"
        case let s as String: return s
        case let a as [Any]: return a.map { display($0) }.joined(separator: ", ")
        default: return String(describing: v)
        }
    }
}
