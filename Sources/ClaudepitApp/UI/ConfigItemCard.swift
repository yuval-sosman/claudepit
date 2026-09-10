import SwiftUI
import AppKit
import ClaudepitCore

/// Expandable card for a config item (skill / command), mirroring the plugin card
/// styling: collapsed header with chevron + name + provenance badge, click to reveal
/// full description, all frontmatter fields, a body preview, and source links.
struct ConfigItemCard<Item: ConfigItem>: View where Item.ID == String {
    let item: Item
    let meta: [String: String]
    let bodyPreview: String
    var showEnableToggle: Bool = false   // skills only; commands have no skillOverrides equivalent
    @ObservedObject var app: AppState
    @State private var expanded = false
    @State private var descExpanded = false

    private var pluginID: String? { item.origin.pluginID }

    // The on/off toggle applies to non-plugin skills, and only with an active project
    // to write into. Plugin skills are controlled via enabledPlugins, not skillOverrides.
    private var canToggle: Bool {
        showEnableToggle && pluginID == nil && app.activePath != nil && item is Skill
    }

    // frontmatter keys shown in the header/description already; don't repeat in chip list
    private var extraKeys: [String] {
        meta.keys.filter { $0 != "description" && $0 != "name" }.sorted()
    }

    var body: some View {
        ExpandableCard(expanded: $expanded) { header } detail: { detail }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.body).bold()
                        .strikethrough(item.isOverridden)
                        .foregroundStyle(item.isOverridden ? .secondary : .primary)
                    if let pid = pluginID {
                        Button { jumpToPlugin(pid) } label: {
                            Pill(pid.components(separatedBy: "@").first ?? pid, color: .purple)
                        }
                        .buttonStyle(.plain)
                        .help("Show \(pid) on the Plugins page")
                    } else {
                        ProvenanceBadge(scope: item.scope, origin: item.origin)
                    }
                }
                if !expanded && !descriptionText.isEmpty {
                    Text(descriptionText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if canToggle, let skill = item as? Skill {
                PillToggle(isOn: skill.skillEnabled) { newValue in
                    guard let base = app.activePath else { return }
                    try WriteOps.setSkillOverride(skill.id, enabled: newValue,
                                                  in: Paths.projectSettings(base),
                                                  epoch: Int(Date().timeIntervalSince1970))
                    app.store.reload(activePath: app.activePath)
                }
                .help(skill.skillEnabled ? "Enabled — Claude can auto-invoke it in \(app.activePath!.lastPathComponent)"
                                         : "Disabled for \(app.activePath!.lastPathComponent) — you can still run it via /")
            }
            OpenInEditorButton(url: item.sourcePath, onDelete: item.origin.pluginID == nil ? {
                try? FileManager.default.trashItem(at: item.sourcePath, resultingItemURL: nil)
                app.store.reload(activePath: app.activePath)
            } : nil)
        }
    }

    private var descriptionText: String {
        if let d = (item as? Skill)?.description { return d }
        if let d = (item as? Command)?.description { return d }
        if let d = (item as? Agent)?.description { return d }
        return meta["description"] ?? ""
    }

    // A description longer than this (chars) gets truncated in the detail with a Show more/less toggle.
    private var descriptionIsLong: Bool { descriptionText.count > 160 }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !descriptionText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(descriptionText).font(.subheadline).foregroundStyle(.primary.opacity(0.75))
                        .lineLimit(descExpanded ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    if descriptionIsLong {
                        Button { withAnimation(.easeInOut(duration: 0.15)) { descExpanded.toggle() } } label: {
                            Text(descExpanded ? "Show less" : "Show more")
                                .font(.caption).foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !extraKeys.isEmpty {
                SectionHeaderLabel("Frontmatter", icon: "text.alignleft")
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(extraKeys, id: \.self) { key in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(key).font(.caption).fontWeight(.bold).foregroundStyle(.secondary)
                            Text(meta[key] ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if !bodyPreview.isEmpty {
                SectionHeaderLabel("Preview", icon: "doc.plaintext")
                Text(bodyPreview)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6).padding(.horizontal, 9)
                    .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
                    .textSelection(.enabled)
            }

            sourceRow

            if let pid = pluginID {
                Button { jumpToPlugin(pid) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "puzzlepiece.extension").font(.system(size: 11))
                        Text("Provided by \(pid)").font(.caption)
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func jumpToPlugin(_ pid: String) {
        app.focusPluginID = pid
        app.selected = .plugins
    }

    private var sourceRow: some View {
        FilePathLabel(url: item.sourcePath)
    }
}
