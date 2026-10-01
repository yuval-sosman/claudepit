import Foundation

/// Stateful, incremental parser. Feed appended bytes via `parse(data:)`; it buffers a
/// trailing partial line between calls and resolves later records into earlier events in place
/// (a tool_result into its call, a Stop-hook summary into its hook run), so an event's index is
/// stable for the life of the transcript — the view keys its rows on it.
///
/// What it keeps is everything a reader needs to follow the session: every message with its
/// time, thinking, each tool call with its result, duration and structured detail, hook runs,
/// the context the CLI injected (CLAUDE.md, memory, environment, listings), the system prompt
/// snapshot, and the system's own notices (turn ends, compactions, API errors, mode changes).
/// What it drops is CLI bookkeeping (`ContextItemBuilder.skipped`, file-history, title records)
/// and boilerplate the model is told to ignore (`<local-command-caveat>`).
public struct SessionTranscript: @unchecked Sendable {
    private var events: [SessionEvent] = []
    private var toolIndexByID: [String: Int] = [:]   // tool_use_id → index into events
    private var hookIndexByID: [String: Int] = [:]   // hook toolUseID → index of its .hook event
    private var partialBytes = Data()                 // leftover bytes not yet ending in \n
    /// `message.id + requestId` → index of that API call's `.turnUsage` event. Claude Code writes
    /// one line per content block, each repeating the call's usage (earlier lines with partial
    /// output counts), so appending one event per line double-counted every total built on them.
    private var usageIndexByCall: [String: Int] = [:]
    private var lastSnapshotIndex: Int?
    /// Index of the last `.command` message, while nothing visible has followed it — its
    /// expansion and output attach to it rather than becoming rows of their own.
    private var openCommandIndex: Int?
    private var lastPermissionMode: String?
    private var lastEnvironment: [String: String]?
    private let timestamps = TimestampParser()
    public private(set) var metadata = TranscriptMetadata()

    public init() {}

    /// Convenience: fresh full parse of a file.
    public func parseAll(_ url: URL) -> [SessionEvent] {
        var copy = SessionTranscript()
        guard let data = try? Data(contentsOf: url) else { return [] }
        return copy.parse(data: data)
    }

