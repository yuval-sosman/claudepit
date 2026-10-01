#if DEBUG
import SwiftUI
import AppKit
import ClaudepitCore

/// Developer tool, DEBUG builds only: the Loops page offscreen, from this machine's real
/// transcripts, live-session registry and CLI flags — or, with `--demo`, from made-up loops in every
/// state. Read only: nothing is scheduled, sent or written.
///
///     .build/debug/ClaudepitApp --snapshot-pages loops --out <dir> [--project p] [--demo]
///         [--select overview|first|<loop id>] [--query q]
///         [--loopfile show|edit|ask|review|none|user]   (the overview's loop.md card)
///         [--new-loop [--draft interval|self|cron|once|durable|cloud|agent|run-as|mention|background]]
///         [--interaction-test]
@MainActor
enum DevLoopsSnapshot {
    static func run(args: [String], outDir: URL, size: CGSize, query: String) {
        func value(_ flag: String) -> String? {
            guard let j = args.firstIndex(of: flag), j + 1 < args.count else { return nil }
            return args[j + 1]
        }
        let project = URL(filePath: value("--project") ?? FileManager.default.currentDirectoryPath)
        var context = LoopPageContext()
        context.herdrAvailable = Herdr.available()
        context.hasProject = true
        context.projectName = project.lastPathComponent
        let t0 = Date()
        if args.contains("--demo") {
            context.snapshot = demoSnapshot(now: Date())
        } else {
            let sessions = SessionScanner().listing(activePath: project).sessions.map {
                LoopBuilder.SessionRef(id: $0.id, transcript: $0.fileURL, title: $0.title, cwd: $0.cwd, modifiedAt: $0.modifiedAt)
            }
            let scanner = LoopScanner()
            context.snapshot = scanner.snapshot(sessions: sessions, project: project)
            let t1 = Date()
            _ = scanner.snapshot(sessions: sessions, project: project)
            print("scan: \(context.snapshot.scannedTranscripts) transcripts, cold \(Int(t1.timeIntervalSince(t0) * 1000))ms "
                  + "(listing included), warm rescan \(Int(Date().timeIntervalSince(t1) * 1000))ms")
            if args.contains("--time-scan") {
                for ref in sessions where Date().timeIntervalSince(ref.modifiedAt) <= LoopScanner.historyWindow {
                    let size = (try? FileManager.default.attributesOfItem(atPath: ref.transcript.path)[.size] as? Int) ?? 0
                    let t = Date()
                    let log = LoopLogReader.read(ref.transcript)
                    print("  \(ref.id.prefix(8)) \(size / 1_000_000) MB: \(Int(Date().timeIntervalSince(t) * 1000))ms, "
                          + "\(log.creates.count) creates, \(log.wakeups.count) wakeups, \(log.fires.count) fires")
                }
            }
        }
        if args.contains("--e2e") {
            exit((value("--e2e") == "background" ? runBackgroundE2E(project: project)
                  : value("--e2e") == "agent" ? runAgentE2E(project: project) : runE2E(project: project)) ? 0 : 1)
        }
        report(context.snapshot)
        if args.contains("--interaction-test") {
            if context.snapshot.records.count < 4 { context.snapshot = demoSnapshot(now: Date()) }
            exit(DevPagesInteraction.runLoops(context) ? 0 : 1)
        }
        let selection: LoopSelection = {
            switch value("--select") {
            case nil, "overview": return .overview
            case "first": return context.snapshot.records.first.map { .loop($0.id) } ?? .overview
            case let id?: return context.records.contains { $0.id == id } ? .loop(id) : .overview
            }
        }()
        let loopFileMode: LoopFileSection.Mode
        switch value("--loopfile") {
        case "edit": loopFileMode = .edit
        case "ask": loopFileMode = .ask
        case "review": loopFileMode = .review
        case "none": loopFileMode = .show; context.snapshot.projectLoopFile = nil; context.snapshot.userLoopFile = nil
        case "user": loopFileMode = .show; context.snapshot.projectLoopFile = nil
        default: loopFileMode = .show
        }
        DevPagesSnapshot.write(LoopsSnapshotPage(context: context, selection: selection, query: query, loopFileMode: loopFileMode),
                               size: size, to: outDir.appending(path: "loops.png"), settle: 2.0)
        if args.contains("--new-loop") {
            var ctx = NewLoopContext(capabilities: context.snapshot.capabilities, loopFile: context.snapshot.activeLoopFile,
                                     herdrAvailable: true,
                                     commands: ["/review-pr": CommandAvailability(modelInvocable: true, description: "Review a PR"),
                                                "/deploy": CommandAvailability(modelInvocable: false, reason: "disable-model-invocation: true")],
                                     agents: [LoopAgent(name: "code-reviewer", description: "Reviews code for bugs and risky changes",
                                                        model: "sonnet", tools: ["Read", "Grep", "Glob"], scope: "project"),
                                              LoopAgent(name: "pr-watcher", description: "Watches the PR's CI and review threads",
                                                        tools: ["Read", "Bash"], scope: "user")],
                                     targets: [("w3:p1", "claudepit-ca", "idle")], hasProject: true,
                                     projectName: project.lastPathComponent)
            ctx.loopFile = context.snapshot.activeLoopFile
            var draft = LoopDraft()
            draft.task = .prompt("Check whether CI passed and address any new review comments.")
            switch value("--draft") {
            case "self": draft.cadence = .selfPaced; draft.task = .prompt("check whether CI passed every 5 minutes")
            case "cron": draft.cadence = .cron("0 9 * * 1-5"); draft.permissionMode = "manual"
            case "once": draft.cadence = .once(Date().addingTimeInterval(5400))
            case "durable": draft.destination = .durableFile
            case "cloud": draft.destination = .cloud; draft.cadence = .interval(LoopInterval(2, .h))
            case "agent":
                draft.task = .agent(name: "code-reviewer", task: "review what changed since the last run and list anything risky",
                                    skipWhileRunning: true)
                draft.cadence = .interval(LoopInterval(15, .m))
            case "run-as": draft.sessionAgent = "pr-watcher"; draft.cadence = .interval(LoopInterval(10, .m))
            case "background": draft.destination = .background; draft.cadence = .selfPaced
            case "mention": draft.task = .prompt("@agent-code-reviewer look at the auth changes"); draft.cadence = .interval(LoopInterval(10, .m))
            default: draft.cadence = .interval(LoopInterval(7, .m))
            }
            let sheet = NewLoopSheet(context: ctx, seed: draft, onSubmit: { _ in true })
            DevPagesSnapshot.write(sheet, size: CGSize(width: 1040, height: 700), to: outDir.appending(path: "new-loop.png"),
                                   settle: 1.5)
        }
    }

