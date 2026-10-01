import SwiftUI
import ClaudepitCore

private struct MemoryNavKey: EnvironmentKey {
    static let defaultValue: Binding<String?>? = nil
}
extension EnvironmentValues {
    var focusMemoryFileID: Binding<String?>? {
        get { self[MemoryNavKey.self] }
        set { self[MemoryNavKey.self] = newValue }
    }
}

private struct TextHighlightKey: EnvironmentKey {
    static let defaultValue = ""
}
extension EnvironmentValues {
    /// A search term to mark wherever markdown text renders it (the transcript's search).
    var textHighlight: String {
        get { self[TextHighlightKey.self] }
        set { self[TextHighlightKey.self] = newValue }
    }
}

/// Heading sizes and spacing: `.document` for pages that are a document (plans, specs,
/// CLAUDE.md), `.compact` for text inside a transcript, where an `#` in a reply shouldn't
/// shout over the conversation.
enum MarkdownScale { case document, compact }

/// Renders markdown as block elements. Inline spans (bold/italic/code/links) via AttributedString.
struct MarkdownText: View {
    let text: String
    var scale: MarkdownScale = .document
    @Environment(\.textHighlight) private var highlight
    init(_ text: String, scale: MarkdownScale = .document) { self.text = text; self.scale = scale }

    var body: some View {
        let blocks = parseMarkdownBlocks(text)
        VStack(alignment: .leading, spacing: scale == .compact ? 8 : 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            PathText(s).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            VStack(alignment: .leading, spacing: 4) {
                inline(text).font(headingFont(level))
                    .fixedSize(horizontal: false, vertical: true)
                if level <= 2 && scale == .document { Divider().opacity(0.4) }
            }
            .padding(.top, level <= 2 ? (scale == .compact ? 4 : 6) : 2)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        marker(it)
                        PathText(it.text).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(it.level) * 18)
                }
            }
        case .code(let lang, let body):
            CodeBlockView(code: body, language: lang, foldAfter: scale == .compact ? 40 : 200)
        case .table(let header, let rows):
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { ci, c in
                        tableCell(c, bold: true, isLast: ci == header.count - 1)
                    }
                }
                .background(Color.white.opacity(0.04))
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { ri, r in
                    GridRow {
                        ForEach(Array(r.enumerated()), id: \.offset) { ci, c in
                            tableCell(c, bold: false, isLast: ci == r.count - 1)
                        }
                    }
                    if ri < rows.count - 1 {
                        Divider().gridCellUnsizedAxes(.horizontal).opacity(0.5)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case .quote(let s):
            HStack(spacing: 10) {
                Rectangle().fill(.secondary.opacity(0.5)).frame(width: 3)
                PathText(s).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
        case .rule:
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).padding(.vertical, 4)
        }
    }

    @ViewBuilder private func marker(_ item: MarkdownListItem) -> some View {
        switch item.marker {
        case .bullet:
            Text(item.level == 0 ? "•" : item.level == 1 ? "◦" : "▪")
                .foregroundStyle(.secondary)
                .frame(minWidth: 10, alignment: .center)
        case .number(let n):
            Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
                .frame(minWidth: 16, alignment: .trailing)
        case .task(let checked):
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? AnyShapeStyle(TranscriptStyle.added) : AnyShapeStyle(.secondary))
                .font(.system(size: 12))
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch (scale, level) {
        case (.document, 1): return .title.bold()
        case (.document, 2): return .title2.bold()
        case (.document, 3): return .title3.bold()
        case (.document, 4): return .headline
        case (.document, _): return .subheadline.bold()
        case (.compact, 1): return .system(size: 16, weight: .bold)
        case (.compact, 2): return .system(size: 14.5, weight: .bold)
        case (.compact, 3): return .system(size: 13.5, weight: .semibold)
        case (.compact, _): return .system(size: 13, weight: .semibold)
        }
    }

    private func tableCell(_ text: String, bold: Bool, isLast: Bool) -> some View {
        inline(text).bold(bold)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6).padding(.horizontal, 10)
            .overlay(alignment: .trailing) {
                if !isLast {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
                }
            }
    }

    /// Inline markdown (bold/italic/code/links) with plain-text fallback.
    private func inline(_ s: String) -> Text {
        Text(InlineMarkdown.attributed(s, highlight: highlight))
    }
}

