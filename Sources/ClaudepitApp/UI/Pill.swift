import SwiftUI
import ClaudepitCore

/// Canonical capsule-pill badge used across the app for scope / plugin / status
/// tags. Matches the exact font/opacity/padding of the original `ProvenanceBadge`
/// (horizontal 8, vertical 3) by default. Some call sites use tighter padding
/// (transport / scope-count pills 7/2, tool annotations 6/2) — pass `hPadding` /
/// `vPadding` to match those.
struct Pill: View {
    let text: String
    let color: Color
    var hPadding: CGFloat
    var vPadding: CGFloat

    init(_ text: String, color: Color, hPadding: CGFloat = 8, vPadding: CGFloat = 3) {
        self.text = text
        self.color = color
        self.hPadding = hPadding
        self.vPadding = vPadding
    }

    var body: some View {
        Text(text)
            .font(.caption2).bold()
            .padding(.horizontal, hPadding).padding(.vertical, vPadding)
            .background(color.opacity(0.22), in: Capsule())
            .foregroundStyle(color)
    }
}

extension Color {
    /// Single source of truth for scope/origin → badge color.
    /// plugin → purple, global → blue, project → green, local → orange.
    static func provenanceColor(origin: Origin, scope: Scope) -> Color {
        switch (origin, scope) {
        case (.plugin, _): return .purple
        case (_, .global): return .blue
        case (_, .project): return .green
        case (_, .local): return .orange
        case (_, .plugin): return .purple  // unreachable: plugin scope only occurs with plugin origin
        }
    }

    /// Scope-only color (no origin). Used where only a `Scope` is known.
    static func scopeColor(_ scope: Scope) -> Color {
        provenanceColor(origin: .user, scope: scope)
    }
}
