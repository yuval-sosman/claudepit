import Foundation

/// Stateful, incremental parser. Feed appended bytes via `parse(data:)`; it buffers a
/// trailing partial line between calls and resolves tool_result → tool_use matches in place.
public struct SessionTranscript: @unchecked Sendable {
    private var events: [SessionEvent] = []
    private var toolIndexByID: [String: Int] = [:]   // tool_use_id → index into events
    private var partialBytes = Data()                 // leftover bytes not yet ending in \n
    private var lastModel: String = ""                // most recent real API model, for compact_boundary

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
        while let nl = partialBytes.firstIndex(of: 0x0A) {
            let lineData = partialBytes[partialBytes.startIndex..<nl]
            partialBytes.removeSubrange(partialBytes.startIndex...nl)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                ingest(line)
            }
        }
        return events
    }

    private mutating func ingest(_ line: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else { return }
        switch obj["type"] as? String {
        case "user":
            guard let m = obj["message"] as? [String: Any] else { return }
            var contentBlocks: [UserContentBlock] = []
            var toolResultBlocks: [[String: Any]] = []
            if let text = m["content"] as? String {
                if let url = imageFileURL(from: text) {
                    contentBlocks = [.imageFile(url)]
                } else {
                    contentBlocks = [.text(text)]
                }
            } else if let blocks = m["content"] as? [[String: Any]] {
                for b in blocks {
                    switch b["type"] as? String {
                    case "text":
                        if let t = b["text"] as? String, !t.isEmpty {
                            if let url = imageFileURL(from: t) {
                                contentBlocks.append(.imageFile(url))
                            } else {
                                contentBlocks.append(.text(t))
                            }
                        }
                    case "image":
                        if let src = b["source"] as? [String: Any],
                           src["type"] as? String == "base64",
                           let dataStr = src["data"] as? String,
                           let mediaType = src["media_type"] as? String,
                           let decoded = Data(base64Encoded: dataStr, options: .ignoreUnknownCharacters) {
                            contentBlocks.append(.image(decoded, mediaType: mediaType))
                        }
                    case "document":
                        if let src = b["source"] as? [String: Any],
                           src["type"] as? String == "base64",
                           let dataStr = src["data"] as? String,
                           let mediaType = src["media_type"] as? String,
                           let decoded = Data(base64Encoded: dataStr, options: .ignoreUnknownCharacters) {
                            contentBlocks.append(.document(decoded, mediaType: mediaType, name: b["title"] as? String))
                        }
                    case "tool_result":
                        toolResultBlocks.append(b)
                    default:
                        break
                    }
                }
                for b in toolResultBlocks { resolveResult(b) }
            }
            if !contentBlocks.isEmpty {
                // Suppress the lone image-path reference entry Claude Code injects after
                // each image paste — it duplicates the base64 entry that precedes it.
                let isImagePathOnly = contentBlocks.count == 1 && {
                    if case .imageFile = contentBlocks[0] { return true }
                    return false
                }()
                if !isImagePathOnly {
                    events.append(.userMessage(contentBlocks))
                }
            }
        case "assistant":
            guard let m = obj["message"] as? [String: Any],
                  let blocks = m["content"] as? [[String: Any]] else { return }
            for b in blocks {
                switch b["type"] as? String {
                case "text":
                    if let t = b["text"] as? String, !t.isEmpty { events.append(.assistantText(t)) }
                case "tool_use":
                    ingestToolUse(b)
                default: break
                }
            }
            if let model = m["model"] as? String, model != "<synthetic>",
               let u = m["usage"] as? [String: Any] {
                lastModel = model
                events.append(.turnUsage(TurnUsage(
                    inputTokens: u["input_tokens"] as? Int ?? 0,
                    outputTokens: u["output_tokens"] as? Int ?? 0,
                    cacheReadTokens: u["cache_read_input_tokens"] as? Int ?? 0,
                    cacheWriteTokens: u["cache_creation_input_tokens"] as? Int ?? 0,
                    model: model)))
            }
        case "system":
            if let c = obj["content"] as? String { events.append(.systemNote(c)) }
        case "attachment":
            guard let att = obj["attachment"] as? [String: Any],
                  let t = att["type"] as? String else { return }
            if t.hasPrefix("hook_") {
                func nonEmpty(_ k: String) -> String? {
                    if let s = att[k] as? String { return s.isEmpty ? nil : s }
                    if let a = att[k] as? [String] { let j = a.joined(separator: "\n"); return j.isEmpty ? nil : j }
                    return nil
                }
                events.append(.hook(HookExecution(
                    id: att["toolUseID"] as? String ?? UUID().uuidString,
                    hookName: att["hookName"] as? String ?? "hook",
                    hookEvent: att["hookEvent"] as? String ?? "",
                    command: nonEmpty("command"),
                    stdout: nonEmpty("stdout"),
                    stderr: nonEmpty("stderr"),
                    content: nonEmpty("content"),
                    exitCode: att["exitCode"] as? Int,
                    durationMs: att["durationMs"] as? Int)))
                return
            }
            // High-frequency internal bookkeeping → too noisy to show as rows.
            let skip: Set<String> = ["task_reminder", "skill_listing"]
            if skip.contains(t) || t.hasSuffix("_delta") { return }
            var fields = att; fields.removeValue(forKey: "type")
            events.append(.attachment(Attachment(id: UUID().uuidString, type: t, fields: fields)))
        default: break
        }
    }

    private mutating func ingestToolUse(_ b: [String: Any]) {
        let id = b["id"] as? String ?? UUID().uuidString
        let name = b["name"] as? String ?? "?"
        let input = b["input"] as? [String: Any] ?? [:]
        let (cls, summary) = ToolInvocation.classify(name: name, input: input)
        let inv = ToolInvocation(id: id, name: name, toolClass: cls, argSummary: summary,
                                 input: input, resultText: nil, isError: nil)
        toolIndexByID[id] = events.count
        events.append(.tool(inv))
    }

    private mutating func resolveResult(_ b: [String: Any]) {
        guard let id = b["tool_use_id"] as? String, let idx = toolIndexByID[id],
              case .tool(var inv) = events[idx] else { return }
        inv.resultText = Self.resultString(b["content"])
        inv.isError = b["is_error"] as? Bool
        events[idx] = .tool(inv)
    }

    private static func resultString(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return content.map { String(describing: $0) }
    }
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
