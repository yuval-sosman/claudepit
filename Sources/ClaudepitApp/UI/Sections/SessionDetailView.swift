import SwiftUI
import ClaudepitCore

struct SessionDetailView: View {
    @ObservedObject var app: AppState
    let summary: SessionSummary
    /// Non-nil when viewing a subagent transcript — the parent session to return to.
    var parentSummary: SessionSummary? = nil
    /// Called when the user taps an Agent row's "Open subagent session" button.
    var onOpenSubagent: ((SubagentSummary) -> Void)? = nil
    /// Called when the user taps the breadcrumb back button.
    var onBack: (() -> Void)? = nil

    @State private var events: [SessionEvent] = []
    @State private var responseUsage: [Int: TurnUsage] = [:]  // response-final index → summed usage
    @State private var cachedSpans: [TaskSpan] = []
    @State private var cachedMarkers: [TimelineMarker] = []
    @State private var cachedStats: SessionStats = .init()
    @State private var activeFilters: Set<TimelineMarker.Kind> = []
    @State private var allExpanded = false
    @State private var showStats = false
    @State private var contextReport: String?   // nil = not loaded; set → show popover
    @State private var loadingContext = false
    /// Bumped when Expand/Collapse All is pressed; rows react via .onChange. Resets on re-entry.
    @State private var expandCommand: ExpandCommand?
    @State private var showSummary = false
    @State private var isGeneratingSummary = false
    @StateObject private var tailer = SessionTailer()

    struct ExpandCommand: Equatable { var token: Int; var expand: Bool }

    /// The worktree this session is homed in, if any (surfaces the session↔worktree binding).
    private var currentWorktree: WorktreeInfo? {
        // A subagent inherits its parent session's worktree (Claude Code enforces
        // the isolated session's worktree on every subagent it spawns).
        let ownerID = parentSummary?.id ?? summary.id
        return app.worktrees.first { $0.ownerSessionID == ownerID }
    }

    /// Working directory for this view's `claude` subprocesses. Prefers the session's
    /// worktree over the project root — same chain the Resume button uses (and unlike
    /// `Paths.projectPath(for:)`, which reverses a slug by replacing every "-" with "/"
    /// and so mangles any project path containing a hyphen).
    private var qaWorkingDirectory: URL? {
        if let wt = currentWorktree { return URL(filePath: wt.path) }
        return app.activePath
    }

    /// Model of the most recent assistant response — same value shown in the last
    /// `TurnUsageLine`, surfaced here too so it's visible without scrolling.
    private var currentModel: String? {
        responseUsage.max(by: { $0.key < $1.key })?.value.model
    }