    /// End to end against the real CLI: start a `/loop 1m` in a new herdr session (Haiku, one-word
    /// replies), read it back the way the page does until it has fired twice, stop it the way the
    /// page does (CronDelete, sent through herdr), confirm it reads as cancelled, close the tab.
    /// Costs a few cheap turns and leaves one short session in the project's history.
    static func runE2E(project: URL) -> Bool {
        final class Box: @unchecked Sendable { var ok = false; var done = false }
        func await_(_ body: @escaping @Sendable () async -> Bool) -> Bool {
            let box = Box()
            Task.detached { box.ok = await body(); box.done = true }
            while !box.done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            return box.ok
        }
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        var draft = LoopDraft()
        draft.task = .prompt("Reply with exactly one word: tick")
        draft.cadence = .interval(LoopInterval(1, .m))
        draft.model = "haiku"
        draft.permissionMode = "auto"
        draft.sessionName = "loop-e2e (Claudepit test)"
        // The summary hook a fire meets is the installed one; bring it to this build's, exactly as
        // `ManagedInstaller.sync()` does at the next launch (it skips scheduled fires).
        let installed = try? String(contentsOf: Paths.summaryHookScript, encoding: .utf8)
        if installed != nil, installed != HookScripts.summaryHook {
            try? HookScripts.summaryHook.write(to: Paths.summaryHookScript, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Paths.summaryHookScript.path)
            print("e2e: updated \(Paths.summaryHookScript.path) to this build's summary hook")
        }
        let sid = UUID().uuidString.lowercased()
        let name = LoopAgentName.forSession(sid)
        let args = draft.claudeArguments(sessionID: sid)
        let message = draft.message()!
        print("e2e: starting \(name) — claude \(args.joined(separator: " ")) — sending “\(message)”")
        let launched = await_ { await TaskRunner.shared.openLoopSession(name: name, cwd: project, tabLabel: "loop-e2e",
                                                                          claudeArgs: args, message: message) }
        guard launched else { print("FAIL  herdr didn't bring Claude up"); return false }
        let scanner = LoopScanner()
        var transcript: URL?
        var record: LoopRecord?
        func scan() -> LoopSnapshot? {
            if transcript == nil {
                let dirs = (try? FileManager.default.contentsOfDirectory(at: Paths.projectsRoot, includingPropertiesForKeys: nil)) ?? []
                transcript = dirs.map { $0.appending(path: "\(sid).jsonl") }.first { FileManager.default.fileExists(atPath: $0.path) }
            }
            guard let transcript else { return nil }
            let ref = LoopBuilder.SessionRef(id: sid, transcript: transcript, title: "loop-e2e", cwd: project.path, modifiedAt: Date())
            return scanner.snapshot(sessions: [ref], project: project)
        }
        let start = Date()
        while Date().timeIntervalSince(start) < 420 {
            wait(10)
            guard let snap = scan() else { print("e2e: no transcript yet"); continue }
            let live = snap.liveSession(sid)
            record = snap.records.first { $0.sessionID == sid && $0.kind != .selfPaced || ($0.sessionID == sid && $0.taskID != nil) }
                ?? snap.records.first { $0.sessionID == sid }
            print("e2e: +\(Int(Date().timeIntervalSince(start)))s live \(live?.status ?? "no") — "
                  + (record.map { "[\($0.state.rawValue)] \($0.kind.rawValue) cron \($0.cron ?? "-") job \($0.taskID ?? "-") "
                                 + "origin \($0.origin) fires \($0.fires.count) next \($0.nextFire.map { LoopTime.clock($0) } ?? "-")" } ?? "no loop yet"))
            if let r = record, r.fires.count >= 2 { break }
            if let live, live.isWaiting {
                print("FAIL  the session stopped and waits for: \(live.waitingFor ?? "?") — answer it in herdr tab \(name)")
                break
            }
        }
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("\(cond ? "PASS" : "FAIL")  \(what)"); if !cond { ok = false } }
        check(record?.kind == .recurring, "/loop 1m became a recurring CronCreate task")
        check(record?.cron.flatMap(CronExpression.init)?.minutes.count == 60, "with an every-minute cron (got \(record?.cron ?? "nil"))")
        check(record?.taskID?.count == 8, "and an 8-character job id read from the result (got \(record?.taskID ?? "nil"))")
        check(record.map { if case .loopCommand(let a, _) = $0.origin { return a.hasPrefix("1m") }; return false } == true,
              "traced back to the /loop that made it")
        check((record?.fires.count ?? 0) >= 2, "it fired at least twice (\(record?.fires.count ?? 0))")
        if let r = record, let f = r.fires.last, let file = r.transcript {
            // From the fire's prompt record, as the detail card reads it.
            let it = f.promptOffset.flatMap { LoopIterationReader.read(file: file, from: $0) }
            check(it?.lastText?.lowercased().contains("tick") == true, "a fire's turn reads back with Claude's reply (“\(it?.lastText ?? "nil")”)")
            check(it?.complete == true, "and its end (\(it?.durationMs.map { "\($0) ms" } ?? "no duration"))")
        }
        // Claudepit's own summary hook must leave fires alone: the hook output after each fire record.
        if let file = transcript, let text = try? String(contentsOf: file, encoding: .utf8) {
            var afterFire = false, fireHooks = 0, instructed = 0
            for line in text.split(separator: "\n") {
                if line.contains(#""subtype":"scheduled_task_fire""#) { afterFire = true; continue }
                if afterFire, line.contains(#""hookEvent":"UserPromptSubmit""#) {
                    fireHooks += 1
                    if line.contains("claudepit_summary_instruction") { instructed += 1 }
                    afterFire = false
                }
                if line.contains(#""subtype":"turn_duration""#) { afterFire = false }
            }
            check(instructed == 0, "no fire was handed the summary instruction (\(instructed) of \(fireHooks) fire hooks did)")
        }
        if let r = record {
            let sent = await_ { await Herdr.prompt(agent: name, text: r.stopRequest) }
            check(sent, "the stop request was sent through herdr")
            let stopStart = Date()
            while Date().timeIntervalSince(stopStart) < 180 {
                wait(8)
                if let snap = scan(), let again = snap.records.first(where: { $0.id == r.id }) {
                    print("e2e: after stop — [\(again.state.rawValue)] \(again.note ?? "")")
                    if again.state == .cancelled { break }
                }
            }
            check(scan()?.records.first { $0.id == r.id }?.state == .cancelled, "the loop reads as cancelled")
        }
        // Close the tab the test opened.
        _ = await_ {
            guard let obj = await Herdr.runJSON(["agent", "get", name], cwd: nil),
                  let tab = ((obj["result"] as? [String: Any])?["agent"] as? [String: Any])?["tab_id"] as? String
                    ?? (obj["result"] as? [String: Any])?["tab_id"] as? String else { return false }
            return await Herdr.succeeds(["tab", "close", tab], cwd: nil)
        }
        print(ok ? "e2e passed — session \(sid)" : "e2e FAILED — session \(sid)")
        return ok
    }

    /// End to end for the "A background session" destination, through the Core pieces the app uses:
    /// `LoopDraft.backgroundArguments` → `claude --bg`, `BackgroundSession.jobID` on what it prints, the
    /// scan (`LiveSession.isBackground`, the loop, its fires), then `claude stop` and the loop reading
    /// as paused. Haiku with `dontAsk`, so no prompt can hold it. Installs nothing.
    static func runBackgroundE2E(project: URL) -> Bool {
        final class Box: @unchecked Sendable { var value: Subprocess.Result?; var done = false }
        func run(_ args: [String]) -> Subprocess.Result? {
            guard let claude = Executable.find("claude") else { return nil }
            let box = Box()
            Task.detached {
                box.value = await Subprocess.run(claude, args, cwd: project, environment: ClaudeCLI.environment(), timeout: 90)
                box.done = true
            }
            while !box.done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            return box.value
        }
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("\(cond ? "PASS" : "FAIL")  \(what)"); if !cond { ok = false } }
        var draft = LoopDraft()
        draft.task = .prompt("Reply with exactly one word: tick")
        draft.cadence = .interval(LoopInterval(1, .m))
        draft.destination = .background
        draft.model = "haiku"
        draft.permissionMode = "dontAsk"
        draft.sessionName = "loop-bg-e2e (Claudepit test)"
        let args = draft.backgroundArguments(message: draft.message()!)
        print("e2e: claude \(args.joined(separator: " "))")
        let started = run(args)
        let id = started.flatMap { BackgroundSession.jobID(fromOutput: $0.stdout) }
        check(started?.ok == true && id != nil, "claude --bg started and printed its id (\(id ?? started.map { ClaudeCLI.failureMessage(stdout: $0.stdout, stderr: $0.stderr) } ?? "no claude"))")
        guard let id else { return false }
        let scanner = LoopScanner()
        func scan() -> (LoopSnapshot, LoopRecord?)? {
            let dirs = (try? FileManager.default.contentsOfDirectory(at: Paths.projectsRoot, includingPropertiesForKeys: nil)) ?? []
            let files = dirs.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            guard let file = files.first(where: { $0.lastPathComponent.hasPrefix(id) && $0.pathExtension == "jsonl" }) else { return nil }
            let sid = file.deletingPathExtension().lastPathComponent
            let ref = LoopBuilder.SessionRef(id: sid, transcript: file, title: "loop-bg-e2e", cwd: project.path, modifiedAt: Date())
            let snap = scanner.snapshot(sessions: [ref], project: project)
            return (snap, snap.records.first { $0.sessionID == sid && $0.kind == .recurring })
        }
        var record: LoopRecord?
        var sawBackground = false
        let start = Date()
        while Date().timeIntervalSince(start) < 300 {
            wait(10)
            guard let (snap, r) = scan() else { print("e2e: no transcript yet"); continue }
            record = r
            if let live = r.flatMap({ snap.liveSession($0.sessionID) }) ?? snap.liveSessions.first(where: { $0.jobID == id }) {
                sawBackground = sawBackground || (live.isBackground && live.jobID == id)
            }
            print("e2e: +\(Int(Date().timeIntervalSince(start)))s " + (r.map { "[\($0.state.rawValue)] fires \($0.fires.count)" } ?? "no loop yet"))
            if let r, r.fires.count >= 2 { break }
        }
        check(sawBackground, "the registry shows a background session (kind bg, jobId \(id))")
        check(record?.cron.flatMap(CronExpression.init)?.minutes.count == 60, "/loop 1m armed an every-minute task")
        check((record?.fires.count ?? 0) >= 2, "it fired at least twice with no terminal (\(record?.fires.count ?? 0))")
        let stopped = run(["stop", id])
        check(stopped?.ok == true, "claude stop \(id)")
        var paused = false
        let stopStart = Date()
        while Date().timeIntervalSince(stopStart) < 60 {
            wait(3)
            if let (_, r) = scan(), r?.state == .paused { paused = true; break }
        }
        check(paused, "after claude stop the loop reads as paused — resume brings it back")
        print(ok ? "background e2e passed — session \(id)" : "background e2e FAILED — session \(id)")
        return ok
    }

