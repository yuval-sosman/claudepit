import Foundation
import AppKit
import SwiftUI
import ClaudepitCore

/// What the Loops page shows on the right: the overview, or one loop.
enum LoopSelection: Hashable {
    case overview
    case loop(String)
}

/// What the Loops page remembers between visits.
struct LoopsPageMemory {
    var selection: LoopSelection = .overview
    var query = ""
}

/// A transcript fire to show on the Loops page (the Sessions page's "Loop" link).
struct LoopFocus: Equatable {
    let sessionID: String
    let taskID: String
}

/// A loop started in a new session that the transcript doesn't record yet.
struct LoopLaunch: Equatable, Identifiable {
    /// The session id — or, for a background session, the short id `claude --bg` printed, which
    /// is the session id's first 8 characters (`matches`).
    let sessionID: String
    let message: String
    let startedAt: Date
    var id: String { sessionID }
    func matches(_ sessionID: String?) -> Bool { sessionID.map { $0.hasPrefix(self.sessionID) } ?? false }
}

/// The page's last action, said once.
struct LoopNotice: Equatable, Identifiable {
    enum Level { case info, warning, error }
    let id = UUID()
    let level: Level
    let text: String
}

/// The herdr agent name a loop session gets — derived from its session id, so the page finds the
/// pane of a session it started without storing anything.
enum LoopAgentName {
    static func forSession(_ sessionID: String) -> String { Herdr.agentName("loop-\(sessionID.prefix(8))") }
}

extension AppState {
    /// Rebuild the Loops page's snapshot off the main actor. Coalesced: one trailing rescan when
    /// asked again mid-scan. Published only when something other than the scan time changed —
    /// every view observing `AppState` re-renders on each set.
    func reloadLoops() {
        if isScanningLoops { loopRescanPending = true; return }
        isScanningLoops = true
        let refs = sessions.map {
            LoopBuilder.SessionRef(id: $0.id, transcript: $0.fileURL, title: $0.title, cwd: $0.cwd, modifiedAt: $0.modifiedAt)
        }
        let project = activePath
        let scanner = loopScanner
        Task { [weak self] in
            let snap = await Task.detached(priority: .utility) {
                scanner.snapshot(sessions: refs, project: project)
            }.value
            guard let self else { return }
            self.isScanningLoops = false
            if self.activePath == project {
                var comparable = snap
                comparable.scannedAt = self.loopSnapshot.scannedAt
                if comparable != self.loopSnapshot { self.loopSnapshot = snap }
                // A launch is done once its session's transcript names a loop, or after 15 minutes.
                let recorded = snap.records.compactMap(\.sessionID)
                let kept = self.loopLaunches.filter { launch in
                    !recorded.contains(where: launch.matches) && Date().timeIntervalSince(launch.startedAt) < 900
                }
                if kept != self.loopLaunches { self.loopLaunches = kept }
            }
            if self.loopRescanPending {
                self.loopRescanPending = false
                self.reloadLoops()
            }
            self.syncLoopPolling()
        }
    }