    var body: some View {
        VStack(spacing: 0) {
            if let parent = parentSummary, let back = onBack {
                breadcrumb(parent: parent, onBack: back)
                    .padding(.bottom, 8)
            }
            HStack {
                Text(summary.title).font(.headline).lineLimit(1)
                if summary.isActive {
                    Label("active", systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon).font(.caption2).foregroundStyle(.green)
                }
                Button {
                    if hasBullets {
                        withAnimation(.easeInOut(duration: 0.22)) { showSummary.toggle() }
                    } else {
                        Task { await generateSummary() }
                    }
                } label: {
                    if isGeneratingSummary {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.6).frame(width: 10, height: 10)
                            Text("Summarising…").font(.caption2)
                        }
                    } else {
                        Label("Summary", systemImage: "sparkles")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(hasBullets && showSummary ? Color.accentColor : .secondary)
                .opacity(!hasBullets && summary.isActive ? 0.35 : 1)
                .disabled(isGeneratingSummary || (!hasBullets && summary.isActive))
                .help(!hasBullets && summary.isActive ? "Session is running — generate summary after it completes" : "")
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.white.opacity(0.06), in: Capsule())
                Spacer()
                if let model = currentModel {
                    ModelBadge(model: model)
                }
                if parentSummary == nil {
                    Button {
                        app.focusSessionID = summary.id
                    } label: {
                        Image(systemName: "scope")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Focus in sidebar")
                }
            }
            .padding(.bottom, showSummary && hasBullets ? 6 : 10)

            if let wt = currentWorktree {
                WorktreeBadge(wt: wt) {
                    app.focusWorktreeName = wt.name
                    app.selected = .worktrees
                }
                .padding(.bottom, 8)
            }

            let herdrOwnerID = parentSummary?.id ?? summary.id
            if let entry = app.herdrSessions[herdrOwnerID], WorktreeResumer.available() {
                HerdrBadge(paneID: entry.paneID, status: entry.status) {
                    let cwd = currentWorktree?.path ?? app.activePath?.path ?? ""
                    Task { await WorktreeResumer.resume(sessionID: herdrOwnerID, cwd: cwd, label: summary.title, existingPaneID: entry.paneID) }
                }
                .padding(.bottom, 8)
            }

            if showSummary && hasBullets {
                summaryPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .padding(.bottom, 8)
            }

            HStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(TimelineMarker.Kind.allCases, id: \.self) { kind in
                            FilterChip(kind: kind, isActive: activeFilters.contains(kind)) {
                                if activeFilters.contains(kind) { activeFilters.remove(kind) }
                                else { activeFilters.insert(kind) }
                            }
                        }
                        if !activeFilters.isEmpty {
                            Button("Clear") { activeFilters.removeAll() }
                                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                Button {
                    allExpanded.toggle()
                    expandCommand = ExpandCommand(token: (expandCommand?.token ?? 0) + 1,
                                                  expand: allExpanded)
                } label: {
                    Label(allExpanded ? "Collapse All" : "Expand All",
                          systemImage: allExpanded ? "chevron.up.chevron.down" : "chevron.down")
                        .labelStyle(.titleAndIcon).font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button { showStats.toggle() } label: {
                    Image(systemName: "chart.bar.fill").font(.system(size: 14))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Session info")
                .popover(isPresented: $showStats, arrowEdge: .bottom) {
                    SessionStatsView(stats: cachedStats).frame(width: 420)
                }
            }
            .padding(.bottom, 8)

            if tailer.isLoading {
                ProgressView("Loading session…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            showSummary = false
            tailer.start(url: summary.fileURL) { newEvents in
                events = newEvents
                responseUsage = responseUsageSummaries(newEvents)
                cachedSpans = taskSpans(newEvents)
                cachedMarkers = timelineMarkers(newEvents)
                cachedStats = sessionStats(newEvents)
            }
        }
        .onDisappear { tailer.stop() }
    }

    // MARK: Summary panel

    private var hasBullets: Bool {
        guard let b = summary.bulletSummary else { return false }
        return !b.bullets.isEmpty
    }

    private var summaryPanel: some View {
        let bullets = summary.bulletSummary?.bullets ?? []
        let summaryFile = Paths.summaryFile(projectSlug: summary.projectSlug, sessionID: summary.id)
        let summaryDir = Paths.summaryDir(projectSlug: summary.projectSlug)
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { index, bullet in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: 4, height: 4)
                            .padding(.top, 5)
                        Text(bullet)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .opacity(showSummary ? 1 : 0)
                    .offset(y: showSummary ? 0 : 6)
                    .animation(.easeOut(duration: 0.35).delay(Double(index) * 0.12), value: showSummary)
                }
            }
            HStack(spacing: 4) {
                Button {
                    NSWorkspace.shared.open(summaryFile)
                } label: {
                    Image(systemName: Icon.openFile)
                }
                .help("Open summary file")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([summaryDir])
                } label: {
                    Image(systemName: Icon.revealInFinder)
                }
                .help("Show summaries folder")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    @MainActor
    private func generateSummary() async {
        guard !isGeneratingSummary else { return }
        isGeneratingSummary = true
        defer { isGeneratingSummary = false }
        let events = SessionTranscript().parseAll(summary.fileURL)
        var text = ""
        for e in events {
            if case .assistantText(let t) = e {
                text += t + "\n"
                if text.count > 8000 { break }
            }
        }
        guard !text.isEmpty else { return }
        let prompt = HookScripts.onDemandSummaryPrompt(transcriptText: String(text.prefix(8000)))
        guard let raw = try? await PlanQARunner.ask(prompt, cwd: qaWorkingDirectory) else { return }
        let bullets = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !bullets.isEmpty else { return }
        let entry = SessionBulletSummary(bullets: bullets, updatedAt: Date())
        try? SummaryStore.shared.save(entry, projectSlug: summary.projectSlug, sessionID: summary.id)
        if let idx = app.sessions.firstIndex(where: { $0.id == summary.id }) {
            app.sessions[idx].bulletSummary = entry
        }
        withAnimation(.easeInOut(duration: 0.22)) { showSummary = true }
    }

    // MARK: Transcript tab

    private var transcript: some View {
        let spans = cachedSpans
        // index of the most recent TaskList event (scroll destination for "go to TODO")
        let todoIndex = events.lastIndex { if case .tool(let i) = $0 { return i.name == "TaskList" } else { return false } }
        // map startIndex → span position (for color) and taskId → span.startIndex (for TODO→task)
        let spanByStart = Dictionary(uniqueKeysWithValues: spans.enumerated().map { ($0.element.startIndex, ($0.offset, $0.element)) })
        let startByTaskId = Dictionary(spans.map { ($0.taskId, $0.startIndex) }, uniquingKeysWith: { a, _ in a })
        let createIndexByTaskId = createIndexMap(events)

        return VStack(spacing: 0) {
          ScrollViewReader { proxy in
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {

                        ForEach(Array(events.enumerated()), id: \.offset) { idx, e in
                            if !activeFilters.isEmpty {
                                if activeFilters.contains(.task) {
                                    // Task filter: render spans as grouped TaskGroupView
                                    if let (colorIdx, span) = spanByStart[idx] {
                                        TaskGroupView(span: span, colorIndex: colorIdx,
                                                      onHeadingTap: { scrollToTODO(proxy, todoIndex: todoIndex, fallback: span.startIndex) }) {
                                            ForEach(span.startIndex...span.endIndex, id: \.self) { j in
                                                eventRow(events[j], index: j, proxy: proxy,
                                                         startByTaskId: startByTaskId, createIndexByTaskId: createIndexByTaskId)
                                            }
                                        }
                                        .id("evt-\(idx)")
                                    } else if isInsideAnySpan(idx, spans) {
                                        EmptyView()
                                    } else {
                                        // Outside spans: only show TaskCreate (todo lines) and TaskList;
                                        // skip bare TaskUpdate/TaskGet/TaskStop which are noise without context
                                        if case .tool(let inv) = e,
                                           inv.name == "TaskCreate" || inv.name == "TaskList" {
                                            eventRow(e, index: idx, proxy: proxy,
                                                     startByTaskId: startByTaskId, createIndexByTaskId: createIndexByTaskId)
                                                .id("evt-\(idx)")
                                        }
                                    }
                                } else if eventMatchesFilter(e) {
                                    eventRow(e, index: idx, proxy: proxy,
                                             startByTaskId: startByTaskId, createIndexByTaskId: createIndexByTaskId)
                                        .id("evt-\(idx)")
                                }
                            } else if let (colorIdx, span) = spanByStart[idx] {
                                // render the whole span as a group starting here
                                TaskGroupView(span: span, colorIndex: colorIdx,
                                              onHeadingTap: { scrollToTODO(proxy, todoIndex: todoIndex, fallback: span.startIndex) }) {
                                    ForEach(span.startIndex...span.endIndex, id: \.self) { j in
                                        eventRow(events[j], index: j, proxy: proxy,
                                                 startByTaskId: startByTaskId, createIndexByTaskId: createIndexByTaskId)
                                    }
                                }
                                .id("evt-\(idx)")
                            } else if isInsideAnySpan(idx, spans) {
                                EmptyView()   // already rendered inside its span group above
                            } else {
                                eventRow(e, index: idx, proxy: proxy,
                                         startByTaskId: startByTaskId, createIndexByTaskId: createIndexByTaskId)
                                    .id("evt-\(idx)")
                            }
                        }
                        Color.clear.frame(height: 1)
                            .id("bottom-anchor")
                    }
                    .padding(.trailing, 6)
                    .animation(.easeOut(duration: 0.2), value: events.count)
                }
                .textSelection(.enabled)   // drag-select + ⌘C across the transcript
                TimelineRail(
                    markers: cachedMarkers,
                    eventCount: events.count,
                    onTap: { index in proxy.scrollTo(scrollID(for: index, spans: spans), anchor: .top) },
                    onJumpTop: { proxy.scrollTo("evt-0", anchor: .top) },
                    onJumpBottom: { proxy.scrollTo("bottom-anchor", anchor: .bottom) }
                )
                .padding(.vertical, 4)
            }
          }
          contextPanel
        }
    }

    /// Live context = the LAST API turn's input + cache (what was actually in the window
    /// on the final request). Reads the last single .turnUsage event, NOT responseUsage —
    /// that sums a response's sub-turns, which triples context across tool round-trips.
    private var lastTurn: TurnUsage? {
        for e in events.reversed() { if case .turnUsage(let u) = e { return u } }
        return nil
    }
    private var contextUsed: Int {
        guard let u = lastTurn else { return 0 }
        return u.inputTokens + u.cacheReadTokens + u.cacheWriteTokens
    }

    private var contextPanel: some View {
        let stats = cachedStats
        let limit = contextWindow(for: lastTurn?.model ?? "")
        let used = contextUsed
        let frac = min(1.0, Double(used) / Double(limit))

        return VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.2)
            HStack {
                Text("Context").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(used.formatted()) / \(limit.formatted())  ·  \(Int(frac * 100))%")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: frac).progressViewStyle(.linear)
            HStack(spacing: 14) {
                tokenStat("↑ in", stats.input)
                tokenStat("↓ out", stats.output)
                tokenStat("cache", stats.cacheRead + stats.cacheWrite)
                Spacer()
                tokenStat("total", stats.total)
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                // Sub-agents are sidechains within the parent's own conversation, not standalone
                // `claude` CLI sessions — `summary.id` here is the internal agentId (the
                // "agent-<id>.jsonl" stem), which `claude -p --resume` doesn't recognize and always
                // rejects as "not a UUID and does not match any session title". Only offer the
                // live /context resume for a real top-level session.
                if parentSummary == nil {
                    Button {
                        loadingContext = true
                        let id = summary.id
                        let projectDir = qaWorkingDirectory
                        Task.detached {
                            let out = runContextCommand(sessionID: id, cwd: projectDir)
                            await MainActor.run { contextReport = out; loadingContext = false }
                        }
                    } label: {
                        if loadingContext {
                            HStack(spacing: 4) { ProgressView().scaleEffect(0.6).frame(width: 12, height: 12); Text("Context…") }
                        } else {
                            Label("Context", systemImage: "chart.pie").labelStyle(.titleAndIcon)
                        }
                    }
                    .disabled(loadingContext).help("Show /context breakdown")
                    .popover(isPresented: Binding(get: { contextReport != nil }, set: { if !$0 { contextReport = nil } }),
                             arrowEdge: .bottom) {
                        ContextReportView(report: contextReport ?? "").frame(width: 460, height: 560)
                    }
                }

                Spacer()
            }
            .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
            .padding(.top, 2)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .padding(.top, 4)
    }

    private func tokenStat(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 4) { Text(label); Text(value.formatted()).foregroundStyle(.primary) }
    }

