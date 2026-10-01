import SwiftUI
import ClaudepitCore

/// A memory file read for display: its frontmatter, and its body split where Claude stops
/// reading (`MemoryReadLimit`). Built once per selection or change, not on every render.
struct MemoryDocument {
    let frontmatter: MemoryFrontmatter?
    let kept: String
    /// What Claude never reads — nil when the whole body fits.
    let remainder: String?

    static func load(_ node: MemoryNode) -> MemoryDocument {
        guard let raw = try? String(contentsOf: node.url, encoding: .utf8) else {
            return MemoryDocument(frontmatter: nil, kept: "_Could not read file._", remainder: nil)
        }
        let (fm, body) = MemoryFrontmatter.parse(from: raw)
        let cut = MemoryReadLimit.split(body)
        return MemoryDocument(frontmatter: node.isRoot ? nil : fm,
                              kept: cut?.kept ?? body, remainder: cut?.remainder)
    }
}

// MARK: - File

/// One memory file: its title and facts (size against the read limit, last change, whether the
/// index links it), Ask, and the file itself — with a marked cut where Claude stops reading.
struct MemoryFileView: View {
    let node: MemoryNode
    let document: MemoryDocument
    let cwd: URL?
    var now = Date()
    var herdrAvailable = false
    var onBack: () -> Void = {}
    var onTrash: () -> Void = {}
    var launchFix: (@escaping @MainActor (Bool) -> Void) -> Void = { $0(false) }
    /// A memory-file link in the text was clicked (its target file id).
    var linkTarget: Binding<String?>? = nil
    var openSession: ((String) -> Void)? = nil
    var sessionTitle: (String) -> String? = { _ in nil }
    var initiallyAsking = false

    @State private var showQA = false

    var body: some View {
        GeometryReader { geo in
            GlassCard {
                VStack(spacing: 0) {
                    header
                    Divider().opacity(0.15)
                    if showQA {
                        PlanQAPanel(planContent: node.body, cwd: cwd, title: "Ask about this memory file",
                                    showImprovement: false, focusOnAppear: true)
                            .frame(height: geo.size.height * 0.4)
                        Divider().opacity(0.15)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let fm = document.frontmatter, fm.hasContent {
                                MemoryFrontmatterCard(frontmatter: fm, openSession: openSession,
                                                      sessionTitle: sessionTitle)
                            }
                            MarkdownText(document.kept)
                            if let remainder = document.remainder { cut(remainder) }
                        }
                        .frame(maxWidth: DocumentDetailView.readingWidth, alignment: .topLeading)
                        .padding(.horizontal, 24).padding(.vertical, 18)
                        .frame(maxWidth: .infinity)
                    }
                    .environment(\.focusMemoryFileID, linkTarget)
                }
            }
        }
        .onAppear { if initiallyAsking { showQA = true } }
        .onChange(of: node.id) { showQA = false }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onBack) {
                Label("Knowledge Graph", systemImage: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Back to the graph of every memory file")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(node.displayTitle).font(.headline).lineLimit(1).truncationMode(.tail)
                    .help(node.displayTitle)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    HeaderButton(title: "Ask", icon: "bubble.left.and.text.bubble.right",
                                 help: showQA ? "Close the questions panel" : "Ask Claude about this memory file",
                                 isOn: showQA) { showQA.toggle() }
                    HeaderButton(title: "Open", icon: Icon.openFile, help: "Open in your default editor") {
                        NSWorkspace.shared.open(node.url)
                    }
                    HeaderMenu {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([node.url]) } label: {
                            Label("Reveal in Finder", systemImage: Icon.revealInFinder)
                        }
                        Button { copy(node.url.path) } label: { Label("Copy Path", systemImage: Icon.copyPath) }
                        Divider()
                        Button(role: .destructive, action: onTrash) { Label("Move to Trash", systemImage: Icon.delete) }
                    }
                }
            }
            FlowLayout(spacing: 10) {
                HeaderFact(icon: node.isRoot ? "list.bullet.rectangle" : "doc.text", text: node.id, help: node.url.path)
                if let size = node.size {
                    HeaderFact(icon: node.exceedsReadLimit ? "scissors" : "ruler", text: size.label,
                               help: node.exceedsReadLimit
                                   ? "Over the read limit — Claude reads only the first \(MemoryReadLimit.maxLines) lines or \(MemoryReadLimit.maxBytes / 1000) KB"
                                   : "Within the read limit (\(MemoryReadLimit.maxLines) lines or \(MemoryReadLimit.maxBytes / 1000) KB)",
                               color: node.exceedsReadLimit ? .orange : .secondary)
                }
                if let modified = node.modifiedAt {
                    HeaderFact(icon: "clock", text: SessionTimeLabel.text(for: modified, now: now, inDateSection: false),
                               help: "Last changed " + modified.formatted(date: .complete, time: .shortened))
                }
                if node.isOrphan {
                    HeaderFact(icon: "link.badge.plus", text: "Not in MEMORY.md",
                               help: "Nothing links to this file, so Claude may never read it. Link it from MEMORY.md, or merge it into a topic.",
                               color: .orange)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 10)
    }

    /// Where Claude stops reading, and what it never sees, faded.
    private func cut(_ remainder: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 6) {
                HStack {
                    Rectangle().fill(Color.orange.opacity(0.5)).frame(height: 1)
                    Image(systemName: "scissors")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Rectangle().fill(Color.orange.opacity(0.5)).frame(height: 1)
                }
                Text("Claude stops reading here — the file exceeds "
                     + "\(MemoryReadLimit.maxLines) lines or \(MemoryReadLimit.maxBytes / 1000) KB")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange.opacity(0.85))
                MemoryFixButton(herdrAvailable: herdrAvailable, hasWork: true, launch: launchFix)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            MarkdownText(remainder)
                .opacity(0.3)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Graph

