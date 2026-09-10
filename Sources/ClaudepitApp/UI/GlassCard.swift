import SwiftUI

/// Reused glass container. Same look for sidebar, main card, everything.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content
    var cornerRadius: CGFloat = 20

    var body: some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
    }
}