    /// Context window for a model id. Current-gen models (Fable/Mythos 5, Opus 5, Opus 4.6–4.8,
    /// Sonnet 5, Sonnet 4.6) default to a 1M window with no opt-in flag — Haiku and every
    /// pre-4.6 Opus/Sonnet generation stay at 200K. The literal "[1m]" suffix is Claude Code's
    /// marker for the older, opt-in Sonnet 4.5 1M-context beta.
    /// ponytail: extend the allow-list below if a new tier ships at 1M by default.
    private func contextWindow(for model: String) -> Int {
        let oneMillionByDefault = ["opus-5", "opus-4-8", "opus-4-7", "opus-4-6",
                                    "sonnet-5", "sonnet-4-6", "fable-5", "mythos-5"]
        if model.contains("[1m]") || oneMillionByDefault.contains(where: model.contains) {
            return 1_000_000
        }
        return 200_000
    }

    /// taskId → index of its TaskCreate event (fallback scroll target for tasks with no span).
    private func createIndexMap(_ events: [SessionEvent]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (i, e) in events.enumerated() {
            guard case .tool(let inv) = e, inv.name == "TaskCreate",
                  let r = inv.resultText, let id = parseCreatedTaskId(r) else { continue }
            if out[id] == nil { out[id] = i }
        }
        return out
    }

    private func scrollToTask(_ proxy: ScrollViewProxy, taskId: String,
                              startByTaskId: [String: Int], createIndexByTaskId: [String: Int]) {
        if let start = startByTaskId[taskId] {
            withAnimation { proxy.scrollTo("evt-\(start)", anchor: .top) }
        } else if let create = createIndexByTaskId[taskId] {
            withAnimation { proxy.scrollTo("evt-\(create)", anchor: .top) }
        }
    }

    private func isInsideAnySpan(_ idx: Int, _ spans: [TaskSpan]) -> Bool {
        spans.contains { idx > $0.startIndex && idx <= $0.endIndex }
    }

