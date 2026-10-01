import SwiftUI
import Splash

/// Swift syntax highlighting via Splash, converted to SwiftUI AttributedString.
/// Used for diff lines and swift fenced-code blocks. Falls back to plain on failure.
@MainActor
enum SwiftHighlighter {
    // One cached highlighter; construction is cheap but reuse avoids per-line rebuilds.
    private static let highlighter: SyntaxHighlighter<AttributedStringOutputFormat> = {
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
            NSColor(red: r, green: g, blue: b, alpha: 1)
        }
        let theme = Theme(
            font: Splash.Font(size: 12),
            plainTextColor: NSColor(white: 0.85, alpha: 1),
            tokenColors: [
                .keyword: c(0.94, 0.40, 0.64),   // pink
                .string: c(0.90, 0.53, 0.40),    // orange-red
                .type: c(0.42, 0.78, 0.90),      // cyan
                .call: c(0.42, 0.78, 0.90),      // cyan
                .number: c(0.66, 0.56, 0.94),    // purple
                .comment: NSColor(white: 0.5, alpha: 1),
                .property: c(0.55, 0.85, 0.55),  // green
                .dotAccess: c(0.55, 0.85, 0.55), // green
                .preprocessing: c(0.85, 0.6, 0.4),
            ],
            backgroundColor: .clear)
        return SyntaxHighlighter(format: AttributedStringOutputFormat(theme: theme))
    }()

    /// Highlight a Swift snippet/line. Strips background so diff row tint shows through.
    static func attributed(_ code: String) -> AttributedString {
        var attr = AttributedString(withoutFont(highlighter.highlight(code)))
        attr.backgroundColor = nil
        return attr
    }
}

/// Both highlighters stamp their theme's font on every run, which beats the view's monospaced
/// `.font` — Splash's is proportional. Strip it on the AppKit side: clearing `appKit.font` on the
/// converted `AttributedString` goes through a `Sendable`-constrained accessor NSFont fails.
func withoutFont(_ ns: NSAttributedString) -> NSAttributedString {
    let out = NSMutableAttributedString(attributedString: ns)
    out.removeAttribute(.font, range: NSRange(location: 0, length: out.length))
    return out
}
