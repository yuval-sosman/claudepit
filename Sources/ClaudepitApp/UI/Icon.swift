import Foundation

/// Single source of truth for SF Symbol names used across the app's UI.
///
/// Reference these constants instead of hardcoding `systemName:` / `systemImage:`
/// strings so shared operations (reveal, refresh, add, edit, etc.) stay visually
/// consistent. Domain-specific / one-off glyphs may remain inline at their call site.
enum Icon {
    /// Reveal a file in Finder.
    static let revealInFinder = "folder"
    /// Open a document/file (in editor).
    static let openFile = "doc.text"
    /// Copy a file path to the pasteboard.
    static let copyPath = "doc.on.doc"
    /// Overflow / more actions menu (ellipsis).
    static let moreActions = "ellipsis"
    /// Refresh / reload.
    static let refresh = "arrow.clockwise"
    /// Add, inside a `Label`.
    static let add = "plus"
    /// Add, standalone icon-only button.
    static let addCircle = "plus.circle"
    /// Open in another app / external window.
    static let externalLink = "arrow.up.right.square"
    /// In-app navigate-to (jump to another item).
    static let jump = "arrow.right.circle"
    /// Edit.
    static let edit = "pencil"
    /// New / compose.
    static let newCompose = "square.and.pencil"
    /// Info.
    static let info = "info.circle"
    /// Delete.
    static let delete = "trash"
    /// Search.
    static let search = "magnifyingglass"
    /// Clear a text field.
    static let clearField = "xmark.circle.fill"
    /// Disclosure chevron, expanded state.
    static let chevronExpanded = "chevron.down"
    /// Disclosure chevron, collapsed state.
    static let chevronCollapsed = "chevron.right"
}