    static func report(_ snap: LoopSnapshot) {
        let caps = snap.capabilities
        print("capabilities: cron \(caps.cron) · durable \(caps.durable) · self-paced \(caps.selfPaced) · "
              + "maintenance \(caps.maintenancePrompt) · disabledBy \(caps.disabledBy.map(\.lastPathComponent))")
        print("live sessions: " + snap.liveSessions.map { "\($0.sessionID.prefix(8)) pid \($0.pid) \($0.status ?? "?")" }.joined(separator: ", "))
        print("loop.md: project \(snap.projectLoopFile.map { "\($0.size)B" } ?? "none"), user \(snap.userLoopFile.map { "\($0.size)B" } ?? "none")")
        for r in snap.records {
            let next = r.nextFire.map { LoopTime.clock($0) } ?? "-"
            print("  [\(r.state.rawValue)] \(r.kind.rawValue) \(r.badge) “\(r.title.prefix(50))”\(r.sessionAgent.map { " as \($0)" } ?? "") next \(next) fires \(r.fires.count) "
                  + "session \(r.sessionID?.prefix(8) ?? "-") id \(r.id)\(r.note.map { " — \($0)" } ?? "")")
            for f in r.fires.suffix(3) {
                let outcome = zip(f.promptOffset.map { [$0] } ?? [], r.transcript.map { [$0] } ?? [])
                    .compactMap { LoopIterationReader.read(file: $1, from: $0) }.first
                print("      fire \(LoopTime.clock(f.time)) due \(f.dueAt.map { LoopTime.clock($0) } ?? "?")\(f.isFallback ? " (fallback)" : "")"
                      + (outcome.map { " → “\($0.lastText ?? "")” \($0.durationMs.map { "\($0) ms" } ?? "")\($0.complete ? "" : " (incomplete)")" } ?? ""))
                for d in outcome?.delegations ?? [] {
                    print("        agent \(d.agent)\(d.background ? " (background)" : "") → \(d.status ?? "no report")"
                          + (d.reportedAt.map { " at \(LoopTime.clock($0))" } ?? "") + (d.result.map { " “\($0.prefix(60))”" } ?? ""))
                }
            }
        }
        for (sid, g) in snap.goals { print("  goal \(sid.prefix(8)): \(g.state.rawValue) “\(g.condition.prefix(60))”") }
    }

