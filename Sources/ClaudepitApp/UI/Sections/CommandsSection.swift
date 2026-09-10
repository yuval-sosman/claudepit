import SwiftUI
import ClaudepitCore

struct CommandsSection: View {
    @ObservedObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Commands").font(.title2).bold()
            ScopeGroupedList(items: app.store.commands.filter { !$0.isOverridden },
                             highlightApp: app, sectionRaw: "commands") { c in
                ConfigItemCard(item: c, meta: c.meta, bodyPreview: c.bodyPreview, app: app)
            }
        }
    }
}
