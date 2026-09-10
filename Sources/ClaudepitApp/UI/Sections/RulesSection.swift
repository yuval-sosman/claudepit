import SwiftUI
import ClaudepitCore

struct RulesSection: View {
    @ObservedObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rules").font(.title2).bold()
            ScopeGroupedList(items: app.store.rules.filter { !$0.isOverridden },
                             highlightApp: app, sectionRaw: "rules") { r in
                RuleCard(rule: r, app: app)
            }
        }
    }
}