    /// The scroll id to use for a given event index: the enclosing span / TODO-run
    /// start id if the event is rendered inside a group (inner rows carry no id),
    /// else the event's own id.
    private func scrollID(for index: Int, spans: [TaskSpan]) -> String {
        if let span = spans.first(where: { index >= $0.startIndex && index <= $0.endIndex }) {
            return "evt-\(span.startIndex)"
        }
        return "evt-\(index)"
    }

    private func scrollToTODO(_ proxy: ScrollViewProxy, todoIndex: Int?, fallback: Int) {
        withAnimation { proxy.scrollTo(todoIndex != nil ? "evt-\(todoIndex!)" : "synth-todo", anchor: .top) }
    }

    @ViewBuilder private func eventRow(_ e: SessionEvent, index: Int, proxy: ScrollViewProxy,
                                       startByTaskId: [String: Int], createIndexByTaskId: [String: Int]) -> some View {
        switch e {
        case .userMessage(let blocks):
            let singleText: String? = blocks.count == 1 ? { if case .text(let t) = blocks[0] { return t } else { return nil } }() : nil
            if let t = singleText, let chip = commandChipLabel(t) {
                // Claude Code command metadata → compact chip, not a full message card.
                HStack(spacing: 6) {
                    Image(systemName: "terminal").font(.caption2)
                    Text(chip).font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.quaternary.opacity(0.25), in: Capsule())
            } else {
                let copyText = blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n")
                VStack(alignment: .leading, spacing: 4) {
                    Text("You").font(.caption2.bold()).foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.7)).frame(width: 4)
                        VStack(alignment: .leading, spacing: 6) {
                            // Text blocks first, then a wrapping grid of all media blocks
                            let textBlocks = blocks.compactMap { b -> String? in
                                if case .text(let t) = b { return t } else { return nil }
                            }
                            let mediaBlocks = blocks.filter {
                                if case .text = $0 { return false } else { return true }
                            }
                            ForEach(Array(textBlocks.enumerated()), id: \.offset) { _, t in
                                MarkdownText(t).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if !mediaBlocks.isEmpty {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 6)], spacing: 6) {
                                    ForEach(Array(mediaBlocks.enumerated()), id: \.offset) { _, block in
                                        switch block {
                                        case .text: EmptyView()
                                        case .image(let data, let mediaType):
                                            UserImageBlock(data: data, mediaType: mediaType)
                                        case .imageFile(let url):
                                            UserImageFileBlock(url: url)
                                        case .document(let data, let mediaType, let name):
                                            UserDocumentChip(data: data, mediaType: mediaType, name: name)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) { CopyButton(text: copyText).padding(8) }
                .padding(.vertical, 4)
            }
        case .assistantText(let t):
            MarkdownText(t)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) { CopyButton(text: t).padding(8) }
        case .systemNote(let t):
            Text(t).font(.caption).foregroundStyle(.secondary).italic()
        case .hook(let h):
            HookRow(hook: h, expandCommand: expandCommand)
        case .attachment(let a):
            AttachmentRow(attachment: a, expandCommand: expandCommand)
        case .turnUsage:
            // Show one summary line per response (last turnUsage of the run), not per message.
            if let summary = responseUsage[index] {
                TurnUsageLine(usage: summary)
            }
        case .tool(let inv):
            if inv.name == "TaskList" {
                TodoListView(inv: inv, startByTaskId: startByTaskId) { taskId in
                    scrollToTask(proxy, taskId: taskId,
                                 startByTaskId: startByTaskId, createIndexByTaskId: createIndexByTaskId)
                }
            } else if inv.name == "TaskCreate" {
                todoLine(inv, startByTaskId: startByTaskId) { taskId in
                    scrollToTask(proxy, taskId: taskId,
                                 startByTaskId: startByTaskId, createIndexByTaskId: createIndexByTaskId)
                }
            } else {
                ToolRow(inv: inv, app: app, expandCommand: expandCommand,
                        subagents: summary.subagents, onOpenSubagent: onOpenSubagent,
                        sessionTitle: summary.title)
            }
        }
    }