/// The right card when no file is open: every memory file and the links between them, with a
/// legend, a Fit control, and Ask across all of memory (its answer lights up the files it names).
struct MemoryGraphPanel: View {
    let graph: MemoryGraph
    let cwd: URL?
    var onOpen: (String) -> Void = { _ in }
    var initiallyAsking = false

    @State private var showQA = false
    @State private var highlights: Set<String> = []
    @State private var fitToken = 0

    var body: some View {
        GeometryReader { geo in
            GlassCard {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider().opacity(0.15)
                    if showQA {
                        PlanQAPanel(planContent: allMemory, cwd: cwd, title: "Ask about all memory files",
                                    showImprovement: false,
                                    onAnswer: { answer in highlights = Self.namedNodes(in: answer, graph: graph) },
                                    focusOnAppear: true)
                            .frame(height: geo.size.height * 0.4)
                        Divider().opacity(0.15)
                    }
                    if graph.nodes.isEmpty {
                        PageListEmptyState(icon: "point.3.filled.connected.trianglepath.dotted",
                                           title: "No memory files yet",
                                           detail: "Claude builds a knowledge graph here as it saves what it learns about this project.")
                    } else {
                        D3GraphView(graph: graph, highlightedIDs: highlights, fitToken: fitToken, onNodeTap: onOpen)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .bottomLeading) { legend.padding(12) }
                    }
                }
            }
        }
        .onAppear { if initiallyAsking { showQA = true } }
    }

    private var header: some View {
        let unlinked = graph.nodes.filter(\.isOrphan).count
        let oversized = graph.nodes.filter(\.exceedsReadLimit).count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Knowledge Graph").font(.headline)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    HeaderButton(title: "Ask", icon: "bubble.left.and.text.bubble.right",
                                 help: showQA ? "Close the questions panel"
                                              : "Ask Claude across every memory file — the files its answer names light up",
                                 isOn: showQA) {
                        showQA.toggle()
                        if !showQA { highlights = [] }
                    }
                    .disabled(graph.nodes.isEmpty)
                    HeaderButton(title: "Fit", icon: "arrow.up.left.and.arrow.down.right",
                                 help: "Zoom to show the whole graph") { fitToken += 1 }
                        .disabled(graph.nodes.isEmpty)
                }
            }
            FlowLayout(spacing: 10) {
                HeaderFact(icon: "doc.on.doc", text: "\(graph.nodes.count) files")
                HeaderFact(icon: "link", text: "\(graph.edges.count) links")
                if oversized > 0 {
                    HeaderFact(icon: "scissors", text: "\(oversized) over the read limit",
                               help: "Claude stops reading these partway", color: .orange)
                }
                if unlinked > 0 {
                    HeaderFact(icon: "link.badge.plus", text: "\(unlinked) not in MEMORY.md",
                               help: "Nothing links to these, so Claude may never read them", color: .orange)
                }
                Text("Drag to move · scroll to zoom · click to open")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(Circle().fill(Color(red: 0.47, green: 0.39, blue: 0.94)), "Index")
            legendItem(Circle().fill(Color.gray.opacity(0.6)), "Topic")
            legendItem(Circle().strokeBorder(Color.orange, lineWidth: 2), "Over limit")
            legendItem(Circle().strokeBorder(Color.gray, style: StrokeStyle(lineWidth: 1.4, dash: [2.5, 2])), "Unlinked")
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .allowsHitTesting(false)
    }

    private func legendItem<S: View>(_ swatch: S, _ label: String) -> some View {
        HStack(spacing: 4) {
            swatch.frame(width: 9, height: 9)
            Text(label)
        }
    }

    /// Every file's body under its name — from the loaded graph, so asking reads no files.
    private var allMemory: String {
        graph.nodes
            .sorted { $0.isRoot != $1.isRoot ? $0.isRoot : $0.title < $1.title }
            .map { "### \($0.displayTitle)\n\($0.body)" }
            .joined(separator: "\n\n---\n\n")
    }

    /// The files an answer mentions by title or filename.
    static func namedNodes(in text: String, graph: MemoryGraph) -> Set<String> {
        let lower = text.lowercased()
        return Set(graph.nodes.filter { n in
            lower.contains(n.title.lowercased()) || lower.contains(n.id.lowercased())
        }.map(\.id))
    }
}

