import Foundation
@testable import ClaudepitCore

func conflictDocumentChecks() -> [Bool] {
    var results: [Bool] = []

    let two = """
    top
    <<<<<<< HEAD
    ours 1
    =======
    theirs 1
    >>>>>>> main
    middle
    <<<<<<< HEAD
    ours 2a
    ours 2b
    =======
    >>>>>>> main
    bottom

    """

    results.append(check("parse: two conflicts, their sides, labels and lines") {
        let doc = ConflictDocument.parse(two)
        try expectEqual(doc.conflicts.count, 2, "two conflicts")
        let c = doc.conflicts
        try expectEqual(c[0].current, ["ours 1"], "first current")
        try expectEqual(c[0].incoming, ["theirs 1"], "first incoming")
        try expectEqual(c[0].currentLabel, "HEAD", "current label")
        try expectEqual(c[0].incomingLabel, "main", "incoming label")
        try expectEqual(c[0].startLine, 2, "opens on line 2")
        try expectEqual(c[1].current, ["ours 2a", "ours 2b"], "second current")
        try expectEqual(c[1].incoming, [], "an empty side")
        try expectEqual(c[1].startLine, 8, "second opens on line 8")
        try expect(c[0].base == nil, "no base without diff3 markers")
    })

    results.append(check("text round-trips exactly — trailing newline and CRLF included") {
        try expectEqual(ConflictDocument.parse(two).text, two, "LF")
        let crlf = two.replacingOccurrences(of: "\n", with: "\r\n")
        let doc = ConflictDocument.parse(crlf)
        try expectEqual(doc.conflicts.count, 2, "markers found before a CR")
        try expectEqual(doc.conflicts[0].incomingLabel, "main", "the CR is not part of the label")
        try expectEqual(doc.text, crlf, "CRLF")
        try expectEqual(ConflictDocument.parse("").text, "", "empty")
    })

    results.append(check("resolving one conflict leaves the other and the clean text alone") {
        let doc = ConflictDocument.parse(two)
        let r = doc.resolving(0, .incoming)
        try expect(r.hasPrefix("top\ntheirs 1\nmiddle\n<<<<<<< HEAD\n"), "first replaced, second kept: \(r)")
        let after = ConflictDocument.parse(r)
        try expectEqual(after.conflicts.count, 1, "one left")
        try expectEqual(after.conflicts[0].current, ["ours 2a", "ours 2b"], "the one left is the second")
        try expectEqual(doc.resolving(1, .both), "top\n<<<<<<< HEAD\nours 1\n=======\ntheirs 1\n>>>>>>> main\nmiddle\nours 2a\nours 2b\nbottom\n", "both = current then incoming")
    })

    results.append(check("resolvingAll applies one choice everywhere") {
        let doc = ConflictDocument.parse(two)
        try expectEqual(doc.resolvingAll(.current), "top\nours 1\nmiddle\nours 2a\nours 2b\nbottom\n", "all current")
        try expectEqual(doc.resolvingAll(.incoming), "top\ntheirs 1\nmiddle\nbottom\n", "all incoming")
        try expect(!ConflictDocument.parse(doc.resolvingAll(.both)).hasConflicts, "no markers left")
    })

    results.append(check("diff3 markers carry the base, which no choice keeps") {
        let t = "<<<<<<< HEAD\nours\n||||||| base\norig\n=======\ntheirs\n>>>>>>> main\n"
        let doc = ConflictDocument.parse(t)
        try expectEqual(doc.conflicts.count, 1, "one conflict")
        try expectEqual(doc.conflicts[0].base, ["orig"], "base lines")
        try expectEqual(doc.conflicts[0].baseLabel, "base", "base label")
        try expectEqual(doc.resolving(0, .both), "ours\ntheirs\n", "base dropped")
        try expectEqual(doc.text, t, "round-trip")
    })

    results.append(check("malformed runs stay text: unterminated, nested, eight-character rulers") {
        let open = "a\n<<<<<<< HEAD\nb\n=======\nc\n"
        try expect(!ConflictDocument.parse(open).hasConflicts, "never closed -> text")
        try expectEqual(ConflictDocument.parse(open).text, open, "and unchanged")
        let nested = "<<<<<<< A\nx\n<<<<<<< B\ny\n=======\nz\n>>>>>>> C\n"
        let n = ConflictDocument.parse(nested)
        try expectEqual(n.conflicts.count, 1, "the inner, well-formed one")
        try expectEqual(n.conflicts[0].currentLabel, "B", "is B")
        try expectEqual(n.text, nested, "round-trip")
        let ruler = "<<<<<<< HEAD\na\n========\nb\n=======\nc\n>>>>>>> main\n"
        let r = ConflictDocument.parse(ruler)
        try expectEqual(r.conflicts.first?.current, ["a", "========", "b"], "eight '=' is content")
        try expect(ConflictDocument.marker("<<<<<<<<", "<") == nil, "eight '<' is not a marker")
        try expect(ConflictDocument.marker("<<<<<<<HEAD", "<") == nil, "a label needs its space")
    })

    // MARK: Hunks

    results.append(check("numberedLines numbers old and new sides from the header") {
        let h = DiffHunk(id: 0, header: "@@ -10,3 +12,4 @@ func x()", lines: [" a", "-b", "+B", "+C", " d", "\\ No newline at end of file"])
        try expect(h.starts! == (10, 12), "starts")
        let l = h.numberedLines()
        try expectEqual(l.map(\.kind), [.context, .remove, .add, .add, .context, .note], "kinds")
        try expectEqual(l.map(\.oldLine), [10, 11, nil, nil, 12, nil], "old numbers")
        try expectEqual(l.map(\.newLine), [12, nil, 13, 14, 15, nil], "new numbers")
        try expectEqual(l[5].text, "No newline at end of file", "note text")
        try expect(h.stat == (2, 1), "stat")
        let single = DiffHunk(id: 0, header: "@@ -0,0 +1 @@", lines: ["+x"])
        try expectEqual(single.numberedLines().first?.newLine, 1, "a count-less range")
        let combined = DiffHunk(id: 0, header: "@@@ -1,1 -1,1 +1,5 @@@", lines: ["++x"])
        try expect(combined.starts == nil, "a combined diff header doesn't parse")
        try expectEqual(combined.numberedLines().first?.newLine, nil, "and gets no numbers")
    })

    results.append(check("hunk label: line range, git's function context, brainstorm headings") {
        func label(_ h: String) -> String { DiffHunk(id: 0, header: h, lines: []).label }
        try expectEqual(label("@@ -10,3 +12,4 @@"), "Lines 12–15", "range")
        try expectEqual(label("@@ -10,3 +12,4 @@ func reload() {"), "Lines 12–15 · func reload() {", "with context")
        try expectEqual(label("@@ -3 +3 @@"), "Line 3", "one line, no counts")
        try expectEqual(label("@@ -5,2 +4,0 @@"), "Removed after line 4", "a pure removal")
        try expectEqual(label("@@ -1,0 +1,1 @@ Requirements · abc123"), "Requirements", "brainstorm kind, id dropped")
        try expectEqual(label("@@ -1,2 +1,3 @@ Description · x9"), "Description", "brainstorm description")
        try expectEqual(label("@@@ -1,1 -1,1 +1,5 @@@"), "@@@ -1,1 -1,1 +1,5 @@@", "unparseable -> raw")
    })

    results.append(check("buildPatch rewrites a rename preamble as an edit of the new path") {
        let header = ["diff --git a/old dir/a.txt b/new dir/z.txt", "similarity index 75%",
                      "rename from old dir/a.txt", "rename to new dir/z.txt", "index 1..2 100644",
                      "--- a/old dir/a.txt", "+++ b/new dir/z.txt"]
        try expectEqual(renamedPath(header), "new dir/z.txt", "new path, spaces kept")
        let patch = buildPatch(fileHeader: header, hunk: DiffHunk(id: 0, header: "@@ -1 +1,2 @@", lines: [" a", "+b"]))
        try expectEqual(patch, "diff --git a/new dir/z.txt b/new dir/z.txt\n--- a/new dir/z.txt\n+++ b/new dir/z.txt\n@@ -1 +1,2 @@\n a\n+b\n", "patch")
        try expect(renamedPath(["diff --git a/x b/x", "--- a/x", "+++ b/x"]) == nil, "not a rename")
    })

    results.append(check("isBinaryDiff") {
        try expect(isBinaryDiff("diff --git a/i.png b/i.png\nindex 1..2 100644\nBinary files a/i.png and b/i.png differ\n"), "binary")
        try expect(!isBinaryDiff("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-Binary files a and b differ\n+x\n"), "text that mentions it")
        try expect(!isBinaryDiff(""), "empty")
    })

    // MARK: Selection

    results.append(check("ChangeSelection.follow: into and out of the conflicts list") {
        let conflictA = ChangeSelection(path: "a", staged: false, untracked: false, conflicted: true)
        try expectEqual(ChangeSelection.follow(conflictA, staged: [], unstaged: [], conflicted: ["a"]), conflictA, "stays")
        let resolved = ChangeSelection.follow(conflictA, staged: ["a"], unstaged: [], conflicted: [])
        try expect(resolved?.staged == true && resolved?.conflicted == false, "marked resolved -> Staged")
        let stagedA = ChangeSelection(path: "a", staged: true, untracked: false)
        let back = ChangeSelection.follow(stagedA, staged: [], unstaged: [], conflicted: ["a"])
        try expect(back?.conflicted == true && back?.staged == false, "a staged file that became a conflict")
        try expectEqual(ChangeSelection.follow(conflictA, staged: [], unstaged: [], conflicted: []), nil, "deleted")
    })

    return results
}
