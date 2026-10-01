import SwiftUI

/// A capsule action in a detail card's header — the Sessions, Plans and Memory pages share it, so
/// their headers read as one family. `isOn` draws it as a toggle that is currently on (a panel it
/// opened is showing).
struct HeaderButton: View {
    let title: String
    let icon: String
    let help: String
    var isOn: Bool = false
    /// Icon only — for a header too narrow for its labels. The title moves into the tooltip.
    var compact: Bool = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                if !compact { Text(title).lineLimit(1) }
            }
            .font(.system(size: 11))
            .foregroundStyle(isOn ? Color.accentColor : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 3.5)
            .background(isOn ? Color.accentColor.opacity(hover ? 0.24 : 0.18) : Color.white.opacity(hover ? 0.10 : 0.06),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(compact ? "\(title) — \(help)" : help)
    }
}

/// The header's "…" capsule: the actions that don't earn a button of their own.
struct HeaderMenu<Items: View>: View {
    var help: String = "More actions"
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu { items() } label: {
            Image(systemName: Icon.moreActions)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 20)
                .background(.white.opacity(0.06), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}

/// One fact in a header's fact strip: a small icon and a short value, with the detail on hover.
struct HeaderFact: View {
    let icon: String
    let text: String
    var help: String = ""
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9.5))
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(color)
        .fixedSize()
        .help(help)
    }
}
