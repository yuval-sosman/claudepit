import SwiftUI
import AppKit
import ClaudepitCore

struct ProvenanceBadge: View {
    let scope: Scope
    let origin: Origin
    private var label: String {
        if case .plugin(let id) = origin { return id }   // e.g. superpowers@official
        return scope.rawValue
    }
    var body: some View {
        Pill(label, color: .provenanceColor(origin: origin, scope: scope))
    }
}

/// File actions (Open in editor / Reveal in Finder / Copy path) for a config
/// item's source file, presented as a compact `…` menu. Kept as a named wrapper
/// for its existing call sites.
struct OpenInEditorButton: View {
    let url: URL
    var onDelete: (() -> Void)? = nil
    var body: some View {
        FileActionsMenu(url: url, onDelete: onDelete)
    }
}
