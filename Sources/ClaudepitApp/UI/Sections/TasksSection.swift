import SwiftUI
import ClaudepitCore

extension TaskStatus {
    var color: Color {
        switch self {
        case .backlog:        return .secondary
        case .running:        return .blue
        case .awaitingReview: return .yellow
        case .blocked:        return .orange
        case .failed:         return .red
        case .done:           return .green
        }
    }
}

struct TasksSection: View {
    @ObservedObject var app: AppState

    enum Mode: String, CaseIterable { case board = "Board", list = "List" }
    @State private var mode: Mode = .board
    @State private var selection: String?
    @State private var showNew = false

    enum Sort: String, CaseIterable { case attention = "Needs attention", priority = "Priority", updated = "Recent" }
    @State private var sort: Sort = .attention   // default surfaces waiting tasks

    // Board mode uses a JIRA-style right-side panel (not a modal sheet) for both
    // task detail and new-task creation. nil = no panel.
    private enum Panel: Equatable { case task(String), new }
    @State private var panel: Panel? = nil

    // filters
    @State private var statusFilter: TaskStatus?
    @State private var priorityFilter: Priority?
    @State private var tagFilter: String?
    @State private var timeFilter: TimeFilter = .all
    @State private var showTimeFilter = false

    private var allTags: [String] { Array(Set(app.tasks.flatMap { $0.tags })).sorted() }

