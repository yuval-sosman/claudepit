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

struct SectionRow<Item: ConfigItem, Trailing: View>: View {
    let item: Item
    let subtitle: String
    var onDelete: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.body).bold()
                    .strikethrough(item.isOverridden)
                    .foregroundStyle(item.isOverridden ? .secondary : .primary)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            trailing
            if case .plugin = item.origin { ProvenanceBadge(scope: item.scope, origin: item.origin) }
            OpenInEditorButton(url: item.sourcePath, onDelete: onDelete)
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

extension SectionRow where Trailing == EmptyView {
    init(item: Item, subtitle: String, onDelete: (() -> Void)? = nil) {
        self.init(item: item, subtitle: subtitle, onDelete: onDelete) { EmptyView() }
    }
}
