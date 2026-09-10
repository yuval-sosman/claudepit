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

/// Renders markdown as block elements. Inline spans (bold/italic/code/links) via AttributedString.
struct MarkdownText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        let blocks = parseMarkdownBlocks(text)
        VStack(alignment: .leading, spacing: 10) {
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
                if level <= 2 { Divider().opacity(0.4) }
            }
            .padding(.top, level <= 2 ? 6 : 2)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        PathText(it).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(idx + 1).").foregroundStyle(.secondary).monospacedDigit()
                        PathText(it).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .code(let lang, let body):
            VStack(alignment: .leading, spacing: 2) {
                if let lang { Text(lang).font(.caption2).foregroundStyle(.secondary) }
                Group {
                    if lang == "swift" {
                        Text(SwiftHighlighter.attributed(body))
                    } else {
                        Text(body)
                    }
                }
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topTrailing) {
                        CopyButton(text: body).padding(6)
                    }
            }
        case .table(let header, let rows):
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { ci, c in
                        tableCell(c, bold: true, isLast: ci == header.count - 1)
                    }
                }
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
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return .title.bold()
        case 2:  return .title2.bold()
        case 3:  return .title3.bold()
        case 4:  return .headline
        default: return .subheadline.bold()
        }
    }

    private func tableCell(_ text: String, bold: Bool, isLast: Bool) -> some View {
        inline(text).bold(bold)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7).padding(.horizontal, 10)
            .overlay(alignment: .trailing) {
                if !isLast {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
                }
            }
    }

    /// Inline markdown (bold/italic/code/links) with plain-text fallback.
    private func inline(_ s: String) -> Text {
        if let attr = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attr)
        }
        return Text(s)
    }
}

/// Renders a string with any absolute file/directory paths as tappable links that
/// open in the system default app (Finder for directories, Preview/default for files).
struct PathText: View {
    let text: String
    init(_ text: String) { self.text = text }

    // Regex: Unix absolute path — starts with / or ~/, no whitespace, common path chars.
    private static let pathRegex = try! NSRegularExpression(
        pattern: #"(?<![`\[])(/|~/)[^\s\]`'"(){}<>]+"#)

    var body: some View {
        let segments = Self.split(text)
        let hasPath = segments.contains {
            if case .path = $0 { return true }
            if case .mdLink = $0 { return true }
            return false
        }
        if hasPath {
            FlowPathView(segments: segments)
        } else {
            inlineText(text)
        }
    }

    private func inlineText(_ s: String) -> some View {
        Group {
            if let attr = try? AttributedString(
                markdown: s,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attr)
            } else {
                Text(s)
            }
        }
    }

    enum Segment { case plain(String); case path(String); case mdLink(label: String, path: String) }

    static func split(_ text: String) -> [Segment] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var segments: [Segment] = []
        var cursor = 0

        // Match [label](path) for any .md link or absolute/relative path
        let mdLinkRegex = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^\)]+)\)"#)
        var allMatches: [(range: NSRange, seg: Segment)] = []

        for m in mdLinkRegex.matches(in: text, range: full) {
            let label = ns.substring(with: m.range(at: 1))
            let rawPath = ns.substring(with: m.range(at: 2))
            allMatches.append((m.range, .mdLink(label: label, path: rawPath)))
        }
        for m in pathRegex.matches(in: text, range: full) {
            let range = m.range
            // Skip if already covered by an mdLink match
            let covered = allMatches.contains { NSIntersectionRange($0.range, range).length > 0 }
            if !covered { allMatches.append((range, .path(ns.substring(with: range)))) }
        }
        allMatches.sort { $0.range.location < $1.range.location }

        for (range, seg) in allMatches {
            if range.location > cursor {
                let plain = ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
                segments.append(.plain(plain))
            }
            segments.append(seg)
            cursor = range.location + range.length
        }
        if cursor < ns.length { segments.append(.plain(ns.substring(from: cursor))) }
        return segments.isEmpty ? [.plain(text)] : segments
    }
}

private struct FlowPathView: View {
    let segments: [PathText.Segment]

    var body: some View {
        // Use a wrapping HStack via ViewThatFits fallback — simplest cross-version approach
        // is to render as a single Text with path tokens styled, but we need tap targets.
        // We build a left-aligned flow manually using a fixed-width container.
        VStack(alignment: .leading, spacing: 2) {
            WrappingHStack(segments: segments)
        }
    }
}

private struct WrappingHStack: View {
    let segments: [PathText.Segment]
    @Environment(\.focusMemoryFileID) private var focusMemoryFileID

    var body: some View {
        // Concatenate all into an AttributedString with links for paths, rendered as Text.
        // This gives native text wrapping + tappable links.
        if let attr = buildAttributed() {
            Text(attr)
                .environment(\.openURL, OpenURLAction { url in
                    let raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
                    if raw.hasPrefix("rel://") {
                        let filename = String(raw.dropFirst("rel://".count))
                            .trimmingCharacters(in: CharacterSet(charactersIn: "./"))
                        if let binding = focusMemoryFileID {
                            binding.wrappedValue = filename
                        }
                    } else {
                        let path = raw.hasPrefix("file://")
                            ? String(raw.dropFirst(7))
                            : raw
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                    return .handled
                })
        }
    }

    private func buildAttributed() -> AttributedString? {
        var result = AttributedString()
        for seg in segments {
            switch seg {
            case .plain(let s):
                if let attr = try? AttributedString(
                    markdown: s,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                    result.append(attr)
                } else {
                    result.append(AttributedString(s))
                }
            case .mdLink(let label, let rawPath):
                var chunk = AttributedString(label)
                let encoded = rawPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rawPath
                let urlStr = rawPath.hasPrefix("/") || rawPath.hasPrefix("~")
                    ? "file://\(encoded)"
                    : "rel://\(encoded)"
                if let url = URL(string: urlStr) { chunk.link = url }
                chunk.foregroundColor = NSColor.linkColor
                result.append(chunk)
            case .path(let p):
                var chunk = AttributedString(p)
                chunk.font = .system(.body, design: .monospaced)
                // Encode path as a file:// URL link
                let encoded = p.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? p
                if let url = URL(string: "file://\(encoded)") {
                    chunk.link = url
                }
                chunk.foregroundColor = NSColor.linkColor
                result.append(chunk)
            }
        }
        return result
    }
}
