#if DEBUG
import Foundation
import ClaudepitCore

extension DevLoopsSnapshot {
    /// End to end for the New Loop dialog's Agent task, against the real CLI: a `/loop 1m` that hands
    /// each fire to a subagent (defined inline with `--agents`, so no agent file is written), run in a
    /// background session (Haiku, `dontAsk`, so no prompt can hold it). Checks that the page reads it
    /// as an agent loop, that each fire starts the agent in the background and the iteration reader
    /// follows it to its report, then stops the session with `claude stop`. Installs nothing.
    ///
    ///     .build/debug/ClaudepitApp --snapshot-pages loops --project <p> --out <dir> --e2e agent
    static func runAgentE2E(project: URL) -> Bool {
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

        let agent = "loop-e2e-echo"
        let definition = #"{"loop-e2e-echo":{"description":"Loop test agent: replies with one word","prompt":"#
            + #""You are a test agent. Reply with exactly one word: the word your task asks for. No other text.","#
            + #""tools":["Read"],"model":"haiku"}}"#
        var draft = LoopDraft()
        draft.task = .agent(name: agent, task: "reply with the word tick", skipWhileRunning: true)
        draft.cadence = .interval(LoopInterval(1, .m))
        draft.destination = .background
        draft.model = "haiku"
        draft.permissionMode = "dontAsk"
        draft.sessionName = "loop-agent-e2e (Claudepit test)"
        let message = draft.message()!
        // The dialog's own arguments, with the test's inline agent before the message.
        var args = draft.backgroundArguments(message: message)
        args.insert(contentsOf: ["--agents", definition], at: args.count - 1)
        print("e2e: claude \(args.dropLast().joined(separator: " ")) “\(message)”")
        let started = run(args)
        let id = started.flatMap { BackgroundSession.jobID(fromOutput: $0.stdout) }
        check(started?.ok == true && id != nil,
              "claude --bg started (\(id ?? started.map { ClaudeCLI.failureMessage(stdout: $0.stdout, stderr: $0.stderr) } ?? "no claude"))")
        guard let id else { return false }

        let scanner = LoopScanner()
        func scan() -> (LoopSnapshot, LoopRecord?)? {
            let dirs = (try? FileManager.default.contentsOfDirectory(at: Paths.projectsRoot, includingPropertiesForKeys: nil)) ?? []
            let files = dirs.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            guard let file = files.first(where: { $0.lastPathComponent.hasPrefix(id) && $0.pathExtension == "jsonl" }) else { return nil }
            let sid = file.deletingPathExtension().lastPathComponent
            let ref = LoopBuilder.SessionRef(id: sid, transcript: file, title: "loop-agent-e2e", cwd: project.path, modifiedAt: Date())
            let snap = scanner.snapshot(sessions: [ref], project: project)
            return (snap, snap.records.first { $0.sessionID == sid && $0.kind == .recurring })
        }
        var record: LoopRecord?
        var stalled: String?
        let start = Date()
        while Date().timeIntervalSince(start) < 300 {
            wait(10)
            guard let (snap, r) = scan() else { print("e2e: no transcript yet"); continue }
            record = r
            if let live = snap.liveSessions.first(where: { $0.jobID == id }), live.isWaiting {
                stalled = live.waitingFor ?? "an answer"
                break
            }
            print("e2e: +\(Int(Date().timeIntervalSince(start)))s " + (r.map { "[\($0.state.rawValue)] fires \($0.fires.count)" } ?? "no loop yet"))
            if let r, r.fires.count >= 2 { break }
        }
        check(stalled == nil, "the session never stopped to wait (\(stalled ?? "it didn't"))")
        if case .agent(let name, _, let mentioned)? = record?.promptKind {
            check(name == agent && !mentioned, "the page reads it as a loop handing each fire to \(name)")
        } else {
            check(false, "the page reads it as an agent loop (got \(String(describing: record?.promptKind)))")
        }
        check((record?.fires.count ?? 0) >= 2, "it fired at least twice (\(record?.fires.count ?? 0))")
        if let r = record, let file = r.transcript {
            // Reports arrive a few seconds after a fire's turn ends; give the last one a moment.
            var reported: LoopIteration.Delegation?
            let readStart = Date()
            while Date().timeIntervalSince(readStart) < 60 {
                let fires = r.fires.filter { $0.promptOffset != nil }
                reported = fires.compactMap { f in f.promptOffset.flatMap { LoopIterationReader.read(file: file, from: $0) } }
                    .flatMap(\.delegations).first { $0.agent == agent && $0.reported }
                if reported != nil { break }
                wait(5)
            }
            check(reported != nil, "a fire's iteration started \(agent) and was followed to its report")
            check(reported?.background == true, "the agent ran in the background")
            check(reported?.result?.lowercased().contains("tick") == true, "its report reads back (“\(reported?.result ?? "nil")”)")
        }
        let stopped = run(["stop", id])
        check(stopped?.ok == true, "claude stop \(id)")
        print(ok ? "agent e2e passed — session \(id)" : "agent e2e FAILED — session \(id)")
        return ok
    }
}
#endif