    /// Append newly-arrived bytes; returns the full current event list.
    public mutating func parse(data: Data) -> [SessionEvent] {
        partialBytes.append(data)
        // Split on the newline byte (0x0A). Keep any trailing bytes (an incomplete
        // line, possibly ending mid-codepoint) buffered for the next call, so a
        // multi-byte UTF-8 char split across chunks is never decoded prematurely.
        // Walk an index and copy the remainder once: removing each line from the front
        // re-copied the rest of the buffer per line — 48 s for a 59 MB transcript.
        // Newlines found with memchr over the raw bytes (as `TranscriptDigest.parse` does): the
        // app runs debug builds, where `Data.firstIndex(of:)` walks byte by byte through the
        // generic Collection path — ~45% of loading a 66 MB transcript went to finding line ends.
        var breaks: [Int] = []
        partialBytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var from = 0
            while from < raw.count,
                  let hit = memchr(base + from, 0x0A, raw.count - from) {
                let at = base.distance(to: UnsafeRawPointer(hit))
                breaks.append(at)
                from = at + 1
            }
        }
        let origin = partialBytes.startIndex
        var start = origin
        for offset in breaks {
            let nl = origin + offset
            if nl > start { ingest(partialBytes.subdata(in: start..<nl)) }
            start = nl + 1
        }
        partialBytes = start < partialBytes.endIndex
            ? partialBytes.subdata(in: start..<partialBytes.endIndex) : Data()
        return events
    }

    // MARK: - Records

    private mutating func ingest(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let time = timestamps.seconds(obj["timestamp"] as? String)
        noteMetadata(obj, time: time)
        switch obj["type"] as? String {
        case "user":            ingestUser(obj, time: time)
        case "assistant":       ingestAssistant(obj, time: time)
        case "system":          ingestSystem(obj, time: time)
        case "attachment":      ingestAttachment(obj, time: time)
        case "permission-mode": ingestPermissionMode(obj, time: time)
        case "ai-title":        metadata.aiTitle = obj["aiTitle"] as? String ?? metadata.aiTitle
        case "agent-name":      metadata.agentName = obj["agentName"] as? String ?? metadata.agentName
        case "pr-link":
            if let url = (obj["url"] as? String) ?? (obj["prUrl"] as? String), !metadata.prLinks.contains(url) {
                metadata.prLinks.append(url)
            }
        default: break
        }
    }

    private mutating func noteMetadata(_ obj: [String: Any], time: TimeInterval?) {
        if metadata.cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty { metadata.cwd = c }
        if let v = obj["version"] as? String, !v.isEmpty { metadata.version = v }
        if let b = obj["gitBranch"] as? String, !b.isEmpty, b != "HEAD" { metadata.gitBranch = b }
        if obj["isSidechain"] as? Bool == true { metadata.isSidechain = true }
        if let t = time {
            metadata.firstTime = min(metadata.firstTime ?? t, t)
            metadata.lastTime = max(metadata.lastTime ?? t, t)
        }
    }

    // MARK: user

    private mutating func ingestUser(_ obj: [String: Any], time: TimeInterval?) {
        guard let m = obj["message"] as? [String: Any] else { return }
        var blocks: [UserContentBlock] = []
        var results: [[String: Any]] = []
        if let text = m["content"] as? String {
            blocks = [imageFileURL(from: text).map { .imageFile($0) } ?? .text(text)]
        } else if let raw = m["content"] as? [[String: Any]] {
            for b in raw {
                switch b["type"] as? String {
                case "text":
                    if let t = b["text"] as? String, !t.isEmpty {
                        blocks.append(imageFileURL(from: t).map { .imageFile($0) } ?? .text(t))
                    }
                case "image":
                    if let img = Self.decodeImage(b) { blocks.append(.image(img.data, mediaType: img.mediaType)) }
                case "document":
                    if let src = b["source"] as? [String: Any], src["type"] as? String == "base64",
                       let s = src["data"] as? String, let mediaType = src["media_type"] as? String,
                       let decoded = Data(base64Encoded: s, options: .ignoreUnknownCharacters) {
                        blocks.append(.document(decoded, mediaType: mediaType, name: b["title"] as? String))
                    }
                case "tool_result":
                    results.append(b)
                default: break
                }
            }
        }
        // The CLI's structured result rides on the record; with one result per record it is that one's.
        let detail = results.count == 1 ? obj["toolUseResult"] as? [String: Any] : nil
        for b in results { resolveResult(b, detail: detail, time: time) }
        guard !blocks.isEmpty else { return }

        // The lone image-path reference Claude Code writes after each image paste duplicates the
        // base64 entry before it.
        if blocks.count == 1, case .imageFile = blocks[0] { return }

        var msg = UserMessage(blocks: blocks, time: time)
        let text = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isMeta = obj["isMeta"] as? Bool == true
        let origin = (obj["origin"] as? [String: Any])?["kind"] as? String
        msg.originKind = origin
        msg.uuid = obj["uuid"] as? String
        msg.parentUUID = obj["parentUuid"] as? String

        if obj["isCompactSummary"] as? Bool == true {
            msg.kind = .compactSummary
        } else if isMeta, let src = obj["sourceToolUseID"] as? String, let idx = toolIndexByID[src],
                  case .tool(var inv) = events[idx] {
            // A skill's SKILL.md body or a command's expansion, injected for this tool call.
            inv.injectedContent = [inv.injectedContent, msg.text].compactMap { $0 }.joined(separator: "\n\n")
            events[idx] = .tool(inv)
            return
        } else if let note = TaskNotification.parse(text) {
            var n = note; n.time = time
            attachCompletion(n)
            msg.kind = .taskNotification
            msg.notification = n
        } else if let input = xmlTag(text, "bash-input") {
            // `!cmd` in the prompt: a shell command the person ran; its output follows.
            msg.kind = .command
            msg.commandName = "!"
            msg.commandArgs = input
            openCommandIndex = events.count
            events.append(.userMessage(msg))
            return
        } else if text.hasPrefix("<bash-stdout>") || text.hasPrefix("<bash-stderr>") {
            let out = stripANSI([xmlTag(text, "bash-stdout"), xmlTag(text, "bash-stderr")]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
            if attachToOpenCommand(output: out) { return }
            guard !out.isEmpty else { return }
            msg.kind = .commandOutput
            msg.blocks = [.text(out)]
        } else if let name = xmlTag(text, "command-name") {
            msg.kind = .command
            msg.commandName = name
            msg.commandArgs = xmlTag(text, "command-args").flatMap { $0.isEmpty ? nil : $0 }
            openCommandIndex = events.count
            events.append(.userMessage(msg))
            return
        } else if text.hasPrefix("<local-command-caveat>") {
            return   // boilerplate telling the model to ignore what follows
        } else if text.hasPrefix("<local-command-stdout>") || text.hasPrefix("<local-command-stderr>") {
            let out = stripANSI(xmlTag(text, "local-command-stdout") ?? xmlTag(text, "local-command-stderr") ?? "")
            if attachToOpenCommand(output: out) { return }
            guard !out.isEmpty else { return }
            msg.kind = .commandOutput
            msg.blocks = [.text(out)]
        } else if text.hasPrefix("[Request interrupted by user") {
            let duringTool = text.contains("for tool use")
            var n = TranscriptNotice(kind: .interrupted, time: time,
                                     title: duringTool ? "Interrupted during a tool call" : "Interrupted")
            n.level = "warning"
            append(.notice(n))
            return
        } else if isMeta, text.hasPrefix("[Image: original ") || text.hasPrefix("[Image: source: ") {
            return   // the CLI's notes on a pasted image, which the image block already shows
        } else if origin == "peer" {
            let o = obj["origin"] as? [String: Any]
            msg.kind = .peer
            msg.sender = o?["from"] as? String
            // `origin.body` is the report without the "Another Claude session sent…" envelope.
            if let body = o?["body"] as? String, !body.isEmpty { msg.blocks = [.text(body)] }
        } else if isMeta {
            // A command's expanded prompt arrives as meta right after the command itself.
            if attachToOpenCommand(expansion: msg.text) { return }
            msg.kind = .meta
        }
        // Print-mode sessions can write Claude's reply before the prompt that caused it; put a
        // prompt back ahead of reply records stamped after it, so the turn reads in order. Only
        // a typed prompt: a system-sent notification can be stamped a few ms before the tail of
        // the reply it follows, and moving it would split that turn.
        if msg.kind == .prompt, msg.startsTurn, let t = msg.time, let at = replyStart(after: t) {
            insert(.userMessage(msg), at: at)
            return
        }
        append(.userMessage(msg))
    }

    /// Where a late-written prompt belongs: before the trailing run of reply events (text,
    /// thinking, calls, usage, API errors — and the hooks and context interleaved with them)
    /// stamped after `time`. nil when it's in order, or when the run is too long to be one
    /// misplaced reply: better left as written than split down the middle.
    private func replyStart(after time: TimeInterval) -> Int? {
        var i = events.count
        while i > 0 {
            if events.count - i >= 256 { return nil }
            let e = events[i - 1]
            let partOfReply: Bool
            switch e {
            case .assistantText, .thinking, .tool, .turnUsage, .hook, .context: partOfReply = true
            case .notice(let n): partOfReply = n.kind == .apiError
            default: partOfReply = false
            }
            guard partOfReply, let et = TranscriptModel.time(of: e), et > time else { break }
            i -= 1
        }
        guard i < events.count else { return nil }
        // Only if what's being jumped over contains Claude's side of the exchange.
        let jumped = events[i...]
        let hasReply = jumped.contains { e in
            switch e {
            case .assistantText, .thinking, .tool, .turnUsage: return true
            case .notice(let n): return n.kind == .apiError
            default: return false
            }
        }
        return hasReply ? i : nil
    }

    /// Insert an event mid-list, shifting every index the parser holds past it.
    private mutating func insert(_ e: SessionEvent, at index: Int) {
        func shift(_ i: Int) -> Int { i >= index ? i + 1 : i }
        toolIndexByID = toolIndexByID.mapValues(shift)
        hookIndexByID = hookIndexByID.mapValues(shift)
        usageIndexByCall = usageIndexByCall.mapValues(shift)
        lastSnapshotIndex = lastSnapshotIndex.map(shift)
        openCommandIndex = nil
        events.insert(e, at: index)
    }

    /// Output of the command still open, if there is one. Returns false when it should be a row.
    private mutating func attachToOpenCommand(output: String) -> Bool {
        guard let idx = openCommandIndex, case .userMessage(var cmd) = events[idx] else { return false }
        if !output.isEmpty {
            cmd.commandOutput = [cmd.commandOutput, output].compactMap { $0 }.joined(separator: "\n")
            events[idx] = .userMessage(cmd)
        }
        return true
    }

    /// The expansion is the last thing a command writes, so it closes the command.
    private mutating func attachToOpenCommand(expansion: String) -> Bool {
        guard let idx = openCommandIndex, case .userMessage(var cmd) = events[idx] else { return false }
        cmd.expansion = [cmd.expansion, expansion].compactMap { $0 }.joined(separator: "\n\n")
        events[idx] = .userMessage(cmd)
        openCommandIndex = nil
        return true
    }

    /// Route a task notification's result back onto the call that started the task.
    private mutating func attachCompletion(_ n: TaskNotification) {
        guard let id = n.toolUseID, let idx = toolIndexByID[id], case .tool(var inv) = events[idx] else { return }
        inv.completion = n
        events[idx] = .tool(inv)
    }

    private mutating func resolveResult(_ b: [String: Any], detail: [String: Any]?, time: TimeInterval?) {
        guard let id = b["tool_use_id"] as? String, let idx = toolIndexByID[id],
              case .tool(var inv) = events[idx] else { return }
        let (text, images) = Self.resultContent(b["content"])
        inv.resultText = text
        inv.resultImages = images
        inv.isError = b["is_error"] as? Bool
        inv.finishedAt = time
        if var d = detail {
            // Heavy duplicates the view never reads: the file before an edit, a Read's content
            // (the result text already carries it).
            d.removeValue(forKey: "originalFile")
            if var f = d["file"] as? [String: Any], f["content"] is String {
                f.removeValue(forKey: "content"); d["file"] = f
            }
            inv.detail = d
        }
        events[idx] = .tool(inv)
    }

    private static func resultContent(_ content: Any?) -> (String?, [TranscriptImage]) {
        if let s = content as? String { return (s, []) }
        guard let arr = content as? [[String: Any]] else { return (content.map { String(describing: $0) }, []) }
        var texts: [String] = [], images: [TranscriptImage] = []
        for block in arr {
            switch block["type"] as? String {
            case "image": if let img = decodeImage(block) { images.append(img) }
            case "tool_reference": if let n = block["tool_name"] as? String { texts.append(n) }
            default: if let t = block["text"] as? String { texts.append(t) }
            }
        }
        return (texts.joined(separator: "\n"), images)
    }

    private static func decodeImage(_ b: [String: Any]) -> TranscriptImage? {
        guard let src = b["source"] as? [String: Any], src["type"] as? String == "base64",
              let s = src["data"] as? String, let mediaType = src["media_type"] as? String,
              let data = Data(base64Encoded: s, options: .ignoreUnknownCharacters) else { return nil }
        return TranscriptImage(data: data, mediaType: mediaType)
    }

    // MARK: assistant

    private mutating func ingestAssistant(_ obj: [String: Any], time: TimeInterval?) {
        guard let m = obj["message"] as? [String: Any] else { return }
        let blocks = m["content"] as? [[String: Any]] ?? []
        let model = m["model"] as? String
        if obj["isApiErrorMessage"] as? Bool == true {
            let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            var n = TranscriptNotice(kind: .apiError, time: time,
                                     title: text.isEmpty ? "API error" : text,
                                     detail: obj["error"] as? String)
            n.level = "error"
            append(.notice(n))
            return
        }
        for b in blocks {
            switch b["type"] as? String {
            case "text":
                if let t = b["text"] as? String, !t.isEmpty {
                    append(.assistantText(AssistantText(text: t, time: time,
                                                        model: model == "<synthetic>" ? nil : model)))
                }
            case "thinking":
                append(.thinking(ThinkingBlock(text: b["thinking"] as? String ?? "", time: time)))
            case "redacted_thinking":
                append(.thinking(ThinkingBlock(text: "", time: time)))
            case "tool_use":
                ingestToolUse(b, time: time)
            default: break
            }
        }
        if let model, model != "<synthetic>", let u = m["usage"] as? [String: Any] {
            let usage = TurnUsage(
                inputTokens: u["input_tokens"] as? Int ?? 0,
                outputTokens: u["output_tokens"] as? Int ?? 0,
                cacheReadTokens: u["cache_read_input_tokens"] as? Int ?? 0,
                cacheWriteTokens: u["cache_creation_input_tokens"] as? Int ?? 0,
                model: model, time: time, effort: obj["effort"] as? String)
            // One event per API call: a later line of the same call replaces the event in
            // place, keeping the line with the most output (the complete count).
            let key = (m["id"] as? String).map { "\($0)|\(obj["requestId"] as? String ?? "")" }
            if let key, let idx = usageIndexByCall[key], case .turnUsage(let old) = events[idx] {
                if usage.outputTokens >= old.outputTokens { events[idx] = .turnUsage(usage) }
            } else {
                if let key { usageIndexByCall[key] = events.count }
                events.append(.turnUsage(usage))
            }
        }
    }

    private mutating func ingestToolUse(_ b: [String: Any], time: TimeInterval?) {
        let id = b["id"] as? String ?? UUID().uuidString
        let name = b["name"] as? String ?? "?"
        let input = b["input"] as? [String: Any] ?? [:]
        let (cls, summary) = ToolInvocation.classify(name: name, input: input)
        var inv = ToolInvocation(id: id, name: name, toolClass: cls, argSummary: summary,
                                 input: input, resultText: nil, isError: nil)
        inv.startedAt = time
        toolIndexByID[id] = events.count
        append(.tool(inv))
    }

    // MARK: system

    private mutating func ingestSystem(_ obj: [String: Any], time: TimeInterval?) {
        let content = (obj["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let level = obj["level"] as? String
        switch obj["subtype"] as? String {
        case "turn_duration":
            var n = TranscriptNotice(kind: .turnEnd, time: time, title: "Turn finished")
            n.durationMs = obj["durationMs"] as? Int
            n.messageCount = obj["messageCount"] as? Int
            append(.notice(n))
        case "compact_boundary":
            let meta = obj["compactMetadata"] as? [String: Any] ?? [:]
            var n = TranscriptNotice(kind: .compaction, time: time, title: "Conversation compacted",
                                     detail: meta["trigger"] as? String, level: level)
            n.preTokens = meta["preTokens"] as? Int
            n.postTokens = meta["postTokens"] as? Int
            n.durationMs = meta["durationMs"] as? Int
            append(.notice(n))
        case "away_summary":
            guard !content.isEmpty else { return }
            append(.notice(TranscriptNotice(kind: .awaySummary, time: time, title: "Recap",
                                            detail: content, level: level)))
        case "local_command":
            // Newer CLIs record the invocation itself here too, not only its output.
            if let name = xmlTag(content, "command-name") {
                var msg = UserMessage(kind: .command, blocks: [.text(content)], time: time)
                msg.commandName = name
                msg.commandArgs = xmlTag(content, "command-args").flatMap { $0.isEmpty ? nil : $0 }
                openCommandIndex = events.count
                events.append(.userMessage(msg))
                return
            }
            let out = stripANSI(xmlTag(content, "local-command-stdout") ?? xmlTag(content, "local-command-stderr") ?? content)
            if attachToOpenCommand(output: out) { return }
            guard !out.isEmpty else { return }
            append(.notice(TranscriptNotice(kind: .localCommand, time: time, title: out, level: level)))
        case "stop_hook_summary":
            ingestStopHookSummary(obj, time: time)
        case "scheduled_task_fire":
            var n = TranscriptNotice(kind: .scheduledWakeup, time: time,
                                     title: content.isEmpty ? "Scheduled wakeup" : content,
                                     detail: obj["prompt"] as? String, level: level)
            n.loopTaskID = obj["taskId"] as? String
            append(.notice(n))
        case "informational":
            guard !content.isEmpty else { return }
            append(.notice(TranscriptNotice(kind: .informational, time: time, title: content, level: level)))
        case "api_error":
            var n = TranscriptNotice(kind: .apiError, time: time,
                                     title: content.isEmpty ? "API error" : content, level: "error")
            n.detail = (obj["error"] as? [String: Any]).map { String(describing: $0) }
            append(.notice(n))
        default:
            guard !content.isEmpty else { return }
            append(.notice(TranscriptNotice(kind: .other, time: time, title: content, level: level)))
        }
    }

    /// A Stop hook writes its run as a `hook_*` attachment *and* this summary. The summary adds
    /// what the attachment lacks (the context it fed back, whether it kept Claude going); it only
    /// becomes rows of its own when no attachment was written for the run.
    private mutating func ingestStopHookSummary(_ obj: [String: Any], time: TimeInterval?) {
        let id = obj["toolUseID"] as? String ?? ""
        let context = (obj["hookAdditionalContext"] as? [String] ?? []).joined(separator: "\n")
        let errors = (obj["hookErrors"] as? [Any] ?? []).map { ($0 as? String) ?? String(describing: $0) }
        let prevented = obj["preventedContinuation"] as? Bool ?? false
        if let idx = hookIndexByID[id], case .hook(var h) = events[idx] {
            if h.content == nil, !context.isEmpty { h.content = context }
            if h.stderr == nil, !errors.isEmpty { h.stderr = errors.joined(separator: "\n") }
            h.preventedContinuation = h.preventedContinuation || prevented
            events[idx] = .hook(h)
            return
        }
        let infos = obj["hookInfos"] as? [[String: Any]] ?? []
        guard !infos.isEmpty || !context.isEmpty || !errors.isEmpty else { return }
        for (i, info) in (infos.isEmpty ? [[:]] : infos).enumerated() {
            var h = HookExecution(id: id.isEmpty ? UUID().uuidString : "\(id)#\(i)", hookName: "Stop",
                                  hookEvent: "Stop", command: info["command"] as? String,
                                  stdout: nil, stderr: errors.isEmpty ? nil : errors.joined(separator: "\n"),
                                  content: i == 0 && !context.isEmpty ? context : nil,
                                  exitCode: nil, durationMs: info["durationMs"] as? Int)
            h.time = time
            h.outcome = errors.isEmpty ? .success : .nonBlockingError
            h.preventedContinuation = prevented
            append(.hook(h))
        }
    }

    private mutating func ingestPermissionMode(_ obj: [String: Any], time: TimeInterval?) {
        guard let mode = obj["permissionMode"] as? String else { return }
        defer { lastPermissionMode = mode; metadata.permissionMode = mode }
        guard let previous = lastPermissionMode, previous != mode else { return }
        append(.notice(TranscriptNotice(kind: .modeChange, time: time,
                                        title: "Permission mode: \(Self.modeLabel(mode))",
                                        detail: "was \(Self.modeLabel(previous))")))
    }

    static func modeLabel(_ mode: String) -> String {
        switch mode {
        case "default": return "ask"
        case "acceptEdits": return "accept edits"
        case "bypassPermissions": return "bypass"
        case "plan": return "plan"
        case "auto": return "auto"
        case "dontAsk": return "don't ask"
        default: return mode
        }
    }

    // MARK: attachment

    private mutating func ingestAttachment(_ obj: [String: Any], time: TimeInterval?) {
        guard let att = obj["attachment"] as? [String: Any], let t = att["type"] as? String else { return }
        let rendered = (obj["rendered"] as? [[String: Any]])?
            .compactMap { $0["content"] as? String }.joined(separator: "\n\n")
        let role = obj["renderedRole"] as? String
        if t.hasPrefix("hook_") { ingestHook(att, type: t, time: time); return }
        switch t {
        case "prompt_snapshot":
            ingestPromptSnapshot(att, time: time)
            return
        case "queued_command":
            ingestQueued(att, time: time)
            return
        default: break
        }
        if ContextItemBuilder.skipped.contains(t) { return }
        if var item = ContextItemBuilder.make(type: t, attachment: att, rendered: rendered, role: role, time: time) {
            if t == "environment" { describeEnvironmentChange(&item, att["snapshot"] as? [String: Any] ?? [:]) }
            append(.context(item))
            return
        }
        // Types that build no item on purpose (an empty permission grant) stay out; anything
        // else unknown keeps its raw fields.
        if t == "command_permissions" { return }
        var fields = att; fields.removeValue(forKey: "type")
        append(.attachment(Attachment(id: UUID().uuidString, type: t, fields: fields, time: time)))
    }

    /// The CLI re-sends the environment block whenever it changes — mostly the working
    /// directory moving after a `cd`. Name a re-send by what changed.
    private mutating func describeEnvironmentChange(_ item: inout ContextItem, _ snapshot: [String: Any]) {
        let current = snapshot.mapValues { String(describing: $0) }
        defer { lastEnvironment = current }
        guard let previous = lastEnvironment else { return }
        let changed = current.keys.filter { current[$0] != previous[$0] }
        if changed.isEmpty {
            item.summary = "re-sent, unchanged"
        } else if changed == ["workingDirectory"], let cwd = snapshot["workingDirectory"] as? String {
            item.title = "Working directory"
            item.summary = "→ " + ContextItemBuilder.abbreviateHome(cwd)
        }
    }

    private mutating func ingestHook(_ att: [String: Any], type t: String, time: TimeInterval?) {
        func nonEmpty(_ k: String) -> String? {
            if let s = att[k] as? String { return s.isEmpty ? nil : s }
            if let a = att[k] as? [String] { let j = a.joined(separator: "\n"); return j.isEmpty ? nil : j }
            return nil
        }
        let outcome: HookExecution.Outcome
        switch t {
        case "hook_success": outcome = .success
        case "hook_additional_context": outcome = .additionalContext
        case "hook_system_message": outcome = .systemMessage
        case "hook_cancelled": outcome = .cancelled
        case "hook_non_blocking_error": outcome = .nonBlockingError
        case "hook_blocking_error", "hook_error_during_execution": outcome = .blockingError
        default: outcome = .other
        }
        let id = att["toolUseID"] as? String ?? UUID().uuidString
        // One run can write several records (the result, then the context it injected).
        // Tool hooks share their tool's id across events (PreToolUse, PostToolUse), so only
        // records of the same hook name merge.
        let hookName = att["hookName"] as? String ?? "hook"
        if let idx = hookIndexByID[id], case .hook(var h) = events[idx], h.hookName == hookName {
            h.command = h.command ?? nonEmpty("command")
            h.stdout = h.stdout ?? nonEmpty("stdout")
            h.stderr = h.stderr ?? nonEmpty("stderr")
            h.content = h.content ?? nonEmpty("content")
            h.exitCode = h.exitCode ?? att["exitCode"] as? Int
            h.durationMs = h.durationMs ?? att["durationMs"] as? Int
            if outcome == .nonBlockingError || outcome == .blockingError || outcome == .cancelled { h.outcome = outcome }
            events[idx] = .hook(h)
            return
        }
        var h = HookExecution(
            id: id, hookName: hookName, hookEvent: att["hookEvent"] as? String ?? "",
            command: nonEmpty("command"), stdout: nonEmpty("stdout"), stderr: nonEmpty("stderr"),
            content: nonEmpty("content"), exitCode: att["exitCode"] as? Int,
            durationMs: att["durationMs"] as? Int)
        h.time = time
        h.outcome = outcome
        hookIndexByID[id] = events.count
        append(.hook(h))
    }

    /// The CLI snapshots its system prompt and tools now and then; show one row per distinct
    /// prompt. A snapshot that only adds the tool list to the previous prompt fills it in.
    private mutating func ingestPromptSnapshot(_ att: [String: Any], time: TimeInterval?) {
        let parts = (att["systemPrompt"] as? [String] ?? [])
            .filter { $0 != "__SYSTEM_PROMPT_DYNAMIC_BOUNDARY__" && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let tools = (att["tools"] as? [[String: Any]] ?? []).map {
            SystemPromptSnapshot.Tool(name: $0["name"] as? String ?? "?",
                                      description: $0["description"] as? String ?? "")
        }
        guard !parts.isEmpty || !tools.isEmpty else { return }
        let snap = SystemPromptSnapshot(time: time, parts: parts, tools: tools,
                                        cliPrefix: att["cliPrefix"] as? String)
        if let last = lastSnapshotIndex, case .systemPrompt(var prev) = events[last], prev.parts == parts {
            if tools.isEmpty || prev.tools.map(\.name) == tools.map(\.name) { return }
            if prev.tools.isEmpty {
                prev.tools = tools
                prev.cliPrefix = prev.cliPrefix ?? snap.cliPrefix
                events[last] = .systemPrompt(prev)
                return
            }
        }
        lastSnapshotIndex = events.count
        append(.systemPrompt(snap))
    }

    /// Something that reached Claude mid-turn: a background task's report, or a prompt the
    /// person typed while Claude was busy.
    private mutating func ingestQueued(_ att: [String: Any], time: TimeInterval?) {
        // A queued prompt is a string, or content blocks when it carries pasted images.
        var blocks: [UserContentBlock] = []
        if let p = att["prompt"] as? String, !p.isEmpty {
            blocks = [.text(p)]
        } else if let arr = att["prompt"] as? [[String: Any]] {
            for b in arr {
                switch b["type"] as? String {
                case "text": if let t = b["text"] as? String, !t.isEmpty { blocks.append(.text(t)) }
                case "image": if let img = Self.decodeImage(b) { blocks.append(.image(img.data, mediaType: img.mediaType)) }
                default: break
                }
            }
        }
        guard !blocks.isEmpty else { return }
        var msg = UserMessage(blocks: blocks, time: time)
        msg.isQueued = true
        let origin = att["origin"] as? [String: Any]
        if var n = TaskNotification.parse(msg.text) {
            n.time = time
            attachCompletion(n)
            msg.kind = .taskNotification
            msg.notification = n
        } else if origin?["kind"] as? String == "peer" {
            msg.kind = .peer
            msg.sender = origin?["from"] as? String
            if let body = origin?["body"] as? String, !body.isEmpty { msg.blocks = [.text(body)] }
        } else if att["isMeta"] as? Bool == true {
            msg.kind = .meta
        }
        append(.userMessage(msg))
    }

    /// Every visible event goes through here. Conversation closes an open command — anything
    /// that isn't its expansion or output ends it — while the hooks and context the CLI records
    /// around a command don't.
    private mutating func append(_ e: SessionEvent) {
        switch e {
        case .hook, .context, .systemPrompt, .attachment, .turnUsage: break
        default: openCommandIndex = nil
        }
        events.append(e)
    }
}

/// The body of the first `<name>…</name>` element in `text`, trimmed.
func xmlTag(_ text: String, _ name: String) -> String? {
    guard let a = text.range(of: "<\(name)>"),
          let b = text.range(of: "</\(name)>", range: a.upperBound..<text.endIndex) else { return nil }
    return String(text[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Detects `[Image: source: /absolute/path]` text blocks written by Claude Code
/// when the user pastes an image. Returns the file URL if the path exists, else nil.
func imageFileURL(from text: String) -> URL? {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.hasPrefix("[Image: source: ") && t.hasSuffix("]") else { return nil }
    let path = String(t.dropFirst("[Image: source: ".count).dropLast())
    guard path.hasPrefix("/") else { return nil }
    let url = URL(fileURLWithPath: path)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

/// Reads a transcript file incrementally, for a live view: each `read()` parses only what was
/// appended since the last one (a half-written last line waits for the rest). A file that shrank
/// — rewritten or truncated — is read again from the start.
public struct TranscriptFileTail: @unchecked Sendable {
    public let url: URL
    private var transcript = SessionTranscript()
    private var offset: UInt64 = 0
    private var started = false

    public init(url: URL) { self.url = url }

    /// Everything parsed so far, or nil when the file hasn't changed since the last read.
    public mutating func read() -> (events: [SessionEvent], metadata: TranscriptMetadata)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset {
            transcript = SessionTranscript()
            offset = 0
        }
        guard size > offset || !started else { return nil }
        started = true
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset += UInt64(data.count)
        return (transcript.parse(data: data), transcript.metadata)
    }
}
