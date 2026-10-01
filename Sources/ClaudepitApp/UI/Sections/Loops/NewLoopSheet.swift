import SwiftUI
import AppKit
import ClaudepitCore

/// What the New Loop dialog knows about the machine and project.
struct NewLoopContext {
    var capabilities = LoopCapabilities()
    var loopFile: LoopFile?
    var herdrAvailable = true
    var commands: [String: CommandAvailability] = [:]
    /// The project's and the user's agent files.
    var agents: [LoopAgent] = []
    /// `claude` is on PATH — a background session runs it directly.
    var claudeAvailable = true
    /// Why `/schedule` isn't there for this login (nil when it should be).
    var scheduleUnavailable: String?
    /// Claude sessions open in herdr in this project: pane, name, status.
    var targets: [(target: String, title: String, status: String)] = []
    var hasProject = true
    var projectName: String?
}

/// The New Loop dialog: what Claude should do, when, and where it runs — on the left; on the right,
/// exactly what will be sent, the schedule it becomes, its next fires, how long it lives, and every
/// caveat the docs attach to the combination, with one-click fixes. The decisions are Core's
/// (`LoopDraft.preview`); this view only edits the draft and shows them.
struct NewLoopSheet: View {
    let context: NewLoopContext
    /// Carry the draft out; return false to keep the dialog open (the page says why).
    let onSubmit: (LoopDraft) async -> Bool
    var onOpenLoopFile: (LoopFile.Scope) -> Void = { _ in }
    var onClose: () -> Void = {}

    enum TaskMode: String, CaseIterable, Identifiable {
        case prompt = "Prompt", command = "Skill or command", agent = "Agent", defaultPrompt = "Default prompt"
        var id: String { rawValue }
    }
    enum CadenceMode: String, CaseIterable, Identifiable {
        case interval = "Every…", selfPaced = "Claude decides", cron = "Cron", once = "Once"
        var id: String { rawValue }
    }
    enum DestinationMode: String, CaseIterable, Identifiable {
        case newSession, background, existing, copy, durable, cloud
        var id: String { rawValue }
    }

    @State private var taskMode: TaskMode = .prompt
    @State private var prompt = ""
    @State private var commandName = ""
    @State private var commandArgs = ""
    @State private var agentName = ""
    @State private var agentTask = ""
    @State private var agentSkip = true
    /// A new session's `--agent`.
    @State private var sessionAgent: String?
    @State private var cadenceMode: CadenceMode = .interval
    @State private var intervalValue = "10"
    @State private var intervalUnit: LoopInterval.Unit = .m
    @State private var cronFields = ["*/30", "*", "*", "*", "*"]
    @State private var onceDate = Date().addingTimeInterval(3600)
    @State private var destinationMode: DestinationMode = .newSession
    @State private var existingTarget: String?
    @State private var permissionMode: String? = "auto"
    @State private var model: String?
    @State private var sessionName = ""
    @State private var submitting = false
    @FocusState private var promptFocused: Bool

