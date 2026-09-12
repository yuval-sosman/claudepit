import Foundation

/// Pure layout policy for the Home dashboard's responsive region. Lives in Core (not the app
/// target) so the check runner, which links ClaudepitCore only, can test the breakpoint and the
/// column arithmetic without a SwiftUI host.
public enum HomeLayout {
    /// Content width at or above which Home shows two columns.
    public static let twoColumnMinWidth: CGFloat = 640
    /// Gap between the two columns.
    public static let columnSpacing: CGFloat = 16
    /// Right column never narrows past this; plan names and session titles need the room.
    public static let minRightColumnWidth: CGFloat = 300
    /// Share of the usable width the right column asks for before the floor applies.
    /// 0.45 (was 0.40) since the Claude Code card grew the year heatmap and model charts —
    /// the extra width goes straight into heatmap cell size.
    public static let rightColumnFraction: CGFloat = 0.45

    public static func isTwoColumn(width: CGFloat) -> Bool { width >= twoColumnMinWidth }

    /// Column widths for `width`, or `nil` when the layout should stack into one column.
    /// `left + columnSpacing + right == width`.
    public static func columnWidths(width: CGFloat) -> (left: CGFloat, right: CGFloat)? {
        guard isTwoColumn(width: width) else { return nil }
        let usable = width - columnSpacing
        let right = max(minRightColumnWidth, usable * rightColumnFraction)
        return (left: usable - right, right: right)
    }
}
