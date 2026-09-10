import SwiftUI

/// A small pill-shaped on/off switch. Shared by the Plugins page and skill cards.
struct PillToggle: View {
    let isOn: Bool
    let onToggle: (Bool) throws -> Void

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.12))
                .frame(width: 36, height: 20)
            Circle()
                .fill(isOn ? Color.white : Color.white.opacity(0.6))
                .frame(width: 14, height: 14)
                .padding(.horizontal, 3)
        }
        .animation(.easeInOut(duration: 0.18), value: isOn)
        .contentShape(Rectangle())
        .onTapGesture { try? onToggle(!isOn) }
    }
}
