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
///
/// A rename's preamble ("rename from/to") is rewritten as a plain edit of the new path: applied
/// to the index, a rename patch would also move the file, so unstaging one block of a renamed
/// file un-renamed it. The edit alone is what the block means.
public func buildPatch(fileHeader: [String], hunk: DiffHunk) -> String {
    var out = fileHeader
    if let newPath = renamedPath(fileHeader) {
        out = ["diff --git a/\(newPath) b/\(newPath)", "--- a/\(newPath)", "+++ b/\(newPath)"]
    }
    out.append(hunk.header)
    out.append(contentsOf: hunk.lines)
    return out.joined(separator: "\n") + "\n"
}

/// The new path of a rename or copy preamble; nil for any other diff.
func renamedPath(_ fileHeader: [String]) -> String? {
    guard fileHeader.contains(where: { $0.hasPrefix("rename from ") || $0.hasPrefix("copy from ") }) else { return nil }
    if let to = fileHeader.first(where: { $0.hasPrefix("rename to ") || $0.hasPrefix("copy to ") }) {
        return String(to.drop { $0 != " " }.dropFirst().drop { $0 != " " }.dropFirst())
    }
    return nil
}

/// `git diff` of a binary file: a "Binary files … differ" line and no hunks.
public func isBinaryDiff(_ unified: String) -> Bool {
    !unified.contains("\n@@") && !unified.hasPrefix("@@")
        && unified.components(separatedBy: "\n").contains { $0.hasPrefix("Binary files ") && $0.hasSuffix(" differ") }
}

public extension DiffHunk {
    /// The old- and new-file start lines from `@@ -a,b +c,d @@`; nil when it doesn't parse.
    var starts: (old: Int, new: Int)? {
        let parts = header.split(separator: " ")
        guard parts.count >= 3, parts[0] == "@@", parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
              let old = Int(parts[1].dropFirst().prefix { $0 != "," }),
              let new = Int(parts[2].dropFirst().prefix { $0 != "," }) else { return nil }
        return (old, new)
    }

    /// What the block's toolbar calls it: "Lines 12–40", plus git's function context when the
    /// header carries one ("Lines 12–40 · func reload()"). A brainstorm suggestion's header
    /// ("@@ -1,0 +1,1 @@ Requirements · <id>") is named by its kind instead, without the id.
    /// Falls back to the raw header if it doesn't parse.
    var label: String {
        let afterOpen = header.dropFirst(2)
        let context = afterOpen.range(of: "@@").map { afterOpen[$0.upperBound...].trimmingCharacters(in: .whitespaces) } ?? ""
        if header.hasPrefix("@@ -1,"), let dot = context.range(of: " · ") {
            return String(context[..<dot.lowerBound])
        }
        guard let starts else { return header }
        // "@@ -a,b +c,d @@" — the new side's range.
        let plus = header.split(separator: " ").dropFirst(2).first ?? ""
        let parts = plus.dropFirst().split(separator: ",")
        let count = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
        var label: String
        if count == 0 {
            label = "Removed after line \(starts.new)"
        } else {
            let end = starts.new + count - 1
            label = starts.new == end ? "Line \(starts.new)" : "Lines \(starts.new)–\(end)"
        }
        if !context.isEmpty { label += " · \(context)" }
        return label
    }

    /// Lines added and removed in this block.
    var stat: (added: Int, removed: Int) {
        lines.reduce(into: (0, 0)) { acc, l in
            if l.hasPrefix("+") { acc.0 += 1 } else if l.hasPrefix("-") { acc.1 += 1 }
        }
    }

    /// The body as `DiffView` rows, each numbered in the old and the new file from the header.
    /// "\ No newline at end of file" becomes a note.
    func numberedLines() -> [DiffLine] {
        var old = starts?.old ?? 0, new = starts?.new ?? 0
        let numbered = starts != nil
        var out: [DiffLine] = []
        for l in lines {
            let body = String(l.dropFirst())
            switch l.first {
            case "+":
                out.append(DiffLine(kind: .add, text: body, newLine: numbered ? new : nil)); new += 1
            case "-":
                out.append(DiffLine(kind: .remove, text: body, oldLine: numbered ? old : nil)); old += 1
            case "\\":
                out.append(DiffLine(kind: .note, text: body.trimmingCharacters(in: .whitespaces)))
            default:
                out.append(DiffLine(kind: .context, text: body, oldLine: numbered ? old : nil,
                                    newLine: numbered ? new : nil))
                old += 1; new += 1
            }
        }
        return out
    }
}
