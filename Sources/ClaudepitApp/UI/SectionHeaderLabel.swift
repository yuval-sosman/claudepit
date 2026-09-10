import SwiftUI

/// The uppercase mini-header ("COMMAND", "TOOLS (3)", …) with a leading SF Symbol
/// and a trailing hairline rule, used inside the config/MCP/rule cards.
struct SectionHeaderLabel: View {
    let label: String
    let icon: String
    init(_ label: String, icon: String) { self.label = label; self.icon = icon }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(label).font(.caption).fontWeight(.bold).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.6)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
        }
    }
}
