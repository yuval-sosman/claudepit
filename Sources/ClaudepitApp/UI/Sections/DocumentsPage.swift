import SwiftUI
import ClaudepitCore

/// The Plans page: every plan Claude wrote in plan mode.
struct PlansSection: View {
    @ObservedObject var app: AppState
    var body: some View { DocumentsPage(app: app, kind: .plan) }
}

/// The Specs page: every spec a task's Spec phase wrote, in this project.
struct SpecsSection: View {
    @ObservedObject var app: AppState
    var body: some View { DocumentsPage(app: app, kind: .spec) }
}

/// The Plans and Specs pages — one design over two sources: the list card (`DocumentListView`)
/// and the document being read (`DocumentDetailView`). This view only wires them to `AppState`;
/// the lists themselves are `AppState.plans`/`specs`, refreshed by the file watcher, so a document
/// Claude is writing updates in place. Everything that differs between the two pages is in
/// `DocumentKind` (wording) and `Source` (which `AppState` fields they read and write).
struct DocumentsPage: View {
    @ObservedObject var app: AppState
    let kind: DocumentKind

    @State private var selection: URL?
    @State private var query = ""
    @State private var timeFilter: TimeFilter = .all
    /// A document another page linked to: the list scrolls it into view once, then lets go.
    @State private var reveal: URL?
    @State private var now = Date()
    /// Keeps "12 min ago" honest. In `@State`, not a `let`: the struct is rebuilt on every
    /// `AppState` publish, and a `let` timer restarts each time and may never fire.
    @State private var clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// Where each page's state lives on `AppState`.
    private struct Source {
        let docs: KeyPath<AppState, [MarkdownDoc]>
        let focusPath: ReferenceWritableKeyPath<AppState, String?>
        let returnToTask: ReferenceWritableKeyPath<AppState, String?>
        let memory: ReferenceWritableKeyPath<AppState, DocumentPageMemory>
        let selectedName: ReferenceWritableKeyPath<AppState, String?>
    }

    private var source: Source {
        switch kind {
        case .plan:
            return Source(docs: \.plans, focusPath: \.focusPlanPath, returnToTask: \.returnToTaskID,
                          memory: \.plansPageMemory, selectedName: \.selectedPlanName)
        case .spec:
            return Source(docs: \.specs, focusPath: \.focusSpecPath, returnToTask: \.returnToSpecTaskID,
                          memory: \.specsPageMemory, selectedName: \.selectedSpecName)
        }
    }

    private var docs: [MarkdownDoc] { app[keyPath: source.docs] }
    private var focusPath: String? { app[keyPath: source.focusPath] }

    /// Plans can be trashed; a spec belongs to its task, so the Specs page offers no Trash.
    private var trashAction: ((MarkdownDoc) -> Void)? {
        kind == .plan ? { doc in trash(doc) } : nil
    }

    private func brainstorm(_ doc: MarkdownDoc, done: @MainActor @escaping (Bool) -> Void) {
        app.openDocumentBrainstorm(noun: kind.noun, doc: doc, done: done)
    }

    private func reloadDocs() {
        if kind == .plan { app.reloadPlanFiles() } else { app.loadTasks() }
    }

    private var selected: MarkdownDoc? {
        selection.flatMap { id in docs.first { $0.id == id } }
    }

    var body: some View {
        MasterDetailLayout(listWidth: 300) {
            GlassCard {
                DocumentListView(kind: kind, docs: docs, now: now, selection: $selection, query: $query,
                                 timeFilter: $timeFilter, revealRequest: $reveal,
                                 onTrash: trashAction, onOpenFolder: openFolder,
                                 onBrainstorm: Herdr.available() ? { doc in brainstorm(doc) { _ in } } : nil)
            }
        } detail: {
            detailCard
        }
        .onAppear {
            let memory = app[keyPath: source.memory]
            selection = memory.selection
            query = memory.query
            timeFilter = memory.timeFilter
            now = Date()
            if kind == .plan { app.reloadPlanFiles() }
            applyFocus()
            ensureSelection()
        }
        .onDisappear {
            app[keyPath: source.memory] = DocumentPageMemory(selection: selection, query: query, timeFilter: timeFilter)
        }
        .onChange(of: focusPath) { applyFocus() }
        .onChange(of: docs) { now = Date(); ensureSelection() }
        .onChange(of: selection) { app[keyPath: source.selectedName] = selected?.title }
        .onChange(of: app.activePath) { if kind == .spec { selection = nil; query = "" } }
        .onReceive(clock) { now = $0 }
    }

    // MARK: Detail card

    @ViewBuilder private var detailCard: some View {
        if let doc = selected {
            DocumentDetailView(kind: kind, doc: doc, cwd: app.activePath, now: now,
                               backToTask: app[keyPath: source.returnToTask].map { tid in
                                   {
                                       app.focusTaskID = tid
                                       app[keyPath: source.returnToTask] = nil
                                       app.selected = .tasks
                                   }
                               },
                               openTask: taskOpener(for: doc),
                               onTrash: trashAction.map { action in { action(doc) } },
                               onChanged: reloadDocs,
                               brainstorm: Herdr.available() ? { done in brainstorm(doc, done: done) } : nil)
        } else {
            GlassCard {
                PageListEmptyState(icon: kind.emptyIcon,
                                   title: docs.isEmpty ? kind.emptyTitle : "Select a \(kind.noun)",
                                   detail: docs.isEmpty ? kind.emptyDetail
                                                        : "Pick one on the left, or move through the list with ↑ and ↓.")
            }
        }
    }

    /// A spec's task, when it still exists — an orphaned task folder has none to open.
    private func taskOpener(for doc: MarkdownDoc) -> (() -> Void)? {
        guard kind == .spec, app.tasks.contains(where: { $0.id == doc.tag }) else { return nil }
        return {
            app.focusTaskID = doc.tag
            app.selected = .tasks
        }
    }

    private var openFolder: (() -> Void)? {
        switch kind {
        case .plan:
            return { NSWorkspace.shared.open(Paths.plansRoot) }
        case .spec:
            guard let base = app.activePath else { return nil }
            return { NSWorkspace.shared.open(Paths.tasksRoot(projectSlug: Paths.slug(for: base))) }
        }
    }

    // MARK: Data

    /// Keeps a document on screen: the remembered one if it still exists, else the newest.
    private func ensureSelection() {
        if selected == nil { selection = docs.first?.id }
        app[keyPath: source.selectedName] = selected?.title
    }

    private func applyFocus() {
        guard let path = app[keyPath: source.focusPath] else { return }
        if kind == .plan { app.reloadPlanFiles() }
        let target = URL(filePath: path).standardizedFileURL.path
        if let doc = docs.first(where: { $0.url.standardizedFileURL.path == target }) {
            selection = doc.id
            // A linked document must show even if the search or date filter would hide it.
            if !timeFilter.includes(doc.modifiedAt) { timeFilter = .all }
            if !doc.matches(query) { query = "" }
            reveal = doc.id
        }
        app[keyPath: source.focusPath] = nil
    }

    /// Moves a plan to the Trash and selects its neighbour, so the reader stays in the list.
    private func trash(_ doc: MarkdownDoc) {
        let order = docs.map(\.id)
        let next = order.firstIndex(of: doc.id).flatMap { i -> URL? in
            if i + 1 < order.count { return order[i + 1] }
            return i > 0 ? order[i - 1] : nil
        }
        guard (try? FileManager.default.trashItem(at: doc.url, resultingItemURL: nil)) != nil else { return }
        if selection == doc.id { selection = next }
        app.reloadPlanFiles()
    }
}
