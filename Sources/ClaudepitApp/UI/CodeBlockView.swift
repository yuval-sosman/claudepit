import SwiftUI
import ClaudepitCore

/// A code or terminal block: a header naming it (file, language) with the line count and a copy
/// button, syntax colouring for any language highlight.js knows (Swift via Splash), an optional
/// line-number gutter, horizontal scrolling instead of wrapping (so code keeps its shape), and
/// long blocks folded to their first lines until asked.
struct CodeBlockView: View {
    let code: String
    /// A fence tag (`swift`, `sh`, `json`…) or a highlight.js id; nil or unknown → plain.
    var language: String? = nil
    /// Header text; defaults to the language.
    var title: String? = nil
    /// A custom header label in place of `title` (a path with open/reveal buttons, say).
    var header: AnyView? = nil
    /// Line numbers: the first line's number (a gutter counting up), or explicit per-line numbers.
    var firstLine: Int? = nil
    var lineNumbers: [Int]? = nil
    var showHeader: Bool = true
    /// Lines shown before "Show all".
    var foldAfter: Int = 30
    /// Colour for unhighlighted text (a terminal's stderr, say).
    var tint: Color? = nil
    /// Wrap long lines instead of scrolling sideways — for prose that happens to be verbatim.
    var wrap: Bool = false

    @State private var showAll = false
    @Environment(\.textHighlight) private var highlight

    var body: some View {
        let lines = code.components(separatedBy: "\n")
        let total = lines.count
        let folded = !showAll && total > foldAfter + 5   // don't fold away a mere 5 lines
        let shownCount = folded ? foldAfter : total
        let shown = folded ? lines.prefix(shownCount).joined(separator: "\n") : code
        VStack(alignment: .leading, spacing: 0) {
            if showHeader { headerBar(total: total) }
            if wrap {
                Text(highlighted(shown))
                    .foregroundStyle(tint ?? Color(white: 0.86))
                    .textSelection(.enabled)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 9)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        if let gutter = gutter(count: shownCount) {
                            Text(gutter)
                                .foregroundStyle(Color.secondary.opacity(0.55))
                                .multilineTextAlignment(.trailing)
                                .fixedSize()
                        }
                        Text(highlighted(shown))
                            .foregroundStyle(tint ?? Color(white: 0.86))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineSpacing(1.5)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if total > foldAfter + 5 { foldBar(total: total) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TranscriptStyle.codeBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TranscriptStyle.hairline))
    }

    private func headerBar(total: Int) -> some View {
        HStack(spacing: 8) {
            if let header {
                header
            } else if let label = title ?? language, !label.isEmpty {
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if total > 1 {
                Text(TranscriptFormat.plural(total, "line"))
                    .font(TranscriptStyle.meta).foregroundStyle(.tertiary)
            }
            CopyButton(text: code, size: 11)
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 4)
        .background(TranscriptStyle.codeHeader)
        .overlay(alignment: .bottom) { Rectangle().fill(TranscriptStyle.hairline).frame(height: 1) }
    }

    private func foldBar(total: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { showAll.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: showAll ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                Text(showAll ? "Show less" : "Show all \(total.formatted()) lines")
            }
            .font(TranscriptStyle.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(TranscriptStyle.codeHeader)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(TranscriptStyle.hairline).frame(height: 1) }
    }

    private func gutter(count: Int) -> String? {
        if let lineNumbers {
            return lineNumbers.prefix(count).map(String.init).joined(separator: "\n")
        }
        guard let firstLine else { return nil }
        return (firstLine..<(firstLine + count)).map(String.init).joined(separator: "\n")
    }

    private func highlighted(_ text: String) -> AttributedString {
        var attr = CodeHighlight.attributed(text, language: language)
        InlineMarkdown.mark(&attr, highlight)   // the transcript search, marked in code too
        return attr
    }
}

/// Highlighting with a small cache — highlight.js runs in JavaScriptCore, and a transcript
/// re-renders its visible code blocks on every scroll.
@MainActor
enum CodeHighlight {
    private static var cache: [Int: AttributedString] = [:]
    private static var order: [Int] = []

    static func attributed(_ code: String, language: String?) -> AttributedString {
        guard let lang = normalized(language), code.count < 60_000 else { return AttributedString(code) }
        var hasher = Hasher()
        hasher.combine(lang); hasher.combine(code)
        let key = hasher.finalize()
        if let hit = cache[key] { return hit }
        var out = lang == "swift" ? SwiftHighlighter.attributed(code)
                                  : GenericHighlighter.attributed(code, language: lang)
        // The highlighters drop their theme's NSFont before converting (`withoutFont`);
        // a font left on the runs would beat the view's monospaced `.font`.
        out.font = nil
        cache[key] = out
        order.append(key)
        if order.count > 400 { cache.removeValue(forKey: order.removeFirst()) }
        return out
    }

    /// A fence tag or file extension → `swift` or a highlight.js id; nil for plain text.
    static func normalized(_ tag: String?) -> String? {
        guard let raw = tag?.lowercased().split(separator: " ").first.map(String.init), !raw.isEmpty else { return nil }
        switch raw {
        case "text", "plain", "plaintext", "txt", "output", "log", "none": return nil
        case "swift": return "swift"
        case "sh", "shell", "zsh", "console", "terminal", "shellsession": return GenericHighlighter.language(forExtension: "sh")
        case "objc", "objective-c": return GenericHighlighter.language(forExtension: "m")
        case "jsonl", "json5": return GenericHighlighter.language(forExtension: "json")
        default: return GenericHighlighter.language(forExtension: raw)
        }
    }

    /// The language for a file path, by extension.
    static func language(forPath path: String) -> String? {
        let ext = (path as NSString).pathExtension
        if ext.lowercased() == "swift" { return "swift" }
        return ext.isEmpty ? nil : GenericHighlighter.language(forExtension: ext)
    }
}
