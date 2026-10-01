import Foundation

/// How much of a memory file Claude actually reads: the first 200 lines or 25 KB of its body,
/// whichever comes first. Everything past that point never reaches the model.
///
/// One rule shared by the Memory page's detail panel (which draws the "Claude stops reading here"
/// cut), the sidebar's over-limit marker and the fix-it prompt — so the three can't disagree about
/// which files are too long. Measured on the body, after the frontmatter block.
public enum MemoryReadLimit {
    public static let maxLines = 200
    public static let maxBytes = 25_000

    /// A body's size, carried on `MemoryNode` so the sidebar can mark a file without reading it.
    public struct Size: Sendable, Hashable {
        public let lines: Int
        public let bytes: Int
        public init(lines: Int, bytes: Int) { self.lines = lines; self.bytes = bytes }

        public var exceedsLimit: Bool { lines > MemoryReadLimit.maxLines || bytes > MemoryReadLimit.maxBytes }

        /// "459 lines · 52.9 KB" — the limit's own units (KB = 1000 bytes, like `maxBytes`).
        public var label: String {
            "\(lines) lines · \(String(format: "%.1f", Double(bytes) / 1000)) KB"
        }
    }

    public static func size(of body: String) -> Size {
        Size(lines: body.components(separatedBy: "\n").count, bytes: body.utf8.count)
    }

    /// Splits `body` where Claude stops reading. Nil when the whole body fits.
    public static func split(_ body: String) -> (kept: String, remainder: String)? {
        let lines = body.components(separatedBy: "\n")
        guard lines.count > maxLines || body.utf8.count > maxBytes else { return nil }
        var bytes = 0
        var kept = 0
        for (i, line) in lines.enumerated() {
            let lineBytes = line.utf8.count + 1
            if i >= maxLines || bytes + lineBytes > maxBytes { break }
            kept = i + 1
            bytes += lineBytes
        }
        return (lines.prefix(kept).joined(separator: "\n"),
                lines.dropFirst(kept).joined(separator: "\n"))
    }

    /// One file the fix prompt names.
    public struct Oversized: Sendable, Equatable {
        public let filename: String
        public let size: Size
        public init(filename: String, size: Size) { self.filename = filename; self.size = size }
    }

    /// herdr agent name for the fix — one per project, so a second click focuses the running
    /// agent instead of starting another one on the same files.
    public static func fixAgentName(projectPath: URL) -> String {
        "memory-fix-\(projectPath.lastPathComponent)"
    }

    /// The brief handed to the herdr agent: why the files are a problem, what done looks like,
    /// and the rules that keep the split from losing anything.
    public static func fixPrompt(memoryDir: URL, files: [Oversized]) -> String {
        let limit = "\(maxLines) lines or \(maxBytes / 1000) KB"
        var out: [String] = []
        out.append("Fix the oversized memory files in this project's memory directory.")
        out.append("")
        out.append("## Why")
        out.append("Claude reads only the first \(limit) of a memory file, whichever comes first. "
                 + "Everything past that point never reaches the model: the facts there are silently "
                 + "lost, and every session that relies on them works from a partial picture. "
                 + "Claudepit's Memory page marks the cut with \"Claude stops reading here\".")
        out.append("")
        out.append("## Files over the limit (\(limit), measured after the frontmatter)")
        for f in files { out.append("- `\(f.filename)` — \(f.size.label)") }
        out.append("")
        out.append("## Goal")
        out.append("Bring every file above under the limit without losing anything load-bearing.")
        out.append("1. **Make it shorter where possible.** Cut history that only narrates how something "
                 + "evolved (keep the current behaviour and the decision, drop the timeline), claims that "
                 + "were superseded or contradicted later in the file, facts repeated within the file or "
                 + "in another topic file, and anything the repo's CLAUDE.md or the code already states. "
                 + "Compress long prose into short bullets.")
        out.append("2. **Split what is still too big.** When a file covers several sub-areas, move each one "
                 + "into its own focused topic file (kebab-case name), one cohesive area per file.")
        out.append("3. **Leave headroom.** Aim for at most 150 lines and 20 KB per resulting file, so the "
                 + "next memory pass doesn't push it straight back over.")
        out.append("")
        out.append("## Rules")
        out.append("- Work only inside the memory directory below.")
        out.append("- Never drop the only record of a decision, a bug's root cause, or a \"don't do X "
                 + "because Y\" rule: move it, don't delete it.")
        out.append("- Every file keeps its frontmatter. A file split off from another copies the parent's "
                 + "`sessions` array and appends the current session id; never remove an id.")
        out.append("- Update `MEMORY.md`: one line per topic file, under 20 lines, and within the limit itself.")
        out.append("- Fix every link: anything pointing at moved content (`[Title](./file.md)`) now points at "
                 + "the new file, and each topic file still ends with its `## See also` section.")
        out.append("- Append one entry to `log.json` (type `write`, title \"Split oversized memory files\") "
                 + "whose `changes` list every file you created, updated or deleted.")
        out.append("- When done, run `wc -l -c` on every `.md` file in the directory and report the "
                 + "before/after sizes.")
        out.append("")
        out.append("## Paths (absolute — use exactly as given)")
        out.append("memoryDir=\(memoryDir.path)")
        return out.joined(separator: "\n")
    }
}