/// Inline markdown → AttributedString, with `code` spans given a visible chip (SwiftUI only
/// switches them to monospace, which is easy to miss mid-sentence).
enum InlineMarkdown {
    static func attributed(_ s: String, highlight: String = "") -> AttributedString {
        var attr = (try? AttributedString(
            markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        styleCode(&attr)
        mark(&attr, highlight)
        return attr
    }

    /// Tint every case-insensitive occurrence of `term`.
    static func mark(_ attr: inout AttributedString, _ term: String) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var searchRange = attr.startIndex..<attr.endIndex
        while let r = attr[searchRange].range(of: t, options: [.caseInsensitive, .diacriticInsensitive]) {
            attr[r].backgroundColor = Color.yellow.opacity(0.35)
            attr[r].foregroundColor = Color.white
            searchRange = r.upperBound..<attr.endIndex
        }
    }

    static func styleCode(_ attr: inout AttributedString) {
        for run in attr.runs {
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
            attr[run.range].backgroundColor = Color.white.opacity(0.09)
            attr[run.range].foregroundColor = Color(red: 0.93, green: 0.78, blue: 0.62)
            attr[run.range].font = .system(size: 12, design: .monospaced)
        }
    }
}

/// Inline markdown with every absolute (`/a/b`) or home-relative (`~/a`) path made a link
/// that opens in Finder / the default app, and `[label](relative.md)` links routed to the
/// Memory section's focus binding.
///
/// Markdown is parsed once, for the whole string, and the links are laid onto the result —
/// cutting the text into pieces at each path first (the old approach) broke any bold or code
/// span that happened to contain one: `**[Config](…)**` rendered its asterisks.
struct PathText: View {
    let text: String
    @Environment(\.textHighlight) private var highlight
    @Environment(\.focusMemoryFileID) private var focusMemoryFileID
    init(_ text: String) { self.text = text }

    // An absolute (`/a/b`) or home-relative (`~/a`) path of at least two components, not glued
    // to a word, a URL scheme or another path — so `input/output`, `https://…` and a
    // `/slash-command` stay plain text.
    private static let pathRegex = try! NSRegularExpression(
        pattern: #"(?<![\w`\[/.:~-])(?:~/[^\s\]`'"(){}<>]+|/[^\s\]`'"(){}<>/]+(?:/[^\s\]`'"(){}<>/]*)+)"#)

    var body: some View {
        Text(Self.linked(text, highlight: highlight))
            .environment(\.openURL, OpenURLAction { url in
                let raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
                if raw.hasPrefix("rel://") {
                    let filename = String(raw.dropFirst("rel://".count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "./"))
                    focusMemoryFileID?.wrappedValue = filename
                    return .handled
                }
                if raw.hasPrefix("file://") {
                    let path = String(raw.dropFirst("file://".count))
                    let expanded = (path as NSString).expandingTildeInPath
                    NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
                    return .handled
                }
                return .systemAction
            })
    }

    static func linked(_ text: String, highlight: String) -> AttributedString {
        var attr = InlineMarkdown.attributed(text, highlight: highlight)
        // 1. Links whose target is a path: files open in place; relative ones go to Memory.
        for run in attr.runs {
            guard let url = run.link, url.scheme == nil || url.scheme == "file" else { continue }
            let target = url.scheme == "file" ? url.path : (url.relativeString.removingPercentEncoding ?? url.relativeString)
            let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
            let isPath = target.hasPrefix("/") || target.hasPrefix("~")
            attr[run.range].link = URL(string: (isPath ? "file://" : "rel://") + encoded)
            attr[run.range].foregroundColor = Color(nsColor: .linkColor)
        }
        // 2. Bare paths in the running text (never inside code or an existing link).
        let plain = String(attr.characters)
        let ns = plain as NSString
        for m in pathRegex.matches(in: plain, range: NSRange(location: 0, length: ns.length)) {
            var r = m.range
            // A path ending a sentence keeps its full stop outside the link.
            while r.length > 1, let last = UnicodeScalar(ns.character(at: r.location + r.length - 1)),
                  ".,:;!?".unicodeScalars.contains(last) { r.length -= 1 }
            guard let strRange = Range(r, in: plain) else { continue }
            let lo = plain.distance(from: plain.startIndex, to: strRange.lowerBound)
            let hi = plain.distance(from: plain.startIndex, to: strRange.upperBound)
            let a = attr.index(attr.startIndex, offsetByCharacters: lo)
            let b = attr.index(attr.startIndex, offsetByCharacters: hi)
            let range = a..<b
            let blocked = attr[range].runs.contains { run in
                run.link != nil || (run.inlinePresentationIntent?.contains(.code) ?? false)
            }
            guard !blocked else { continue }
            let path = String(plain[strRange])
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            attr[range].link = URL(string: "file://" + encoded)
            attr[range].foregroundColor = Color(nsColor: .linkColor)
            attr[range].font = .system(size: 12.5, design: .monospaced)
        }
        return attr
    }
}
