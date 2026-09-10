import SwiftUI
import AppKit
import ClaudepitCore

struct RuleCard: View {
    let rule: Rule
    @ObservedObject var app: AppState
    @State private var expanded = false

    private var extraKeys: [String] {
        rule.meta.keys.filter { $0 != "paths" }.sorted()
    }

    var body: some View {
        ExpandableCard(expanded: $expanded) { header } detail: { detail }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.displayName)
                        .font(.body).bold()
                        .strikethrough(rule.isOverridden)
                        .foregroundStyle(rule.isOverridden ? .secondary : .primary)
                    ProvenanceBadge(scope: rule.scope, origin: rule.origin)
                }
                if !expanded && !rule.paths.isEmpty {
                    Text(rule.paths.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            OpenInEditorButton(url: rule.sourcePath, onDelete: rule.origin.pluginID == nil ? {
                try? FileManager.default.trashItem(at: rule.sourcePath, resultingItemURL: nil)
                app.store.reload(activePath: app.activePath)
            } : nil)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            appliesToSection

            if !extraKeys.isEmpty {
                SectionHeaderLabel("Frontmatter", icon: "text.alignleft")
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(extraKeys, id: \.self) { key in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(key).font(.caption).fontWeight(.bold).foregroundStyle(.secondary)
                            Text(rule.meta[key] ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if !rule.bodyPreview.isEmpty {
                SectionHeaderLabel("Preview", icon: "doc.plaintext")
                Text(rule.bodyPreview)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6).padding(.horizontal, 9)
                    .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
                    .textSelection(.enabled)
            }

            sourceRow
        }
    }

    private var appliesToSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeaderLabel("Applies to", icon: "scope")
            if rule.paths.isEmpty {
                Text("All files")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(rule.paths, id: \.self) { glob in
                        Text(glob)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var sourceRow: some View {
        FilePathLabel(url: rule.sourcePath)
    }

}