    /// Render a TaskCreate as a TODO line: status glyph + subject (struck through when done).
    @ViewBuilder private func todoLine(_ inv: ToolInvocation, startByTaskId: [String: Int],
                                       onTap: @escaping (String) -> Void) -> some View {
        let subject = (inv.input["subject"] as? String) ?? inv.argSummary
        let status = taskStatus(inv)
        let taskId: String? = inv.resultText.flatMap { parseCreatedTaskId($0) }
        let hasSpan = taskId.map { startByTaskId[$0] != nil } ?? false
        Button {
            if let id = taskId { onTap(id) }
        } label: {
            HStack(spacing: 8) {
                todoGlyph(status)
                Text(subject)
                    .strikethrough(status == "completed", color: .secondary)
                    .foregroundStyle(status == "completed" ? .secondary : .primary)
                    .fontWeight(status == "in_progress" ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if hasSpan, let id = taskId {
                    Text("→ #\(id)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(Color.accentColor.opacity(0.8))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func todoGlyph(_ status: String) -> some View {
        Group {
            switch status {
            case "completed":
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case "in_progress":
                ProgressView().controlSize(.small)
            default:
                Image(systemName: "circle").foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, alignment: .center)   // stable glyph column so subjects align
    }

    /// Latest TaskUpdate status for the task this TaskCreate created ("pending" if none).
    private func taskStatus(_ createInv: ToolInvocation) -> String {
        guard let r = createInv.resultText, let id = parseCreatedTaskId(r) else { return "pending" }
        var status = "pending"
        for e in events {
            guard case .tool(let inv) = e, inv.name == "TaskUpdate",
                  inv.input["taskId"] as? String == id,
                  let st = inv.input["status"] as? String else { continue }
            status = st
        }
        return status
    }

    // MARK: Breadcrumb (subagent view)

    @ViewBuilder private func breadcrumb(parent: SessionSummary, onBack: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.caption2)
                    Text(parent.title).lineLimit(1)
                }
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            Text(summary.title).lineLimit(1).foregroundStyle(.secondary)
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Filtering

    private func eventMatchesFilter(_ e: SessionEvent) -> Bool {
        guard !activeFilters.isEmpty else { return true }
        switch e {
        case .userMessage(let blocks):
            let t = blocks.compactMap { if case .text(let s) = $0 { return s } else { return nil } }.joined()
            return activeFilters.contains(.user) && commandChipLabel(t) == nil
        case .tool(let inv):
            if inv.name == "TaskCreate" { return activeFilters.contains(.task) }
            if inv.name == "AskUserQuestion" { return activeFilters.contains(.question) }
            if inv.name == "TaskUpdate" || inv.name == "TaskGet" || inv.name == "TaskList" || inv.name == "TaskStop" { return activeFilters.contains(.task) }
            if case .agent = inv.toolClass { return activeFilters.contains(.subagent) }
            if case .skill = inv.toolClass { return activeFilters.contains(.skill) }
            if inv.name == "Write",
               let path = inv.input["file_path"] as? String,
               path.hasPrefix(Paths.plansRoot.path + "/"),
               path.hasSuffix(".md") { return activeFilters.contains(.plan) }
            return activeFilters.contains(.tools)
        case .hook:
            return activeFilters.contains(.hook)
        default:
            return false
        }
    }
}

private struct FilterChip: View {
    let kind: TimelineMarker.Kind
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Circle().fill(timelineColor(kind)).frame(width: 8, height: 8)
                Text(timelineKindName(kind)).font(.caption)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(isActive ? timelineColor(kind).opacity(0.18) : Color.clear,
                        in: Capsule())
            .overlay(Capsule().stroke(isActive ? timelineColor(kind).opacity(0.4) : Color.secondary.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? timelineColor(kind) : .secondary)
    }
}

/// A card-less, collapsible tool invocation row. Header is a chevron + status + (linkable) title + summary.
private struct ToolRow: View {
    let inv: ToolInvocation
    @ObservedObject var app: AppState
    let expandCommand: SessionDetailView.ExpandCommand?
    let subagents: [SubagentSummary]
    let onOpenSubagent: ((SubagentSummary) -> Void)?
    let sessionTitle: String
    @State private var expanded: Bool

    init(inv: ToolInvocation, app: AppState, expandCommand: SessionDetailView.ExpandCommand?,
         subagents: [SubagentSummary] = [], onOpenSubagent: ((SubagentSummary) -> Void)? = nil,
         sessionTitle: String = "") {
        self.inv = inv
        self.app = app
        self.expandCommand = expandCommand
        self.subagents = subagents
        self.onOpenSubagent = onOpenSubagent
        self.sessionTitle = sessionTitle
        _expanded = State(initialValue: expandCommand?.expand ?? ToolRow.expandsByDefault(inv))
    }

    private static func expandsByDefault(_ inv: ToolInvocation) -> Bool {
        ["Edit", "MultiEdit", "Write", "NotebookEdit", "AskUserQuestion"].contains(inv.name)
    }

    /// A file path in the input → just the file name (shown larger); else the arg summary.
    private var headerSummary: (text: String, isFile: Bool) {
        if let path = (inv.input["file_path"] as? String) ?? (inv.input["notebook_path"] as? String) {
            let name = path.split(separator: "/").last.map(String.init) ?? path
            return (name, true)
        }
        return (inv.argSummary, false)
    }

    /// True when this Write block wrote a plan file.
    private var isPlanWrite: Bool {
        guard inv.name == "Write",
              let path = inv.input["file_path"] as? String
        else { return false }
        let plansDir = Paths.plansRoot.path + "/"
        return path.hasPrefix(plansDir) && path.hasSuffix(".md")
    }

    private var planFilePath: String? {
        guard isPlanWrite else { return nil }
        return inv.input["file_path"] as? String
    }

    @State private var showPlanQA = false
    @State private var planQAContent: String = ""
    @State private var planFileNotFound = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                        statusGlyph
                        classGlyph
                        titleView
                        let s = headerSummary
                        if !s.text.isEmpty {
                            if s.isFile {
                                Text(s.text)
                                    .font(.body).bold()
                                    .foregroundStyle(.primary).lineLimit(1)
                            } else {
                                Text(s.text)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isPlanWrite {
                    // Q&A toggle
                    Button {
                        planFileNotFound = false
                        if let path = planFilePath,
                           let c = try? String(contentsOfFile: path, encoding: .utf8) {
                            planQAContent = c
                            showPlanQA.toggle()
                        } else {
                            planFileNotFound = true
                        }
                    } label: {
                        Image(systemName: showPlanQA
                              ? "bubble.left.and.text.bubble.right.fill"
                              : "bubble.left.and.text.bubble.right")
                            .font(.body)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Ask about this plan")
                    if planFileNotFound {
                        Text("Plan file not found")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Button {
                        if let path = planFilePath {
                            app.breadcrumbSessionCrumb = sessionTitle
                            app.breadcrumbSessionID = app.selectedSessionID
                            app.focusPlanPath = path
                            app.selected = .plans
                        }
                    } label: {
                        Image(systemName: Icon.jump)
                            .font(.body)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("View in Plans")
                    .padding(.trailing, 8)
                }
            }

            // Inline Q&A panel (same as Plans page)
            if isPlanWrite && showPlanQA {
                PlanQAPanel(planContent: planQAContent, cwd: app.activePath)
                    .frame(height: 420)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.12)))
                    .padding(.leading, 16)
                    .padding(.trailing, 8)
                    .padding(.bottom, 4)
            }

            if expanded {
                if let sub = matchedSubagent, let open = onOpenSubagent {
                    Button {
                        open(sub)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: Icon.jump).font(.caption)
                            Text("Open subagent session")
                            Text("·").foregroundStyle(.tertiary)
                            Text(sub.agentType).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 16)
                }
                ToolDetail(inv: inv)
            }
        }
        .padding(.vertical, 2)
        .onChange(of: expandCommand) { _, cmd in
            if let cmd { expanded = cmd.expand }
        }
    }

    @ViewBuilder private var statusGlyph: some View {
        if inv.isError == true {
            Image(systemName: "xmark.circle").foregroundStyle(.red)
        } else if inv.resultText != nil {
            Image(systemName: "checkmark.circle").foregroundStyle(.green)
        } else {
            Image(systemName: "clock").foregroundStyle(.orange)
        }
    }

    /// Distinct glyph for a subagent (Agent/Task) dispatch — reads as different from a plain tool.
    @ViewBuilder private var classGlyph: some View {
        if case .agent = inv.toolClass {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var titleView: some View {
        if let target = linkTarget {
            Button {
                app.navigate(to: target.sectionRaw, itemID: target.itemID)
            } label: {
                Text(inv.displayName).font(.system(.body, design: .monospaced)).bold()
                    .foregroundStyle(Color.accentColor).underline()
            }
            .buttonStyle(.plain)
        } else {
            Text(inv.displayName).font(.system(.body, design: .monospaced)).bold()
        }
    }

    private var matchedSubagent: SubagentSummary? {
        guard case .agent = inv.toolClass else { return nil }
        return subagents.first { $0.toolUseId == inv.id }
    }

    private var linkTarget: HighlightTarget? {
        let store = app.store
        return deepLinkTarget(
            for: inv.toolClass,
            skillIDs: Set(store.skills.map(\.id)),
            agentIDs: Set(store.agents.map(\.id)),
            mcpServerIDs: Set(store.mcpServers.map(\.id)),
            commandIDs: Set(store.commands.map(\.id)),
            hookIDs: Set(store.hooks.map(\.id)))
    }
}

/// Renders the `/context` report: a 10×10 usage grid (1 cell ≈ 1% of the window,
/// colored by category) above the raw markdown breakdown. Parses category rows out
/// of the "Estimated usage by category" table in the report.
private struct ContextReportView: View {
    let report: String

    // category label (lowercased, matched by prefix) → color; anything else → grey
    private static let colors: [(String, Color)] = [
        ("system prompt", Color(white: 0.55)),
        ("system tools", Color(white: 0.72)),
        ("mcp", .teal),
        ("custom agents", Color(red: 0.69, green: 0.73, blue: 0.98)),
        ("skills", Color(red: 1.0, green: 0.76, blue: 0.03)),
        ("messages", Color(red: 0.51, green: 0.49, blue: 0.74)),
    ]
    private func color(for label: String) -> Color {
        let l = label.lowercased()
        return Self.colors.first { l.hasPrefix($0.0) }?.1 ?? Color(white: 0.6)
    }

    /// [(label, tokens, percent)] for every category row incl. free space, from the table.
    private var rows: [(label: String, tokens: String, pct: Double)] {
        for block in parseMarkdownBlocks(report) {
            guard case .table(_, let rs) = block else { continue }
            var out: [(String, String, Double)] = []
            for r in rs where r.count >= 3 {
                let label = r[0].trimmingCharacters(in: .whitespaces)
                let tokens = r[1].trimmingCharacters(in: .whitespaces)
                let pct = Double(r[2].filter { $0.isNumber || $0 == "." }) ?? 0
                out.append((label, tokens, pct))
            }
            if !out.isEmpty { return out }   // first table is the category breakdown
        }
        return []
    }

    private var categories: [(String, Double)] {
        rows.filter { !$0.label.lowercased().hasPrefix("free space") && $0.pct > 0 }
            .map { ($0.label, $0.pct) }
    }

    /// 100 cells: fill round(pct) per category in order; the rest are hollow (free).
    private var cellColors: [Color?] {
        var cells: [Color?] = Array(repeating: nil, count: 100)
        var i = 0
        for (label, pct) in categories {
            let n = min(100 - i, Int(pct.rounded()))
            for _ in 0..<max(0, n) where i < 100 { cells[i] = color(for: label); i += 1 }
        }
        return cells
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !categories.isEmpty {
                    HStack(alignment: .top, spacing: 16) {
                        grid
                        legend
                    }
                }
                MarkdownText(report)
            }
            .padding(16)
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Estimated usage by category").font(.caption).italic().foregroundStyle(.secondary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                let free = r.label.lowercased().hasPrefix("free space")
                HStack(spacing: 6) {
                    Image(systemName: free ? "cylinder.split.1x2" : "cylinder.split.1x2.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(free ? Color(white: 0.4) : color(for: r.label))
                    Text(r.label).foregroundStyle(.primary)
                    Text("\(r.tokens) (\(String(format: "%.1f", r.pct))%)").foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }

    private var grid: some View {
        let cells = cellColors
        return VStack(spacing: 3) {
            ForEach(0..<10, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<10, id: \.self) { col in
                        let c = cells[row * 10 + col]
                        Image(systemName: c == nil ? "cylinder.split.1x2" : "cylinder.split.1x2.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(c ?? Color(white: 0.35))
                    }
                }
            }
        }
        .padding(.bottom, 2)
    }
}

/// Aggregate session stats popover: token usage, per-model, messages, tools.
private struct SessionStatsView: View {
    let stats: SessionStats
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 20) {
                    tokenUsage
                    modelDetails
                }
                Divider()
                messagesAndTools
            }
            .padding(16)
        }
        .frame(maxHeight: 460)
    }

    private var tokenUsage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Token Usage").font(.headline)
            row("Input", stats.input)
            row("Output", stats.output)
            row("Cache read", stats.cacheRead)
            row("Cache write", stats.cacheWrite)
            Divider()
            row("Total", stats.total, bold: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modelDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model Details").font(.headline)
            ForEach(stats.perModel, id: \.model) { m in
                VStack(alignment: .leading, spacing: 2) {
                    ModelBadge(model: m.model)
                    Text("In: \(m.input.formatted()) · Out: \(m.output.formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Cache read: \(m.cacheRead.formatted()) · write: \(m.cacheWrite.formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(m.messages) message\(m.messages == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var messagesAndTools: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Messages & Tools").font(.headline)
            row("Your messages", stats.userMessages)
            row("Assistant messages", stats.assistantMessages)
            row("Tool calls", stats.toolCalls)
            if !stats.topTools.isEmpty {
                Text(stats.topTools.prefix(8).map { "\($0.label) ×\($0.count)" }.joined(separator: "   "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            }
        }
    }

    private func row(_ label: String, _ value: Int, bold: Bool = false) -> some View {
        HStack {
            Text(label).fontWeight(bold ? .bold : .regular)
            Spacer()
            Text(value.formatted()).fontWeight(bold ? .bold : .regular).monospacedDigit()
        }
        .font(.callout)
    }
}

/// Small colored pill naming the model that produced a response. Color-coded by model
/// family (not by config scope — see `ManagedBadge`'s scope palette, which this
/// deliberately avoids) so a session or subagent transcript that switches models mid-way
/// is scannable at a glance.
struct ModelBadge: View {
    let model: String

    var body: some View {
        Text(shortModel)
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.22), in: Capsule())
            .foregroundStyle(color)
    }

    private var shortModel: String {
        model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }

    private var color: Color { ModelBadge.color(for: model) }

    /// One family→color mapping for every surface that tints by model (this badge, Home's
    /// model-token bars), so the same model never wears two colors in one window.
    static func color(for model: String) -> Color {
        let m = model.lowercased()
        if m.contains("opus") { return .pink }
        if m.contains("sonnet") { return .cyan }
        if m.contains("haiku") { return .mint }
        if m.contains("fable") { return .indigo }
        return .gray
    }
}

/// Dim per-turn token summary shown under an assistant message, with a `ModelBadge`
/// standing out inline so the model is legible without breaking out of the usage line.
private struct TurnUsageLine: View {
    let usage: TurnUsage
    var body: some View {
        HStack(spacing: 8) {
            ModelBadge(model: usage.model)
            Text("↑ \(usage.inputTokens.formatted())")
            Text("↓ \(usage.outputTokens.formatted())")
            if usage.cacheReadTokens > 0 { Text("· \(usage.cacheReadTokens.formatted()) cached") }
            Spacer()
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.leading, 2)
    }
}

private func tempFileURL(for data: Data, ext: String) -> URL {
    // Hash the full data so different images never share a temp path.
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in data { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("claudepit-\(String(hash, radix: 16)).\(ext)")
    if !FileManager.default.fileExists(atPath: url.path) {
        try? data.write(to: url)
    }
    return url
}

private func extForMediaType(_ mediaType: String) -> String {
    switch mediaType {
    case "image/png": return "png"
    case "image/jpeg", "image/jpg": return "jpg"
    case "image/gif": return "gif"
    case "image/webp": return "webp"
    case "application/pdf": return "pdf"
    default: return mediaType.components(separatedBy: "/").last ?? "bin"
    }
}

private struct UserImageBlock: View {
    let data: Data
    let mediaType: String

    var body: some View {
        if let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                .onTapGesture {
                    let url = tempFileURL(for: data, ext: extForMediaType(mediaType))
                    NSWorkspace.shared.open(url)
                }
        }
    }
}

private struct UserImageFileBlock: View {
    let url: URL

    var body: some View {
        if let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                .onTapGesture { NSWorkspace.shared.open(url) }
        }
    }
}

private struct UserDocumentChip: View {
    let data: Data
    let mediaType: String
    let name: String?

