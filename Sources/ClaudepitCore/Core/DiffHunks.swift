import Foundation

/// One hunk of a unified diff: its `@@ … @@` header line plus the body lines
/// (each keeping its leading `+`/`-`/` `). Pure; used to reconstruct a
/// single-hunk patch for `git apply --cached`.
public struct DiffHunk: Sendable, Identifiable {
    public var id: Int
    public let header: String
    public let lines: [String]
    public init(id: Int, header: String, lines: [String]) {
        self.id = id; self.header = header; self.lines = lines
    }
}

/// Split a unified `git diff` into its file preamble (everything before the
/// first `@@`) and its hunks. Lines are kept verbatim.
public func parseHunks(_ unified: String) -> (fileHeader: [String], hunks: [DiffHunk]) {
    var fileHeader: [String] = []
    var hunks: [DiffHunk] = []
    var current: (header: String, lines: [String])? = nil
    var seenHunk = false

    func flush() {
        if let c = current { hunks.append(DiffHunk(id: hunks.count, header: c.header, lines: c.lines)) }
        current = nil
    }

    for line in unified.components(separatedBy: "\n") {
        if line.hasPrefix("@@") {
            flush()
            current = (header: line, lines: [])
            seenHunk = true
        } else if current != nil {
            current!.lines.append(line)
        } else if !seenHunk {
            if line.isEmpty { continue }
            fileHeader.append(line)
        }
    }
    flush()
    // Drop a trailing empty body line produced by a final newline.
    hunks = hunks.map { h in
        var lines = h.lines
        if lines.last == "" { lines.removeLast() }
        return DiffHunk(id: h.id, header: h.header, lines: lines)
    }
    return (fileHeader, hunks)
}

/// Reconstruct a valid single-hunk patch that `git apply --cached` accepts:
/// the file preamble, the hunk header, then the hunk body. Trailing newline
/// required — git apply rejects a patch without it.
public func buildPatch(fileHeader: [String], hunk: DiffHunk) -> String {
    var out = fileHeader
    out.append(hunk.header)
    out.append(contentsOf: hunk.lines)
    return out.joined(separator: "\n") + "\n"
}