    init(context: NewLoopContext, seed: LoopDraft? = nil, onSubmit: @escaping (LoopDraft) async -> Bool,
         onOpenLoopFile: @escaping (LoopFile.Scope) -> Void = { _ in }, onClose: @escaping () -> Void = {}) {
        self.context = context
        self.onSubmit = onSubmit
        self.onOpenLoopFile = onOpenLoopFile
        self.onClose = onClose
        let d = seed ?? LoopDraft()
        switch d.task {
        case .prompt(let p): _taskMode = State(initialValue: .prompt); _prompt = State(initialValue: p)
        case .command(let n, let a):
            _taskMode = State(initialValue: .command); _commandName = State(initialValue: n); _commandArgs = State(initialValue: a)
        case .agent(let n, let t, let skip):
            _taskMode = State(initialValue: .agent); _agentName = State(initialValue: n)
            _agentTask = State(initialValue: t); _agentSkip = State(initialValue: skip)
        case .defaultPrompt: _taskMode = State(initialValue: .defaultPrompt)
        }
        switch d.cadence {
        case .interval(let i):
            _cadenceMode = State(initialValue: .interval)
            _intervalValue = State(initialValue: "\(i.value)"); _intervalUnit = State(initialValue: i.unit)
        case .selfPaced: _cadenceMode = State(initialValue: .selfPaced)
        case .cron(let c):
            _cadenceMode = State(initialValue: .cron)
            let f = c.split(whereSeparator: \.isWhitespace).map(String.init)
            _cronFields = State(initialValue: f.count == 5 ? f : ["*/30", "*", "*", "*", "*"])
        case .once(let date): _cadenceMode = State(initialValue: .once); _onceDate = State(initialValue: date)
        }
        switch d.destination {
        case .newSession: _destinationMode = State(initialValue: context.herdrAvailable ? .newSession : .copy)
        case .background: _destinationMode = State(initialValue: context.claudeAvailable ? .background : .copy)
        case .existingSession(let t, _): _destinationMode = State(initialValue: .existing); _existingTarget = State(initialValue: t)
        case .copy: _destinationMode = State(initialValue: .copy)
        case .durableFile: _destinationMode = State(initialValue: context.capabilities.durable.isKnownOff ? .copy : .durable)
        case .cloud: _destinationMode = State(initialValue: .cloud)
        }
        _permissionMode = State(initialValue: d.permissionMode)
        _model = State(initialValue: d.model)
        _sessionName = State(initialValue: d.sessionName)
        _sessionAgent = State(initialValue: d.sessionAgent)
    }