    private var icon: String {
        if mediaType == "application/pdf" { return "doc.fill" }
        if mediaType.hasPrefix("text/") { return "doc.text" }
        return "paperclip"
    }

    private var label: String { name ?? mediaType }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption)
            Text(label).font(.caption).lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
        .onTapGesture {
            let url = tempFileURL(for: data, ext: extForMediaType(mediaType))
            NSWorkspace.shared.open(url)
        }
    }
}

/// A generic (non-hook) attachment: type name + pretty-printed JSON of its fields when expanded.
private struct AttachmentRow: View {
    let attachment: Attachment
    let expandCommand: SessionDetailView.ExpandCommand?
    @State private var expanded: Bool

    init(attachment: Attachment, expandCommand: SessionDetailView.ExpandCommand?) {
        self.attachment = attachment
        self.expandCommand = expandCommand
        _expanded = State(initialValue: expandCommand?.expand ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                    Image(systemName: "paperclip").foregroundStyle(.secondary)
                    Text(attachment.type).font(.system(.body, design: .monospaced)).bold()
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, !attachment.fields.isEmpty {
                Text(Self.prettyJSON(attachment.fields))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 2)
        .onChange(of: expandCommand) { _, cmd in
            if let cmd { expanded = cmd.expand }
        }
    }

    private static func prettyJSON(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return String(describing: obj) }
        return s
    }
}

