import Foundation
@testable import ClaudepitCore

func taskDraftChecks() -> [Bool] {
    let fullJSON = """
    {"name":"Add dark mode","topic":"UI","description":"Support a dark theme.","requirements":["Toggle in settings","Persists across launches"],"priority":"high","tags":["ui","theme"],"dependsOn":["real1"]}
    """
    return [
        check("buildPrompt_includesIdeaTopicsCandidates") {
            let prompt = TaskDraftRunner.buildPrompt(
                idea: "Let users export sessions as PDF",
                topics: ["Export", "Sessions"],
                candidates: [
                    .init(id: "a1b2c3d4", name: "Add print layout", topic: "Export"),
                    .init(id: "e5f6a7b8", name: "Set up CI", topic: nil),
                ])
            try expect(prompt.contains("Let users export sessions as PDF"), "missing idea")
            try expect(prompt.contains("- Export"), "missing topic line")
            try expect(prompt.contains("- Sessions"), "missing topic line")
            try expect(prompt.contains("- a1b2c3d4 — Add print layout (Export)"), "missing candidate with topic")
            try expect(prompt.contains("- e5f6a7b8 — Set up CI\n"), "missing topicless candidate")
            try expect(!prompt.contains("Set up CI ("), "topicless candidate should have no parens")
            try expect(prompt.contains("Return ONLY a valid JSON object"), "missing JSON-only contract")
            try expect(prompt.contains("\"priority\":\"low|normal|high|urgent\""), "missing shape line")
        },
        check("buildPrompt_emptyTopicsAndCandidates") {
            let prompt = TaskDraftRunner.buildPrompt(idea: "Idea", topics: [], candidates: [])
            try expect(prompt.contains("(none yet"), "missing empty-topics fallback")
            try expect(!prompt.contains("Existing tasks"), "candidates section should be omitted")
            try expect(prompt.contains("Return ONLY a valid JSON object"), "missing JSON-only contract")
        },
        check("decode_happyPath") {
            let v = try TaskDraftRunner.decode(fullJSON, validTaskIDs: ["real1"])
            try expect(v.name == "Add dark mode", "name")
            try expect(v.topic == "UI", "topic")
            try expect(v.description == "Support a dark theme.", "description")
            try expect(v.requirements == ["Toggle in settings", "Persists across launches"], "requirements")
            try expect(v.priority == .high, "priority")
            try expect(v.tags == ["ui", "theme"], "tags")
            try expect(v.dependsOn == ["real1"], "dependsOn")
        },
        check("decode_fencedJSON") {
            let fenced = "```json\n\(fullJSON)\n```"
            let v = try TaskDraftRunner.decode(fenced, validTaskIDs: ["real1"])
            try expect(v.name == "Add dark mode", "name through fences")
            try expect(v.priority == .high, "priority through fences")
        },
        check("decode_missingKeysDefault") {
            let v = try TaskDraftRunner.decode(#"{"name":"X"}"#, validTaskIDs: [])
            try expect(v.name == "X", "name")
            try expect(v.topic == "", "topic defaults empty")
            try expect(v.description == "", "description defaults empty")
            try expect(v.requirements == [], "requirements default empty")
            try expect(v.priority == .normal, "priority defaults normal")
            try expect(v.tags == [], "tags default empty")
            try expect(v.dependsOn == [], "dependsOn defaults empty")
        },
        check("decode_priorityTolerance") {
            let upper = try TaskDraftRunner.decode(#"{"name":"X","priority":"HIGH"}"#, validTaskIDs: [])
            try expect(upper.priority == .high, "uppercase priority should lowercase-match")
            let unknown = try TaskDraftRunner.decode(#"{"name":"X","priority":"critical"}"#, validTaskIDs: [])
            try expect(unknown.priority == .normal, "unknown priority should fall back to normal")
        },
        check("decode_dropsUnknownDependsOn") {
            let v = try TaskDraftRunner.decode(
                #"{"name":"X","dependsOn":["real1","fake9"]}"#, validTaskIDs: ["real1"])
            try expect(v.dependsOn == ["real1"], "hallucinated id should be dropped")
        },
        check("decode_trimsAndDropsEmptyItems") {
            let v = try TaskDraftRunner.decode(
                #"{"name":" X ","requirements":["","  a  "],"tags":[" b ",""]}"#, validTaskIDs: [])
            try expect(v.name == "X", "name trimmed")
            try expect(v.requirements == ["a"], "requirements trimmed and empties dropped")
            try expect(v.tags == ["b"], "tags trimmed and empties dropped")
        },
        check("decode_preambleSalvage") {
            let v = try TaskDraftRunner.decode("Here is the draft: \(fullJSON)", validTaskIDs: ["real1"])
            try expect(v.name == "Add dark mode", "salvage via first-{ last-}")
        },
        check("decode_garbageThrows") {
            do {
                _ = try TaskDraftRunner.decode("I could not produce a draft.", validTaskIDs: [])
                try expect(false, "should have thrown")
            } catch TaskDraftError.invalidJSON(let raw) {
                try expect(raw.contains("could not produce"), "error should carry raw text")
            }
        },
        check("decode_wrongShapeThrows") {
            do {
                _ = try TaskDraftRunner.decode("{}", validTaskIDs: [])
                try expect(false, "empty object should have thrown")
            } catch TaskDraftError.invalidJSON {}
            do {
                _ = try TaskDraftRunner.decode(#"{"error":"cannot draft"}"#, validTaskIDs: [])
                try expect(false, "object without name/description should have thrown")
            } catch TaskDraftError.invalidJSON {}
        },
        check("decode_singleElementArraySalvages") {
            // The first-{/last-} salvage unwraps a one-object array — tolerance, not an error.
            let v = try TaskDraftRunner.decode(#"[{"name":"X"}]"#, validTaskIDs: [])
            try expect(v.name == "X", "array-wrapped object should salvage")
        },
    ]
}
