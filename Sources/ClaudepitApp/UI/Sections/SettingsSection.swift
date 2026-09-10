import SwiftUI
import ClaudepitCore

struct SettingsSection: View {
    @ObservedObject var app: AppState
    @State private var showUnified = true
    @State private var expandOverride: Bool? = nil
    @State private var filterQuery: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Text("Settings").font(.title3).bold()
                    Spacer()
                    HStack(spacing: 6) {
                        Text(showUnified ? "Unified" : "Layered")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        PillToggle(isOn: showUnified) { newValue in
                            withAnimation(.easeInOut(duration: 0.2)) { showUnified = newValue }
                        }
                    }
                    HStack(spacing: 2) {
                        Button {
                            expandOverride = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { expandOverride = nil }
                        } label: {
                            Image(systemName: "rectangle.expand.vertical")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Expand all")

                        Button {
                            expandOverride = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { expandOverride = nil }
                        } label: {
                            Image(systemName: "rectangle.compress.vertical")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Collapse all")
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    searchBox
                    if !filterQuery.isEmpty {
                        HStack(spacing: 4) {
                            Text("Filter: \"\(filterQuery)\"")
                            Button { filterQuery = "" } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                SettingsTreeView(app: app, showUnified: showUnified, expandOverride: expandOverride, filterQuery: filterQuery)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var searchBox: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Filter settings…", text: $filterQuery).textFieldStyle(.plain).font(.caption)
            if !filterQuery.isEmpty {
                Button { filterQuery = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }
}