/// A hook execution attachment: collapsed by default, expands to command/stdout/stderr/context.
private struct HookRow: View {
    let hook: HookExecution
    let expandCommand: SessionDetailView.ExpandCommand?
    @State private var expanded: Bool

    init(hook: HookExecution, expandCommand: SessionDetailView.ExpandCommand?) {
        self.hook = hook
        self.expandCommand = expandCommand
        _expanded = State(initialValue: expandCommand?.expand ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                    Image(systemName: hook.isError ? "xmark.circle" : "checkmark.circle")
                        .foregroundStyle(hook.isError ? .red : .green)
                    Image(systemName: "link").foregroundStyle(Color.accentColor)
                    Text(hook.hookName).font(.system(.body, design: .monospaced)).bold()
                    if !hook.hookEvent.isEmpty {
                        Text(hook.hookEvent).font(.caption).foregroundStyle(.secondary)
                    }
                    if let ms = hook.durationMs {
                        Text("· \(ms)ms").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    section("COMMAND", hook.command)
                    section("STDOUT", hook.stdout)
                    section("STDERR", hook.stderr, tint: .red)
                    section("CONTEXT", hook.content)
                }
            }
        }
        .padding(.vertical, 2)
        .onChange(of: expandCommand) { _, cmd in
            if let cmd { expanded = cmd.expand }
        }
    }

    @ViewBuilder private func section(_ title: String, _ text: String?, tint: Color = .black) -> some View {
        if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(tint.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

/// Simple wrapping text of chips for the counts header.
private struct FlowText: View {
    let items: [String]
    init(_ items: [String]) { self.items = items }
    var body: some View {
        Text(items.joined(separator: "   "))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}

/// Owns live-tail state: incremental parse + FileWatcher on one session file.
@MainActor
final class SessionTailer: ObservableObject {
    @Published private(set) var isLoading = false
    private var transcript = SessionTranscript()
    private var offset: UInt64 = 0
    private var handle: FileHandle?
    private var watcher: FileWatcher?
    private var onUpdate: (([SessionEvent]) -> Void)?
    private var url: URL?

    func start(url: URL, onUpdate: @escaping ([SessionEvent]) -> Void) {
        self.url = url
        self.onUpdate = onUpdate
        readNew()
        watcher = FileWatcher(paths: [url]) { [weak self] in
            Task { @MainActor in self?.readNew() }
        }
        watcher?.start()
    }

    private func readNew() {
        guard let url else { return }
        // Incremental tail: offset > 0, only new bytes — stay synchronous on main actor
        if offset > 0 {
            if handle == nil { handle = try? FileHandle(forReadingFrom: url) }
            guard let handle else { return }
            do {
                try handle.seek(toOffset: offset)
                let data = handle.readDataToEndOfFile()
                offset = handle.offsetInFile
                if data.isEmpty { return }
                let events = transcript.parse(data: data)
                onUpdate?(events)
            } catch {
                try? handle.close(); self.handle = nil
            }
            return
        }
        // Initial load: read + parse off main thread, deliver in two batches
        isLoading = true
        let capturedTranscript = transcript
        Task.detached(priority: .userInitiated) { [weak self, url] in
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                await MainActor.run { self?.isLoading = false }
                return
            }
            let data = handle.readDataToEndOfFile()
            try? handle.close()
            var t = capturedTranscript
            let events = t.parse(data: data)
            let newOffset = UInt64(data.count)
            // First batch: show top immediately
            let first = Array(events.prefix(150))
            await MainActor.run { self?.onUpdate?(first) }
            await Task.yield()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.transcript = t
                self.offset = newOffset
                self.isLoading = false
                self.onUpdate?(events)
            }
        }
    }

    func forceReload() {
        transcript = SessionTranscript()
        offset = 0
        try? handle?.close()
        handle = nil
        readNew()
    }

    func stop() {
        watcher?.stop(); watcher = nil
        try? handle?.close(); handle = nil
    }
}

/// Tappable banner shown in a session's detail view when that session is homed in a
/// git worktree. Reads as a button (accent tint, hover highlight, trailing "View" cue).
private struct WorktreeBadge: View {
    let wt: WorktreeInfo
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(Color.accentColor)
                (Text("Running in worktree  ").foregroundStyle(.secondary)
                 + Text(wt.name).fontWeight(.semibold).foregroundStyle(.primary)
                 + Text("  ·  \(wt.branch)").foregroundStyle(.secondary))
                    .font(.caption).lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    Text("View in Worktrees").font(.caption2.weight(.medium))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(hovering ? 0.16 : 0.10),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show this worktree in the Worktrees section")
    }
}

