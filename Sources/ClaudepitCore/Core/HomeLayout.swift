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
    /// 0.45 (was 0.40): the right column carries the number cards — limits, usage (six tiles and
    /// a cost chart) and the year heatmap — and the extra width goes into tiles and heatmap cells.
    public static let rightColumnFraction: CGFloat = 0.45

    public static func isTwoColumn(width: CGFloat) -> Bool { width >= twoColumnMinWidth }

    /// Columns for `count` stat tiles in balanced rows: the fewest rows the width allows, then
    /// the fewest columns that keep that many rows — 6 across, 3 + 3 or 2 + 2 + 2, never 5 + 1.
    ///
    /// SwiftUI measures with an **unlimited** proposal too (a lazy stack sizing its children
    /// ideally proposes `.infinity`), and `Int(.infinity)` traps — that crashed Home on open. A
    /// width that isn't finite means "no limit": everything goes in one row.
    public static func balancedColumns(width: CGFloat, count: Int, minWidth: CGFloat,
                                       spacing: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        guard width.isFinite else { return count }
        let fit = max(1, Int(max(0, width + spacing) / (minWidth + spacing)))
        let rows = (count + fit - 1) / fit
        return (count + rows - 1) / rows
    }

    /// Column widths for `width`, or `nil` when the layout should stack into one column.
    /// `left + columnSpacing + right == width`.
    public static func columnWidths(width: CGFloat) -> (left: CGFloat, right: CGFloat)? {
        guard isTwoColumn(width: width) else { return nil }
        let usable = width - columnSpacing
        let right = max(minRightColumnWidth, usable * rightColumnFraction)
        return (left: usable - right, right: right)
    }
}
