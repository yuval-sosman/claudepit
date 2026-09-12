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
            // Tight and faint on purpose: Home stacks cards 16pt apart, and a wide
            // (radius 24) shadow from both neighbors overlapped the whole gap, tinting
            // it into a visible band that read as a wrapping container.
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}
