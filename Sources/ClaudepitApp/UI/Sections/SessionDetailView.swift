import SwiftUI
import ClaudepitCore

/// A session's page: a header with what the session was (when, how long, how much, on what)
/// and its actions, then the transcript — every prompt, reply, thought, tool call, injected
/// context, hook and system event, in order (`TranscriptView`).
struct SessionDetailView: View {
    @ObservedObject var app: AppState
    let summary: SessionSummary
    /// Non-nil when viewing a subagent transcript — the parent session to return to.
    var parentSummary: SessionSummary? = nil
    /// Called when the user taps an Agent row's "Open subagent transcript" button.
    var onOpenSubagent: ((SubagentSummary) -> Void)? = nil
    /// Called when the user taps the breadcrumb back button.
    var onBack: (() -> Void)? = nil

    @StateObject private var loader = TranscriptLoader()
    @State private var contextReport: String?   // nil = not loaded; set → show popover
    @State private var loadingContext = false
    @State private var showSummary = false
    @State private var isGeneratingSummary = false
    /// The report sheet's subject, set on tap. Sized once at tap time from the main window, like
    /// the Source Control sheet — `keyWindow` becomes the sheet itself once it opens.
    @State private var reportRequest: SessionReportRequest?
    @State private var reportSheetSize = CGSize(width: 900, height: 600)

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let parent = parentSummary, let back = onBack {
                breadcrumb(parent: parent, onBack: back)
                    .padding(.bottom, 8)
            }
            header
                .padding(.bottom, 10)

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
                    .transition(.opacity)
                    .padding(.bottom, 10)
            }

            if let model = loader.model {
                TranscriptView(model: model, actions: actions, isLive: summary.isActive)
            } else {
                ProgressView("Loading session…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            showSummary = false
            loader.start(url: summary.fileURL)
        }
        .onDisappear { loader.stop() }
    }

    // MARK: Header

    private var header: some View {
        SessionHeader(title: summary.title, isActive: summary.isActive, model: loader.model) {
            actionButtons
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            summaryButton
            HeaderButton(title: "Report", icon: "chart.bar.xaxis",
                         help: parentSummary == nil ? "Usage report: cost, context, cache misses, subagents, tools"
                                                    : "Usage report for the parent session, this subagent included") {
                if let f = (NSApp.mainWindow ?? NSApp.keyWindow)?.frame, f.width > 200, f.height > 200 {
                    reportSheetSize = CGSize(width: max(760, f.width * 0.92), height: max(520, f.height * 0.92))
                }
                reportRequest = SessionReportRequest(session: parentSummary ?? summary)
            }
            .sheet(item: $reportRequest) { request in
                SessionReportView(request: request)
                    .frame(width: reportSheetSize.width, height: reportSheetSize.height)
            }
            // Sub-agents are sidechains within the parent's own conversation, not standalone
            // `claude` CLI sessions — `summary.id` here is the internal agentId (the
            // "agent-<id>.jsonl" stem), which `claude -p --resume` doesn't recognize and always
            // rejects as "not a UUID and does not match any session title". Only offer the
            // live /context resume for a real top-level session.
            if parentSummary == nil {
                HeaderButton(title: loadingContext ? "Context…" : "Context", icon: "chart.pie",
                             help: "Run /context on this session: what fills its context window, by category") {
                    loadingContext = true
                    let id = summary.id
                    let projectDir = qaWorkingDirectory
                    Task.detached {
                        let out = runContextCommand(sessionID: id, cwd: projectDir)
                        await MainActor.run { contextReport = out; loadingContext = false }
                    }
                }
                .disabled(loadingContext)
                .popover(isPresented: Binding(get: { contextReport != nil }, set: { if !$0 { contextReport = nil } }),
                         arrowEdge: .bottom) {
                    ContextReportView(report: contextReport ?? "").frame(width: 460, height: 560)
                }
            }
            if parentSummary == nil {
                Button { app.focusSessionID = summary.id } label: {
                    Image(systemName: "scope")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 20)
                        .background(.white.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Focus in sidebar — select this session in the list and scroll to it")
            }
            Menu {
                Button { NSWorkspace.shared.open(summary.fileURL) } label: { Label("Open Raw Transcript", systemImage: Icon.openFile) }
                Button { NSWorkspace.shared.activateFileViewerSelecting([summary.fileURL]) } label: {
                    Label("Reveal in Finder", systemImage: Icon.revealInFinder)
                }
                Button { copy(summary.fileURL.path) } label: { Label("Copy Transcript Path", systemImage: Icon.copyPath) }
                if let model = loader.model {
                    Button { copy(model.markdown()) } label: {
                        Label("Copy Conversation as Markdown", systemImage: "doc.richtext")
                    }
                }
                if parentSummary == nil {
                    Divider()
                    Button("Copy Session ID") { copy(summary.id) }
                    Button("Copy Resume Command") { copy("claude --resume \(summary.id)") }
                    Divider()
                    Button { app.focusSessionID = summary.id } label: { Label("Focus in Sidebar", systemImage: "scope") }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 20)
                    .background(.white.opacity(0.06), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var summaryButton: some View {
        Button {
            if hasBullets {
                withAnimation(Self.summaryAnimation) { showSummary.toggle() }
            } else {
                Task { await generateSummary() }
            }
        } label: {
            HStack(spacing: 4) {
                if isGeneratingSummary {
                    ProgressView().controlSize(.mini)
                    Text("Summarising…")
                } else {
                    Image(systemName: "sparkles").font(.system(size: 10))
                    Text("Summary")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(hasBullets && showSummary ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3.5)
            .background(hasBullets && showSummary ? Color.accentColor.opacity(0.15) : Color.white.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .opacity(!hasBullets && summary.isActive ? 0.4 : 1)
        .disabled(isGeneratingSummary || (!hasBullets && summary.isActive))
        .help(hasBullets ? "Show the session's bullet summary"
              : summary.isActive ? "Session is running — generate a summary after it completes"
              : "Generate a bullet summary with Claude")
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: Transcript actions

    private var actions: TranscriptActions {
        let subagents = summary.subagents
        let store = app.store
        let skillIDs = Set(store.skills.map(\.id)), agentIDs = Set(store.agents.map(\.id))
        let mcpIDs = Set(store.mcpServers.map(\.id)), commandIDs = Set(store.commands.map(\.id))
        let hookIDs = Set(store.hooks.map(\.id))
        return TranscriptActions(
            openSubagent: onOpenSubagent.map { open in
                { toolUseID in if let sub = subagents.first(where: { $0.toolUseId == toolUseID }) { open(sub) } }
            },
            hasSubagent: { id in subagents.contains { $0.toolUseId == id } },
            sectionLink: { [app] inv in
                guard let target = deepLinkTarget(for: inv.toolClass, skillIDs: skillIDs, agentIDs: agentIDs,
                                                  mcpServerIDs: mcpIDs, commandIDs: commandIDs, hookIDs: hookIDs)
                else { return nil }
                return { app.navigate(to: target.sectionRaw, itemID: target.itemID) }
            },
            openPlan: { [app, summary] path in
                app.breadcrumbSessionCrumb = summary.title
                app.breadcrumbSessionID = app.selectedSessionID
                app.focusPlanPath = path
                app.selected = .plans
            },
            cwd: qaWorkingDirectory)
    }

    // MARK: Summary panel

    private var hasBullets: Bool {
        guard let b = summary.bulletSummary else { return false }
        return !b.bullets.isEmpty
    }

    /// One quick fade, the transcript easing down with it. The bullets used to fade in one by
    /// one, 0.12s apart — two seconds for a 15-bullet summary, while the panel slid in over the
    /// header.
    private static let summaryAnimation = Animation.easeOut(duration: 0.18)

    private var summaryPanel: some View {
        let bullets = summary.bulletSummary?.bullets ?? []
        let summaryFile = Paths.summaryFile(projectSlug: summary.projectSlug, sessionID: summary.id)
        let summaryDir = Paths.summaryDir(projectSlug: summary.projectSlug)
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: 4, height: 4)
                            .padding(.top, 5)
                        Text(bullet)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
        let url = summary.fileURL
        let events = await Task.detached(priority: .userInitiated) { SessionTranscript().parseAll(url) }.value
        var text = ""
        for e in events {
            if case .assistantText(let a) = e {
                text += a.text + "\n"
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
        withAnimation(Self.summaryAnimation) { showSummary = true }
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
            Image(systemName: "person.2").font(.caption2).foregroundStyle(TranscriptStyle.agent)
            Text(summary.title).lineLimit(1).foregroundStyle(.secondary)
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// The session's title line (with its actions) and one line of facts: when, how long, how much
/// happened, on what, and how full the context is. Takes values, not `AppState`.
struct SessionHeader<Actions: View>: View {
    let title: String
    let isActive: Bool
    let model: TranscriptModel?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.headline).lineLimit(1).truncationMode(.tail)
                    .help(title)
                if isActive {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("live").font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(.green)
                    .help("Written to in the last minute — the view follows new activity")
                }
                Spacer(minLength: 8)
                actions()
            }
            if let model { factStrip(model) }
        }
    }

    private func factStrip(_ model: TranscriptModel) -> some View {
        let meta = model.metadata
        let stats = model.stats
        let lastUsage = model.events.reversed().lazy.compactMap { e -> TurnUsage? in
            if case .turnUsage(let u) = e { return u } else { return nil }
        }.first
        return FlowLayout(spacing: 10) {
            if let start = meta.firstTime {
                fact("calendar", TranscriptFormat.dayClock(start) ?? "",
                     help: "Started \(TranscriptFormat.dayClock(start) ?? "")"
                        + (meta.version.map { " · written by Claude Code \($0)" } ?? ""))
            }
            if let s = meta.firstTime, let e = meta.lastTime, e > s {
                fact("clock", Elapsed.short(e - s), help: "First record to last")
            }
            if !stats.models.isEmpty {
                HStack(spacing: 4) {
                    ForEach(stats.models, id: \.self) { m in
                        Text(TranscriptFormat.model(m))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(ModelBadge.color(for: m))
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(ModelBadge.color(for: m).opacity(0.18), in: Capsule())
                            .help("Model: \(m)")
                    }
                }
            }
            if let u = lastUsage { ContextGauge(used: u.contextTokens, model: u.model) }
            if stats.totalTokens > 0 {
                let sent = stats.inputTokens + stats.cacheReadTokens + stats.cacheWriteTokens
                fact("arrow.up.arrow.down",
                     "\(TranscriptFormat.tokens(sent)) in · \(TranscriptFormat.tokens(stats.outputTokens)) out",
                     help: Self.tokenHelp(stats))
            }
            // Prompts, calls, edits, subagents and errors are counted on the filter chips below.
            if stats.compactions > 0 {
                fact("rectangle.compress.vertical", "\(stats.compactions)",
                     help: TranscriptFormat.plural(stats.compactions, "compaction") + " — the conversation was summarised to free context")
            }
            if let branch = meta.gitBranch { fact("arrow.triangle.branch", branch, help: "Git branch") }
        }
    }

    /// Every token the session's API calls sent and received, by kind.
    static func tokenHelp(_ s: TranscriptStats) -> String {
        func n(_ v: Int) -> String { v.formatted() }
        return """
        Tokens over \(TranscriptFormat.plural(s.apiCalls, "API call"))
        ↑ sent: \(n(s.inputTokens)) input · \(n(s.cacheReadTokens)) cache read · \(n(s.cacheWriteTokens)) cache write
        ↓ received: \(n(s.outputTokens)) output
        Total: \(n(s.totalTokens))
        """
    }

    private func fact(_ icon: String, _ text: String, help: String, color: Color = .secondary) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9.5))
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(color)
        .fixedSize()
        .help(help)
    }
}

/// A capsule action in the session header.
private struct HeaderButton: View {
    let title: String
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3.5)
            .background(Color.white.opacity(hover ? 0.10 : 0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// How full the context window was on the last request: a slim bar and `152k / 1M`.
struct ContextGauge: View {
    let used: Int
    let model: String

    var body: some View {
        let limit = Self.window(for: model)
        let frac = min(1, Double(used) / Double(limit))
        let color: Color = frac > 0.85 ? TranscriptStyle.error : frac > 0.6 ? TranscriptStyle.warning : Color.accentColor
        HStack(spacing: 5) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 9.5)).foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(color).frame(width: max(2, 44 * frac))
            }
            .frame(width: 44, height: 4)
            Text("\(TranscriptFormat.tokens(used)) / \(limit >= 1_000_000 ? "\(limit / 1_000_000)M" : "\(limit / 1000)k")")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
        }
        .fixedSize()
        .help("Context on the last request: \(used.formatted()) of \(limit.formatted()) tokens (\(Int(frac * 100))%)")
    }

    /// Context window for a model id. Current-gen models (Fable/Mythos 5, Opus 5, Opus 4.6–4.8,
    /// Sonnet 5, Sonnet 4.6) default to a 1M window with no opt-in flag — Haiku and every
    /// pre-4.6 Opus/Sonnet generation stay at 200K. The literal "[1m]" suffix is Claude Code's
    /// marker for the older, opt-in Sonnet 4.5 1M-context beta.
    /// ponytail: extend the allow-list below if a new tier ships at 1M by default.
    static func window(for model: String) -> Int {
        let oneMillionByDefault = ["opus-5", "opus-4-8", "opus-4-7", "opus-4-6",
                                    "sonnet-5", "sonnet-4-6", "fable-5", "mythos-5"]
        if model.contains("[1m]") || oneMillionByDefault.contains(where: model.contains) {
            return 1_000_000
        }
        return 200_000
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

/// The one model-family → colour map for the whole window: the session header's model pills,
/// the transcript's turn footers and call tables, Home's model-token bars and cost breakdown.
/// Color-coded by model family (not by config scope — see `ManagedBadge`'s scope palette, which
/// this deliberately avoids) so a transcript that switches models mid-way is scannable at a glance.
enum ModelBadge {
    /// One family→color mapping for every surface that tints by model, so the same model never
    /// wears two colors in one window. The hues are the old system ones (pink, cyan, mint,
    /// indigo) stepped for the dark surface: Sonnet's cyan and Haiku's mint were too close to
    /// tell apart side by side. Checked as a categorical palette on the card surface in
    /// `familyOrder`, the order Home stacks them in — re-check both if either changes.
    static func color(for model: String) -> Color {
        switch family(model) {
        case "fable", "mythos": return rgb(0x90, 0x85, 0xE9)   // violet
        case "opus":            return rgb(0xD5, 0x51, 0x81)   // magenta
        case "sonnet":          return rgb(0x39, 0x87, 0xE5)   // blue
        case "haiku":           return rgb(0x19, 0x9E, 0x70)   // aqua
        default:                return .gray
        }
    }

    /// Stacking order for segments colored by `color(for:)`, biggest tier first.
    static let familyOrder = ["fable", "mythos", "opus", "sonnet", "haiku"]

    static func family(_ model: String) -> String {
        let m = model.lowercased()
        return familyOrder.first { m.contains($0) } ?? ""
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
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
                    .font(.caption.weight(.bold)).foregroundStyle(WorktreePalette.color(for: wt.name))
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

