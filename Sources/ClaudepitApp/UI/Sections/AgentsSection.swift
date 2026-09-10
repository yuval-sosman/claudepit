import SwiftUI
import ClaudepitCore

struct AgentsSection: View {
    @ObservedObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agents").font(.title2).bold()
            ScopeGroupedList(items: app.store.agents.filter { !$0.isOverridden },
                             highlightApp: app, sectionRaw: "agents") { a in
                ConfigItemCard(item: a, meta: a.meta, bodyPreview: a.bodyPreview, app: app)
            }
        }
    }
}
