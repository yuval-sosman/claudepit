import Foundation
@testable import ClaudepitCore

/// The review command writes its findings as a JSON block inside review.md, and the findings screen
/// is built entirely from what this parser recovers. Both formats are pinned here: the JSON one the
/// command emits now, and the `severity | title | detail` lines older reviews already on disk carry.
func reviewFindingParseChecks() -> [Bool] {
    var results: [Bool] = []

    func block(_ inner: String) -> String {
        "noise before\nCLAUDEPIT_FINDINGS_BEGIN\n\(inner)\nCLAUDEPIT_FINDINGS_END\nnoise after"
    }

    let jsonBody = """
    [
      {
        "ruleId": "C1",
        "severity": "high",
        "category": "correctness",
        "title": "Null deref in parseUser",
        "locations": ["Sources/Parser.swift:41", "Sources/Parser.swift"],
        "what": "Force-unwraps a nil optional.",
        "why": "Empty body crashes the process.",
        "fix": "Guard the unwrap."
      },
      {
        "ruleId": "M1",
        "severity": "low",
        "category": "maintainability",
        "title": "Vague name",
        "locations": [],
        "what": "foo builds a URL.",
        "why": "Call sites are unreadable.",
        "fix": "Rename to requestURL(for:)."
      }
    ]
    """

    results.append(check("the JSON block yields every structured field") {
        let out = TaskTransition.parseFindings(from: block(jsonBody))
        try expectEqual(out.count, 2, "two findings")
        let c = out[0]
        try expectEqual(c.title, "Null deref in parseUser", "title")
        try expectEqual(c.severity, "high", "severity")
        try expectEqual(c.category, "correctness", "category")
        try expectEqual(c.ruleID, "C1", "ruleId")
        try expectEqual(c.what, "Force-unwraps a nil optional.", "what")
        try expectEqual(c.why, "Empty body crashes the process.", "why")
        try expectEqual(c.fix, "Guard the unwrap.", "fix")
        try expect(c.isStructured, "reads as structured")
        try expectEqual(c.locations?.count, 2, "both locations")
        try expectEqual(c.locations?[0].file, "Sources/Parser.swift", "file")
        try expectEqual(c.locations?[0].line, 41, "line")
        try expect(c.locations?[1].line == nil, "a bare path has no line")
        // `detail` stays populated for every consumer that predates the structured fields.
        try expect(c.detail.contains("Force-unwraps"), "detail carries what")
        try expect(c.detail.contains("Guard the unwrap"), "detail carries fix")
    })

    results.append(check("an empty locations array leaves locations nil, not empty") {
        let out = TaskTransition.parseFindings(from: block(jsonBody))
        try expect(out[1].locations == nil, "nil rather than []")
        try expect(out[1].isStructured, "still structured — what/why/fix carry it")
    })

    results.append(check("a ```json fence around the array is tolerated") {
        // Agents add one by reflex; refusing it would silently yield zero findings.
        let out = TaskTransition.parseFindings(from: block("```json\n\(jsonBody)\n```"))
        try expectEqual(out.count, 2, "parsed through the fence")
    })

    results.append(check("severity accepts the report's words and SARIF's") {
        func sev(_ raw: String) throws -> String {
            let j = "[{\"title\":\"t\",\"severity\":\"\(raw)\",\"what\":\"w\"}]"
            guard let f = TaskTransition.parseFindings(from: block(j)).first else {
                throw CheckFailure(message: "no finding for \(raw)")
            }
            return f.severity
        }
        for raw in ["high", "Critical", "error"] { try expectEqual(sev(raw), "high", raw) }
        for raw in ["med", "medium", "Important", "warning"] { try expectEqual(sev(raw), "med", raw) }
        for raw in ["low", "Minor", "note", "banana"] { try expectEqual(sev(raw), "low", raw) }
    })

    results.append(check("SARIF's own level field works when severity is absent") {
        let out = TaskTransition.parseFindings(from: block("[{\"title\":\"t\",\"level\":\"error\",\"what\":\"w\"}]"))
        try expectEqual(out.first?.severity, "high", "level read as severity")
    })

    results.append(check("an empty array means no findings, not a parse failure") {
        try expectEqual(TaskTransition.parseFindings(from: block("[]")).count, 0, "none")
    })

    results.append(check("the legacy pipe format still parses") {
        // Reviews already on disk use it; dropping support would blank their findings screen.
        let out = TaskTransition.parseFindings(from: block(
            "high | Null deref | parseUser force-unwraps (Parser.swift:41)\nlow | Rename foo | vague"))
        try expectEqual(out.count, 2, "two")
        try expectEqual(out[0].severity, "high", "severity")
        try expectEqual(out[0].detail, "parseUser force-unwraps (Parser.swift:41)", "detail verbatim")
        try expect(!out[0].isStructured, "no structure to show")
    })

    results.append(check("no markers at all yields nothing") {
        try expectEqual(TaskTransition.parseFindings(from: "just a review, no block").count, 0, "none")
    })

    results.append(check("a finding's id survives the review being reworded") {
        // mergeFindings matches spawnedTaskID by id, so an id keyed on the narrative would drop
        // every "task created" link the moment a reviewer edited a sentence.
        func idFor(what: String, why: String) -> String? {
            let j = """
            [{"title":"Null deref in parseUser","severity":"high",
              "locations":["Sources/Parser.swift:41"],"what":"\(what)","why":"\(why)","fix":"f"}]
            """
            return TaskTransition.parseFindings(from: block(j)).first?.id
        }
        try expectEqual(idFor(what: "a", why: "b"), idFor(what: "rewritten", why: "also rewritten"),
                        "same title + location → same id")
    })

    results.append(check("same title in two files stays two findings") {
        let j = """
        [{"title":"Vague name","severity":"low","locations":["A.swift:1"],"what":"w"},
         {"title":"Vague name","severity":"low","locations":["B.swift:1"],"what":"w"}]
        """
        let out = TaskTransition.parseFindings(from: block(j))
        try expectEqual(out.count, 2, "both kept")
        try expect(out[0].id != out[1].id, "distinct ids")
    })

    results.append(check("FindingLocation parses the shapes a review actually writes") {
        try expectEqual(FindingLocation("Sources/A.swift:41")?.line, 41, "file:line")
        try expectEqual(FindingLocation("`Sources/A.swift:41`")?.file, "Sources/A.swift", "backticks stripped")
        // The prose writes multi-line references as `File.swift:225,227`; one anchor is enough.
        try expectEqual(FindingLocation("Tests/X.swift:225,227")?.line, 225, "first of a list")
        try expect(FindingLocation("Sources/A.swift")?.line == nil, "bare path")
        try expectEqual(FindingLocation("Sources/A.swift")?.display, "Sources/A.swift", "display without line")
        try expectEqual(FindingLocation("Sources/A.swift:9")?.display, "Sources/A.swift:9", "display with line")
        try expect(FindingLocation("   ") == nil, "blank is not a location")
    })

    results.append(check("a title-less entry is skipped rather than rendered blank") {
        let out = TaskTransition.parseFindings(from: block("[{\"severity\":\"high\",\"what\":\"w\"}]"))
        try expectEqual(out.count, 0, "dropped")
    })

    results.append(check("parses a block embedded in a full review.md, with code and quotes inside") {
        // The real failure mode is not a synthetic fixture — it is a finding whose prose contains
        // backticks, escaped quotes and Swift code. Anchored on the actual b83e93c7 review text.
        let body = #"""
        [
          {
            "ruleId": "I1",
            "severity": "med",
            "category": "tests",
            "title": "The tie-break test cannot fail",
            "locations": ["Tests/ClaudepitTests/HomeActivityChecks.swift:225,227"],
            "what": "`\"identical timestamps fall back to the id tie-break\"` contains two vacuous assertions: `try expectEqual(feed.map(\\.id), feed.map(\\.id).sorted())` is already ascending.",
            "why": "The id tie-break is the only thing stopping the feed reshuffling between reloads.",
            "fix": "Two entries at `ts: 500` titled `\"z\"` then `\"a\"`; assert the feed returns `a` first."
          }
        ]
        """#
        let doc = """
        # Code Review — something

        ## Important

        ### I1 — The tie-break test cannot fail

        **What.** prose version here.

        CLAUDEPIT_FINDINGS_BEGIN
        \(body)
        CLAUDEPIT_FINDINGS_END
        CLAUDEPIT_ARTIFACT: /tmp/review.md
        """
        let out = TaskTransition.parseFindings(from: doc)
        try expectEqual(out.count, 1, "one finding out of a whole document")
        let f = out[0]
        try expectEqual(f.severity, "med", "severity")
        try expectEqual(f.locations?.first?.file, "Tests/ClaudepitTests/HomeActivityChecks.swift", "file")
        try expectEqual(f.locations?.first?.line, 225, "first line of the 225,227 pair")
        try expect(f.what?.contains("vacuous assertions") == true, "backticked/quoted prose survives")
        try expect(f.fix?.contains("returns `a` first") == true, "fix survives")
    })

    return results
}