    /// Poll every 30 s while a loop is running or being started and the Loops page (which polls
    /// every 5 s itself) isn't showing; stop when nothing is.
    func syncLoopPolling() {
        let wanted = (loopSnapshot.activeCount > 0 || !loopLaunches.isEmpty) && selected != .loops
        if wanted {
            guard loopPollTimer == nil else { return }
            loopPollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                Task { @MainActor [weak self] in
                    self?.refreshHerdrAgents()
                    self?.reloadLoops()
                }
            }
        } else {
            loopPollTimer?.invalidate()
            loopPollTimer = nil
        }
    }

    /// Loops whose session waits on a prompt, for Home's "needs attention" and the menu bar.
    func loopAttention() -> [LoopAttention] {
        loopSnapshot.records.filter { $0.state == .blocked }.map { r in
            LoopAttention(id: r.id, title: r.title,
                          reason: "Loop waiting for you" + (loopSnapshot.liveSession(r.sessionID)?.waitingFor.map { ": \($0)" } ?? ""),
                          paneID: loopHerdrTarget(sessionID: r.sessionID), since: r.lastActivity)
        }
    }

    /// The sidebar's Loops badge: how many loops need you (red), else how many run (green).
    var loopSidebarBadge: SidebarBadge? {
        let blocked = loopSnapshot.records.filter { $0.state == .blocked }.count
        if blocked > 0 {
            return SidebarBadge(text: "\(blocked)", color: .red,
                                help: "\(blocked) loop\(blocked == 1 ? "" : "s") waiting for you — a session stopped on a prompt")
        }
        let active = loopSnapshot.activeCount
        guard active > 0 else { return nil }
        return SidebarBadge(text: "\(active)", color: .green, help: "\(active) loop\(active == 1 ? "" : "s") running")
    }

    /// The herdr pane hosting a session, when there is one: bound by herdr, or a session the page
    /// started (named after its id).
    func loopHerdrTarget(sessionID: String?) -> String? {
        guard let sessionID else { return nil }
        if let pane = herdrSessions[sessionID]?.paneID { return pane }
        let name = LoopAgentName.forSession(sessionID)
        return herdrAgents.first { $0.name == name }?.paneID
    }

    func noteLoop(_ text: String, _ level: LoopNotice.Level = .info) {
        loopNotice = LoopNotice(level: level, text: text)
    }

    // MARK: Creating

    /// Carry out the New Loop dialog. Returns false (with `loopNotice` saying why) on failure.
    @discardableResult
    func startLoop(_ draft: LoopDraft) async -> Bool {
        guard let message = draft.message() else { return false }
        let cwd = activePath ?? FileManager.default.homeDirectoryForCurrentUser
        switch draft.destination {
        case .newSession, .cloud:
            let sessionID = UUID().uuidString.lowercased()
            var args = draft.claudeArguments(sessionID: sessionID)
            if draft.destination == .cloud {
                // /schedule is a conversation, not a loop: leave the user's own permission mode.
                args = ["--session-id", sessionID, "-n", "schedule: \(LoopPromptKind(prompt: draft.taskText).title.prefix(40))"]
            }
            let ok = await TaskRunner.shared.openLoopSession(
                name: LoopAgentName.forSession(sessionID), cwd: cwd,
                tabLabel: draft.destination == .cloud ? "schedule" : "loop", claudeArgs: args, message: message)
            guard ok else {
                noteLoop("herdr didn't bring Claude up — the command is on the clipboard instead.", .error)
                copyToPasteboard(message)
                return false
            }
            activateHerdrHost()
            if draft.destination == .newSession {
                loopLaunches.append(LoopLaunch(sessionID: sessionID, message: message, startedAt: Date()))
                noteLoop("Started a new session in herdr and sent “\(message.prefix(60))\(message.count > 60 ? "…" : "")”.")
            } else {
                noteLoop("Opened /schedule in a new herdr session — answer its questions there to save the routine.")
            }
            reloadLoops()
            return true
        case .background:
            guard let claude = Executable.find("claude") else {
                noteLoop("Claude Code isn't on this Mac's PATH — copy the command instead.", .error)
                return false
            }
            let result = await Subprocess.run(claude, draft.backgroundArguments(message: message), cwd: cwd,
                                              environment: ClaudeCLI.environment(), timeout: 90)
            guard let result, result.ok, let id = BackgroundSession.jobID(fromOutput: result.stdout) else {
                let why = result.map { ClaudeCLI.failureMessage(stdout: $0.stdout, stderr: $0.stderr) } ?? "claude didn't start"
                noteLoop("The background session didn't start: \(why.prefix(240))", .error)
                return false
            }
            loopLaunches.append(LoopLaunch(sessionID: id, message: message, startedAt: Date()))
            noteLoop("Started background session \(id) and sent “\(message.prefix(50))\(message.count > 50 ? "…" : "")” — "
                     + "\(BackgroundSession.attachCommand(id)) opens it.")
            reloadLoops()
            return true
        case .existingSession(let target, let title):
            guard await Herdr.prompt(agent: target, text: message) else {
                noteLoop("“\(title)” didn't take it — it may be waiting on a question. Answer it first, or copy the command.", .error)
                return false
            }
            noteLoop("Sent to “\(title)”. It runs when that session is idle.")
            reloadLoops()
            return true
        case .copy:
            copyToPasteboard(message)
            noteLoop("Copied — paste it into any Claude Code session.")
            return true
        case .durableFile:
            guard let project = activePath, let cron = draft.cron() else { return false }
            let recurring: Bool
            if case .once = draft.cadence { recurring = false } else { recurring = true }
            do {
                let id = try DurableTaskStore.add(cron: cron, prompt: draft.taskText, recurring: recurring, project: project)
                noteLoop("Saved task \(id) to .claude/scheduled_tasks.json.")
                reloadLoops()
                return true
            } catch {
                noteLoop(error.localizedDescription, .error)
                return false
            }
        }
    }

    // MARK: Acting on a loop

    /// Stop a loop the way its kind allows: a durable task leaves the file; a cron task in a live
    /// herdr session is cancelled by asking for CronDelete; a self-paced loop waiting in an idle
    /// session gets Esc (the documented stop), or a stop request when the session is busy —
    /// Esc then would interrupt the turn instead.
    func stopLoop(_ r: LoopRecord) async {
        if r.kind == .durable, let id = r.taskID, let project = activePath {
            do {
                try DurableTaskStore.remove(id: id, project: project)
                noteLoop("Removed task \(id) from .claude/scheduled_tasks.json.")
            } catch { noteLoop(error.localizedDescription, .error) }
            reloadLoops()
            return
        }
        guard let target = loopHerdrTarget(sessionID: r.sessionID) else {
            noteLoop("This session isn't open in herdr — ask it to stop, or press Esc there.", .warning)
            return
        }
        let live = loopSnapshot.liveSession(r.sessionID)
        let ok: Bool
        if r.kind == .selfPaced, live?.isIdle == true, r.state == .scheduled {
            ok = await Herdr.sendKeys(agent: target, keys: ["esc"])
            if ok { noteLoop("Pressed Esc in the session — that clears a self-paced loop's pending wakeup.") }
        } else if r.kind == .selfPaced {
            ok = await Herdr.prompt(agent: target, text: "Stop the /loop: call ScheduleWakeup with stop: true and don't schedule another iteration.")
            if ok { noteLoop("Asked the session to stop the loop — it does so when its turn ends.") }
        } else if let id = r.taskID {
            ok = await Herdr.prompt(agent: target, text: "Cancel the scheduled task \(id) with CronDelete, and reply with one line.")
            if ok { noteLoop("Asked the session to cancel task \(id) — it does so when it's idle.") }
        } else {
            ok = false
        }
        if !ok { noteLoop("The session didn't take it — it may be waiting on a question.", .error) }
        reloadLoops()
    }

    /// Resume a closed session in herdr — which brings back its cron loops that haven't expired.
    func resumeLoopSession(_ r: LoopRecord) {
        guard let sid = r.sessionID else { return }
        let cwd = r.cwd ?? activePath?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        Task {
            // Always a fresh `claude --resume`: a pane still bound to this (closed) session would only
            // be focused, and nothing would come back.
            await WorktreeResumer.resume(sessionID: sid, cwd: cwd, label: "resume", existingPaneID: nil)
            activateHerdrHost()
            noteLoop("Resuming the session in herdr — its unexpired cron loops come back with it.")
        }
    }

    /// Open a loop's background session in a new herdr tab: `claude attach <id>` — where its
    /// prompts can be answered and the loop talked to.
    func attachBackgroundSession(_ r: LoopRecord) {
        guard let id = loopSnapshot.liveSession(r.sessionID)?.jobID else { return }
        let cwd = r.cwd ?? activePath?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        Task {
            let dir = URL(filePath: cwd)
            guard let obj = await Herdr.runJSON(["tab", "create", "--cwd", cwd, "--label", "attach \(id)", "--focus"], cwd: dir),
                  let pane = Herdr.rootPaneID(fromJSON: obj) else {
                noteLoop("herdr didn't open a tab — run \(BackgroundSession.attachCommand(id)) in a terminal.", .error)
                return
            }
            _ = await Herdr.run(["pane", "run", pane, "claude", "attach", id], cwd: dir)
            activateHerdrHost()
            noteLoop("Attached to background session \(id) in herdr. Leaving that tab leaves the session running.")
        }
    }

    /// `claude stop <id>`: ends the background session — every loop in it — and keeps its
    /// conversation, so `claude --resume` (Resume, on the page) brings cron loops back.
    func stopBackgroundSession(_ r: LoopRecord) async {
        guard let id = loopSnapshot.liveSession(r.sessionID)?.jobID, let claude = Executable.find("claude") else { return }
        let result = await Subprocess.run(claude, ["stop", id], environment: ClaudeCLI.environment(), timeout: 60)
        if let result, result.ok {
            noteLoop("Stopped background session \(id). Resume it to bring its cron loops back.")
        } else {
            let why = result.map { ClaudeCLI.failureMessage(stdout: $0.stdout, stderr: $0.stderr) } ?? "claude didn't run"
            noteLoop("claude stop \(id) failed: \(why.prefix(200))", .error)
        }
        reloadLoops()
    }

    /// Why `/schedule` won't be offered by this Claude Code, from its login (docs: it needs a
    /// claude.ai subscription login — not an API key, a profile, or a cloud provider).
    var loopScheduleUnavailable: String? {
        guard let auth = claudeAuth else { return nil }
        if auth.needsSignIn { return "Claude Code is signed out." }
        if let method = auth.authMethod, method != "claude.ai" { return "Claude Code is signed in with \(method), not claude.ai." }
        return nil
    }

    func focusLoopSession(_ r: LoopRecord) {
        guard let target = loopHerdrTarget(sessionID: r.sessionID) else { return }
        let cwd = r.cwd ?? activePath?.path ?? "/"
        Task {
            if await WorktreeResumer.focusPane(paneID: target, cwd: cwd) { activateHerdrHost() }
        }
    }

    /// Open `loop.md` in the default editor, writing the starter template first when it is missing.
    func openLoopFile(_ scope: LoopFile.Scope) {
        guard let url = LoopFile.url(scope, project: activePath) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (LoopFile.template + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
        reloadLoops()
    }

    /// Write a loop.md from the overview's editor — refused (`LoopFile.SaveError`) when the file
    /// isn't what the edit started from, unless `force`.
    func saveLoopFile(_ scope: LoopFile.Scope, text: String, base: String?, force: Bool) throws {
        guard let url = LoopFile.url(scope, project: activePath) else { throw CocoaError(.fileNoSuchFile) }
        try LoopFile.save(text, to: url, base: base, force: force)
        let name = scope == .project ? "this project's loop.md" : "your loop.md"
        noteLoop(base == nil ? "Wrote \(name) — a bare /loop runs it from its next iteration."
                             : "Saved \(name) — the next iteration reads it.")
        reloadLoops()
    }

    /// Move a loop.md to the Trash (the page has confirmed).
    func trashLoopFile(_ file: LoopFile) {
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            noteLoop("Moved \(file.scope == .project ? "this project's" : "your") loop.md to the Trash.")
        } catch {
            noteLoop("Couldn't move loop.md to the Trash: \(error.localizedDescription)", .error)
        }
        reloadLoops()
    }

    func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// Skills and commands a loop could run, keyed by `/name`, with whether Claude may invoke them
    /// on its own — the dialog warns about the rest.
    func loopCommandAvailability() -> [String: CommandAvailability] {
        var out: [String: CommandAvailability] = [:]
        for s in store.skills {
            let disabled = (s.meta["disable-model-invocation"] ?? "").lowercased() == "true"
            let name = s.origin.pluginID.map { "/\($0.split(separator: "@").first ?? ""):\(s.id)" } ?? "/\(s.id)"
            out[name] = CommandAvailability(
                modelInvocable: !disabled && s.skillEnabled,
                reason: disabled ? "disable-model-invocation: true" : s.skillEnabled ? nil : "hidden from Claude by skillOverrides",
                description: s.description)
        }
        for c in store.commands {
            let name = c.origin.pluginID.map { "/\($0.split(separator: "@").first ?? ""):\(c.id)" } ?? "/\(c.id)"
            let disabled = (c.meta["disable-model-invocation"] ?? "").lowercased() == "true"
            if out[name] == nil {
                out[name] = CommandAvailability(modelInvocable: !disabled,
                                                reason: disabled ? "disable-model-invocation: true" : nil,
                                                description: c.description)
            }
        }
        return out
    }

    /// The project's and the user's agent files (the project's wins a name both define), for the
    /// dialog's Agent task and a new session's `--agent`.
    func loopAgents() -> [LoopAgent] {
        var out: [LoopAgent] = []
        for a in store.agents where !a.isOverridden {
            let plugin: String? = a.origin.pluginID.map { String($0.split(separator: "@").first ?? "") }
            let scope: String = plugin ?? (a.scope == .project || a.scope == .local ? "project" : "user")
            var agent = LoopAgent(name: a.id, meta: a.meta, scope: scope)
            if let plugin { agent.name = "\(plugin):\(agent.name)" }
            out.append(agent)
        }
        // The project's first, then yours, each by name.
        return out.sorted { a, b in
            let pa = a.scope == "project", pb = b.scope == "project"
            return pa != pb ? pa : a.name < b.name
        }
    }

    /// Live Claude sessions in herdr in this project, to send a loop to.
    func loopSessionTargets() -> [(target: String, title: String, status: String)] {
        let projectPath = activePath?.path(percentEncoded: false)
        return herdrAgents.compactMap { a in
            guard a.kind == nil || a.kind == "claude",
                  let cwd = a.cwd, projectPath.map({ cwd == $0 || cwd.hasPrefix($0 + "/") }) ?? true else { return nil }
            let title = a.name.map { $0.hasPrefix("loop-") ? "\($0) (\(a.title ?? "loop"))" : $0 } ?? a.title ?? a.paneID
            return (a.paneID, title, a.status)
        }
    }
}