    /// Made-up loops in every state, timed around `now`, for screenshots and the interaction test.
    static func demoSnapshot(now: Date) -> LoopSnapshot {
        var snap = LoopSnapshot()
        snap.scannedAt = now
        var caps = LoopCapabilities()
        caps.cron = .on; caps.durable = .off; caps.selfPaced = .on; caps.maintenancePrompt = .on
        caps.flagsFetchedAt = now.addingTimeInterval(-7200)
        snap.capabilities = caps
        snap.liveSessions = [
            LiveSession(pid: 48030, sessionID: "demo-a", cwd: "/demo", version: "2.1.286", kind: "interactive",
                        name: "claudepit-ca", status: "idle"),
            LiveSession(pid: 3144, sessionID: "demo-b", cwd: "/demo", version: "2.1.286", kind: "interactive",
                        name: "release-watch", status: "busy"),
            LiveSession(pid: 65591, sessionID: "demo-w", cwd: "/demo", version: "2.1.286", kind: "interactive",
                        name: "sentry-triage", status: "waiting", waitingFor: "permission prompt"),
        ]
        func rec(_ id: String, _ kind: LoopRecord.Kind, _ prompt: String, cron: String?, recurring: Bool = true,
                 state: LoopState, session: String? = "demo-a", created: TimeInterval) -> LoopRecord {
            var r = LoopRecord(id: id, kind: kind, origin: .conversation, prompt: prompt, cron: cron, recurring: recurring,
                               createdAt: now.addingTimeInterval(created), state: state)
            r.sessionID = session
            r.sessionTitle = session == "demo-b" ? "Release watch" : "Sessions page rebuild"
            r.transcript = session.map { URL(filePath: "/tmp/\($0).jsonl") }
            r.permissionMode = "auto"
            r.expiresAt = recurring && kind != .oneShot ? r.createdAt.addingTimeInterval(7 * 86_400) : nil
            return r
        }
        let j = CronJitter.cliDefault
        var deploy = rec("demo-a#3fa1c2d0", .recurring, "Check if the deployment finished and tell me what happened.",
                         cron: "*/5 * * * *", state: .scheduled, created: -3000)
        deploy.origin = .loopCommand(args: "5m Check if the deployment finished and tell me what happened.", viaSkill: false)
        deploy.taskID = "3fa1c2d0"; deploy.taskIDs = ["3fa1c2d0"]
        var t = deploy.createdAt
        for i in 0..<9 {
            let due = j.recurringFire(CronExpression("*/5 * * * *")!, from: t, taskID: "3fa1c2d0") ?? t
            let fired = i == 4 ? due.addingTimeInterval(420) : due
            deploy.fires.append(LoopFire(time: fired, taskID: "3fa1c2d0", dueAt: due, offset: i + 1, isFallback: false, label: nil, deliveredAt: nil, promptOffset: 1))
            t = fired
        }
        deploy.nextFire = j.recurringFire(CronExpression("*/5 * * * *")!, from: t, taskID: "3fa1c2d0")
        if let n = deploy.nextFire, n <= now { deploy.nextFire = now.addingTimeInterval(140) }

        var tests = rec("demo-b#a91c00e7", .recurring, "/review-pr 1234", cron: "*/30 * * * *", state: .running,
                        session: "demo-b", created: -9000)
        tests.taskID = "a91c00e7"; tests.taskIDs = ["a91c00e7"]
        tests.origin = .loopCommand(args: "30m /review-pr 1234", viaSkill: false)
        for k in [-8100.0, -6300, -4500, -2700, -240] {
            tests.fires.append(LoopFire(time: now.addingTimeInterval(k), taskID: "a91c00e7", dueAt: now.addingTimeInterval(k - 410),
                                        offset: 1, isFallback: false, label: nil, deliveredAt: nil, promptOffset: 1))
        }
        tests.nextFire = now.addingTimeInterval(1560)

        var ci = rec("demo-a#auto-1", .selfPaced, "check whether CI passed and address any review comments", cron: nil,
                     state: .scheduled, created: -5400)
        ci.origin = .loopCommand(args: "check whether CI passed and address any review comments", viaSkill: false)
        ci.wakeups = [
            LoopLog.Wakeup(toolUseID: "w1", time: now.addingTimeInterval(-5300), offset: -1, delaySeconds: 600,
                           reason: "CI still running on the PR", prompt: ci.prompt, stop: false,
                           scheduledFor: now.addingTimeInterval(-4700), clampedDelaySeconds: 600, wasClamped: false),
            LoopLog.Wakeup(toolUseID: "w2", time: now.addingTimeInterval(-4400), offset: -1, delaySeconds: 1800,
                           reason: "CI green; waiting on review comments", prompt: ci.prompt, stop: false,
                           scheduledFor: now.addingTimeInterval(-2600), clampedDelaySeconds: 1800, wasClamped: false),
            LoopLog.Wakeup(toolUseID: "w3", time: now.addingTimeInterval(-1900), offset: -1, delaySeconds: 3600,
                           reason: "PR quiet, nothing pending", prompt: ci.prompt, stop: false,
                           scheduledFor: now.addingTimeInterval(1700), clampedDelaySeconds: 3600, wasClamped: false),
        ]
        ci.fires = [LoopFire(time: now.addingTimeInterval(-4700), taskID: "9d1e0a11", dueAt: now.addingTimeInterval(-4700),
                             offset: 1, isFallback: false, label: nil, deliveredAt: nil, promptOffset: 1),
                    LoopFire(time: now.addingTimeInterval(-2100), taskID: "51c2aa90", dueAt: now.addingTimeInterval(-2600),
                             offset: 1, isFallback: false, label: nil, deliveredAt: nil, promptOffset: 1)]
        ci.nextFire = now.addingTimeInterval(1700)
        ci.taskIDs = ["9d1e0a11", "51c2aa90"]

        var reminder = rec("demo-a#c0ffee12", .oneShot, "Remind me to push the release branch", cron: "37 18 * * *",
                           recurring: false, state: .scheduled, created: -600)
        reminder.taskID = "c0ffee12"
        reminder.cron = DraftCron.pinned(now.addingTimeInterval(4000))
        reminder.nextFire = now.addingTimeInterval(4000)

        var due = rec("demo-w#77aa0b1c", .recurring, "Summarize new Sentry errors since the last check", cron: "7 * * * *",
                      state: .blocked, session: "demo-w", created: -20_000)
        due.taskID = "77aa0b1c"; due.nextFire = now.addingTimeInterval(-300)
        due.sessionTitle = "Sentry triage"
        due.note = "Its session is waiting for you (permission prompt) — nothing fires until it's answered"

        var paused = rec("demo-c#5e5e5e5e", .recurring, "<<autonomous-loop>>", cron: "0 */2 * * *", state: .paused,
                         session: "demo-c", created: -86_400 * 2)
        paused.origin = .loopCommand(args: "2h", viaSkill: false)
        paused.taskID = "5e5e5e5e"; paused.sessionTitle = "Weekend refactor"
        paused.note = "Comes back when the session is resumed"

        var durable = rec("durable#0badf00d", .durable, "Run the nightly link checker", cron: "13 3 * * *", state: .notRunning,
                          session: nil, created: -86_400 * 3)
        durable.origin = .durableFile; durable.taskID = "0badf00d"
        durable.durable = DurableTask(id: "0badf00d", cron: "13 3 * * *", prompt: "Run the nightly link checker",
                                      createdAt: durable.createdAt, recurring: true)
        durable.note = "Durable tasks are switched off in this Claude Code — it never reads this file"
        durable.nextFire = now.addingTimeInterval(30_000)

        var stopped = rec("demo-a#auto-0", .selfPaced, "<<autonomous-loop-dynamic>>", cron: nil, state: .stopped,
                          created: -40_000)
        stopped.endedAt = now.addingTimeInterval(-30_000)
        stopped.note = "Claude ended the loop (ScheduleWakeup stop)"
        var expired = rec("demo-d#e1e1e1e1", .recurring, "Rebase the feature branch on main", cron: "0 9 * * *", state: .expired,
                          session: "demo-d", created: -86_400 * 8)
        expired.endedAt = now.addingTimeInterval(-86_400 + 600); expired.taskID = "e1e1e1e1"
        expired.note = "Reached the 7-day limit: fired one last time and deleted itself"
        var lapsed = rec("demo-e#auto-2", .selfPaced, "keep an eye on the flaky e2e job", cron: nil, state: .lapsed,
                         session: "demo-e", created: -7200)
        lapsed.endedAt = now.addingTimeInterval(-3600)
        lapsed.fires = [LoopFire(time: now.addingTimeInterval(-5000), taskID: "1", dueAt: now.addingTimeInterval(-5600),
                                 offset: 1, isFallback: false, label: nil, deliveredAt: nil, promptOffset: 1),
                        LoopFire(time: now.addingTimeInterval(-3600), taskID: "2", dueAt: nil, offset: 1, isFallback: true, label: nil, deliveredAt: nil, promptOffset: 1)]
        lapsed.note = "Claude didn't re-arm the loop, even after the fallback wakeup — it ended"
        var failed = rec("demo-a#toolu_1", .recurring, "poll the queue", cron: "*/1 * * * *", state: .failed, created: -800)
        failed.note = "Too many scheduled tasks (max 50)"; failed.endedAt = failed.createdAt
        var desktop = rec("desktop#daily-review", .desktop, "Review the commits merged yesterday.", cron: nil, state: .external,
                          session: nil, created: -86_400 * 10)
        desktop.origin = .desktopApp
        desktop.desktop = DesktopScheduledTask(name: "daily-review", description: "Review yesterday's commits",
                                               prompt: "Review the commits merged yesterday.",
                                               url: URL(filePath: "/Users/me/.claude/scheduled-tasks/daily-review/SKILL.md"),
                                               modifiedAt: desktop.createdAt)
        snap.records = [deploy, tests, ci, reminder, due, paused, durable, stopped, expired, lapsed, failed, desktop]
        snap.projectLoopFile = LoopFile(scope: .project, url: URL(filePath: "/demo/.claude/loop.md"),
                                        size: LoopFile.template.utf8.count + 1, modifiedAt: now.addingTimeInterval(-7200),
                                        text: LoopFile.template + "\n")
        let userText = "Look at what changed on this branch since the last iteration. Run the tests that cover it;\n"
            + "if one fails, fix it. Otherwise reply \"quiet\" and stop.\n"
        snap.userLoopFile = LoopFile(scope: .user, url: URL(filePath: "/Users/me/.claude/loop.md"), size: userText.utf8.count,
                                     modifiedAt: now.addingTimeInterval(-86_400 * 3), text: userText)
        snap.goals["demo-a"] = GoalSummary(condition: "all tests in test/auth pass and lint is clean", state: .active,
                                           lastReason: "2 auth tests still failing", iterations: 4, since: now.addingTimeInterval(-3600))
        return snap
    }
}

/// `M H D Mo *` for a demo one-shot.
private enum DraftCron {
    static func pinned(_ d: Date) -> String { LoopDraft.pinnedCron(d) }
}

/// The Loops page as `LoopsSection` lays it out, with closures that do nothing.
struct LoopsSnapshotPage: View {
    let context: LoopPageContext
    @State var selection: LoopSelection
    @State var query: String
    var loopFileMode: LoopFileSection.Mode = .show
    @State private var reveal: String?

    var body: some View {
        MasterDetailLayout(listWidth: 320) {
            GlassCard {
                LoopListView(context: context, selection: $selection, query: $query, revealRequest: $reveal, now: Date())
            }
        } detail: {
            switch selection {
            case .overview:
                LoopOverviewView(context: context, select: { selection = .loop($0) }, loopFileMode: loopFileMode)
            case .loop(let id):
                if let r = context.record(id) {
                    LoopDetailView(record: r, context: context, select: { selection = .loop($0) })
                } else {
                    LoopOverviewView(context: context)
                }
            }
        }
    }
}
#endif
