import Foundation
@testable import ClaudepitCore

func taskModelChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("v1→v2 migration remaps removed cases") {
        func v1(_ phase: String, autoAdvance: Bool = true) -> Data {
            let obj: [String: Any] = [
                "version": 1, "id": "abc123", "name": "T", "description": "",
                "phase": phase, "status": "idle", "requirements": ["r1"],
                "autoAdvance": ["writeSpec": autoAdvance], "createdAt": 1.0, "updatedAt": 2.0,
                "links": ["sessionIDs": ["s1"], "herdrPaneID": "w1:p1"],
            ]
            return try! JSONSerialization.data(withJSONObject: obj)
        }
        let created = TaskStore.remapV1(v1("created"))!
        try expect(created.phase == nil && created.status == .backlog, "created→backlog")
        try expectEqual(created.requirements, ["r1"], "requirements kept")
        try expectEqual(created.links.sessionIDs, ["s1"], "sessionIDs kept")

        let done = TaskStore.remapV1(v1("done"))!
        try expect(done.phase == nil && done.status == .done, "done→done")

        let review = TaskStore.remapV1(v1("codeReview"))!
        try expect(review.phase == .codeReview && review.status == .awaitingReview, "codeReview→awaitingReview")
        // old autoAdvance ignored: v2 has no such field; ensure defaults present
        try expectEqual(review.plannedPhases, ProjectTask.defaultPhases, "default plannedPhases")
        try expectEqual(review.priority, .normal, "default priority")
    })

    results.append(check("v2 round-trip") {
        var t = ProjectTask.empty
        t.name = "hi"; t.phase = .implement; t.status = .running; t.priority = .high
        t.tags = ["a", "b"]; t.dependsOn = ["x"]; t.plannedPhases = [.writeSpec, .implement]
        t.worktree = TaskWorktree(branch: "task/1", path: "/wt", paneID: "p1")
        t.links.reviewFindings = [ReviewFinding(id: "1", title: "f", detail: "d", severity: "high")]
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(ProjectTask.self, from: data)
        try expectEqual(back, t, "round-trip equal")
    })

    results.append(check("nextPlannedPhase across a subset") {
        let planned: [TaskPhase] = [.writeSpec, .implement, .codeReview]
        try expect(TaskTransition.nextPlannedPhase(after: nil, in: planned) == .writeSpec, "nil→first")
        try expect(TaskTransition.nextPlannedPhase(after: .writeSpec, in: planned) == .implement, "spec→impl")
        try expect(TaskTransition.nextPlannedPhase(after: .codeReview, in: planned) == nil, "last→nil")
        try expect(TaskTransition.nextPlannedPhase(after: .brainstorm, in: planned) == nil, "not-in-planned→nil")
    })

    results.append(check("canRun: done/running/missing/cycle") {
        let a = ProjectTask(id: "a", status: .done)
        let running = ProjectTask(id: "a", status: .running)
        let b = ProjectTask(id: "b", dependsOn: ["a"])
        try expect(TaskTransition.canRun(b, allTasks: [a, b]), "dep done → runnable")
        try expect(!TaskTransition.canRun(b, allTasks: [running, b]), "dep running → blocked")
        try expect(!TaskTransition.canRun(b, allTasks: [b]), "missing dep → blocked")
        // cycle: c↔d both depend on each other, neither done → both false
        let c = ProjectTask(id: "c", dependsOn: ["d"])
        let d = ProjectTask(id: "d", dependsOn: ["c"])
        try expect(!TaskTransition.canRun(c, allTasks: [c, d]), "cycle c false")
        try expect(!TaskTransition.canRun(d, allTasks: [c, d]), "cycle d false")
    })

    results.append(check("insertPhase at canonical position") {
        try expectEqual(TaskTransition.insertPhase(.codeReview, into: [.writeSpec, .implement]),
                        [.writeSpec, .implement, .codeReview], "review after implement")
        try expectEqual(TaskTransition.insertPhase(.createPlan, into: [.writeSpec, .implement]),
                        [.writeSpec, .createPlan, .implement], "plan between spec and implement")
        try expectEqual(TaskTransition.insertPhase(.writeSpec, into: [.writeSpec, .implement]),
                        [.writeSpec, .implement], "idempotent")
    })

    results.append(check("canAddDependency rejects cycles and self") {
        let a = ProjectTask(id: "a")
        var b = ProjectTask(id: "b")
        try expect(TaskTransition.canAddDependency(from: a, to: b, allTasks: [a, b]), "A→B ok")
        try expect(!TaskTransition.canAddDependency(from: a, to: a, allTasks: [a]), "self rejected")
        b.dependsOn = ["a"]   // B depends on A
        try expect(!TaskTransition.canAddDependency(from: a, to: b, allTasks: [a, b]),
                   "A→B when B→A exists → cycle")
    })

    results.append(check("parseFindings: 2-finding block, stable ids, no-block") {
        let out = """
        noise
        CLAUDEPIT_FINDINGS_BEGIN
        high | Null deref in foo | foo() unwraps nil
        low  |  | empty title skipped
        med | Slow loop | O(n^2) scan
        CLAUDEPIT_FINDINGS_END
        trailer
        """
        let f1 = TaskTransition.parseFindings(from: out)
        try expectEqual(f1.count, 2, "two findings (empty-title skipped)")
        try expectEqual(f1[0].severity, "high", "severity")
        try expectEqual(f1[0].title, "Null deref in foo", "title")
        let f2 = TaskTransition.parseFindings(from: out)
        try expectEqual(f1[0].id, f2[0].id, "ids stable across parses")
        try expect(TaskTransition.parseFindings(from: "nothing").isEmpty, "no block → []")
    })

    results.append(check("parseArtifact last-wins + trim") {
        let out = "CLAUDEPIT_ARTIFACT: /a/old.md\nCLAUDEPIT_ARTIFACT:  /a/spec.md  "
        try expectEqual(TaskTransition.parseArtifact(from: out), "/a/spec.md", "last wins, trimmed")
        try expect(TaskTransition.parseArtifact(from: "none") == nil, "none")
    })

    results.append(check("parseBrainstormSuggestions: 3 kinds, stable ids, skips") {
        let yaml = """
        suggestions:
          - kind: requirement
            value: "Support offline mode"
            rationale: "users work on planes"
          - kind: description
            value: 'A sharper description'
            rationale: "clearer scope"
          - kind: tag   # a classification hint
            value: backend
          - kind: requirement
            value: ""
            rationale: "empty value should skip"
          - kind: bogus
            value: "unknown kind should skip"
        """
        let s = TaskTransition.parseBrainstormSuggestions(from: yaml)
        try expectEqual(s.count, 3, "three valid suggestions (empty + unknown skipped)")
        try expectEqual(s[0].kind, .requirement, "kind req")
        try expectEqual(s[0].value, "Support offline mode", "double-quote stripped")
        try expectEqual(s[0].rationale, "users work on planes", "rationale kept")
        try expectEqual(s[1].kind, .description, "kind desc")
        try expectEqual(s[1].value, "A sharper description", "single-quote stripped")
        try expectEqual(s[2].kind, .tag, "kind tag")
        try expectEqual(s[2].value, "backend", "bare scalar + inline comment stripped")
        try expectEqual(s[2].rationale, "", "missing rationale tolerated")

        let s2 = TaskTransition.parseBrainstormSuggestions(from: yaml)
        try expectEqual(s[0].id, s2[0].id, "ids stable across parses")
        try expect(s[0].id != s[1].id, "distinct ids per suggestion")

        try expect(TaskTransition.parseBrainstormSuggestions(from: "no suggestions here").isEmpty, "no list → []")
        try expect(TaskTransition.parseBrainstormSuggestions(from: "suggestions:\n").isEmpty, "empty list → []")
    })

    results.append(check("v2 JSON missing topic/suggestions decodes with nil (not remapV1)") {
        // Old v2 tasks lack the new Optional keys — synthesized decode must succeed with nil.
        let json = """
        {"version":2,"id":"t1","name":"N","description":"D","status":"backlog",
         "priority":"normal","tags":[],"dependsOn":[],
         "plannedPhases":["writeSpec"],"requirements":["r1"],
         "createdAt":1.0,"updatedAt":2.0,
         "links":{"brainstormSuggestions":[],"sessionIDs":[],"reviewFindings":[]}}
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(ProjectTask.self, from: json)
        try expect(t.topic == nil, "topic nil")
        try expect(t.suggestions == nil, "suggestions nil")
        try expect(!t.hasSuggestions, "no suggestions")
        try expectEqual(t.name, "N", "name kept")
        try expectEqual(t.mainVersion.topic, "", "mainVersion coalesces nil topic to \"\"")
    })

    results.append(check("v2 round-trip with topic + suggestions") {
        var t = ProjectTask.empty
        t.name = "hi"; t.topic = "backend"; t.priority = .high
        t.suggestions = [TaskVersion(id: "v1", label: "Draft", name: "hi 2", topic: "frontend",
                                     description: "alt", requirements: ["r"], priority: .urgent,
                                     tags: ["x"], dependsOn: ["d1"])]
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(ProjectTask.self, from: data)
        try expectEqual(back, t, "round-trip equal with versions")
    })

    results.append(check("applyField copies one field onto main") {
        var t = ProjectTask.empty
        t.name = "main"; t.priority = .low; t.tags = ["a"]
        let v = TaskVersion(name: "suggested", priority: .urgent, tags: ["b", "c"])
        t.applyField(.name, from: v)
        try expectEqual(t.name, "suggested", "name copied")
        try expectEqual(t.priority, .low, "priority untouched")
        t.applyField(.tags, from: v)
        try expectEqual(t.tags, ["b", "c"], "tags copied")
    })

    results.append(check("promote swaps main and retains old main") {
        var t = ProjectTask.empty
        t.name = "old main"; t.priority = .low; t.topic = "t1"
        let v = TaskVersion(id: "v1", name: "new main", topic: "t2", priority: .high)
        t.suggestions = [v, TaskVersion(id: "v2", name: "other")]
        t.promote(v, now: 99.0)
        try expectEqual(t.name, "new main", "main = promoted")
        try expectEqual(t.priority, .high, "priority promoted")
        try expectEqual(t.topic, "t2", "topic promoted")
        let s = t.suggestions ?? []
        try expect(!s.contains { $0.id == "v1" }, "promoted removed from suggestions")
        try expect(s.contains { $0.id == "v2" }, "other suggestion kept")
        try expect(s.contains { $0.name == "old main" && $0.createdAt == 99.0 }, "old main retained")
    })

    results.append(check("changedFields reports differing fields in canonical order") {
        let base = TaskVersion(name: "a", topic: "t", description: "d", requirements: ["r"],
                               priority: .low, tags: ["x"], dependsOn: ["d1"])
        try expectEqual(base.changedFields(vs: base), [], "identical → none")
        var v = base
        v.priority = .high; v.name = "b"; v.tags = ["y"]
        try expectEqual(v.changedFields(vs: base), [.name, .priority, .tags], "canonical order name<priority<tags")
    })

    results.append(check("brainstormProposal folds pending suggestions onto main; skips decided") {
        var t = ProjectTask.empty
        t.description = "old"; t.requirements = ["r1"]; t.tags = ["a"]
        t.links.brainstormSuggestions = [
            BrainstormSuggestion(id: "1", kind: .description, value: "new desc", rationale: ""),   // pending
            BrainstormSuggestion(id: "2", kind: .requirement, value: "r2", rationale: ""),          // pending
            BrainstormSuggestion(id: "3", kind: .tag, value: "b", rationale: ""),                   // pending
            BrainstormSuggestion(id: "4", kind: .requirement, value: "skip", rationale: "", accepted: false), // decided → ignored
            BrainstormSuggestion(id: "5", kind: .requirement, value: "r1", rationale: ""),          // dup → not re-added
        ]
        let p = t.brainstormProposal
        try expectEqual(p.description, "new desc", "description replaced")
        try expectEqual(p.requirements, ["r1", "r2"], "requirement appended, dup+decided skipped")
        try expectEqual(p.tags, ["a", "b"], "tag appended")
        try expectEqual(t.pendingBrainstormFields, Set([.description, .requirements, .tags]), "pending fields")
    })

    results.append(check("agentName is phase-scoped so each phase gets a distinct herdr agent/session") {
        try expectEqual(TaskRunner.agentName(id: "abc", phase: .brainstorm), "task-abc-brainstorm", "brainstorm slug")
        try expectEqual(TaskRunner.agentName(id: "abc", phase: .writeSpec), "task-abc-spec", "writeSpec → spec slug")
        try expectEqual(TaskRunner.agentName(id: "abc", phase: .codeReview), "task-abc-review", "codeReview → review slug")
        try expectEqual(TaskRunner.agentName(id: "abc", phase: nil), "task-abc-start", "nil phase fallback")
        try expect(TaskRunner.agentName(id: "abc", phase: .writeSpec) != TaskRunner.agentName(id: "abc", phase: .createPlan),
                   "adjacent phases must not share an agent name")
    })

    return results
}
