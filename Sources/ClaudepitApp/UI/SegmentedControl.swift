import SwiftUI

/// App-standard segmented control — a rounded translucent track with an
/// accent-tinted active pill. Matches `ThreeStateSegment`'s look so mode
/// toggles read as native to the app rather than a stock `.segmented` Picker.
struct SegmentedControl<T: Hashable & CaseIterable & RawRepresentable, Label: View>: View
    where T.RawValue == String, T.AllCases: RandomAccessCollection {
    @Binding var selection: T
    @ViewBuilder var label: (T) -> Label

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(T.allCases), id: \.self) { option in
                let isActive = option == selection
                label(option)
                    .font(.caption).fontWeight(isActive ? .semibold : .regular)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(isActive ? Color.accentColor.opacity(0.18) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { if !isActive { selection = option } }
            }
        }
        .padding(2)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .animation(.easeInOut(duration: 0.15), value: selection)
        .fixedSize()
    }
}
