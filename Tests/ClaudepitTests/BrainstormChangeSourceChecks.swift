import Foundation
@testable import ClaudepitCore

func brainstormChangeSourceChecks() -> [Bool] {
    var results: [Bool] = []

    // A single-hunk patch as buildPatch would hand it to applyHunk, with the
    // "<KindDir> · <id>" heading trailing the second @@.
    let patch = """
    diff --git a/T — brainstorm b/T — brainstorm
    --- a/T — brainstorm
    +++ b/T — brainstorm
    @@ -1,0 +1,1 @@ Requirements · abc123
    +do the thing
    """

    results.append(check("suggestionID: recovers id from the hunk section heading") {
        try expectEqual(BrainstormChangeSource.suggestionID(fromPatch: patch), "abc123", "id from heading")
    })

    results.append(check("suggestionID: nil when no heading present") {
        let noHeading = "@@ -1,0 +1,1 @@\n+x"
        try expect(BrainstormChangeSource.suggestionID(fromPatch: noHeading) == nil, "nil when absent")
    })

    results.append(check("suggestionID: nil when patch has no hunk header") {
        try expect(BrainstormChangeSource.suggestionID(fromPatch: "no hunk here") == nil, "nil, no @@")
    })

    return results
}
