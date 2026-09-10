import SwiftUI
import ClaudepitCore

struct SkillsSection: View {
    @ObservedObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Skills").font(.title2).bold()
            ScopeGroupedList(items: app.store.skills.filter { !$0.isOverridden },
                             highlightApp: app, sectionRaw: "skills") { s in
                ConfigItemCard(item: s, meta: s.meta, bodyPreview: s.bodyPreview, showEnableToggle: true, app: app)
            }
        }
    }
}
