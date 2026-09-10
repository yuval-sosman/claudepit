import SwiftUI

/// Three-state segmented control for plugin enable state:
///   on  |  off  |  –
/// "–" means "unset" (key not present in enabledPlugins).
struct ThreeStateSegment: View {
    enum State3: Equatable { case on, off, unset }

    let value: Bool?      // nil = unset
    var enabled: Bool = true
    let onChange: (State3) -> Void

    private var current: State3 {
        switch value {
        case true:  return .on
        case false: return .off
        default:    return .unset
        }
    }

    var body: some View {
        HStack(spacing: 1) {
            segment(label: "on",  state: .on,    activeColor: .green)
            segment(label: "off", state: .off,   activeColor: .red.opacity(0.8))
            segment(label: "–",   state: .unset, activeColor: .secondary)
        }
        .padding(2)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        .fixedSize()
        .opacity(enabled ? 1 : 0.35)
        .allowsHitTesting(enabled)
    }

    private func segment(label: String, state: State3, activeColor: Color) -> some View {
        let isActive = current == state
        return Text(label)
            .font(.caption2).fontWeight(isActive ? .bold : .regular)
            .foregroundStyle(isActive ? activeColor : .secondary.opacity(0.6))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(isActive ? activeColor.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onTapGesture { if enabled && current != state { onChange(state) } }
    }
}