/// Tappable banner shown when the session is open in a herdr pane. Styled like
/// `WorktreeBadge`, but the action focuses the existing pane instead of navigating.
private struct HerdrBadge: View {
    let paneID: String
    let status: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.caption).foregroundStyle(Color.accentColor)
                (Text("Managed by herdr  ").foregroundStyle(.secondary)
                 + Text("pane \(paneID)").fontWeight(.semibold).foregroundStyle(.primary)
                 + Text("  ·  \(status)").foregroundStyle(.secondary))
                    .font(.caption).lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    Text("Focus pane").font(.caption2.weight(.medium))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(hovering ? 0.16 : 0.10),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Focus this session's herdr pane")
    }
}

/// Isolated `claude -r … -p /context` call. `--safe-mode` keeps hooks (ours included)
/// from injecting additionalContext into the report; it replaced `--bare`, which
/// suppressed the same things but also disabled OAuth/keychain auth, so every call
/// came back "Not logged in". Never set CLAUDE_CONFIG_DIR here either — see `ClaudeCLI`.
private func runContextCommand(sessionID: String, cwd: URL?) -> String {
    guard let claudePath = Executable.find("claude") else { return "claude CLI not found" }
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/env")
    p.arguments = ClaudeCLI.resumeArgs(
        claudePath: claudePath, sessionID: sessionID, command: "/context",
        extra: ["--no-session-persistence"])
    if let cwd { p.currentDirectoryURL = cwd }
    p.environment = ClaudeCLI.environment()
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return "Failed to launch: \(error.localizedDescription)" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(data: data, encoding: .utf8) ?? ""
    // stdout and stderr share one pipe here, so the merged text is already what
    // `isNotLoggedIn` wants — a signed-out run prints its reason instead of a report.
    if p.terminationStatus != 0, ClaudeAuth.isNotLoggedIn(out) {
        NotificationCenter.default.post(name: .claudeAuthSuspect, object: nil)
    }
    return out
}

