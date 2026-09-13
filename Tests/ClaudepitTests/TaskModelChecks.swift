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

    results.append(check("allowsMainEdit: backlog + brainstorm only") {
        func t(_ phase: TaskPhase?, _ status: TaskStatus) -> ProjectTask {
            ProjectTask(id: "a", phase: phase, status: status)
        }
        try expect(t(nil, .backlog).allowsMainEdit, "backlog column → editable")
        try expect(t(.brainstorm, .awaitingReview).allowsMainEdit, "brainstorm landed → editable")
        try expect(t(.brainstorm, .failed).allowsMainEdit, "brainstorm failed → editable")
        // A live agent already holds the old request in its prompt.
        try expect(!t(.brainstorm, .running).allowsMainEdit, "brainstorm running → locked")
        try expect(!t(.brainstorm, .blocked).allowsMainEdit, "brainstorm blocked → locked")
        // Later columns argue from artifacts built on the request.
        try expect(!t(.writeSpec, .awaitingReview).allowsMainEdit, "spec → locked")
        try expect(!t(.implement, .awaitingReview).allowsMainEdit, "implement → locked")
        try expect(!t(nil, .done).allowsMainEdit, "done → locked")
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

    results.append(check("phaseNeedsReview: brainstorm goes quiet once every suggestion is resolved") {
        func sugg(_ id: String, accepted: Bool?) -> BrainstormSuggestion {
            BrainstormSuggestion(id: id, kind: .requirement, value: "r\(id)", rationale: "", accepted: accepted)
        }
        var t = ProjectTask.empty
        t.phase = .brainstorm; t.status = .awaitingReview

        try expect(t.phaseNeedsReview, "no suggestions parsed yet → still needs a look")

        t.links.brainstormSuggestions = [sugg("a", accepted: true), sugg("b", accepted: nil)]
        try expect(t.phaseNeedsReview, "one pending suggestion → needs review")

        t.links.brainstormSuggestions = [sugg("a", accepted: true), sugg("b", accepted: false)]
        try expect(!t.phaseNeedsReview, "all accepted/dismissed → phase done, not waiting")
    })

    results.append(check("phaseNeedsReview: an artifact phase is done once its deliverable is linked") {
        var t = ProjectTask.empty
        t.status = .awaitingReview

        // Parked on a phase with no deliverable recorded → it still wants you.
        for phase in [TaskPhase.writeSpec, .createPlan, .codeReview] {
            t.phase = phase
            try expect(t.phaseNeedsReview, "\(phase.rawValue) without its artifact needs you")
        }

        // Deliverable produced → phase done. NOT "waiting until the user opens the file".
        t.links.specPath = "/t/spec.md"; t.links.planPath = "/t/plan.md"; t.links.reviewPath = "/t/review.md"
        for phase in [TaskPhase.writeSpec, .createPlan, .codeReview] {
            t.phase = phase
            try expect(!t.phaseNeedsReview, "\(phase.rawValue) with its artifact is done")
        }
        // Each phase reads only its OWN link.
        t.links.specPath = nil; t.phase = .createPlan
        try expect(!t.phaseNeedsReview, "createPlan ignores a missing specPath")

        t = ProjectTask.empty; t.status = .awaitingReview
        t.phase = .implement
        try expect(!t.phaseNeedsReview, "implement has no deliverable — landing here means it finished")
        t.phase = nil
        try expect(!t.phaseNeedsReview, "no phase → nothing outstanding")
    })

    results.append(check("expectedArtifact: only the phases with a fixed filename have one") {
        let slug = "p", id = "abc123"
        func path(_ phase: TaskPhase?) -> String? {
            TaskTransition.expectedArtifact(phase: phase, projectSlug: slug, taskID: id)?.lastPathComponent
        }
        try expectEqual(path(.brainstorm), "brainstorm.yaml", "brainstorm deliverable")
        try expectEqual(path(.writeSpec), "spec.md", "spec deliverable")
        try expectEqual(path(.codeReview), "review.md", "review deliverable")
        // createPlan picks its own filename under plansDir; implement writes no file. Both are
        // discoverable only from the agent's CLAUDEPIT_ARTIFACT marker.
        try expect(path(.createPlan) == nil, "createPlan has no fixed deliverable")
        try expect(path(.implement) == nil, "implement has no deliverable")
        try expect(path(nil) == nil, "no phase → no deliverable")
    })

    results.append(check("healArtifactLinks adopts on-disk deliverables the record missed") {
        let projectsRoot = try tempDir()
        let slug = "claudepit-check"
        let dir = projectsRoot.appending(path: slug).appending(path: "tasks").appending(path: "t1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var t = ProjectTask(id: "t1", phase: .writeSpec, status: .awaitingReview)
        try expect(TaskTransition.healArtifactLinks(t, projectSlug: slug, projectsRoot: projectsRoot) == nil,
                   "nothing on disk → no change")

        try Data("# spec".utf8).write(to: dir.appending(path: "spec.md"))
        let healed = TaskTransition.healArtifactLinks(t, projectSlug: slug, projectsRoot: projectsRoot)
        try expectEqual(healed?.links.specPath, dir.appending(path: "spec.md").path, "specPath adopted")
        try expect(healed?.links.reviewPath == nil, "review.md absent → still nil")

        // Heals earlier phases too, not just the current one.
        try Data("# review".utf8).write(to: dir.appending(path: "review.md"))
        t.phase = .implement
        try expectEqual(TaskTransition.healArtifactLinks(t, projectSlug: slug, projectsRoot: projectsRoot)?.links.reviewPath,
                        dir.appending(path: "review.md").path, "past phase healed while on implement")

        // Never overwrites a path the runner already recorded.
        t.links.specPath = "/somewhere/else/spec.md"
        let again = TaskTransition.healArtifactLinks(t, projectSlug: slug, projectsRoot: projectsRoot)
        try expectEqual(again?.links.specPath, "/somewhere/else/spec.md", "existing link preserved")
    })

    // MARK: - Follow-up tasks and finding merges

    results.append(check("followUp round-trips, and a task.json without it decodes to nil") {
        var t = ProjectTask(id: "f1", name: "Fix", plannedPhases: [.implement, .codeReview])
        t.followUp = TaskFollowUp(parentTaskID: "p1", findingIDs: ["a", "b"],
                                  resumeSessionID: "sess", parentReviewPath: "/tmp/r.md",
                                  parentSpecPath: "/tmp/s.md", parentPlanPath: "/tmp/p.md")
        let back = try JSONDecoder().decode(ProjectTask.self, from: JSONEncoder().encode(t))
        try expectEqual(back.followUp, t.followUp, "round-trip")

        // Every task.json written before this feature has no followUp key at all.
        let legacy = #"{"version":2,"id":"old","name":"Old","description":"","status":"backlog","priority":"normal","tags":[],"dependsOn":[],"plannedPhases":["writeSpec"],"requirements":[],"createdAt":0,"updatedAt":0,"links":{"brainstormSuggestions":[],"sessionIDs":[],"reviewFindings":[]}}"#
        let old = try JSONDecoder().decode(ProjectTask.self, from: Data(legacy.utf8))
        try expect(old.followUp == nil, "missing key decodes to nil")
        try expect(!old.isFixTask, "and is not a fix task")
    })

    results.append(check("isFixTask needs the link AND no plan phase") {
        var t = ProjectTask(id: "f1", plannedPhases: [.implement, .codeReview])
        try expect(!t.isFixTask, "no link → not a fix task")
        t.followUp = TaskFollowUp(parentTaskID: "p1", findingIDs: [])
        try expect(t.isFixTask, "link + no plan phase")
        t.plannedPhases = ProjectTask.defaultPhases
        try expect(!t.isFixTask, "a follow-up back on the full pipeline has a plan to follow")
    })

    results.append(check("mergeFindings keeps the links a re-review would have thrown away") {
        let existing = [
            ReviewFinding(id: "a", title: "A", detail: "d", severity: "med", spawnedTaskID: "task-1"),
            ReviewFinding(id: "gone", title: "Gone", detail: "d", severity: "low", spawnedTaskID: "task-2"),
        ]
        let parsed = [
            ReviewFinding(id: "a", title: "A rephrased", detail: "d", severity: "high"),
            ReviewFinding(id: "new", title: "New", detail: "d", severity: "low"),
        ]
        let merged = TaskTransition.mergeFindings(existing: existing, parsed: parsed)
        try expectEqual(merged.map(\.id), ["a", "new"], "the new parse decides membership and order")
        try expectEqual(merged[0].spawnedTaskID, "task-1", "an existing link survives the re-parse")
        try expectEqual(merged[0].title, "A rephrased", "but the text comes from the new parse")
        try expectEqual(merged[0].severity, "high", "including severity")
        try expect(merged[1].spawnedTaskID == nil, "a genuinely new finding has no link")
    })

    results.append(check("worktreeBusy names the co-tenant, and only while it is live") {
        var parent = ProjectTask(id: "p1")
        parent.worktree = TaskWorktree(branch: "b", path: "/tmp/wt")
        var child = ProjectTask(id: "c1")
        child.worktree = TaskWorktree(branch: "b", path: "/tmp/wt/")   // same dir, other spelling
        var other = ProjectTask(id: "o1")
        other.worktree = TaskWorktree(branch: "z", path: "/tmp/elsewhere")
        other.status = .running

        parent.status = .backlog
        try expect(TaskTransition.worktreeBusy(child, allTasks: [parent, child, other]) == nil,
                   "an idle co-tenant does not block")
        parent.status = .running
        try expectEqual(TaskTransition.worktreeBusy(child, allTasks: [parent, child, other]), "p1",
                        "a running co-tenant does")
        parent.status = .blocked
        try expectEqual(TaskTransition.worktreeBusy(child, allTasks: [parent, child, other]), "p1",
                        "so does a blocked one — its agent still holds the checkout")
        child.status = .running
        try expect(TaskTransition.worktreeBusy(other, allTasks: [parent, child, other]) == nil,
                   "a different worktree is never busy")
        try expect(TaskTransition.worktreeBusy(ProjectTask(id: "n1"), allTasks: [parent, child]) == nil,
                   "a task with no worktree is never busy")
    })

    results.append(check("a task.json with no auto-run keys decodes cleanly") {
        // remapV1 preserves none of tags/plannedPhases/suggestions, so their survival proves the
        // PLAIN decode branch was taken rather than the lossy v1 fallback.
        let obj: [String: Any] = [
            "version": 2, "id": "abc123", "name": "T", "description": "",
            "status": "awaitingReview", "phase": "writeSpec", "priority": "high",
            "tags": ["ui"], "dependsOn": [], "plannedPhases": ["writeSpec", "implement"],
            "requirements": ["r1"], "createdAt": 1.0, "updatedAt": 2.0,
            "links": ["brainstormSuggestions": [], "sessionIDs": [], "reviewFindings": []],
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        guard let t = TaskStore.decode(data) else { try expect(false, "decode failed"); return }
        try expectEqual(t.tags, ["ui"], "plain decode, not remapV1")
        try expectEqual(t.plannedPhases, [.writeSpec, .implement], "pipeline kept")
        try expect(t.autoRun == nil, "a missing flag is nil, not a decode failure")
        try expect(t.autoRunRetried == nil, "missing retry budget is nil")
        try expect(t.autoRunHaltReason == nil, "missing halt reason is nil")
        try expect(!t.isAutoRunning, "nil reads as off")
    })

    results.append(check("auto-run fields round-trip") {
        let t = ProjectTask(id: "rt1", name: "T", phase: .implement, status: .blocked,
                            autoRun: true, autoRunRetried: [.writeSpec, .implement],
                            autoRunHaltReason: "Implement failed twice")
        let data = try! JSONEncoder().encode(t)
        guard let back = TaskStore.decode(data) else { try expect(false, "decode failed"); return }
        try expect(back.isAutoRunning, "flag survives")
        try expectEqual(back.autoRunRetried, [.writeSpec, .implement], "budget survives")
        try expectEqual(back.autoRunHaltReason, "Implement failed twice", "reason survives")
    })

    results.append(check("a retired phase is stripped from autoRunRetried too") {
        let obj: [String: Any] = [
            "version": 2, "id": "abc123", "name": "T", "description": "",
            "status": "failed", "phase": "verify", "priority": "normal",
            "tags": [], "dependsOn": [], "plannedPhases": ["implement", "verify"],
            "requirements": [], "createdAt": 1.0, "updatedAt": 2.0,
            "autoRunRetried": ["verify", "implement"],
            "links": ["brainstormSuggestions": [], "sessionIDs": [], "reviewFindings": []],
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        guard let t = TaskStore.decode(data) else { try expect(false, "decode failed"); return }
        try expectEqual(t.autoRunRetried, [.implement], "verify stripped, implement kept")
        try expect(t.phase == .codeReview, "the task itself still falls forward to codeReview")
    })

    results.append(check("healArtifactLinks adopts findings from review.md, and upgrades legacy ones") {
        let projectsRoot = try tempDir()
        let slug = "claudepit-check"
        let dir = projectsRoot.appending(path: slug).appending(path: "tasks").appending(path: "t9")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let reviewURL = dir.appending(path: "review.md")

        let doc = """
        # Code Review

        CLAUDEPIT_FINDINGS_BEGIN
        [{"ruleId":"C1","severity":"high","category":"correctness","title":"Null deref",
          "locations":["Sources/Parser.swift:41"],"what":"unwraps nil","why":"crashes","fix":"guard"}]
        CLAUDEPIT_FINDINGS_END
        """
        try Data(doc.utf8).write(to: reviewURL)

        // 1. A task that recorded no findings at all picks them up on the next load.
        var t = ProjectTask(id: "t9", phase: .codeReview, status: .awaitingReview)
        let healed = TaskTransition.healArtifactLinks(t, projectSlug: slug, projectsRoot: projectsRoot)
        try expectEqual(healed?.links.reviewFindings.count, 1, "finding adopted")
        try expectEqual(healed?.links.reviewFindings.first?.fix, "guard", "structured, not a blob")

        // 2. A task holding the old one-line format is upgraded in place — no re-review needed.
        t.links.reviewPath = reviewURL.path
        t.links.reviewFindings = [ReviewFinding(id: "old", title: "Null deref", detail: "unwraps nil",
                                                severity: "high", spawnedTaskID: "task-7")]
        let upgraded = TaskTransition.healArtifactLinks(t, projectSlug: slug, projectsRoot: projectsRoot)
        try expectEqual(upgraded?.links.reviewFindings.count, 1, "still one finding")
        try expect(upgraded?.links.reviewFindings.first?.isStructured == true, "now structured")

        // 3. Already structured → left alone, so this can run on every loadTasks without churn.
        var done = t
        done.links.reviewFindings = upgraded?.links.reviewFindings ?? []
        try expect(TaskTransition.healArtifactLinks(done, projectSlug: slug, projectsRoot: projectsRoot) == nil,
                   "idempotent once upgraded")
    })

    return results
}
