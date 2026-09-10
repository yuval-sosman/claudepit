import SwiftUI
import AppKit
import ClaudepitCore

// Opens a standalone NSPanel for re-keying a plugin's marketplace.
// Using NSPanel avoids SwiftUI @State resets caused by FileWatcher-triggered store reloads.
@MainActor
func openRekeyPanel(plugin: Plugin, knownMarketplaces: [String], onSave: @escaping (String) -> Void) {
    let controller = RekeyPanelController(plugin: plugin, knownMarketplaces: knownMarketplaces, onSave: onSave)
    controller.showPanel()
}

@MainActor
private final class RekeyPanelController: NSObject {
    private var panel: NSPanel?
    private let plugin: Plugin
    private let knownMarketplaces: [String]
    private let onSave: (String) -> Void

    init(plugin: Plugin, knownMarketplaces: [String], onSave: @escaping (String) -> Void) {
        self.plugin = plugin
        self.knownMarketplaces = knownMarketplaces
        self.onSave = onSave
    }

    func showPanel() {
        let contentView = RekeyView(
            plugin: plugin,
            knownMarketplaces: knownMarketplaces,
            onSave: { [weak self] marketplace in
                self?.onSave(marketplace)
                self?.closePanel()
            },
            onCancel: { [weak self] in self?.closePanel() }
        )
        let hosting = NSHostingController(rootView: contentView)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 280),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Change Marketplace"
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
        // Keep controller alive while panel is open
        objc_setAssociatedObject(panel, &RekeyPanelController.key, self, .OBJC_ASSOCIATION_RETAIN)
    }

    private func closePanel() {
        panel?.close()
        panel = nil
    }

    private nonisolated(unsafe) static var key = "RekeyPanelController"
}

private struct RekeyView: View {
    let plugin: Plugin
    let knownMarketplaces: [String]
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var selected: String
    @State private var search: String = ""
    @State private var addMode: Bool = false
    @State private var newSource: String = ""
    @State private var loading: Bool = false
    @State private var error: String? = nil
    @FocusState private var searchFocused: Bool
    @FocusState private var sourceFocused: Bool

    init(plugin: Plugin, knownMarketplaces: [String], onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.plugin = plugin
        self.knownMarketplaces = knownMarketplaces
        self.onSave = onSave
        self.onCancel = onCancel
        _selected = State(initialValue: plugin.marketplace)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if addMode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("GitHub repo, URL, or local path").font(.caption).foregroundStyle(.secondary)
                    TextField("e.g. obra/superpowers", text: $newSource)
                        .textFieldStyle(.roundedBorder)
                        .focused($sourceFocused)
                        .onAppear { sourceFocused = true }
                    if let err = error {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        Button("Cancel") { addMode = false; newSource = "" }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        Spacer()
                        Button("Add & Select") {
                            loading = true; error = nil
                            let src = newSource
                            Task.detached {
                                let out = shell("claude", "plugin", "marketplace", "add", src)
                                let failed = out.lowercased().contains("error") || out.lowercased().contains("failed")
                                await MainActor.run {
                                    loading = false
                                    if failed {
                                        error = out.components(separatedBy: .newlines).first { !$0.isEmpty } ?? "Failed"
                                    } else {
                                        selected = src.split(separator: "/").last.map(String.init) ?? src
                                        addMode = false; newSource = ""
                                    }
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newSource.isEmpty || loading)
                    }
                }
            } else {
                let filtered = knownMarketplaces.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
                TextField("Search…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onAppear { searchFocused = true }
                ScrollView {
                    VStack(spacing: 0) {
                        Button {
                            search = ""; addMode = true
                        } label: {
                            HStack {
                                Image(systemName: Icon.add).font(.system(size: 11))
                                Text("Add new marketplace…").font(.subheadline)
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(Color.accentColor)
                            .background(Color.accentColor.opacity(0.1), in: Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                        ForEach(filtered, id: \.self) { name in
                            Button { selected = name } label: {
                                HStack {
                                    Text(name).font(.subheadline)
                                    Spacer()
                                    if selected == name {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(selected == name ? Color.accentColor.opacity(0.08) : Color.clear, in: Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 140)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.1)))

                if let err = error {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button("Cancel", action: onCancel).buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") { onSave(selected) }
                        .buttonStyle(.borderedProminent)
                        .disabled(selected.isEmpty || loading)
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
