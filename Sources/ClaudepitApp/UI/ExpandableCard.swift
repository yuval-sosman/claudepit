import SwiftUI

/// Shared expandable-card scaffold used by MCP servers, config items (skills/commands),
/// rules, and plugin rows. Owns the chevron, the rounded background whose opacity shifts
/// on expand, the header row (padding + tap-to-toggle), and the detail block's padding +
/// transition. Call sites supply only the header content *after* the chevron and the
/// detail content.
struct ExpandableCard<Header: View, Detail: View>: View {
    @Binding var expanded: Bool
    @ViewBuilder var header: () -> Header
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                // Chevron is the only expand/collapse target — header buttons get clean first-tap.
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? Icon.chevronExpanded : Icon.chevronCollapsed)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(expanded ? Color.accentColor : .secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                header()
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .textSelection(.disabled)
            if expanded {
                detail()
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12).padding(.leading, 22)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(.white.opacity(expanded ? 0.06 : 0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}
