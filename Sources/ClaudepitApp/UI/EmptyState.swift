import SwiftUI

struct EmptyState: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    func selectableRowBackground(isSelected: Bool) -> some View {
        self
            .background(isSelected ? Color.white.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 4)
    }
}
