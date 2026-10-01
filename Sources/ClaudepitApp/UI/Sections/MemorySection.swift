import SwiftUI
import ClaudepitCore

// MARK: - MemorySection

/// The Memory page: the list card (`MemoryListView`) and, beside it, either the knowledge graph
/// (`MemoryGraphPanel`) or the open file (`MemoryFileView`). This view only wires them to
/// `AppState`; the graph is `AppState.memoryGraph`, reloaded by the file watcher, so a file Claude
/// writes mid-session updates in place.
struct MemorySection: View {
    @ObservedObject var app: AppState
    @State private var selection: MemorySelection = .graph
    @State private var query = ""
    @State private var revealRequest: MemorySelection?
    /// The open file, parsed once per selection or change — not on every render.
    @State private var document: MemoryDocument?
    @State private var strategyText = HookScripts.memorySystemPrompt
    @State private var now = Date()
    /// Keeps "12 min ago" honest. In `@State`, not a `let`: the struct is rebuilt on every
    /// `AppState` publish, and a `let` timer restarts each time and may never fire.
    @State private var clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var graph: MemoryGraph { app.memoryGraph }

    private var selectedNode: MemoryNode? {
        guard case .file(let id) = selection else { return nil }
        return graph.nodes.first { $0.id == id }
    }

    private var context: MemoryListContext {
        MemoryListContext(nodes: graph.nodes, edgeCount: graph.edges.count, log: app.memoryLog,
                          memoryEnabled: app.memoryEnabled, strategyText: strategyText,
                          herdrAvailable: Herdr.available(), now: now)
    }

    private var actions: MemoryListActions {
        MemoryListActions(
            setEnabled: { app.memoryEnabled = $0 },
            openFolder: app.activePath.map { base in
                { NSWorkspace.shared.open(Paths.memoryDir(projectSlug: Paths.slug(for: base))) }
            },
            trash: trash,
            launchFix: { done in app.openMemoryFixAgent(done: done) },
            editStrategy: {
                app.focusManagedConfigID = "memory-system-prompt"
                app.selected = .appConfig
            })
    }

    var body: some View {
        MasterDetailLayout(listWidth: 300) {
            GlassCard {
                MemoryListView(context: context, selection: $selection, query: $query,
                               revealRequest: $revealRequest, actions: actions)
            }
        } detail: {
            detail
        }
        .onAppear {
            let memory = app.memoryPageMemory
            selection = memory.selection
            query = memory.query
            now = Date()
            loadStrategy()
            applyFocus(app.focusMemoryFileID)
            refresh()
        }
        .onDisappear {
            app.memoryPageMemory = MemoryPageMemory(selection: selection, query: query)
        }
        .onChange(of: selection) { refresh() }
        .onChange(of: app.memoryGraph) { now = Date(); refresh() }
        .onChange(of: app.focusMemoryFileID) { _, id in applyFocus(id) }
        .onChange(of: app.memoryEnabled) { loadStrategy() }
        .onChange(of: app.activePath) { selection = .graph; query = "" }
        .onReceive(clock) { now = $0 }
    }

    // MARK: Detail card

    @ViewBuilder private var detail: some View {
        if let node = selectedNode, let document {
            MemoryFileView(node: node, document: document, cwd: app.activePath, now: now,
                           herdrAvailable: Herdr.available(),
                           onBack: { selection = .graph },
                           onTrash: { trash(node) },
                           launchFix: { done in app.openMemoryFixAgent(done: done) },
                           linkTarget: $app.focusMemoryFileID,
                           openSession: { sid in
                               app.focusSessionID = sid
                               app.selected = .sessions
                           },
                           sessionTitle: { sid in app.sessions.first { $0.id == sid }?.title })
        } else {
            MemoryGraphPanel(graph: graph, cwd: app.activePath) { id in selection = .file(id) }
        }
    }

    // MARK: Data

    /// Re-reads the open file, and falls back to the graph when it no longer exists.
    private func refresh() {
        if case .file = selection, selectedNode == nil, !graph.nodes.isEmpty || app.activePath == nil {
            selection = .graph
        }
        document = selectedNode.map(MemoryDocument.load)
        app.selectedMemoryTitle = selectedNode?.title
    }

    /// A deep link (Home's Recent, a memory link inside a file) names a file by id, or by bare
    /// filename for a nested one.
    private func applyFocus(_ id: String?) {
        guard let id else { return }
        let name = (id as NSString).lastPathComponent
        if let node = graph.nodes.first(where: { $0.id == id })
            ?? graph.nodes.first(where: { ($0.id as NSString).lastPathComponent == name }) {
            if !node.matches(query) { query = "" }
            selection = .file(node.id)
            revealRequest = .file(node.id)
        }
        app.focusMemoryFileID = nil
    }

    private func loadStrategy() {
        guard let base = app.activePath, let config = ManagedConfig.byID("memory-system-prompt") else { return }
        strategyText = app.appConfig.content(base, config)
    }

    private func trash(_ node: MemoryNode) {
        guard (try? FileManager.default.trashItem(at: node.url, resultingItemURL: nil)) != nil else { return }
        if selection == .file(node.id) { selection = .graph }
        app.reloadMemory()
    }
}
