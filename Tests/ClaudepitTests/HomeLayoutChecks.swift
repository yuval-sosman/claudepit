import Foundation
@testable import ClaudepitCore

func homeLayoutChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("constants: 640 breakpoint, 16 gap, 280 floor, 0.40 fraction") {
        try expectEqual(HomeLayout.twoColumnMinWidth, 640, "twoColumnMinWidth")
        try expectEqual(HomeLayout.columnSpacing, 16, "columnSpacing")
        try expectEqual(HomeLayout.minRightColumnWidth, 280, "minRightColumnWidth")
        try expectEqual(HomeLayout.rightColumnFraction, 0.40, "rightColumnFraction")
    })

    results.append(check("isTwoColumn: false below 640, true at and above") {
        try expectEqual(HomeLayout.isTwoColumn(width: 0), false, "width 0")
        try expectEqual(HomeLayout.isTwoColumn(width: 639), false, "width 639")
        try expectEqual(HomeLayout.isTwoColumn(width: 640), true, "width 640")
        try expectEqual(HomeLayout.isTwoColumn(width: 1600), true, "width 1600")
    })

    results.append(check("columnWidths: nil below the breakpoint (incl. unmeasured 0)") {
        try expect(HomeLayout.columnWidths(width: 0) == nil, "width 0 should stack")
        // 900x600 window with the sidebar expanded lands near 554pt of content width.
        try expect(HomeLayout.columnWidths(width: 554) == nil, "width 554 should stack")
        try expect(HomeLayout.columnWidths(width: 639) == nil, "width 639 should stack")
    })

    results.append(check("columnWidths at the breakpoint: the 280 floor is active") {
        guard let cols = HomeLayout.columnWidths(width: 640) else {
            throw CheckFailure(message: "expected two columns at 640")
        }
        try expectEqual(cols.left, 344, "left at 640")
        try expectEqual(cols.right, 280, "right at 640")
    })

    results.append(check("columnWidths at 1200: the 0.40 fraction is active") {
        guard let cols = HomeLayout.columnWidths(width: 1200) else {
            throw CheckFailure(message: "expected two columns at 1200")
        }
        try expectEqual(cols.right, 473.6, "right at 1200")
        try expectEqual(cols.left, 710.4, "left at 1200")
    })

    results.append(check("columnWidths invariants: no drift, floor honoured, left is wider") {
        for width in [CGFloat(640), 724, 1000, 1600] {
            guard let cols = HomeLayout.columnWidths(width: width) else {
                throw CheckFailure(message: "expected two columns at \(width)")
            }
            try expectEqual(cols.left + HomeLayout.columnSpacing + cols.right, width,
                            "left + spacing + right at \(width)")
            try expect(cols.right >= HomeLayout.minRightColumnWidth,
                       "right \(cols.right) below floor at \(width)")
            try expect(cols.left >= cols.right,
                       "left \(cols.left) narrower than right \(cols.right) at \(width)")
            try expect(cols.left >= 344, "left \(cols.left) starved at \(width)")
        }
    })

    return results
}
