import SwiftUI

/// Simple left-to-right wrapping layout for glob chips.
///
/// An item wider than a whole row is offered the row's width rather than its own, so one that can
/// shrink (a truncating `Text`, say a long branch name) fits instead of running out of the card;
/// an item that can't shrink (`.fixedSize()`) still takes what it needs.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0; var y: CGFloat = 0; var rowH: CGFloat = 0
        for sub in subviews {
            let s = Self.size(of: sub, rowWidth: maxWidth)
            if x + s.width > maxWidth && x > 0 { y += rowH + spacing; x = 0; rowH = 0 }
            rowH = max(rowH, s.height); x += s.width + spacing
        }
        return CGSize(width: maxWidth, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX; var y = bounds.minY; var rowH: CGFloat = 0
        for sub in subviews {
            let s = Self.size(of: sub, rowWidth: bounds.width)
            if x + s.width > bounds.maxX && x > bounds.minX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            rowH = max(rowH, s.height); x += s.width + spacing
        }
    }

    private static func size(of sub: LayoutSubview, rowWidth: CGFloat) -> CGSize {
        let ideal = sub.sizeThatFits(.unspecified)
        guard rowWidth.isFinite, ideal.width > rowWidth else { return ideal }
        return sub.sizeThatFits(ProposedViewSize(width: rowWidth, height: nil))
    }
}
