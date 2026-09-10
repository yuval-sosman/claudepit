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
        let ns = highlighter.highlight(code)
        var attr = AttributedString(ns)
        attr.backgroundColor = nil
        return attr
    }
}
