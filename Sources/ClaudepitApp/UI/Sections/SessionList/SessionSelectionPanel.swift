import SwiftUI
import AppKit
import ClaudepitCore

/// The detail card while several sessions are selected: what they add up to, and what can be
/// done to all of them at once.
struct SessionSelectionPanel: View {
    let sessions: [SessionSummary]
    let context: SessionListContext
    let onAssign: (_ groupID: String, _ key: String) -> Void
    let onNewGroup: () -> Void
    let onUngroup: () -> Void
    let onTrash: () -> Void
    let onOpen: (SessionSummary) -> Void
    let onClear: () -> Void

    private var key: String? {
        let keys = Set(sessions.map(\.groupKey))
        return keys.count == 1 ? keys.first : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(sessions.count) sessions selected").font(.title3.weight(.semibold))
                    Text(facts).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear Selection", action: onClear).controlSize(.small)
            }

            actions

            VStack(alignment: .leading, spacing: 0) {
                ForEach(sessions.prefix(12)) { s in
                    Button { onOpen(s) } label: {
                        HStack(spacing: 8) {
                            SessionStatusGlyph(status: context.status(of: s)).frame(width: 10)
                            if let g = context.group(of: s) {
                                Circle().fill(g.color.swiftUIColor).frame(width: 7, height: 7)
                            }
                            Text(context.title(of: s)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(SessionTimeLabel.text(for: s.modifiedAt, now: context.now, inDateSection: false))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6).padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open only this session")
                    Divider().opacity(0.3)
                }
                if sessions.count > 12 {
                    Text("and \(sessions.count - 12) more").font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.top, 6)
                }
            }
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

            Text("⌘-click adds or removes a session · ⇧-click selects a range · ⌘A selects all · drag the selection onto a group")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var facts: String {
        let prompts = sessions.compactMap { context.stats[$0.id]?.prompts }.reduce(0, +)
        let cost = sessions.compactMap { context.stats[$0.id]?.cost }.reduce(0, +)
        let dates = sessions.map(\.modifiedAt)
        var parts: [String] = []
        if prompts > 0 { parts.append("\(prompts) prompts") }
        if cost >= 0.005 { parts.append(Money.compact(cost)) }
        if let lo = dates.min(), let hi = dates.max() {
            let a = lo.formatted(.dateTime.month(.abbreviated).day()), b = hi.formatted(.dateTime.month(.abbreviated).day())
            parts.append(a == b ? a : "\(a) – \(b)")
        }
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        let live = sessions.filter { context.status(of: $0).isLive }
        return HStack(spacing: 8) {
            if let key {
                let groups = context.groups[key]?.groups ?? []
                Menu {
                    ForEach(groups) { g in
                        let allIn = sessions.allSatisfy { $0.groupID == g.id }
                        Button { onAssign(g.id, key) } label: {
                            if allIn { Label(g.name, systemImage: "checkmark") } else { Text(g.name) }
                        }
                        .disabled(allIn)
                    }
                    if !groups.isEmpty { Divider() }
                    Button("New Group from Selection…", action: onNewGroup)
                } label: {
                    Label("Move to Group", systemImage: "folder")
                }
                .fixedSize()
            } else {
                Text("From different projects — they can't share a group")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if sessions.contains(where: { $0.groupID != nil }) {
                Button("Remove from Groups", action: onUngroup)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sessions.map(\.id).joined(separator: "\n"), forType: .string)
            } label: { Label("Copy IDs", systemImage: Icon.copyPath) }
            Spacer(minLength: 0)
            Button(role: .destructive, action: onTrash) {
                Label(live.isEmpty ? "Move to Trash…" : "Move \(sessions.count - live.count) to Trash…", systemImage: Icon.delete)
            }
            .disabled(live.count == sessions.count)
            .help(live.isEmpty ? "Move these sessions to the Trash"
                               : "\(live.count) running session\(live.count == 1 ? " is" : "s are") skipped")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}