// MARK: - Fix button

/// Opens a Claude agent in herdr briefed to split and trim every oversized memory file
/// (`MemoryReadLimit.fixPrompt`). Reports a launch failure inline rather than doing nothing.
struct MemoryFixButton: View {
    let herdrAvailable: Bool
    let hasWork: Bool
    let launch: (@escaping @MainActor (Bool) -> Void) -> Void
    @State private var launching = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                launching = true
                failed = false
                launch { ok in
                    launching = false
                    failed = !ok
                }
            } label: {
                HStack(spacing: 5) {
                    if launching {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "terminal").font(.system(size: 10))
                    }
                    Text(launching ? "Opening herdr…" : "Fix with Claude in herdr")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.orange)
            .disabled(launching || !herdrAvailable || !hasWork)
            .help(herdrAvailable
                  ? "Open a Claude agent in herdr that splits the oversized files into focused topic "
                    + "files and trims them, keeping every decision and rule"
                  : "herdr isn't installed — it's needed to run the agent")
            if failed {
                Text("Couldn't start the agent in herdr.")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Frontmatter

extension MemoryFrontmatter {
    /// Anything worth a card: a description, a type, a date or a session.
    var hasContent: Bool {
        (description?.isEmpty == false) || type != nil || modified != nil || !sessions.isEmpty || originSessionId != nil
    }
}

/// A topic file's frontmatter: what it covers, its kind, when it was last written, and the
/// sessions that wrote it (each one opens that session).
struct MemoryFrontmatterCard: View {
    let frontmatter: MemoryFrontmatter
    var openSession: ((String) -> Void)? = nil
    var sessionTitle: (String) -> String? = { _ in nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let desc = frontmatter.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            FlowLayout(spacing: 6) {
                if let type = frontmatter.type, !type.isEmpty {
                    Pill(type, color: .teal, hPadding: 7, vPadding: 2)
                        .help("Memory type")
                }
                if let modified = frontmatter.modified {
                    Text("Written \(modified.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                let sessions = frontmatter.sessions.isEmpty ? frontmatter.originSessionId.map { [$0] } ?? [] : frontmatter.sessions
                if !sessions.isEmpty {
                    Text(sessions.count == 1 ? "Session" : "\(sessions.count) sessions")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    ForEach(sessions, id: \.self) { sid in
                        sessionPill(id: sid, isOrigin: sid == frontmatter.originSessionId)
                    }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.12)))
    }

    private func sessionPill(id: String, isOrigin: Bool) -> some View {
        Button { openSession?(id) } label: {
            HStack(spacing: 3) {
                if isOrigin {
                    Image(systemName: "star.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(Color.accentColor)
                }
                Text(String(id.prefix(8)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isOrigin ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(
                isOrigin ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 5)
            )
        }
        .buttonStyle(.plain)
        .disabled(openSession == nil)
        .help([sessionTitle(id), isOrigin ? "Created this file" : nil, id, "Click to open the session"]
            .compactMap { $0 }.joined(separator: "\n"))
    }
}

// MARK: - Strategy popover

/// What the memory strategy installs: the rules file as it is installed in this project, and
/// the two things the end-of-session hook can say.
struct MemoryInspectorPopover: View {
    var strategyText: String = HookScripts.memorySystemPrompt
    /// Jump to the strategy's card in App Settings, where it is edited.
    var onEdit: (() -> Void)? = nil
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "brain")
                    .foregroundStyle(.secondary)
                Text("Memory Strategy")
                    .font(.headline)
                Spacer()
                if let onEdit {
                    Button(action: onEdit) {
                        Label("Edit in App Settings", systemImage: "slider.horizontal.3")
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Picker("", selection: $tab) {
                Text("Rules File").tag(0)
                Text("Stop Hook").tag(1)
                Text("Stop Hook (Dream)").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            Divider().opacity(0.2)

            ScrollView {
                MarkdownText(tab == 0 ? strategyText
                             : tab == 1 ? HookScripts.memoryHookReminder : HookScripts.memoryHookDreaming)
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 700, height: 650)
    }

    private var caption: String {
        switch tab {
        case 0: return "Installed as .claude/rules/claudepit-memory.md — Claude reads it once at session start."
        case 1: return "What the end-of-session hook tells Claude after a session that changed files."
        default: return "What the hook says instead once 10 memory passes have piled up since the last consolidation."
        }
    }
}
