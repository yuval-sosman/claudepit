import SwiftUI
import ClaudepitCore

struct HooksSection: View {
    @ObservedObject var app: AppState
    @State private var showLifecycle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Hooks").font(.title2).bold()
                Button { showLifecycle.toggle() } label: {
                    Image(systemName: Icon.info)
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hook lifecycle diagram")
                .popover(isPresented: $showLifecycle, arrowEdge: .trailing) {
                    LifecycleDiagramPopover()
                }
            }
            ScopeGroupedList(items: app.store.hooks.filter { !$0.isOverridden },
                             highlightApp: app, sectionRaw: "hooks") { h in
                HookCard(hook: h, app: app)
            }
        }
    }
}

private struct LifecycleDiagramPopover: View {
    var body: some View {
        ScrollView {
            if let url = Bundle.module.url(forResource: "hooks-lifecycle", withExtension: "png"),
               let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 400).padding(16)
            } else {
                Text("Lifecycle diagram not available.")
                    .font(.caption).foregroundStyle(.secondary).padding(16)
            }
        }
        .frame(width: 432, height: 900)
    }
}
