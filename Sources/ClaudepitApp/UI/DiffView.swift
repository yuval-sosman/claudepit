import SwiftUI
import AppKit
import ClaudepitCore

/// Colored line diff (removed red, added green), with an optional file header. When the lines
/// carry numbers (an edit's structured patch) a two-column old/new gutter runs down the left.
struct DiffView: View {
    let lines: [DiffLine]
    var isSwift: Bool = false
    var isMarkdown: Bool = false
    /// Non-Swift language for GenericHighlighter (nil = plain). Derive from the
    /// file extension at the call site.
    var language: String? = nil
    /// Lines shown before "Show all".
    var foldAfter: Int = 400
    /// Rendered markdown's type scale: a document's own headings elsewhere, the transcript's
    /// tighter ones inside a tool call.
    var markdownScale: MarkdownScale = .document
    @State private var rendered = true
    @State private var showAll = false
    @Environment(\.textHighlight) private var highlight

    private var hasNumbers: Bool { lines.contains { $0.oldLine != nil || $0.newLine != nil } }
    private var gutterWidth: CGFloat {
        let widest = lines.compactMap { max($0.oldLine ?? 0, $0.newLine ?? 0) }.max() ?? 0
        return CGFloat(max(2, String(widest).count)) * 7 + 6
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar: file name (first .file line) + action buttons
            HStack(spacing: 8) {
                if let fileLabel = lines.first(where: { $0.kind == .file })?.text {
                    Text(TranscriptFormat.path(fileLabel))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let path = lines.first(where: { $0.kind == .file })?.text, path.hasPrefix("/"),
                   FileManager.default.fileExists(atPath: path) {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: {
                        Image(systemName: Icon.openFile).font(.system(size: 10))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Open the file")
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                        Image(systemName: Icon.revealInFinder).font(.system(size: 10))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Reveal in Finder")
                }
                let stat = diffStat(lines)
                if stat.added > 0 {
                    Text("+\(stat.added)").font(TranscriptStyle.meta).foregroundStyle(TranscriptStyle.added)
                }
                if stat.removed > 0 {
                    Text("−\(stat.removed)").font(TranscriptStyle.meta).foregroundStyle(TranscriptStyle.removed)
                }
                Spacer()
                if isMarkdown {
                    Button { rendered.toggle() } label: {
                        Image(systemName: rendered ? "chevron.left.forwardslash.chevron.right" : "text.viewfinder")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(rendered ? "Show raw" : "Render markdown")
                }
                CopyButton(text: copyText, help: "Copy the new text", size: 11)
            }
            .padding(.leading, 10).padding(.trailing, 6)
            .padding(.vertical, 4)
            .background(TranscriptStyle.codeHeader)

            Rectangle().fill(TranscriptStyle.hairline).frame(height: 1)

            if isMarkdown && rendered {
                MarkdownText(copyText, scale: markdownScale)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    diffRows
                }
                .padding(.vertical, 4)
            }
        }
        .background(TranscriptStyle.codeBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TranscriptStyle.hairline))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var diffRows: some View {
        let body = lines.filter { $0.kind != .file }
        let shown = showAll ? body : Array(body.prefix(foldAfter))
        ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
            row(line)
        }
        if body.count > foldAfter {
            Button { showAll.toggle() } label: {
                Text(showAll ? "Show less" : "Show all \(body.count.formatted()) lines")
                    .font(TranscriptStyle.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
    }

    /// Added lines (the resulting content) — the useful thing to copy from a diff.
    private var copyText: String {
        lines.filter { $0.kind == .add }.map(\.text).joined(separator: "\n")
    }

    @ViewBuilder private func row(_ line: DiffLine) -> some View {
        switch line.kind {
        case .file:
            EmptyView()   // rendered in toolbar header
        case .note:
            HStack(spacing: 0) {
                if hasNumbers { Color.clear.frame(width: gutterWidth * 2 + 4) }
                Text(line.text == "—" ? "⋯" : line.text)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    .padding(.leading, 18)
                Spacer()
            }
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.03))
        case .add:
            diffLine("+", line, TranscriptStyle.added)
        case .remove:
            diffLine("-", line, TranscriptStyle.removed)
        case .context:
            diffLine(" ", line, .primary)
        }
    }

    private func diffLine(_ sign: String, _ line: DiffLine, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if hasNumbers {
                number(line.oldLine)
                number(line.newLine)
                    .padding(.trailing, 4)
            }
            Text(sign)
                .foregroundStyle(color == .primary ? Color.secondary : color)
                .frame(width: 14)
            lineText(line.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.vertical, 0.5)
        .padding(.trailing, 8)
        .background(color == .primary ? Color.clear : color.opacity(0.12))
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .foregroundStyle(Color.secondary.opacity(0.5))
            .frame(width: gutterWidth, alignment: .trailing)
    }

    @ViewBuilder private func lineText(_ text: String) -> some View {
        let shown = text.isEmpty ? " " : text
        if isSwift || language != nil {
            Text(marked(CodeHighlight.attributed(shown, language: isSwift ? "swift" : language)))
        } else {
            Text(marked(AttributedString(shown))).foregroundStyle(Color(white: 0.86))
        }
    }

    private func marked(_ a: AttributedString) -> AttributedString {
        var attr = a
        InlineMarkdown.mark(&attr, highlight)
        return attr
    }
}
