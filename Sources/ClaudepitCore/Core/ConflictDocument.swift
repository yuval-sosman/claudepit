import Foundation

/// A conflicted file's text split at its conflict markers, so the Source Control sheet can show
/// each conflict's two sides and resolve one at a time — "Accept Current / Incoming / Both", the
/// way an editor's merge view does — by rewriting the file. Pure; `ConflictFileIO` does the disk.
///
/// Markers are git's: `<<<<<<< <current label>`, an optional `||||||| <base label>` (diff3 /
/// zdiff3 style), `=======`, `>>>>>>> <incoming label>`, each at the start of a line. The text
/// round-trips exactly: rejoining the segments gives back the file, CRLF and the trailing
/// newline included, so resolving one conflict touches nothing else. An unterminated or
/// malformed marker run stays text rather than being guessed at.
public struct ConflictDocument: Equatable, Sendable {
    public enum Segment: Equatable, Sendable {
        case text([String])
        case conflict(ConflictBlock)
    }

    public let segments: [Segment]

    public var conflicts: [ConflictBlock] {
        segments.compactMap { if case .conflict(let c) = $0 { return c } else { return nil } }
    }
    public var hasConflicts: Bool { !conflicts.isEmpty }

    public init(segments: [Segment]) { self.segments = segments }

    public static func parse(_ text: String) -> ConflictDocument {
        let lines = text.components(separatedBy: "\n")
        var segments: [Segment] = []
        var plain: [String] = []
        var i = 0
        func flushPlain() { if !plain.isEmpty { segments.append(.text(plain)); plain = [] } }

        while i < lines.count {
            guard marker(lines[i], "<") != nil, let block = block(in: lines, from: i) else {
                plain.append(lines[i]); i += 1; continue
            }
            flushPlain()
            segments.append(.conflict(block))
            i += block.raw.count
        }
        flushPlain()
        return ConflictDocument(segments: segments)
    }

    /// The file with conflict `index` (0-based, in file order) replaced by `choice`'s lines.
    public func resolving(_ index: Int, _ choice: ConflictChoice) -> String {
        var n = -1
        return render { block in
            n += 1
            return n == index ? block.lines(for: choice) : block.raw
        }
    }

    /// The file with every conflict replaced by `choice`'s lines — the parts git merged cleanly
    /// stay as they are (unlike `git checkout --ours`, which takes the whole file from one side).
    public func resolvingAll(_ choice: ConflictChoice) -> String {
        render { $0.lines(for: choice) }
    }

    /// The file as it is. `parse(t).text == t` for any `t`.
    public var text: String { render { $0.raw } }

    private func render(_ conflict: (ConflictBlock) -> [String]) -> String {
        var out: [String] = []
        for s in segments {
            switch s {
            case .text(let l): out += l
            case .conflict(let c): out += conflict(c)
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: Parsing

    /// The label after a 7-character marker of `char`, or nil when `line` isn't one. A CR left
    /// by a CRLF file is not part of the label.
    static func marker(_ line: String, _ char: Character) -> String? {
        let l = line.hasSuffix("\r") ? String(line.dropLast()) : line
        let run = String(repeating: char, count: 7)
        guard l.hasPrefix(run) else { return nil }
        let rest = l.dropFirst(7)
        if rest.isEmpty { return "" }
        // `========` (eight) is content, not a separator; a label needs its space.
        guard rest.first == " ", char != "=" else { return nil }
        return String(rest.dropFirst())
    }

    /// The well-formed conflict starting at `start`, or nil (left as text) when it never closes
    /// or another conflict opens inside it.
    private static func block(in lines: [String], from start: Int) -> ConflictBlock? {
        guard let currentLabel = marker(lines[start], "<") else { return nil }
        var current: [String] = [], base: [String]? = nil, incoming: [String] = []
        var baseLabel: String?
        enum Part { case current, base, incoming }
        var part = Part.current
        var i = start + 1
        while i < lines.count {
            let l = lines[i]
            if marker(l, "<") != nil { return nil }
            switch part {
            case .current:
                if let b = marker(l, "|") { baseLabel = b; base = []; part = .base }
                else if marker(l, "=") != nil { part = .incoming }
                else { current.append(l) }
            case .base:
                if marker(l, "=") != nil { part = .incoming } else { base?.append(l) }
            case .incoming:
                if let label = marker(l, ">") {
                    return ConflictBlock(raw: Array(lines[start...i]), startLine: start + 1,
                                         currentLabel: currentLabel, incomingLabel: label, baseLabel: baseLabel,
                                         current: current, base: base, incoming: incoming)
                }
                incoming.append(l)
            }
            i += 1
        }
        return nil
    }
}

/// One conflict: what this branch has (current / ours), what the merged-in branch has
/// (incoming / theirs), and the common ancestor's version when the markers carry it.
public struct ConflictBlock: Equatable, Sendable {
    /// The lines as they are in the file, markers included.
    public let raw: [String]
    /// 1-based line of the opening marker.
    public let startLine: Int
    public let currentLabel: String
    public let incomingLabel: String
    public let baseLabel: String?
    public let current: [String]
    public let base: [String]?
    public let incoming: [String]

    public func lines(for choice: ConflictChoice) -> [String] {
        switch choice {
        case .current: current
        case .incoming: incoming
        case .both: current + incoming
        }
    }
}

public enum ConflictChoice: Sendable { case current, incoming, both }

/// Resolves conflicts in the file on disk. Re-reads the file and checks the conflict is still the
/// one the person saw before writing, so an agent (or an editor) that changed the file meanwhile
/// is never overwritten with a resolution computed from a stale copy.
public enum ConflictFileIO {
    public enum Failure: Error, Equatable {
        case unreadable
        /// The conflict being resolved is no longer there as shown — refresh and look again.
        case changed
        case unwritable(String)
    }

    public static func load(_ url: URL) -> ConflictDocument? {
        (try? String(contentsOf: url, encoding: .utf8)).map(ConflictDocument.parse)
    }

    /// Resolve conflict `index` — `expected` is the block as the person saw it.
    public static func resolve(_ url: URL, index: Int, expected: ConflictBlock, _ choice: ConflictChoice) -> Result<Void, Failure> {
        guard let doc = load(url) else { return .failure(.unreadable) }
        let blocks = doc.conflicts
        guard index < blocks.count, blocks[index] == expected else { return .failure(.changed) }
        return write(doc.resolving(index, choice), to: url)
    }

    /// Resolve every conflict — `expected` is how many the person saw.
    public static func resolveAll(_ url: URL, expected: Int, _ choice: ConflictChoice) -> Result<Void, Failure> {
        guard let doc = load(url) else { return .failure(.unreadable) }
        guard doc.conflicts.count == expected else { return .failure(.changed) }
        return write(doc.resolvingAll(choice), to: url)
    }

    /// In place, not atomically: an atomic write replaces the file and drops its permissions
    /// (an executable script would lose +x).
    private static func write(_ text: String, to url: URL) -> Result<Void, Failure> {
        do {
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.truncate(atOffset: 0)
            try h.write(contentsOf: Data(text.utf8))
            return .success(())
        } catch {
            return .failure(.unwritable(error.localizedDescription))
        }
    }
}
