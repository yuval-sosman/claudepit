import Foundation
@testable import ClaudepitCore

func worktreeResumerChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("rootPaneID: parses tab create response") {
        let json: [String: Any] = ["result": ["root_pane": ["pane_id": "w4:pQ", "tab_id": "w4:tE"], "tab": ["tab_id": "w4:tE"]]]
        try expectEqual(Herdr.rootPaneID(fromJSON: json), "w4:pQ", "root pane id")
    })

    results.append(check("rootPaneID: returns nil on missing root_pane") {
        let json: [String: Any] = ["result": ["pane": ["pane_id": "w4:pQ"]]]
        try expect(Herdr.rootPaneID(fromJSON: json) == nil, "nil when no root_pane key")
    })

    results.append(check("tabID: parses pane get response") {
        let json: [String: Any] = ["result": ["pane": ["pane_id": "w4:p8", "tab_id": "w4:t5"]]]
        try expectEqual(Herdr.tabID(fromPaneJSON: json), "w4:t5", "tab id")
    })

    results.append(check("tabID: returns nil on missing tab_id") {
        let json: [String: Any] = ["result": ["pane": ["pane_id": "w4:p8"]]]
        try expect(Herdr.tabID(fromPaneJSON: json) == nil, "nil when no tab_id key")
    })

    return results
}