    private var filtered: [ProjectTask] {
        app.tasks.filter { t in
            (statusFilter == nil || t.status == statusFilter) &&
            (priorityFilter == nil || t.priority == priorityFilter) &&
            (tagFilter == nil || t.tags.contains(tagFilter!)) &&
            timeFilter.includes(Date(timeIntervalSince1970: t.updatedAt))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !TaskRunner.herdrAvailable() {
                Label("herdr not found — task execution is disabled.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 16)
            }
            content
        }
        .sheet(isPresented: $showNew) { NewTaskSheet(app: app, onClose: { showNew = false }).frame(width: 540, height: 640) }
        .onAppear { app.loadTasks(); applyFocus() }
        .onChange(of: app.focusTaskID) { applyFocus() }
        .onChange(of: mode) { if mode != .board { panel = nil } }   // panel is board-only
    }

    private func applyFocus() {
        guard let id = app.focusTaskID else { return }
        // Clear filters so a deep-linked task (e.g. createPlan Back-to-task) is always visible.
        statusFilter = nil; priorityFilter = nil; tagFilter = nil; timeFilter = .all
        mode = .list; selection = id
        app.focusTaskID = nil
    }

    private var anyFilterActive: Bool {
        statusFilter != nil || priorityFilter != nil || tagFilter != nil || timeFilter.isActive
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                // Board/List toggle first, before the title.
                SegmentedControl(selection: $mode) { Text($0.rawValue) }

                Text("Tasks").font(.title2).bold()

                Text("\(filtered.count) task\(filtered.count == 1 ? "" : "s")")
                    .font(.callout).foregroundStyle(.secondary)

                Spacer()

                if let base = app.activePath {
                    Button {
                        let dir = Paths.tasksRoot(projectSlug: Paths.slug(for: base))
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    } label: { Image(systemName: Icon.revealInFinder) }
                    .buttonStyle(.borderless)
                    .help("Open tasks folder in Finder")
                }
                Button { newTask() } label: {
                    Label("New Task", systemImage: Icon.add)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            // Filter row — standard bordered dropdown menus + a Clear button when any is active.
            HStack(spacing: 8) {
                filterMenu("Status", active: statusFilter?.label) {
                    Button("All Statuses") { statusFilter = nil }
                    Divider()
                    ForEach([TaskStatus.backlog, .running, .awaitingReview, .blocked, .failed, .done], id: \.self) { s in
                        Button(s.label) { statusFilter = s }
                    }
                }
                filterMenu("Priority", active: priorityFilter?.label) {
                    Button("All Priorities") { priorityFilter = nil }
                    Divider()
                    ForEach(Priority.allCases, id: \.self) { p in Button(p.label) { priorityFilter = p } }
                }
                if !allTags.isEmpty {
                    filterMenu("Tag", active: tagFilter) {
                        Button("All Tags") { tagFilter = nil }
                        Divider()
                        ForEach(allTags, id: \.self) { tag in Button(tag) { tagFilter = tag } }
                    }
                }
                filterMenu("Sort", active: sort == .attention ? nil : sort.rawValue) {
                    ForEach(Sort.allCases, id: \.self) { s in Button(s.rawValue) { sort = s } }
                }
                Button { showTimeFilter = true } label: {
                    Label(timeFilter.isActive ? "Date: on" : "Date", systemImage: "calendar")
                        .font(.caption)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .tint(timeFilter.isActive ? .accentColor : nil)
                .popover(isPresented: $showTimeFilter, arrowEdge: .bottom) { TimeFilterPopover(filter: $timeFilter) }

                if anyFilterActive {
                    Button(role: .destructive) {
                        statusFilter = nil; priorityFilter = nil; tagFilter = nil; timeFilter = .all
                    } label: {
                        Label("Clear", systemImage: "xmark.circle").font(.caption)
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                    .help("Clear all filters")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16).padding(.top, 12)
    }

    /// Standard bordered dropdown filter. Shows "Title: value" and tints accent when a value is set.
    @ViewBuilder
    private func filterMenu(_ title: String, active: String?, @ViewBuilder _ items: () -> some View) -> some View {
        Menu {
            items()
        } label: {
            Text(active.map { "\(title): \($0)" } ?? title).font(.caption)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(active != nil ? .accentColor : nil)
        .fixedSize()
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        Group {
            if mode == .list {
                MasterDetailLayout(listWidth: 320) {
                    GlassCard {
                        if filtered.isEmpty { EmptyState("No tasks") }
                        else { TaskListView(tasks: filtered, selection: $selection, app: app, sort: sort) }
                    }
                } detail: {
                    if let id = selection, let t = app.tasks.first(where: { $0.id == id }) {
                        TaskDetailView(task: t, app: app)
                    } else {
                        GlassCard { EmptyState("Select a task") }
                    }
                }
            } else {
                boardWithPanel
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 16)
    }

    // Board + JIRA-style right-side panel. Wide → panel (40% w, floored 380) sits
    // beside a shrunken board; if the board would drop below ~360pt the panel
    // takes over the whole area. `sideBySide` recomputes on window/sidebar resize.
    private var boardWithPanel: some View {
        GeometryReader { geo in
            let panelW = max(380, geo.size.width * 0.40)
            let sideBySide = panel == nil || (geo.size.width - panelW - 20) >= 360
            HStack(spacing: 20) {
                if panel == nil || sideBySide {
                    GlassCard {
                        if filtered.isEmpty { EmptyState("No tasks") }
                        else { TaskBoardView(tasks: filtered, app: app, sort: sort) { panel = .task($0) } }
                    }
                }
                if let p = panel {
                    taskPanel(p)
                        .frame(width: sideBySide ? panelW : nil)
                        .frame(maxWidth: sideBySide ? nil : .infinity, maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(.easeInOut(duration: 0.2), value: panel)
            .animation(.easeInOut(duration: 0.2), value: sideBySide)
        }
    }

    @ViewBuilder
    private func taskPanel(_ p: Panel) -> some View {
        switch p {
        case .new:
            GlassCard { NewTaskSheet(app: app, onClose: { panel = nil }) }
        case .task(let id):
            if let t = app.tasks.first(where: { $0.id == id }) {
                TaskDetailView(task: t, app: app, onDismiss: { panel = nil })
            } else {
                // Task deleted elsewhere while its panel was open → close.
                Color.clear.onAppear { panel = nil }
            }
        }
    }

    /// New Task: board mode opens the side panel; list mode keeps the modal sheet.
    private func newTask() {
        if mode == .board { panel = .new } else { showNew = true }
    }
}
