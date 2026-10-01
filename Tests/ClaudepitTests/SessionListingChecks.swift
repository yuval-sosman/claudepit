import Foundation
@testable import ClaudepitCore

/// The Sessions page's left list: folder scoping, titles, stubs, group keys and layout, search,
/// date sections, live status, keyboard ranges, group-name rules and the trash.
func sessionListingChecks() -> [Bool] {
    var results: [Bool] = []

    func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    func user(_ text: String, cwd: String = "/p", meta: Bool = false) -> String {
        let obj: [String: Any] = ["type": "user", "cwd": cwd, "isMeta": meta,
                                  "message": ["role": "user", "content": text]]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }
    func session(_ id: String, _ modified: Date, groupKey: String = "k", groupID: String? = nil,
                 task: SessionTaskRef? = nil, title: String = "t") -> SessionSummary {
        var s = SessionSummary(id: id, fileURL: URL(filePath: "/x/\(id).jsonl"), projectSlug: groupKey,
                               title: title, modifiedAt: modified, turnCount: 1, isActive: false, groupID: groupID)
        s.groupKey = groupKey
        s.task = task
        return s
    }

    // MARK: ProjectFolders

    results.append(check("folders: own, worktree and subdirectory folders — never a sibling") {
        let root = try tempDir()
        for name in ["-Dev-app", "-Dev-app--claude-worktrees-task-1", "-Dev-app-Sources",
                     "-Dev-app-v2", "-Dev-application", "-Dev-other"] {
            try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        let cwds = ["-Dev-app-Sources": "/Dev/app/Sources", "-Dev-app-v2": "/Dev/app-v2"]
        let found = ProjectFolders.folders(for: URL(filePath: "/Dev/app"), in: root) { cwds[$0.lastPathComponent] }
        try expectEqual(Set(found.map(\.lastPathComponent)),
                        ["-Dev-app", "-Dev-app--claude-worktrees-task-1", "-Dev-app-Sources"], "folders")
    })

    results.append(check("folders: a path with a dot finds Claude Code's folder; trailing slash ignored") {
        let root = try tempDir()
        try FileManager.default.createDirectory(at: root.appending(path: "-Dev-my-site"), withIntermediateDirectories: true)
        let found = ProjectFolders.folders(for: URL(filePath: "/Dev/my.site/"), in: root) { _ in nil }
        try expectEqual(found.map(\.lastPathComponent), ["-Dev-my-site"], "dot → dash")
    })

    results.append(check("ownerPath / ownerSlug fold a worktree into its project") {
        try expectEqual(ProjectFolders.ownerPath(ofCwd: "/Dev/app/.claude/worktrees/task-1"), "/Dev/app", "cwd")
        try expectEqual(ProjectFolders.ownerPath(ofCwd: "/Dev/app/Sources"), "/Dev/app/Sources", "plain cwd")
        try expectEqual(ProjectFolders.ownerSlug(ofFolder: "-Dev-app--claude-worktrees-task-1"), "-Dev-app", "slug")
    })

    // MARK: SessionOpening / titles

    results.append(check("opening: a slash-command start titles by the command that carried args") {
        let lines = [
            user("<local-command-caveat>Caveat</local-command-caveat>", meta: true),
            user("<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>"),
            user("<local-command-stdout>ok</local-command-stdout>"),
            user("<command-name>/goal</command-name>\n<command-message>goal</command-message>\n<command-args>review the  sessions\npanel</command-args>"),
        ]
        let o = SessionOpening.parse(userLines: lines)
        try expect(o.hasConversation, "has conversation")
        try expectEqual(o.prompt, nil, "no typed prompt")
        try expectEqual(o.command, "/goal review the sessions", "first line of the args, whitespace collapsed")
        try expectEqual(SessionTitle.resolve(aiTitle: nil, opening: o, fallback: "uuid"), "/goal review the sessions", "title")
    })

    results.append(check("opening: a bare command is a last resort; a typed prompt beats it") {
        var o = SessionOpening.parse(userLines: [user("<command-name>/model</command-name><command-args></command-args>")])
        try expectEqual(SessionTitle.resolve(aiTitle: nil, opening: o, fallback: "uuid"), "/model", "bare command")
        o = SessionOpening.parse(userLines: [user("<command-name>/model</command-name><command-args></command-args>"),
                                             user("Fix the login bug\nmore detail")])
        try expectEqual(SessionTitle.resolve(aiTitle: nil, opening: o, fallback: "uuid"), "Fix the login bug", "prompt")
        try expectEqual(SessionTitle.resolve(aiTitle: "AI title", opening: o, fallback: "uuid"), "AI title", "ai-title")
        o = SessionOpening.parse(userLines: [user("[Request interrupted by user]"), user("Real one")])
        try expectEqual(o.prompt, "Real one", "the CLI's interruption marker is not a prompt")
    })

    results.append(check("opening: a task phase prompt yields the task, its phase and its name") {
        let prompt = "/claudepit-task-review\n\nYou are running the **Code Review** phase (step 5 of 5) of Claudepit task `e433a56e`.\nblah\n\n## Task\nLet worktrees merge the latest base\n\nTopic: tasks"
        let o = SessionOpening.parse(userLines: [user(prompt, cwd: "/Dev/app/.claude/worktrees/t")])
        try expectEqual(o.task, SessionTaskRef(taskID: "e433a56e", command: "review", taskName: "Let worktrees merge the latest base"), "ref")
        try expectEqual(o.task?.phaseLabel, "Review", "phase label")
        try expectEqual(o.cwd, "/Dev/app/.claude/worktrees/t", "cwd")
        // The task name beats even the CLI's ai-title, which names a detail of the phase.
        try expectEqual(SessionTitle.resolve(aiTitle: "Some detail", opening: o, fallback: "u"),
                        "Let worktrees merge the latest base", "title")
    })

    // MARK: SessionScanner

    results.append(check("scanner: metadata-only stub transcripts are not listed") {
        let root = try tempDir()
        let dir = root.appending(path: "-p")
        try write([#"{"type":"last-prompt","lastPrompt":"x","sessionId":"stub"}"#, #"{"type":"mode","mode":"normal"}"#],
                  to: dir.appending(path: "stub.jsonl"))
        try write([user("hello")], to: dir.appending(path: "real.jsonl"))
        let ids = SessionScanner(projectsRoot: root, groupStore: GroupStore(root: try tempDir()),
                                 summaryStore: SummaryStore(root: root)).list(activePath: nil).map(\.id)
        try expectEqual(ids, ["real"], "stub hidden")
    })

    results.append(check("scanner: a session that only ran local commands and got no reply is not listed") {
        let root = try tempDir()
        let dir = root.appending(path: "-p")
        let model = user("<command-name>/model</command-name><command-args></command-args>")
        try write([model, user("<local-command-stdout>ok</local-command-stdout>")], to: dir.appending(path: "cmd.jsonl"))
        try write([user("<command-name>/goal</command-name><command-args>do it</command-args>"),
                   #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"on it"}]}}"#],
                  to: dir.appending(path: "goal.jsonl"))
        try write([user("a typed prompt nobody answered yet")], to: dir.appending(path: "fresh.jsonl"))
        let ids = SessionScanner(projectsRoot: root, groupStore: GroupStore(root: try tempDir()),
                                 summaryStore: SummaryStore(root: root)).list(activePath: nil).map(\.id)
        try expectEqual(Set(ids), ["goal", "fresh"], "command-only session hidden")
    })

    results.append(check("scanner: worktree sessions share the open project's group file") {
        let root = try tempDir()
        try write([user("main", cwd: "/p")], to: root.appending(path: "-p/a.jsonl"))
        try write([user("wt", cwd: "/p/.claude/worktrees/w")], to: root.appending(path: "-p--claude-worktrees-w/b.jsonl"))
        let gs = GroupStore(root: try tempDir())
        let g = try gs.createGroup(name: "G", color: .red, projectSlug: "-p")
        try gs.assign(sessionIDs: ["a", "b"], groupID: g.id, projectSlug: "-p")
        let scanner = SessionScanner(projectsRoot: root, groupStore: gs, summaryStore: SummaryStore(root: root))
        let scoped = scanner.listing(activePath: URL(filePath: "/p"))
        try expectEqual(Set(scoped.sessions.map(\.groupKey)), ["-p"], "one key with a project open")
        try expect(scoped.sessions.allSatisfy { $0.groupID == g.id }, "both grouped")
        try expectEqual(scoped.groups["-p"]?.groups.map(\.name), ["G"], "groups returned")
        // Across all projects the worktree folds into its owner by cwd.
        let all = scanner.listing(activePath: nil)
        try expectEqual(all.sessions.first { $0.id == "b" }?.groupKey, "-p", "owner by cwd")
        try expectEqual(all.sessions.first { $0.id == "b" }?.worktreeName, "w", "worktree name")
    })

    results.append(check("scanner: an assignment to a deleted group reads as ungrouped") {
        let root = try tempDir()
        try write([user("x", cwd: "/p")], to: root.appending(path: "-p/a.jsonl"))
        let gs = GroupStore(root: try tempDir())
        try gs.save(ProjectGroups(groups: [], assignments: ["a": "gone"]), projectSlug: "-p")
        let s = SessionScanner(projectsRoot: root, groupStore: gs, summaryStore: SummaryStore(root: root))
            .list(activePath: URL(filePath: "/p")).first
        try expectEqual(s?.groupID, nil, "stale id dropped")
    })

    results.append(check("scanner: a re-scan picks up a title that appeared after the first scan") {
        let root = try tempDir()
        let f = root.appending(path: "-p/a.jsonl")
        let reply = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}"#
        try write([user("<command-name>/model</command-name><command-args></command-args>"), reply], to: f)
        let scanner = SessionScanner(projectsRoot: root, groupStore: GroupStore(root: try tempDir()),
                                     summaryStore: SummaryStore(root: root))
        try expectEqual(scanner.list(activePath: nil).first?.title, "/model", "first scan")
        try write([user("<command-name>/model</command-name><command-args></command-args>"), reply,
                   user("now a real prompt"), #"{"type":"ai-title","aiTitle":"Named","sessionId":"a"}"#], to: f)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: f.path)
        try expectEqual(scanner.list(activePath: nil).first?.title, "Named", "second scan")
    })

    // MARK: Group layout

    results.append(check("layout: manual groups win, task sessions group by task, rest ungrouped") {
        let now = Date()
        let ref = SessionTaskRef(taskID: "t1", command: "plan", taskName: "Prompt name")
        let sessions = [
            session("m", now, groupID: "g1", task: ref),
            session("t-a", now.addingTimeInterval(-10), task: ref),
            session("t-b", now.addingTimeInterval(-5), task: SessionTaskRef(taskID: "t1", command: "spec", taskName: nil)),
            session("u", now.addingTimeInterval(-20)),
            session("stale", now.addingTimeInterval(-30), groupID: nil),
        ]
        let groups = ["k": ProjectGroups(groups: [SessionGroup(id: "g1", name: "A", color: .red, createdAt: 0),
                                                  SessionGroup(id: "g2", name: "Empty", color: .blue, createdAt: 0)],
                                         assignments: ["m": "g1"])]
        let layout = SessionListing.groupLayout(sessions, groups: groups, keyOrder: ["k"], taskNames: ["t1": "Live name"])
        try expectEqual(layout.manual.map { $0.group.name }, ["A", "Empty"], "manual groups incl. empty")
        try expectEqual(layout.manual[0].sessions.map(\.id), ["m"], "manual wins over task")
        try expectEqual(layout.tasks.map(\.name), ["Live name"], "live task name")
        try expectEqual(layout.tasks[0].sessions.map(\.id), ["t-b", "t-a"], "newest first")
        try expectEqual(layout.ungrouped.map(\.id), ["u", "stale"], "rest")
        let off = SessionListing.groupLayout(sessions, groups: groups, keyOrder: ["k"], automaticTaskGroups: false)
        try expectEqual(off.tasks.count, 0, "automatic groups off")
        try expectEqual(off.ungrouped.map(\.id), ["t-b", "t-a", "u", "stale"], "task sessions fall to ungrouped")
    })

    results.append(check("groupKeyOrder: open project alone; across projects only files with groups, recent first") {
        let now = Date()
        let s = [session("a", now, groupKey: "old"), session("b", now.addingTimeInterval(60), groupKey: "new"),
                 session("c", now, groupKey: "none")]
        let g = SessionGroup(id: "g", name: "G", color: .red, createdAt: 0)
        let groups = ["old": ProjectGroups(groups: [g]), "new": ProjectGroups(groups: [g]), "none": ProjectGroups()]
        try expectEqual(SessionListing.groupKeyOrder(sessions: s, groups: groups, projectKey: "old"), ["old"], "project")
        try expectEqual(SessionListing.groupKeyOrder(sessions: s, groups: groups, projectKey: nil), ["new", "old"], "all")
    })

    // MARK: Search, dates, status, ranges

    results.append(check("search: every word must match title, bullets, task or extra fields") {
        var s = session("abc123", Date(), title: "Fix login flow")
        s.bulletSummary = SessionBulletSummary(bullets: ["Added OAuth refresh"], updatedAt: Date())
        s.task = SessionTaskRef(taskID: "t", command: "review", taskName: "Auth task")
        try expect(SessionListing.matches(s, query: ""), "empty matches")
        try expect(SessionListing.matches(s, query: "login oauth"), "title + bullet")
        try expect(SessionListing.matches(s, query: "review auth"), "phase + task name")
        try expect(SessionListing.matches(s, query: "abc1"), "session id")
        try expect(SessionListing.matches(s, query: "backend", extra: ["Backend work"]), "group name")
        try expect(!SessionListing.matches(s, query: "login payments"), "all words required")
    })

    results.append(check("dateSections: today, yesterday, 7 days, 30 days, then months") {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.locale = Locale(identifier: "en_US")
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 15))!
        let d = { (days: Double) in now.addingTimeInterval(-days * 86_400) }
        let sessions = [session("today", d(0.1)), session("yday", d(1)), session("week", d(4)),
                        session("month", d(20)), session("aug", d(45)), session("lastyear", d(400))]
        let sections = SessionListing.dateSections(sessions, now: now, calendar: cal)
        try expectEqual(sections.map(\.title),
                        ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "August", "August 2025"], "titles")
        try expectEqual(sections.map { $0.sessions.map(\.id) },
                        [["today"], ["yday"], ["week"], ["month"], ["aug"], ["lastyear"]], "members")
    })

    results.append(check("live status: herdr wins; otherwise a fresh write is working") {
        let now = Date()
        try expectEqual(SessionLiveStatus.resolve(herdrStatus: "working", modifiedAt: .distantPast, now: now), .working, "herdr working")
        try expectEqual(SessionLiveStatus.resolve(herdrStatus: "blocked", modifiedAt: now, now: now), .waiting, "herdr blocked")
        try expectEqual(SessionLiveStatus.resolve(herdrStatus: "idle", modifiedAt: now, now: now), .open, "herdr idle")
        try expectEqual(SessionLiveStatus.resolve(herdrStatus: nil, modifiedAt: now.addingTimeInterval(-30), now: now), .working, "fresh")
        try expectEqual(SessionLiveStatus.resolve(herdrStatus: nil, modifiedAt: now.addingTimeInterval(-90), now: now), .none, "stale")
        try expect(!SessionLiveStatus.none.isLive && SessionLiveStatus.open.isLive, "isLive")
    })

    results.append(check("range / neighbor: shift-selection and arrow keys over display order") {
        let order = ["a", "b", "c", "d"]
        try expectEqual(SessionListing.range(from: "b", to: "d", in: order), ["b", "c", "d"], "down")
        try expectEqual(SessionListing.range(from: "d", to: "b", in: order), ["b", "c", "d"], "up")
        try expectEqual(SessionListing.range(from: "zz", to: "c", in: order), ["c"], "unknown anchor")
        try expectEqual(SessionListing.neighbor(of: "b", step: 1, in: order), "c", "next")
        try expectEqual(SessionListing.neighbor(of: "d", step: 1, in: order), "d", "clamped")
        try expectEqual(SessionListing.neighbor(of: nil, step: -1, in: order), "d", "nothing selected, up → last")
    })

    results.append(check("stats: prompts and cost per session, subagent calls included") {
        var digest = TranscriptDigest()
        var cost = TokenCost(); cost.output = 1.5
        digest.calls["a"] = UsageCall(key: "a", sessionID: "s1", agentID: nil, inWorktree: false, model: "m",
                                      time: 0, end: 0, input: 0, output: 0, cacheRead: 0, cacheWrite: 0,
                                      cacheWrite1h: 0, priceMultiplier: 1, cost: cost)
        digest.calls["b"] = UsageCall(key: "b", sessionID: "s1", agentID: "agent", inWorktree: false, model: "m",
                                      time: 0, end: 0, input: 0, output: 0, cacheRead: 0, cacheWrite: 0,
                                      cacheWrite1h: 0, priceMultiplier: 1, cost: cost)
        digest.prompts["s1"] = [1, 2, 3]
        let table = SessionStat.table(from: digest)
        try expectEqual(table["s1"], SessionStat(prompts: 3, cost: 3.0), "s1")
    })

    // MARK: Groups

    results.append(check("group names: trimmed, required, unique ignoring case; rename keeps its own") {
        let groups = [SessionGroup(id: "1", name: "Auth", color: .red, createdAt: 0)]
        try expectEqual(SessionGroup.validatedName("  New   one ", among: groups), .success("New one"), "trim")
        try expectEqual(SessionGroup.validatedName("   ", among: groups), .failure(.empty), "empty")
        try expectEqual(SessionGroup.validatedName("auth", among: groups), .failure(.duplicate("Auth")), "dup")
        try expectEqual(SessionGroup.validatedName("AUTH", among: groups, excluding: "1"), .success("AUTH"), "rename self")
    })

    results.append(check("next colour: first unused, then least used") {
        let g = { (c: GroupColor) in SessionGroup(id: UUID().uuidString, name: "x", color: c, createdAt: 0) }
        try expectEqual(GroupColor.next(after: []), .red, "first")
        try expectEqual(GroupColor.next(after: [g(.red), g(.orange)]), .yellow, "skips used")
        try expectEqual(GroupColor.next(after: GroupColor.allCases.map(g) + [g(.red)]), .orange, "least used")
    })

    results.append(check("GroupStore: batch assign, create-with-members, collapse, move, decode old files") {
        let store = GroupStore(root: try tempDir())
        let a = try store.createGroup(name: "A", color: .red, projectSlug: "p")
        let b = try store.createGroup(name: "B", color: .blue, assigning: ["s1", "s2"], projectSlug: "p")
        try store.assign(sessionIDs: ["s1", "s3"], groupID: a.id, projectSlug: "p")
        try store.assign(sessionIDs: ["s4"], groupID: "missing", projectSlug: "p")
        var pg = store.load(projectSlug: "p")
        try expectEqual(pg.assignments, ["s1": a.id, "s2": b.id, "s3": a.id], "assignments")
        try store.unassign(sessionIDs: ["s1", "s2"], projectSlug: "p")
        try store.setCollapsed(id: a.id, collapsed: true, projectSlug: "p")
        try store.moveGroup(id: b.id, by: -1, projectSlug: "p")
        try store.moveGroup(id: b.id, by: -5, projectSlug: "p")
        pg = store.load(projectSlug: "p")
        try expectEqual(pg.assignments, ["s3": a.id], "unassigned")
        try expectEqual(pg.groups.map(\.name), ["B", "A"], "moved")
        try expect(pg.groups[1].isCollapsed && !pg.groups[0].isCollapsed, "collapsed")
        let old = #"{"version":1,"groups":[{"id":"x","name":"Old","color":"teal","createdAt":0}],"assignments":{}}"#
        let decoded = try JSONDecoder().decode(ProjectGroups.self, from: Data(old.utf8))
        try expect(decoded.groups[0].collapsed == nil, "pre-collapse files decode")
    })

    // MARK: Trash

    results.append(check("trash: transcript and folder trashed, summary and assignment removed") {
        let root = try tempDir()
        let file = root.appending(path: "-p/s1.jsonl")
        try write([user("x")], to: file)
        try FileManager.default.createDirectory(at: root.appending(path: "-p/s1/subagents"), withIntermediateDirectories: true)
        let summaries = SummaryStore(root: root)
        try summaries.save(SessionBulletSummary(bullets: ["b"], updatedAt: Date()), projectSlug: "-p", sessionID: "s1")
        let gs = GroupStore(root: try tempDir())
        let g = try gs.createGroup(name: "G", color: .red, assigning: ["s1", "s2"], projectSlug: "-p")
        final class Box: @unchecked Sendable { var urls: [String] = [] }
        let trashed = Box()
        let trash = SessionTrash(groupStore: gs, summaryStore: summaries) { url in
            trashed.urls.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
        var s = SessionSummary(id: "s1", fileURL: file, projectSlug: "-p", title: "", modifiedAt: Date(),
                               turnCount: 1, isActive: false)
        s.groupKey = "-p"
        let failed = trash.trash([s])
        try expectEqual(failed, [], "no failures")
        try expectEqual(trashed.urls, ["s1.jsonl", "s1"], "transcript then folder")
        try expect(summaries.load(projectSlug: "-p", sessionID: "s1") == nil, "summary gone")
        try expectEqual(gs.load(projectSlug: "-p").assignments, ["s2": g.id], "assignment gone")
    })

    return results
}
