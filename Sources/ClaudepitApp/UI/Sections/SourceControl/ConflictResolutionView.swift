import SwiftUI
import ClaudepitCore

/// What the diff panel shows for a conflicted file: each conflict's two sides with Accept
/// Current / Incoming / Both (rewriting the file — `ConflictFileIO`), the clean text between
/// conflicts folded to a few lines of context, and the whole-file choices. Once no markers are
/// left, it says so, offers Mark Resolved, and shows what the file will change on this branch.
struct ConflictResolutionView: View {
    let file: StagedFile
    /// The file parsed at its markers; nil when it is gone or isn't UTF-8 text.
    let document: ConflictDocument?
    /// `git diff HEAD` — what resolving it this way changes on this branch.
    let headHunks: [DiffHunk]
    let busy: Bool
    let actions: Actions

    struct Actions {
        var resolve: (_ index: Int, _ block: ConflictBlock, _ choice: ConflictChoice) -> Void
        var resolveAll: (_ count: Int, _ choice: ConflictChoice) -> Void
        var takeSide: (ConflictSide) -> Void
        var delete: () -> Void
        var markResolved: () -> Void
        var open: (() -> Void)?
    }

    @State private var expandedText: Set<Int> = []

    private var kind: MergeConflictKind { file.conflict ?? .bothModified }
    private var conflicts: [ConflictBlock] { document?.conflicts ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                summary
                if let document, document.hasConflicts {
                    conflictList(document)
                } else if document != nil {
                    resolvedBody
                } else {
                    missingBody
                }
            }
            .padding(10)
        }
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: conflicts.isEmpty && document != nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(conflicts.isEmpty && document != nil ? TranscriptStyle.added : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.callout.weight(.semibold))
                    Text(kind.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { actions.markResolved() } label: { Label("Mark Resolved", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .tint(conflicts.isEmpty ? .accentColor : .gray)
                    .disabled(busy)
                    .help("Stage the file as it is now — git add. Space does the same in the list.")
                    .debugFrame("sc-mark-resolved")
            }
            HStack(spacing: 14) {
                if conflicts.count > 1 {
                    SourceControlTextButton(title: "Accept All Current", busy: busy) { actions.resolveAll(conflicts.count, .current) }
                        .help("Every conflict takes this branch's side; the parts git merged cleanly stay")
                        .debugFrame("sc-conflict-all-current")
                    SourceControlTextButton(title: "Accept All Incoming", busy: busy) { actions.resolveAll(conflicts.count, .incoming) }
                        .help("Every conflict takes the incoming side; the parts git merged cleanly stay")
                        .debugFrame("sc-conflict-all-incoming")
                }
                Spacer(minLength: 0)
                Text("Whole file:").font(.caption2).foregroundStyle(.tertiary)
                SourceControlTextButton(title: "Use Current", busy: busy) { actions.takeSide(.current) }
                    .help("Replace the file with this branch's version (git checkout --ours) — clean merges from the other side are dropped too")
                    .debugFrame("sc-take-current")
                SourceControlTextButton(title: "Use Incoming", busy: busy) { actions.takeSide(.incoming) }
                    .help("Replace the file with the incoming version (git checkout --theirs)")
                    .debugFrame("sc-take-incoming")
                if kind.isDeletion || document == nil {
                    SourceControlTextButton(title: "Delete File", role: .destructive, busy: busy) { actions.delete() }
                        .help("Resolve by deleting it (git rm)")
                        .debugFrame("sc-delete-conflicted")
                }
                if let open = actions.open {
                    SourceControlTextButton(title: "Open in Editor", busy: false, action: open)
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(conflicts.isEmpty && document != nil ? 0 : 0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)))
    }

    private var headline: String {
        if document == nil { return kind.isDeletion ? "Keep or delete this file" : "This file can't be shown as text" }
        if conflicts.isEmpty { return "No conflict markers left — mark it resolved" }
        return conflicts.count == 1 ? "1 conflict to resolve" : "\(conflicts.count) conflicts to resolve"
    }

    // MARK: Conflicts

    @ViewBuilder private func conflictList(_ doc: ConflictDocument) -> some View {
        let segs = Array(doc.segments.enumerated())
        let starts = lineStarts(doc.segments)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(segs, id: \.offset) { i, seg in
                switch seg {
                case .text(let lines):
                    textSegment(i, lines, firstLine: starts[i], isFirst: i == 0, isLast: i == segs.count - 1)
                case .conflict(let block):
                    let n = conflictIndex(of: i, in: doc.segments)
                    ConflictBlockCard(block: block, number: n + 1, total: conflicts.count, busy: busy) { choice in
                        actions.resolve(n, block, choice)
                    }
                }
            }
        }
    }

    /// 1-based line number each segment starts at.
    private func lineStarts(_ segments: [ConflictDocument.Segment]) -> [Int] {
        var out: [Int] = [], line = 1
        for s in segments {
            out.append(line)
            switch s {
            case .text(let l): line += l.count
            case .conflict(let c): line += c.raw.count
            }
        }
        return out
    }

    private func conflictIndex(of segment: Int, in segments: [ConflictDocument.Segment]) -> Int {
        segments[..<segment].filter { if case .conflict = $0 { return true } else { return false } }.count
    }

    /// Clean text: three lines of context beside each conflict, the rest folded behind a count.
    @ViewBuilder private func textSegment(_ i: Int, _ lines: [String], firstLine: Int, isFirst: Bool, isLast: Bool) -> some View {
        // The file's final newline leaves one empty string at the end; it is not a line.
        let body = isLast && lines.last == "" ? Array(lines.dropLast()) : lines
        let context = 3
        let head = isFirst ? 0 : min(context, body.count)
        let tail = isLast ? 0 : min(context, max(0, body.count - head))
        let hidden = body.count - head - tail
        if !body.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if expandedText.contains(i) || hidden <= 1 {
                    linesView(body, from: firstLine, tint: nil)
                } else {
                    if head > 0 { linesView(Array(body.prefix(head)), from: firstLine, tint: nil) }
                    Button {
                        expandedText.insert(i)
                    } label: {
                        Text("⋯ \(hidden) unchanged line\(hidden == 1 ? "" : "s")")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 52).padding(.vertical, 3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show them")
                    if tail > 0 { linesView(Array(body.suffix(tail)), from: firstLine + body.count - tail, tint: nil) }
                }
            }
            .background(TranscriptStyle.codeBackground, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: Resolved / missing

    @ViewBuilder private var resolvedBody: some View {
        if headHunks.isEmpty {
            Text("The file now matches this branch exactly — resolving it changes nothing here.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("What it will change on this branch").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(headHunks) { hunk in
                DiffView(lines: hunk.numberedLines(), isSwift: file.path.hasSuffix(".swift"),
                         isMarkdown: file.path.hasSuffix(".md"),
                         language: GenericHighlighter.language(forExtension: (file.path as NSString).pathExtension),
                         title: hunk.label, startsRendered: false)
            }
        }
    }

    private var missingBody: some View {
        Text(kind.isDeletion
             ? "One side deleted this file and the other changed it. Keep a side's version, or delete it, then mark it resolved."
             : "It isn't UTF-8 text, so its conflicts can't be shown here. Use one side's version, or resolve it in an editor, then mark it resolved.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One conflict: its two sides (and the base, for diff3 markers) and the three ways to take it.
private struct ConflictBlockCard: View {
    let block: ConflictBlock
    let number: Int
    let total: Int
    let busy: Bool
    let onChoose: (ConflictChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Conflict \(number) of \(total)").font(.caption.weight(.semibold))
                Text("line \(block.startLine)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                Spacer()
                SourceControlTextButton(title: "Accept Current", busy: busy) { onChoose(.current) }
                    .help("Keep this branch's side (\(block.currentLabel))")
                    .debugFrame("sc-conflict-\(number - 1)-current")
                SourceControlTextButton(title: "Accept Incoming", busy: busy) { onChoose(.incoming) }
                    .help("Keep the incoming side (\(block.incomingLabel))")
                    .debugFrame("sc-conflict-\(number - 1)-incoming")
                SourceControlTextButton(title: "Accept Both", busy: busy) { onChoose(.both) }
                    .help("Keep both — current first, then incoming")
                    .debugFrame("sc-conflict-\(number - 1)-both")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(TranscriptStyle.codeHeader)
            side("Current", block.currentLabel, block.current, ConflictColors.current)
            if let base = block.base {
                side("Base", block.baseLabel ?? "", base, ConflictColors.base)
            }
            side("Incoming", block.incomingLabel, block.incoming, ConflictColors.incoming)
        }
        .background(TranscriptStyle.codeBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func side(_ title: String, _ label: String, _ lines: [String], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title).font(.caption2.weight(.bold)).foregroundStyle(color)
                if !label.isEmpty { Text(label).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 2)
            if lines.isEmpty {
                Text("(nothing — this side removed these lines)")
                    .font(.caption2).italic().foregroundStyle(.tertiary)
                    .padding(.horizontal, 10).padding(.bottom, 5)
            } else {
                linesView(lines, from: nil, tint: color)
            }
        }
        .background(color.opacity(0.07))
    }
}

enum ConflictColors {
    static let current = Color(red: 0.36, green: 0.62, blue: 1.0)
    static let incoming = Color(red: 0.72, green: 0.52, blue: 1.0)
    static let base = Color.gray
}

/// Monospaced lines with an optional line-number gutter and an optional side tint.
@ViewBuilder private func linesView(_ lines: [String], from start: Int?, tint: Color?) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
            HStack(alignment: .top, spacing: 0) {
                if let start {
                    Text("\(start + i)").foregroundStyle(Color.secondary.opacity(0.5))
                        .frame(width: 40, alignment: .trailing).padding(.trailing, 12)
                } else if let tint {
                    Rectangle().fill(tint.opacity(0.7)).frame(width: 2).padding(.trailing, 10)
                }
                Text(line.isEmpty ? " " : line)
                    .foregroundStyle(Color(white: 0.86))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11.5, design: .monospaced))
            .padding(.vertical, 0.5)
            .padding(.leading, tint != nil && start == nil ? 8 : 0)
        }
    }
    .padding(.vertical, tint == nil ? 4 : 0)
    .padding(.bottom, tint == nil ? 0 : 5)
}
