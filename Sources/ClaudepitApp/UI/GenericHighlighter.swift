import SwiftUI
import Highlightr

/// Syntax highlighting for the languages Splash can't do (Splash is Swift-only),
/// backed by Highlightr (highlight.js via JavaScriptCore) — ~190 languages.
/// Kept behind the same `attributed(_:language:)` / `language(forExtension:)` API
/// the diff views already call. Strips Highlightr's background so the diff-row
/// tint shows through, matching SwiftHighlighter.
@MainActor
enum GenericHighlighter {
    // One cached engine + theme. Constructing Highlightr spins up a JS context,
    // so reuse is important — highlight() is called per diff line.
    private static let engine: Highlightr? = {
        let h = Highlightr()
        // "atom-one-dark" reads well on our dark diff panels.
        _ = h?.setTheme(to: "atom-one-dark")
        return h
    }()

    private static let supported: Set<String> = {
        Set((engine?.supportedLanguages() ?? []).map { $0.lowercased() })
    }()

    /// Map a file extension to a highlight.js language id. nil for Swift (handled
    /// by SwiftHighlighter) and for unknown/plain files (skip highlighting).
    static func language(forExtension ext: String) -> String? {
        let e = ext.lowercased()
        if e == "swift" { return nil }
        let mapped: String
        switch e {
        case "js", "jsx", "mjs", "cjs": mapped = "javascript"
        case "ts", "tsx": mapped = "typescript"
        case "py": mapped = "python"
        case "rb": mapped = "ruby"
        case "rs": mapped = "rust"
        case "kt", "kts": mapped = "kotlin"
        case "h", "hpp", "cc", "cpp", "cxx": mapped = "cpp"
        case "m", "mm": mapped = "objectivec"
        case "sh", "zsh": mapped = "bash"
        case "yml": mapped = "yaml"
        case "md", "markdown": mapped = "markdown"
        default: mapped = e
        }
        // Only claim a language highlight.js actually knows; else nil (plain text).
        return supported.contains(mapped) ? mapped : nil
    }

    /// Highlight a snippet in the given language. Falls back to plain on any failure.
    static func attributed(_ code: String, language lang: String) -> AttributedString {
        guard let ns = engine?.highlight(code, as: lang, fastRender: true) else {
            return AttributedString(code)
        }
        var attr = AttributedString(ns)
        attr.backgroundColor = nil
        return attr
    }
}
