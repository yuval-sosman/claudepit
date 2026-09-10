import SwiftUI
import ClaudepitCore

struct MCPSection: View {
    @ObservedObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MCP Servers").font(.title2).bold()
            ScopeGroupedList(items: app.store.mcpServers.filter { !$0.isOverridden },
                             highlightApp: app, sectionRaw: "mcp") { s in
                MCPServerCard(server: s, app: app)
            }
        }
    }
}
