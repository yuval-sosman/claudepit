import Foundation
@testable import ClaudepitCore

func homeActivityChecks() -> [Bool] {
    var results: [Bool] = []

    /// `MemoryLogEntry` has no public memberwise init (Claude owns the file; we only decode it),
    /// so the fixtures go through JSON exactly as the real log does.
    func log(_ json: String) -> [MemoryLogEntry] {
        (try? JSONDecoder().decode([MemoryLogEntry].self, from: Data(json.utf8))) ?? []
    }
    func session(_ id: String, title: String, bullets: [String]?, at: TimeInterval) -> SessionSummary {
        SessionSummary(
            id: id, fileURL: URL(filePath: "/tmp/\(id).jsonl"), projectSlug: "-tmp",
            title: title, modifiedAt: Date(timeIntervalSince1970: at), turnCount: 1, isActive: false,
            bulletSummary: bullets.map {
                SessionBulletSummary(bullets: $0, updatedAt: Date(timeIntervalSince1970: at))
            })
    }

    func task(_ id: String, name: String, status: TaskStatus, at: TimeInterval,
              spec: String? = nil, plan: String? = nil) -> ProjectTask {
        ProjectTask(id: id, name: name, status: status, updatedAt: at,
                    links: TaskLinks(specPath: spec, planPath: plan))
    }

    results.append(check("memory writes and session summaries interleave by date, newest first") {
        let entries = log("""
        [
          {"type": "write", "ts": 100, "title": "Oldest write", "changes": [{"action": "update", "file": "a.md"}]},
          {"type": "write", "ts": 300, "title": "Newest write", "changes": [{"action": "update", "file": "b.md"}]}
        ]
        """)
        let sessions = [session("s1", title: "Middle session", bullets: ["did a thing"], at: 200)]
        let feed = buildActivityFeed(memoryLog: entries, sessions: sessions)
        try expectEqual(feed.map(\.title), ["Newest write", "Middle session", "Oldest write"], "order")
    })

    results.append(check("limit trims to the newest N") {
        let entries = log("""
        [{"type": "write", "ts": 100, "title": "a"}, {"type": "write", "ts": 200, "title": "b"},
         {"type": "write", "ts": 300, "title": "c"}]
        """)
        let feed = buildActivityFeed(memoryLog: entries, sessions: [], limit: 2)
        try expectEqual(feed.map(\.title), ["c", "b"], "newest two")
    })

    results.append(check("memory target is a BARE filename — MemoryGraph node ids have no path") {
        let entries = log("""
        [{"type": "write", "ts": 100, "title": "Pathful",
          "changes": [{"action": "update", "file": "/Users/me/.claude/projects/-p/memory/hooks.md"}]}]
        """)
        let feed = buildActivityFeed(memoryLog: entries, sessions: [])
        try expect(feed.first?.target == .memoryFile("hooks.md"), "normalized to the node id")
    })

    results.append(check("legacy single-file entries still resolve a target") {
        let entries = log(#"[{"type": "write", "ts": 100, "file": "tasks.md", "note": "legacy"}]"#)
        let feed = buildActivityFeed(memoryLog: entries, sessions: [])
        try expect(feed.first?.target == .memoryFile("tasks.md"), "legacy file becomes the target")
        try expectEqual(feed.first?.detail, "legacy", "note becomes the detail")
    })

    results.append(check("an entry that touched no file gets no target rather than a bogus one") {
        let entries = log(#"[{"type": "write", "ts": 100, "title": "Nothing written"}]"#)
        let feed = buildActivityFeed(memoryLog: entries, sessions: [])
        // `feed.first?.target == nil` would be true for an EMPTY feed too — the outer Optional
        // swallows it. Map through the row so the assertion is about the target, not the row.
        try expect(feed.first.map { $0.target == nil } == true, "nil target")
    })

    results.append(check("dream entries map to .memoryDream, writes to .memoryWrite") {
        let entries = log("""
        [{"type": "dream", "ts": 200, "title": "Consolidation", "changes": [{"action": "delete", "file": "old.md"}]},
         {"type": "write", "ts": 100, "title": "Write", "changes": [{"action": "create", "file": "new.md"}]}]
        """)
        let feed = buildActivityFeed(memoryLog: entries, sessions: [])
        try expectEqual(feed.count, 2, "two rows")
        try expect(feed.first?.kind == .memoryDream, "dream")
        try expect(feed.last?.kind == .memoryWrite, "write")
    })

    results.append(check("sessions without a bullet summary are excluded") {
        let sessions = [session("s1", title: "Summarized", bullets: ["b"], at: 100),
                        session("s2", title: "Bare", bullets: nil, at: 900)]
        let feed = buildActivityFeed(memoryLog: [], sessions: sessions)
        try expectEqual(feed.map(\.title), ["Summarized"], "only the summarized one")
        guard let row = feed.first else { throw CheckFailure(message: "no row") }
        try expect(row.target == .session("s1"), "session target")
        try expectEqual(row.detail, "b", "first bullet becomes the detail")
        try expectEqual(row.id, "sess:s1", "id namespace")
    })

    results.append(check("ids are namespaced so a memory ts can't collide with a session id") {
        let entries = log(#"[{"type": "write", "ts": 100, "file": "a.md"}]"#)
        let feed = buildActivityFeed(memoryLog: entries, sessions: [])
        try expect(feed.first?.id.hasPrefix("mem:") == true, "memory ids are mem:-prefixed")
    })

    results.append(check("neither source → an empty feed") {
        try expectEqual(buildActivityFeed(memoryLog: [], sessions: []).count, 0, "empty")
    })

    results.append(check("a session is dated by modifiedAt when it outruns its summary") {
        // A live session is still being typed into long after its last summary write. Dating it by
        // the summary alone would sort it below stale rows and label it "6 hr. ago".
        let stale = SessionSummary(
            id: "s1", fileURL: URL(filePath: "/tmp/s1.jsonl"), projectSlug: "-tmp",
            title: "Live", modifiedAt: Date(timeIntervalSince1970: 900), turnCount: 1, isActive: true,
            bulletSummary: SessionBulletSummary(bullets: ["b"], updatedAt: Date(timeIntervalSince1970: 100)))
        let entries = log(#"[{"type": "write", "ts": 500, "title": "Middle"}]"#)
        let feed = buildActivityFeed(memoryLog: entries, sessions: [stale])
        try expectEqual(feed.map(\.title), ["Live", "Middle"], "modifiedAt wins the sort")
        try expect(feed.first?.isActive == true, "isActive propagates from the session")
        try expect(feed.last?.isActive == false, "memory rows are never active")
    })

    results.append(check("task specs and plans interleave by file mtime with path targets") {
        let artifacts = [
            TaskArtifact(kind: .spec, taskID: "t1", taskName: "Redesign Home",
                         path: "/p/tasks/t1/spec.md", date: Date(timeIntervalSince1970: 300)),
            TaskArtifact(kind: .plan, taskID: "t1", taskName: "Redesign Home",
                         path: "/home/.claude/plans/redesign.md", date: Date(timeIntervalSince1970: 100)),
        ]
        let entries = log(#"[{"type": "write", "ts": 200, "title": "Memory"}]"#)
        let feed = buildActivityFeed(memoryLog: entries, sessions: [], artifacts: artifacts)
        // Memory ids embed the title, so compare namespaces rather than whole ids.
        try expectEqual(feed.map { String($0.id.prefix(5)) }, ["spec:", "mem:2", "plan:"], "merged by date")
        try expect(feed.first?.kind == .spec, "spec kind")
        try expect(feed.first?.target == .spec("/p/tasks/t1/spec.md"), "spec target is a path")
        try expectEqual(feed.first?.title, "Redesign Home", "titled by the task")
        try expect(feed.last?.target == .plan("/home/.claude/plans/redesign.md"), "plan target is a path")
    })

    results.append(check("only DONE tasks produce a row, dated by updatedAt") {
        let tasks = [task("t1", name: "Finished", status: .done, at: 400),
                     task("t2", name: "Still going", status: .running, at: 900),
                     task("t3", name: "Not started", status: .backlog, at: 900)]
        let feed = buildActivityFeed(memoryLog: [], sessions: [], tasks: tasks)
        try expectEqual(feed.map(\.title), ["Finished"], "only the done one")
        guard let row = feed.first else { throw CheckFailure(message: "no row") }
        try expect(row.kind == .taskDone, "taskDone kind")
        try expect(row.target == .task("t1"), "task id target")
        try expectEqual(row.date, Date(timeIntervalSince1970: 400), "dated by updatedAt")
        try expectEqual(row.id, "task:t1", "id namespace")
    })

    results.append(check("limit caps the merged feed across every source") {
        let entries = log("""
        [{"type": "write", "ts": 10, "title": "m1"}, {"type": "write", "ts": 20, "title": "m2"}]
        """)
        let sessions = [session("s1", title: "sess", bullets: ["b"], at: 30)]
        let artifacts = [TaskArtifact(kind: .spec, taskID: "t1", taskName: "spec-task",
                                      path: "/p/spec.md", date: Date(timeIntervalSince1970: 40))]
        let tasks = [task("t2", name: "done-task", status: .done, at: 50)]
        let all = buildActivityFeed(memoryLog: entries, sessions: sessions,
                                    artifacts: artifacts, tasks: tasks, limit: 40)
        try expectEqual(all.count, 5, "everything merges")
        let capped = buildActivityFeed(memoryLog: entries, sessions: sessions,
                                       artifacts: artifacts, tasks: tasks, limit: 3)
        try expectEqual(capped.map(\.title), ["done-task", "spec-task", "sess"], "newest three")
    })

    results.append(check("collectTaskArtifacts emits both links and drops files that are gone") {
        let tasks = [task("t1", name: "Both", status: .done, at: 0,
                          spec: "/p/spec.md", plan: "/p/plan.md"),
                     task("t2", name: "Dangling", status: .done, at: 0, spec: "/p/gone.md"),
                     task("t3", name: "Neither", status: .backlog, at: 0)]
        let out = collectTaskArtifacts(tasks: tasks) { path in
            path == "/p/gone.md" ? nil : Date(timeIntervalSince1970: 7)
        }
        try expectEqual(out.map(\.path), ["/p/spec.md", "/p/plan.md"], "dangling link dropped")
        try expect(out.first?.kind == .spec, "spec first")
        try expectEqual(out.first?.taskName, "Both", "carries the task name")
        try expectEqual(out.last?.date, Date(timeIntervalSince1970: 7), "stamped by the closure")
    })

    results.append(check("page-listed plans and specs appear; task-linked paths dedupe to the artifact row") {
        let artifacts = [TaskArtifact(kind: .plan, taskID: "t1", taskName: "Redesign Home",
                                      path: "/home/.claude/plans/redesign.md",
                                      date: Date(timeIntervalSince1970: 100))]
        let plans = [PageFile(path: "/home/.claude/plans/redesign.md", name: "redesign",
                              date: Date(timeIntervalSince1970: 100)),
                     PageFile(path: "/home/.claude/plans/cheerful-yao.md", name: "cheerful-yao",
                              date: Date(timeIntervalSince1970: 300))]
        let specs = [PageFile(path: "/p/tasks/orphan/spec.md", name: "orphan",
                              date: Date(timeIntervalSince1970: 200))]
        let feed = buildActivityFeed(memoryLog: [], sessions: [], artifacts: artifacts,
                                     planFiles: plans, specFiles: specs)
        try expectEqual(feed.map(\.title), ["cheerful-yao", "orphan", "Redesign Home"], "one row per file")
        try expect(feed.first?.kind == .plan, "standalone plan keeps the plan kind")
        try expect(feed.first?.target == .plan("/home/.claude/plans/cheerful-yao.md"), "plan target")
        try expect(feed[1].target == .spec("/p/tasks/orphan/spec.md"), "spec target")
        try expectEqual(feed.last?.id, "plan:t1", "linked path kept the artifact row, not the file row")
    })

    results.append(check("memory files appear unless a log entry already covers that write") {
        let entries = log("""
        [{"type": "write", "ts": 1000, "title": "Logged hooks write",
          "changes": [{"action": "update", "file": "hooks.md"}]}]
        """)
        let files = [
            // mtime within 10 min of the logged write → the richer log row wins.
            PageFile(path: "/m/hooks.md", name: "Hook & Settings", date: Date(timeIntervalSince1970: 1030)),
            // written long after its last log entry → surfaces on its own.
            PageFile(path: "/m/home-dashboard.md", name: "Home Dashboard", date: Date(timeIntervalSince1970: 90_000)),
        ]
        let feed = buildActivityFeed(memoryLog: entries, sessions: [], memoryFiles: files)
        try expectEqual(feed.map(\.title), ["Home Dashboard", "Logged hooks write"], "suppressed the covered file")
        try expect(feed.first?.kind == .memoryWrite, "memoryWrite kind")
        try expect(feed.first?.target == .memoryFile("home-dashboard.md"), "target is the bare node id")
        try expectEqual(feed.first?.detail, "Memory updated", "file rows carry the generic detail")
        try expectEqual(feed.first?.id, "memfile:home-dashboard.md", "id namespace")
    })

    return results
}
