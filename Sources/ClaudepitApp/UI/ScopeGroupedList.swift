import SwiftUI
import ClaudepitCore

/// Three always-present, equal-HEIGHT stacked sections — User (global) / Project / Local —
/// each taking a third of the container height with its own internal scroll.
/// Every entity appears under its own scope; plugin-scoped items fold into User.
/// Callers pass only effective items (filter out isOverridden) and supply a row
/// builder (so toggles still work).
struct ScopeGroupedList<Item: ConfigItem, Row: View>: View where Item.ID == String {
    let items: [Item]
    var highlightApp: AppState? = nil
    var sectionRaw: String? = nil
    @ViewBuilder var row: (Item) -> Row

    private var groups: [(title: String, items: [Item])] {
        [
            ("User (global)", items.filter { $0.scope == .global || $0.scope == .plugin }),
            ("Project",       items.filter { $0.scope == .project }),
            ("Local",         items.filter { $0.scope == .local }),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(group.title)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(group.items.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let app = highlightApp, let raw = sectionRaw {
                        PaneWithHighlight(app: app, sectionRaw: raw, items: group.items, row: row)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                if group.items.isEmpty {
                                    Text("—").font(.caption).foregroundStyle(.tertiary)
                                } else {
                                    ForEach(group.items) { row($0) }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Helper view that wraps a pane's content in a ScrollViewReader and scrolls to pending highlights.
private struct PaneWithHighlight<Item: ConfigItem, Row: View>: View where Item.ID == String {
    @ObservedObject var app: AppState
    let sectionRaw: String
    let items: [Item]
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if items.isEmpty {
                        Text("—").font(.caption).foregroundStyle(.tertiary)
                    } else {
                        ForEach(items) { item in
                            row(item).sessionHighlight(sectionRaw: sectionRaw, id: item.id, app: app)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
            .onChange(of: app.pendingHighlight) { _, target in
                guard let t = target, t.sectionRaw == sectionRaw else { return }
                withAnimation { proxy.scrollTo("\(sectionRaw)::\(t.itemID)", anchor: .center) }
            }
            .onAppear {
                if let t = app.pendingHighlight, t.sectionRaw == sectionRaw {
                    proxy.scrollTo("\(sectionRaw)::\(t.itemID)", anchor: .center)
                }
            }
        }
    }
}