    /// The draft the controls describe.
    var draft: LoopDraft {
        var d = LoopDraft()
        switch taskMode {
        case .prompt: d.task = .prompt(prompt)
        case .command: d.task = .command(name: commandName, args: commandArgs)
        case .agent: d.task = .agent(name: agentName, task: agentTask, skipWhileRunning: agentSkip)
        case .defaultPrompt: d.task = .defaultPrompt
        }
        switch cadenceMode {
        case .interval:
            // Clamped: a value nobody means would otherwise reach the interval math from a view body.
            let n = min(Int(intervalValue.trimmingCharacters(in: .whitespaces)) ?? 0, 99_999)
            d.cadence = .interval(LoopInterval(n, intervalUnit))
        case .selfPaced: d.cadence = .selfPaced
        case .cron: d.cadence = .cron(cronFields.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "*" : $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))
        case .once: d.cadence = .once(onceDate)
        }
        switch destinationMode {
        case .newSession: d.destination = .newSession
        case .background: d.destination = .background
        case .existing:
            let t = context.targets.first { $0.target == existingTarget } ?? context.targets.first
            d.destination = t.map { .existingSession(target: $0.target, title: $0.title) } ?? .copy
        case .copy: d.destination = .copy
        case .durable: d.destination = .durableFile
        case .cloud: d.destination = .cloud
        }
        d.permissionMode = permissionMode
        d.model = model
        d.sessionName = sessionName
        d.sessionAgent = destinationMode == .newSession || destinationMode == .background ? sessionAgent : nil
        return d
    }

    var body: some View {
        let d = draft
        let preview = d.preview(in: draftContext())
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        taskSection
                        cadenceSection
                        destinationSection
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(minWidth: 400, maxWidth: .infinity)
                Divider().opacity(0.2)
                ScrollView {
                    previewColumn(d, preview).padding(18)
                }
                .frame(width: 380)
                .background(.black.opacity(0.08))
            }
            Divider().opacity(0.2)
            footer(d, preview)
        }
        .background(.ultraThinMaterial)
        .onAppear { if taskMode == .prompt && prompt.isEmpty { promptFocused = true } }
    }

    /// What the preview knows about this machine and project.
    private func draftContext() -> LoopDraftContext {
        var c = LoopDraftContext(now: Date(), capabilities: context.capabilities, loopFile: context.loopFile,
                                 herdrAvailable: context.herdrAvailable, commands: context.commands, agents: context.agents)
        c.scheduleUnavailable = context.scheduleUnavailable
        return c
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.trianglehead.2.clockwise").font(.system(size: 15)).foregroundStyle(.blue)
            Text("New Loop").font(.headline)
            if let p = context.projectName { Text(p).font(.caption).foregroundStyle(.tertiary) }
            Spacer()
            Menu {
                ForEach(LoopTemplate.all) { t in
                    Button { apply(t) } label: { Label(t.title, systemImage: t.icon) }
                }
            } label: {
                Label("Start from…", systemImage: "sparkles").font(.caption)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Fill the dialog from a common loop")
            .debugFrame("loop-templates")
            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: What

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("1", "What should Claude do each time?")
            Picker("", selection: $taskMode) {
                ForEach(TaskMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .debugFrame("loop-task-mode")
            switch taskMode {
            case .prompt:
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $prompt)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .focused($promptFocused)
                        .frame(minHeight: 84, maxHeight: 140)
                        .padding(6)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12)))
                        .debugFrame("loop-prompt")
                    if prompt.isEmpty {
                        Text("e.g. check whether CI passed and address any review comments")
                            .font(.callout).foregroundStyle(.tertiary)
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                Text("Written as if you typed it. Each fire sends it to the same session, which keeps its context — say what to check and what to do about it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .command:
                HStack(spacing: 8) {
                    TextField("/review-pr", text: $commandName)
                        .textFieldStyle(.roundedBorder).font(.callout.monospaced()).frame(width: 190)
                    Menu {
                        ForEach(context.commands.keys.sorted(), id: \.self) { name in
                            let info = context.commands[name]!
                            Button { commandName = name } label: {
                                Text(info.modelInvocable ? name : "\(name) — Claude can't run it")
                            }
                        }
                    } label: { Image(systemName: "list.bullet") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(context.commands.isEmpty)
                    .help("Pick one of this project's skills and commands")
                    TextField("arguments", text: $commandArgs).textFieldStyle(.roundedBorder).font(.callout.monospaced())
                }
                Text("Re-runs a skill or command at every fire. Claude can only run ones it may invoke itself — built-in commands, MCP prompts and skills marked disable-model-invocation arrive as plain text.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .agent:
                agentTaskEditor
            case .defaultPrompt:
                if let file = context.loopFile {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            Text("\(file.scope == .project ? "This project's" : "Your") loop.md")
                                .font(.callout.weight(.semibold))
                            Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                                .font(.caption).foregroundStyle(.tertiary)
                            Spacer()
                            Button("Open") { NSWorkspace.shared.open(file.url) }.buttonStyle(.link).font(.caption)
                        }
                        Text(file.preview.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        Text("Its tasks run at every fire; edits apply from the next iteration.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The built-in maintenance prompt: continue unfinished work, tend this branch's PR (review comments, failed CI, conflicts), then cleanup passes. It never starts new initiatives.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if context.hasProject {
                            Button("Write a loop.md for this project instead…") { onOpenLoopFile(.project) }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                }
            }
        }
    }

    /// Which agent each fire hands the work to, and what to ask of it.
    private var agentTaskEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("code-reviewer", text: $agentName)
                    .textFieldStyle(.roundedBorder).font(.callout.monospaced()).frame(width: 190)
                    .debugFrame("loop-agent-name")
                Menu {
                    if !context.agents.isEmpty {
                        SwiftUI.Section("Agent files") {
                            ForEach(context.agents) { a in
                                Button { agentName = a.name } label: { Text(a.scope == "project" ? a.name : "\(a.name) (\(a.scope))") }
                            }
                        }
                    }
                    SwiftUI.Section("Built into Claude Code") {
                        ForEach(LoopAgent.builtIns) { a in Button(a.name) { agentName = a.name } }
                    }
                } label: { Image(systemName: "list.bullet") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Pick one of this project's or your agents")
                .debugFrame("loop-agent-menu")
                if let a = agentInfo(agentName) {
                    Text(agentFacts(a)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .help(a.description)
                }
                Spacer(minLength: 0)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $agentTask)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 64, maxHeight: 120)
                    .padding(6)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12)))
                    .debugFrame("loop-agent-task")
                if agentTask.isEmpty {
                    Text("e.g. review what changed since the last run and list anything risky")
                        .font(.callout).foregroundStyle(.tertiary)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            Toggle("Skip a fire while the last run is still going", isOn: $agentSkip)
                .toggleStyle(.checkbox).font(.caption)
                .debugFrame("loop-agent-skip")
            Text("Each fire asks Claude to “use the \(agentName.isEmpty ? "…" : agentName) subagent to …”, naming it in words, which works on every fire. An @agent- mention doesn't survive a fire.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func agentInfo(_ name: String) -> LoopAgent? {
        let n = name.trimmingCharacters(in: .whitespaces)
        return context.agents.first { $0.name == n } ?? LoopAgent.builtIns.first { $0.name == n }
    }

    /// "sonnet · Read, Grep, Glob" — what a run of it brings.
    private func agentFacts(_ a: LoopAgent) -> String {
        if a.isBuiltIn { return a.description }
        return [a.model, a.toolSummary].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: When

    private var cadenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("2", "When?")
            Picker("", selection: $cadenceMode) {
                ForEach(CadenceMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .debugFrame("loop-cadence-mode")
            switch cadenceMode {
            case .interval:
                HStack(spacing: 8) {
                    Text("Every").font(.callout)
                    TextField("10", text: $intervalValue)
                        .textFieldStyle(.roundedBorder).font(.callout.monospacedDigit()).frame(width: 64)
                        .multilineTextAlignment(.center)
                        .debugFrame("loop-interval")
                    Picker("", selection: $intervalUnit) {
                        ForEach(LoopInterval.Unit.allCases, id: \.self) { u in Text(u.word + "s").tag(u) }
                    }
                    .labelsHidden().fixedSize()
                }
                FlowLayout(spacing: 6) {
                    ForEach(["1m", "5m", "10m", "15m", "30m", "1h", "2h", "6h", "1d"], id: \.self) { token in
                        chip(token, on: "\(intervalValue)\(intervalUnit.rawValue)" == token) {
                            if let i = LoopInterval(token: token) { intervalValue = "\(i.value)"; intervalUnit = i.unit }
                        }
                    }
                }
            case .selfPaced:
                Text("No interval: Claude runs it now, then after each iteration picks how long to wait — short while something is moving, longer when it's quiet — and can end the loop once the work is done.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .cron:
                HStack(alignment: .top, spacing: 6) {
                    ForEach(0..<5, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(["Minute", "Hour", "Day", "Month", "Weekday"][i]).font(.caption2).foregroundStyle(.secondary)
                            TextField("*", text: $cronFields[i])
                                .textFieldStyle(.roundedBorder).font(.callout.monospaced())
                                .multilineTextAlignment(.center)
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(cronFieldInvalid(i) ? Color.red.opacity(0.7) : .clear))
                        }
                    }
                }
                FlowLayout(spacing: 6) {
                    chip("Hourly at :07") { cronFields = ["7", "*", "*", "*", "*"] }
                    chip("Every 30 min") { cronFields = ["*/30", "*", "*", "*", "*"] }
                    chip("Weekdays 9:03") { cronFields = ["3", "9", "*", "*", "1-5"] }
                    chip("Daily 8:57") { cronFields = ["57", "8", "*", "*", "*"] }
                    chip("Mondays 10:07") { cronFields = ["7", "10", "*", "*", "1"] }
                }
                Text("Local time. Fields take *, */N, N, A-B, A-B/N and lists; weekdays are 0–6 (Sunday 0 or 7). No names, no L/W/?. If day and weekday are both set, either matches.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .once:
                HStack(spacing: 8) {
                    DatePicker("", selection: $onceDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                    Spacer(minLength: 0)
                }
                FlowLayout(spacing: 6) {
                    chip("In 30 min") { onceDate = Date().addingTimeInterval(1800) }
                    chip("In 1 hour") { onceDate = Date().addingTimeInterval(3600) }
                    chip("In 3 hours") { onceDate = Date().addingTimeInterval(3 * 3600) }
                    chip("Tomorrow 9:03") {
                        let cal = Calendar.current
                        let t = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                        onceDate = cal.date(bySettingHour: 9, minute: 3, second: 0, of: t) ?? t
                    }
                }
            }
        }
    }

    private func cronFieldInvalid(_ i: Int) -> Bool {
        let f = cronFields[i].trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return false }
        return CronExpression.parseFieldIsValid(f, index: i) == false
    }

    // MARK: Where

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("3", "Where does it run?")
            VStack(alignment: .leading, spacing: 4) {
                destinationRow(.newSession, title: "A new Claude session in herdr", icon: "plus.rectangle.on.rectangle",
                               detail: context.herdrAvailable ? "Opens a tab in the project and sends the command. The loop lives as long as that session."
                                                              : "herdr isn't installed.",
                               enabled: context.herdrAvailable)
                if destinationMode == .newSession { newSessionOptions.padding(.leading, 30).padding(.bottom, 6) }
                destinationRow(.background, title: "A background session (no terminal)", icon: "server.rack",
                               detail: context.claudeAvailable
                                ? "claude --bg: keeps firing after you close the terminal or Claudepit, and across sleep. Attach from this page to answer a prompt."
                                : "Claude Code isn't on this Mac's PATH.",
                               enabled: context.claudeAvailable)
                if destinationMode == .background { newSessionOptions.padding(.leading, 30).padding(.bottom, 6) }
                destinationRow(.existing, title: "A session already open in herdr", icon: "rectangle.and.text.magnifyingglass",
                               detail: context.targets.isEmpty ? "None open in this project." : "Sends the command to it as a message.",
                               enabled: !context.targets.isEmpty)
                if destinationMode == .existing, !context.targets.isEmpty {
                    Picker("", selection: Binding(get: { existingTarget ?? context.targets.first?.target },
                                                  set: { existingTarget = $0 })) {
                        ForEach(context.targets, id: \.target) { t in
                            Text("\(t.title) — \(t.status)").tag(Optional(t.target))
                        }
                    }
                    .labelsHidden().frame(maxWidth: 360).padding(.leading, 30).padding(.bottom, 6)
                }
                destinationRow(.copy, title: "Copy the command", icon: "doc.on.clipboard",
                               detail: "Paste it into any Claude Code session — a terminal, an IDE, the desktop app.", enabled: true)
                destinationRow(.durable, title: "Save to .claude/scheduled_tasks.json", icon: "doc.badge.clock",
                               detail: context.capabilities.durable.isKnownOff
                                ? "Off: this Claude Code has durable tasks switched off, so it never reads that file."
                                : "Durable: survives restarts, runs while a session is open in this folder.",
                               enabled: context.hasProject && !context.capabilities.durable.isKnownOff)
                destinationRow(.cloud, title: "A cloud routine (/schedule)", icon: "cloud",
                               detail: "Runs on Anthropic's cloud even with this Mac off — hourly at most, from a fresh clone.",
                               enabled: context.herdrAvailable)
            }
        }
    }

    private var newSessionOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Permissions").font(.caption).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                Picker("", selection: $permissionMode) {
                    ForEach(LoopDraft.permissionModes, id: \.id) { m in Text(m.label).tag(Optional(m.id)) }
                }
                .labelsHidden().fixedSize()
                .debugFrame("loop-permission")
            }
            HStack(spacing: 8) {
                Text("Model").font(.caption).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                Picker("", selection: $model) {
                    ForEach(LoopDraft.models, id: \.label) { m in Text(m.label).tag(m.id) }
                }
                .labelsHidden().fixedSize()
            }
            HStack(spacing: 8) {
                Text("Name").font(.caption).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                TextField(draft.effectiveSessionName, text: $sessionName).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }
            if !context.agents.isEmpty || sessionAgent != nil {
                HStack(spacing: 8) {
                    Text("Run as").font(.caption).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                    Picker("", selection: $sessionAgent) {
                        Text("Claude Code (no agent)").tag(String?.none)
                        ForEach(context.agents) { a in Text(a.name).tag(Optional(a.name)) }
                        if let s = sessionAgent, !context.agents.contains(where: { $0.name == s }) { Text(s).tag(Optional(s)) }
                    }
                    .labelsHidden().fixedSize()
                    .help("claude --agent: the whole session takes on the agent's instructions, tools and model")
                    .debugFrame("loop-session-agent")
                    if let a = sessionAgent.flatMap(agentInfo) {
                        Text(agentFacts(a)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
            }
        }
    }

    private func destinationRow(_ mode: DestinationMode, title: String, icon: String, detail: String, enabled: Bool) -> some View {
        Button { destinationMode = mode } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: destinationMode == mode ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13)).foregroundStyle(destinationMode == mode ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5).padding(.horizontal, 6)
            .background(destinationMode == mode ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .debugFrame("loop-dest-\(mode.rawValue)")
    }

    // MARK: Preview

    private func previewColumn(_ d: LoopDraft, _ p: LoopPreview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(previewTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if let text = shownText(d, p) {
                        Button("Copy") { copy(text) }.buttonStyle(.link).font(.caption)
                    }
                }
                Text(shownText(d, p) ?? "—")
                    .font(.callout.monospaced())
                    .foregroundStyle(p.message == nil ? .tertiary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .debugFrame("loop-preview-message")
            }
            if !p.cadence.isEmpty || p.runsNow {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Schedule").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(p.cadence.isEmpty ? "—" : p.cadence).font(.callout)
                        if let cron = p.cron, cron != p.cadence {
                            Text(cron).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if p.runsNow { fireLine("Now", "first run, as soon as it's sent") }
                        ForEach(Array(p.nextFires.prefix(p.runsNow ? 4 : 5).enumerated()), id: \.offset) { _, date in
                            fireLine(LoopTime.clock(date), LoopTime.until(date, now: Date()))
                        }
                        if case .selfPaced = d.cadence { fireLine("Then", "after each run, a delay Claude picks (1 min – 1 h)") }
                    }
                    if let note = p.scheduleNote {
                        Text(note).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let delay = p.maxDelay {
                        Text("Each may start up to \(LoopCadence.duration(delay)) late — a fixed offset per task (from its id), so loops don't all fire at once.")
                            .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let exp = p.expiresAt {
                        Text(d.cadence == .selfPaced
                             ? "Ends by \(LoopTime.clock(exp)) at the latest — the 7-day expiry holds for self-paced loops too."
                             : "Lasts until \(LoopTime.clock(exp)) (7 days), then fires once more and deletes itself.")
                            .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !p.notes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Good to know").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(p.notes) { note in LoopNoteRow(note: note) { apply($0) } }
                }
            }
        }
    }

    private var previewTitle: String {
        switch destinationMode {
        case .newSession, .background, .existing: return "Claude receives"
        case .copy: return "Copied to paste"
        case .durable: return "Added to .claude/scheduled_tasks.json"
        case .cloud: return "Sent to a new session"
        }
    }

    /// The durable destination writes a task, not a message — show the task.
    private func shownText(_ d: LoopDraft, _ p: LoopPreview) -> String? {
        if destinationMode == .durable {
            guard let cron = d.cron(), !d.taskText.isEmpty else { return nil }
            var recurring = true
            if case .once = d.cadence { recurring = false }
            return "{ \"cron\": \"\(cron)\", \"prompt\": \(LoopDraft.jsonString(d.taskText))\(recurring ? ", \"recurring\": true" : "") }"
        }
        return p.message
    }

    private func fireLine(_ when: String, _ detail: String) -> some View {
        HStack(spacing: 8) {
            Text(when).font(.caption.monospacedDigit().weight(.semibold)).frame(width: 96, alignment: .leading)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private func footer(_ d: LoopDraft, _ p: LoopPreview) -> some View {
        HStack(spacing: 10) {
            if let blocking = p.notes.first(where: { $0.level == .error }) {
                Image(systemName: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
                Text(blocking.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text(summary(d)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Cancel") { onClose() }.buttonStyle(.plain).foregroundStyle(.secondary).font(.callout)
            if submitting {
                ProgressView().controlSize(.small).padding(.horizontal, 12)
            } else {
                Button(primaryLabel) { submit(d) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!p.canSubmit)
                    .help(p.canSubmit ? "⌘↩" : "Resolve the red note first")
                    .debugFrame("loop-submit")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    /// One line on what pressing the button does.
    private func summary(_ d: LoopDraft) -> String {
        let place = context.projectName.map { " in \($0)" } ?? ""
        switch destinationMode {
        case .newSession:
            let mode = LoopDraft.permissionModes.first { $0.id == permissionMode }?.label ?? "default"
            let agent = d.sessionAgent.map { " --agent \($0)" } ?? ""
            return "Opens a herdr tab\(place) running claude\(agent) -n “\(d.effectiveSessionName)” (\(mode.lowercased()) permissions) and sends it."
        case .background:
            let mode = LoopDraft.permissionModes.first { $0.id == permissionMode }?.label ?? "default"
            let agent = d.sessionAgent.map { " --agent \($0)" } ?? ""
            return "Starts claude --bg\(agent) -n “\(d.effectiveSessionName)”\(place) (\(mode.lowercased()) permissions) and sends it — no terminal."
        case .existing:
            let title = context.targets.first { $0.target == (existingTarget ?? context.targets.first?.target) }?.title ?? "the session"
            return "Sends it to “\(title)” as if you typed it."
        case .copy: return "Copies it — nothing is sent."
        case .durable: return "Adds one task to .claude/scheduled_tasks.json\(place)."
        case .cloud: return "Opens a herdr tab\(place) and sends /schedule — it asks before saving the routine."
        }
    }

    private var primaryLabel: String {
        switch destinationMode {
        case .newSession: return "Start in herdr"
        case .background: return "Start in Background"
        case .existing: return "Send to Session"
        case .copy: return "Copy Command"
        case .durable: return "Save Task"
        case .cloud: return "Open /schedule in herdr"
        }
    }

    private func submit(_ d: LoopDraft) {
        submitting = true
        Task {
            let ok = await onSubmit(d)
            submitting = false
            if ok { onClose() }
        }
    }

    // MARK: Pieces

    private func sectionTitle(_ n: String, _ s: String) -> some View {
        HStack(spacing: 8) {
            Text(n).font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 18, height: 18).background(.white.opacity(0.08), in: Circle())
            Text(s).font(.callout.weight(.semibold))
        }
    }

    private func chip(_ label: String, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.caption.monospaced())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(on ? Color.accentColor : .secondary)
                .background(on ? Color.accentColor.opacity(0.16) : .white.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .debugFrame("loop-chip-\(label)")
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func apply(_ fix: LoopPreview.Fix) {
        switch fix {
        case .interval(let i):
            cadenceMode = .interval; intervalValue = "\(i.value)"; intervalUnit = i.unit
        case .cron(let c):
            cadenceMode = .cron
            let f = c.split(whereSeparator: \.isWhitespace).map(String.init)
            if f.count == 5 { cronFields = f }
        case .permissionMode(let m):
            permissionMode = m
        case .cadence(let c):
            switch c {
            case .interval(let i): cadenceMode = .interval; intervalValue = "\(i.value)"; intervalUnit = i.unit
            case .selfPaced: cadenceMode = .selfPaced
            case .cron(let s): apply(.cron(s))
            case .once(let d): cadenceMode = .once; onceDate = d
            }
        case .task(let t):
            switch t {
            case .prompt(let p): taskMode = .prompt; prompt = p
            case .command(let n, let a): taskMode = .command; commandName = n; commandArgs = a
            case .agent(let n, let task, let skip): taskMode = .agent; agentName = n; agentTask = task; agentSkip = skip
            case .defaultPrompt: taskMode = .defaultPrompt
            }
        case .sessionAgent(let a):
            sessionAgent = a
        case .model(let m):
            model = m
        case .destination(let dest):
            switch dest {
            case .cloud: destinationMode = .cloud
            case .copy: destinationMode = .copy
            case .durableFile: destinationMode = .durable
            case .newSession: destinationMode = .newSession
            case .background: destinationMode = .background
            case .existingSession(let t, _): destinationMode = .existing; existingTarget = t
            }
        }
    }

    private func apply(_ t: LoopTemplate) {
        taskMode = t.taskMode
        prompt = t.prompt
        cadenceMode = t.cadence
        if let i = t.interval { intervalValue = "\(i.value)"; intervalUnit = i.unit }
        if let c = t.cron { cronFields = c.split(separator: " ").map(String.init) }
        if t.cadence == .once { onceDate = Date().addingTimeInterval(3600) }
    }
}

/// The dialog's "Start from…" menu: loops the docs use as examples.
struct LoopTemplate: Identifiable {
    let title: String
    let icon: String
    let taskMode: NewLoopSheet.TaskMode
    let prompt: String
    let cadence: NewLoopSheet.CadenceMode
    var interval: LoopInterval? = nil
    var cron: String? = nil
    var id: String { title }

    static let all: [LoopTemplate] = [
        LoopTemplate(title: "Babysit this branch's PR", icon: "checkmark.seal", taskMode: .prompt,
                     prompt: "Check whether CI passed and address any new review comments. If everything is green and quiet, say so in one line.",
                     cadence: .selfPaced),
        LoopTemplate(title: "Watch a deploy", icon: "shippingbox", taskMode: .prompt,
                     prompt: "Check if the deployment finished and tell me what happened. Stop the loop once it has.",
                     cadence: .interval, interval: LoopInterval(5, .m)),
        LoopTemplate(title: "Keep the tests green", icon: "testtube.2", taskMode: .prompt,
                     prompt: "Run the test suite. If anything newly fails, find the cause and fix it; otherwise reply in one line.",
                     cadence: .interval, interval: LoopInterval(30, .m)),
        LoopTemplate(title: "Maintenance (loop.md or built-in)", icon: "wrench.and.screwdriver", taskMode: .defaultPrompt,
                     prompt: "", cadence: .selfPaced),
        LoopTemplate(title: "Weekday morning summary", icon: "sun.horizon", taskMode: .prompt,
                     prompt: "Summarize what changed in this repository since yesterday morning: merged PRs, open PRs needing me, failing CI.",
                     cadence: .cron, cron: "57 8 * * 1-5"),
        LoopTemplate(title: "Remind me in an hour", icon: "alarm", taskMode: .prompt,
                     prompt: "Remind me to ", cadence: .once),
    ]
}

extension CronExpression {
    /// One field on its own, for the dialog's per-field red outline.
    static func parseFieldIsValid(_ field: String, index: Int) -> Bool {
        guard (0..<5).contains(index) else { return false }
        var fields = ["0", "0", "1", "1", "0"]
        fields[index] = field
        return CronExpression(fields.joined(separator: " ")) != nil
    }
}

extension LoopDraft {
    /// A JSON string literal, for previews.
    static func jsonString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]),
              let array = String(data: data, encoding: .utf8) else { return "\"\(s)\"" }
        return String(array.dropFirst().dropLast())
    }
}
