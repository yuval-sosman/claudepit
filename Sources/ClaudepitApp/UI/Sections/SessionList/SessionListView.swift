import SwiftUI
import AppKit
import ClaudepitCore

/// What the list can ask the app to do. Plain closures, so the list renders without `AppState`
/// (the DEBUG `--snapshot-sessions` tool supplies stand-ins).
struct SessionListActions {
    var openTranscript: (SessionSummary) -> Void = { NSWorkspace.shared.open($0.fileURL) }
    /// Resume in herdr, or focus its pane when already open. nil without herdr.
    var resume: ((SessionSummary) -> Void)?
    var openTask: ((String) -> Void)?
    var createGroup: (_ name: String, _ key: String, _ ids: [String]) -> Result<SessionGroup, GroupNameError> = { _, _, _ in .failure(.empty) }
    var renameGroup: (_ id: String, _ name: String, _ key: String) -> GroupNameError? = { _, _, _ in nil }
    var recolorGroup: (_ id: String, _ color: GroupColor, _ key: String) -> Void = { _, _, _ in }
    var deleteGroup: (_ id: String, _ key: String) -> Void = { _, _ in }
    var moveGroup: (_ id: String, _ offset: Int, _ key: String) -> Void = { _, _, _ in }
    var setGroupCollapsed: (_ id: String, _ collapsed: Bool, _ key: String) -> Void = { _, _, _ in }
    var assign: (_ ids: [String], _ groupID: String, _ key: String) -> Void = { _, _, _ in }
    var unassign: (_ ids: [String]) -> Void = { _ in }
    var trash: (_ sessions: [SessionSummary]) -> Void = { _ in }
    var discover: (_ query: String) -> Void = { _ in }
}

/// The Sessions page's left card: Recent (by day) and Groups (yours, then one per task, then the
/// rest), with search, filters, keyboard navigation, multi-selection and drag-to-group.
struct SessionListView: View {
    let sessions: [SessionSummary]
    let context: SessionListContext
    @Binding var prefs: SessionListPrefs
    @ObservedObject var state: SessionListState
    let actions: SessionListActions

    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var hoveredID: String?
    @State private var dropTarget: String?
    @State private var showCustomRange = false

    var body: some View {
        let model = SessionListModel(sessions: sessions, context: context, prefs: prefs, query: state.query,
                                     includeDate: state.timeFilter.includes, expanded: state.expanded)
        VStack(spacing: 0) {
            header
            searchRow
            chips
            content(model)
        }
        .onAppear { ensureSelection(model) }
        .onChange(of: sessions.count) { ensureSelection(model) }
        .onChange(of: state.revealRequest) { _, id in
            guard let id else { return }
            state.revealRequest = nil
            reveal(id)
        }
        .confirmationDialog(trashTitle, isPresented: trashBinding, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { performTrash(model) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(trashMessage)
        }
        .confirmationDialog(groupDeleteTitle, isPresented: groupDeleteBinding, titleVisibility: .visible,
                            presenting: state.pendingGroupDelete) { pending in
            Button("Delete Group", role: .destructive) { actions.deleteGroup(pending.group.id, pending.key) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.count == 0
                 ? "The group is empty."
                 : "Its \(pending.count) session\(pending.count == 1 ? "" : "s") move to Ungrouped. The sessions themselves are kept.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            ForEach([SessionListTab.recent, .groups], id: \.self) { tab in
                Button { prefs.tab = tab } label: {
                    Text(tab == .recent ? "Recent" : "Groups")
                        .font(.body)
                        .fontWeight(prefs.tab == tab ? .semibold : .regular)
                        .foregroundStyle(prefs.tab == tab ? .primary : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .overlay(alignment: .bottom) {
                            if prefs.tab == tab {
                                Rectangle().fill(Color.accentColor).frame(height: 2).cornerRadius(1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if prefs.tab == .groups {
                Button { startNewGroup(ids: []) } label: {
                    Image(systemName: Icon.add)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(newGroupKey(for: []) == nil)
                .help("New Group")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var searchRow: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: Icon.search).font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search sessions", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .focused($searchFocused)
                    .onExitCommand { state.query = "" }
                    .onKeyPress(.downArrow) {
                        listFocused = true
                        moveSelection(1, extend: false, order: currentOrder)
                        return .handled
                    }
                if !state.query.isEmpty {
                    Button { state.query = "" } label: {
                        Image(systemName: Icon.clearField).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .help("Searches titles, summaries, tasks, groups and session ids (⌥⌘F)")

            filterMenu

            Button { actions.discover(state.query) } label: {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, 8)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Discover — find sessions by describing what happened in them")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .opacity(0).frame(width: 0, height: 0)
        }
    }

    private var filtersActive: Bool { state.timeFilter.isActive || !prefs.showTaskSessions }

    private var filterMenu: some View {
        Menu {
            Picker(selection: datePresetBinding) {
                Text("Any Time").tag("all")
                ForEach(TimePreset.allCases, id: \.self) { p in Text(p.menuTitle).tag(p.rawValue) }
                if case .custom = state.timeFilter { Text("Custom Range").tag("custom") }
            } label: { Text("Modified") }
            .pickerStyle(.inline)
            Button("Custom Range…") { showCustomRange = true }
            Divider()
            Toggle("Show Task Sessions", isOn: $prefs.showTaskSessions)
            Toggle("Show Summaries", isOn: $prefs.showSummaries)
            Toggle("Group Task Sessions Automatically", isOn: $prefs.automaticTaskGroups)
            if filtersActive {
                Divider()
                Button("Clear Filters") { clearFilters() }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12, weight: filtersActive ? .bold : .regular))
                .foregroundStyle(filtersActive ? Color.accentColor : .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // A borderless menu draws its label bare, so the button's chrome goes outside it.
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 6)
        .background(filtersActive ? Color.accentColor.opacity(0.16) : .white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 7))
        .help("Filter and view options")
        .popover(isPresented: $showCustomRange, arrowEdge: .bottom) {
            TimeFilterPopover(filter: $state.timeFilter)
        }
    }

    private var datePresetBinding: Binding<String> {
        Binding(
            get: {
                switch state.timeFilter {
                case .all: return "all"
                case .preset(let p): return p.rawValue
                case .custom: return "custom"
                }
            },
            set: { tag in
                if tag == "all" { state.timeFilter = .all }
                else if let p = TimePreset(rawValue: tag) { state.timeFilter = .preset(p) }
            })
    }

    @ViewBuilder private var chips: some View {
        if filtersActive {
            HStack(spacing: 6) {
                if state.timeFilter.isActive {
                    chip("Modified: \(state.timeFilter.menuLabel)") { state.timeFilter = .all }
                }
                if !prefs.showTaskSessions {
                    chip("Task sessions hidden") { prefs.showTaskSessions = true }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    private func chip(_ text: String, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(text)
            Button(action: clear) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Remove filter")
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.2), in: Capsule())
    }

    // MARK: - Content

    @ViewBuilder private func content(_ model: SessionListModel) -> some View {
        if sessions.isEmpty {
            emptyState(icon: "bubble.left.and.text.bubble.right", title: "No sessions yet",
                       detail: "Sessions appear here as soon as you run claude in this project.") { EmptyView() }
        } else if model.sections.isEmpty && state.newGroup == nil {
            noMatches
        } else {
            list(model)
        }
    }

    private var noMatches: some View {
        emptyState(icon: "magnifyingglass",
                   title: state.query.isEmpty ? "Nothing matches these filters" : "No sessions match “\(state.query)”",
                   detail: state.query.isEmpty ? "Try a wider date range, or show task sessions."
                                               : "Search reads titles, summaries, tasks and groups. Discover reads what happened inside sessions.") {
            VStack(spacing: 6) {
                if !state.query.isEmpty {
                    Button { actions.discover(state.query) } label: {
                        Label("Search with Discover", systemImage: "sparkle.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                }
                if !state.query.isEmpty || filtersActive {
                    Button("Clear Search and Filters") { state.query = ""; clearFilters() }
                        .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
        }
    }

    private func emptyState<Extra: View>(icon: String, title: String, detail: String,
                                         @ViewBuilder extra: () -> Extra) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(.tertiary)
            Text(title).font(.callout.weight(.semibold)).multilineTextAlignment(.center)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            extra().padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(_ model: SessionListModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    if prefs.tab == .groups { groupsTop(model) }
                    ForEach(model.sections) { section in
                        SwiftUI.Section {
                            if !section.collapsed { sectionRows(section, model) }
                        } header: {
                            sectionHeader(section)
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { handleKey($0, model) }
            .onChange(of: state.scrollRequest) { _, request in
                guard let request else { return }
                if request.center {
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(request.id, anchor: .center) }
                } else {
                    proxy.scrollTo(request.id)
                }
            }
        }
    }

    // MARK: Rows

    @ViewBuilder private func sectionRows(_ section: SessionListModel.Section, _ model: SessionListModel) -> some View {
        if section.sessions.isEmpty, let placeholder = section.placeholder {
            Text(placeholder)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(dropTarget == section.id ? Color.accentColor : Color.white.opacity(0.15)))
                .padding(.horizontal, 12).padding(.vertical, 2)
                .modifier(DropTargetModifier(section: section, dropTarget: $dropTarget, onDrop: drop))
        }
        ForEach(section.sessions) { s in
            sessionRow(s, section: section, model: model)
            if state.expanded.contains(s.id) {
                ForEach(s.subagents) { sub in
                    let id = SessionListModel.subagentID(parent: s.id, sub: sub.id)
                    SubagentRowView(sub: sub, isSelected: state.selection.contains(id),
                                    isFocused: listFocused, isHovered: hoveredID == id)
                        .id(id)
                        .contentShape(Rectangle())
                        .onTapGesture { click(id, model: model) }
                        .onHover { hover(id, $0) }
                }
            }
        }
    }

    private func sessionRow(_ s: SessionSummary, section: SessionListModel.Section, model: SessionListModel) -> some View {
        SessionRowView(
            session: s, context: context, prefs: prefs,
            inDateSection: prefs.tab == .recent,
            isSelected: state.selection.contains(s.id),
            isFocused: listFocused,
            isHovered: hoveredID == s.id,
            isExpanded: state.expanded.contains(s.id),
            onToggleExpand: { toggleExpanded(s.id) }
        ) {
            sessionMenu(targets(for: s))
        }
        .id(s.id)
        .contentShape(Rectangle())
        .onTapGesture { click(s.id, model: model) }
        .onHover { hover(s.id, $0) }
        .contextMenu { sessionMenu(targets(for: s)) }
        .draggable(SessionDragPayload.encode(targets(for: s).map(\.id))) {
            dragPreview(targets(for: s))
        }
        .modifier(DropTargetModifier(section: section, dropTarget: $dropTarget, onDrop: drop))
    }

    private func dragPreview(_ targets: [SessionSummary]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: targets.count > 1 ? "square.stack" : "text.bubble")
            Text(targets.count > 1 ? "\(targets.count) sessions" : context.title(of: targets[0]))
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }

    // MARK: Section headers

    @ViewBuilder private func sectionHeader(_ section: SessionListModel.Section) -> some View {
        switch section.header {
        case .date(let title):
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
                .background(headerBackground)
        case .caption(let title):
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 2)
                .background(headerBackground)
        case let .group(key, group, count, projectName, isFirst, isLast):
            groupHeader(section, key: key, group: group, count: count, projectName: projectName,
                        isFirst: isFirst, isLast: isLast)
        case let .taskGroup(taskID, name, count):
            foldHeader(section, collapsed: section.collapsed,
                       toggle: { toggleTaskGroup(taskID) },
                       help: "Sessions of this task's phases — click to \(section.collapsed ? "show" : "fold")") {
                Image(systemName: "checklist").font(.system(size: 10, weight: .semibold)).foregroundStyle(.teal)
                Text(name).font(.caption.weight(.semibold)).lineLimit(1)
                countLabel(count)
            } menu: {
                if let open = actions.openTask {
                    Button { open(taskID) } label: { Label("Open Task", systemImage: "checklist") }
                }
                Button(section.collapsed ? "Expand" : "Collapse") { toggleTaskGroup(taskID) }
            }
        case .ungrouped(let count):
            foldHeader(section, collapsed: section.collapsed,
                       toggle: { prefs.ungroupedCollapsed.toggle() },
                       help: "Sessions in no group — drop a session here to take it out of its group") {
                Text("Ungrouped").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                countLabel(count)
            } menu: {
                Button(section.collapsed ? "Expand" : "Collapse") { prefs.ungroupedCollapsed.toggle() }
            }
        }
    }

    private func groupHeader(_ section: SessionListModel.Section, key: String, group: SessionGroup, count: Int,
                             projectName: String?, isFirst: Bool, isLast: Bool) -> some View {
        foldHeader(section, collapsed: section.collapsed,
                   toggle: { actions.setGroupCollapsed(group.id, !group.isCollapsed, key) },
                   help: "Click to \(section.collapsed ? "show" : "fold") · double-click the name to rename · drop sessions here to file them") {
            Circle().fill(group.color.swiftUIColor).frame(width: 8, height: 8)
            if state.renamingGroupID == group.id {
                GroupNameField(initial: group.name, placeholder: "Group name",
                               commit: { name in
                                   if name == group.name { state.renamingGroupID = nil; return nil }
                                   let error = actions.renameGroup(group.id, name, key)
                                   if error == nil { state.renamingGroupID = nil }
                                   return error
                               },
                               cancel: { state.renamingGroupID = nil })
            } else {
                // Double-click renames; a single click still folds. Exclusive, so a double-click
                // doesn't also fold and unfold the group on the way.
                Text(group.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .gesture(TapGesture(count: 2).onEnded { state.renamingGroupID = group.id }
                        .exclusively(before: TapGesture().onEnded {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                actions.setGroupCollapsed(group.id, !group.isCollapsed, key)
                            }
                        }))
            }
            if let projectName {
                Text(projectName).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            countLabel(count)
        } menu: {
            groupMenu(key: key, group: group, count: count, isFirst: isFirst, isLast: isLast)
        }
    }

    /// A foldable section header: chevron, label, count, hover menu; right-click shows the menu
    /// too, and the whole header is a drop target when its section is.
    private func foldHeader<Label: View, Menu_: View>(_ section: SessionListModel.Section, collapsed: Bool,
                                                     toggle: @escaping () -> Void, help: String,
                                                     @ViewBuilder label: () -> Label,
                                                     @ViewBuilder menu: @escaping () -> Menu_) -> some View {
        let id = "header-\(section.id)"
        let targeted = dropTarget == section.id
        return HStack(spacing: 6) {
            Image(systemName: Icon.chevronCollapsed)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .frame(width: 10)
            label()
            Spacer(minLength: 4)
            Menu { menu() } label: {
                Image(systemName: Icon.moreActions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hoveredID == id ? 1 : 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(targeted ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor.opacity(targeted ? 0.8 : 0)))
        .padding(.horizontal, 6).padding(.top, 4)
        .background(headerBackground)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { toggle() } }
        .onHover { hover(id, $0) }
        .contextMenu { menu() }
        .help(help)
        .modifier(DropTargetModifier(section: section, dropTarget: $dropTarget, onDrop: drop))
    }

    private func countLabel(_ count: Int) -> some View {
        Text("\(count)").font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
    }

    /// Pinned headers sit over the rows scrolling beneath them.
    private var headerBackground: some View {
        Rectangle().fill(.ultraThinMaterial).opacity(0.96)
    }

    // MARK: Groups tab — intro and the new-group editor

    @ViewBuilder private func groupsTop(_ model: SessionListModel) -> some View {
        if let draft = state.newGroup {
            let existing = context.groups[draft.key]?.groups ?? []
            HStack(spacing: 6) {
                Circle().fill(GroupColor.next(after: existing).swiftUIColor).frame(width: 8, height: 8)
                GroupNameField(initial: "", placeholder: draft.sessionIDs.isEmpty ? "New group name"
                               : "Name a group for \(draft.sessionIDs.count) session\(draft.sessionIDs.count == 1 ? "" : "s")",
                               commit: { name in
                                   switch actions.createGroup(name, draft.key, draft.sessionIDs) {
                                   case .success: state.newGroup = nil; return nil
                                   case .failure(let e): return e
                                   }
                               },
                               cancel: { state.newGroup = nil })
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        } else if !model.hasManualGroups && state.query.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Group related sessions", systemImage: "folder")
                    .font(.callout.weight(.semibold))
                Text("Keep one group per feature, bug or experiment. Drag sessions onto a group, or right-click a session → Move to Group.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.sections.contains(where: { if case .taskGroup = $0.header { return true }; return false }) {
                    Text("Sessions that ran a task's phases are grouped by task automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { startNewGroup(ids: []) } label: { Label("New Group", systemImage: Icon.add) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .padding(.top, 2)
                    .disabled(newGroupKey(for: []) == nil)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 6)
        }
    }

    // MARK: - Menus

    @ViewBuilder private func sessionMenu(_ targets: [SessionSummary]) -> some View {
        if targets.count == 1, let s = targets.first {
            Button { actions.openTranscript(s) } label: { Label("Open Transcript", systemImage: Icon.openFile) }
            Button { NSWorkspace.shared.activateFileViewerSelecting([s.fileURL]) } label: {
                Label("Reveal in Finder", systemImage: Icon.revealInFinder)
            }
            Button { copy(s.fileURL.path) } label: { Label("Copy Path", systemImage: Icon.copyPath) }
            Divider()
            groupMenuItems(targets)
            Divider()
            if let resume = actions.resume {
                let open = context.herdrStatus[s.id] != nil
                Button { resume(s) } label: {
                    Label(open ? "Focus in herdr" : "Resume in herdr", systemImage: open ? "terminal" : "play.circle")
                }
            }
            if let ref = s.task, let openTask = actions.openTask {
                Button { openTask(ref.taskID) } label: { Label("Open Task", systemImage: "checklist") }
            }
            Button("Copy Session ID") { copy(s.id) }
            Button("Copy Resume Command") { copy("claude --resume \(s.id)") }
            Divider()
            trashItem(targets)
        } else {
            Text("\(targets.count) Sessions")
            groupMenuItems(targets)
            Divider()
            Button("Copy Session IDs") { copy(targets.map(\.id).joined(separator: "\n")) }
            Divider()
            trashItem(targets)
        }
    }

    @ViewBuilder private func groupMenuItems(_ targets: [SessionSummary]) -> some View {
        let keys = Set(targets.map(\.groupKey))
        let ids = targets.map(\.id)
        if keys.count == 1, let key = keys.first {
            let groups = context.groups[key]?.groups ?? []
            Menu("Move to Group") {
                ForEach(groups) { g in
                    let allIn = targets.allSatisfy { $0.groupID == g.id }
                    Button { actions.assign(ids, g.id, key) } label: {
                        if allIn { Label(g.name, systemImage: "checkmark") } else { Text(g.name) }
                    }
                    .disabled(allIn)
                }
                if !groups.isEmpty { Divider() }
                Button(targets.count == 1 ? "New Group…" : "New Group from Selection…") { startNewGroup(ids: ids) }
            }
        } else {
            Text("Sessions from different projects can't share a group")
        }
        if targets.contains(where: { $0.groupID != nil }) {
            Button(targets.count == 1 ? "Remove from Group" : "Remove from Groups") { actions.unassign(ids) }
        }
    }

    @ViewBuilder private func trashItem(_ targets: [SessionSummary]) -> some View {
        let movable = targets.filter { !context.status(of: $0).isLive }
        if movable.isEmpty {
            Text(targets.count == 1 ? "Can't Trash a Running Session" : "Can't Trash Running Sessions")
        } else {
            Button(role: .destructive) { state.pendingTrash = movable } label: {
                Label(targets.count == 1 ? "Move to Trash…" : "Move \(movable.count) to Trash…", systemImage: Icon.delete)
            }
        }
    }

    @ViewBuilder private func groupMenu(key: String, group: SessionGroup, count: Int, isFirst: Bool, isLast: Bool) -> some View {
        Button("Rename…") { state.renamingGroupID = group.id }
        Menu("Color") {
            ForEach(GroupColor.allCases, id: \.self) { c in
                Button { actions.recolorGroup(group.id, c, key) } label: {
                    if c == group.color { Label(c.rawValue.capitalized, systemImage: "checkmark") }
                    else { Text(c.rawValue.capitalized) }
                }
            }
        }
        Button(group.isCollapsed ? "Expand" : "Collapse") { actions.setGroupCollapsed(group.id, !group.isCollapsed, key) }
        Divider()
        Button("Move Up") { actions.moveGroup(group.id, -1, key) }.disabled(isFirst)
        Button("Move Down") { actions.moveGroup(group.id, 1, key) }.disabled(isLast)
        Divider()
        Button(role: .destructive) {
            state.pendingGroupDelete = .init(key: key, group: group, count: count)
        } label: { Label("Delete Group…", systemImage: Icon.delete) }
    }

    // MARK: - Selection

    private var currentOrder: [String] {
        SessionListModel(sessions: sessions, context: context, prefs: prefs, query: state.query,
                         includeDate: state.timeFilter.includes, expanded: state.expanded).order
    }

    /// The sessions a menu or drag acts on: the whole selection when the row is part of it,
    /// otherwise just the row (Finder's rule).
    private func targets(for s: SessionSummary) -> [SessionSummary] {
        let ids = state.selectedSessionIDs
        guard ids.count > 1, ids.contains(s.id) else { return [s] }
        return sessions.filter { state.selection.contains($0.id) }
    }

    private func click(_ id: String, model: SessionListModel) {
        listFocused = true
        searchFocused = false
        let flags = NSEvent.modifierFlags
        let isSession = !id.contains("/")
        if isSession, flags.contains(.command) {
            if state.selection.contains(id), state.selection.count > 1 {
                state.selection.remove(id)
                if state.primaryID == id { state.primaryID = model.order.first { state.selection.contains($0) } }
            } else {
                state.selection = state.selection.filter { !$0.contains("/") }.union([id])
                state.primaryID = id
            }
            state.anchorID = id
        } else if isSession, flags.contains(.shift) {
            let sessionOrder = model.order.filter { !$0.contains("/") }
            state.selection = Set(SessionListing.range(from: state.anchorID ?? state.primaryID, to: id, in: sessionOrder))
            state.primaryID = id
        } else {
            state.select(id)
        }
    }

    private func moveSelection(_ step: Int, extend: Bool, order: [String]) {
        guard let target = SessionListing.neighbor(of: state.primaryID, step: step, in: order) else { return }
        if extend, !target.contains("/") {
            let sessionOrder = order.filter { !$0.contains("/") }
            state.selection = Set(SessionListing.range(from: state.anchorID ?? state.primaryID, to: target, in: sessionOrder))
            state.primaryID = target
        } else {
            state.select(target)
        }
        state.scrollRequest = .init(id: target, center: false)
    }

    private func handleKey(_ press: KeyPress, _ model: SessionListModel) -> KeyPress.Result {
        let shift = press.modifiers.contains(.shift)
        switch press.key {
        case .upArrow: moveSelection(-1, extend: shift, order: model.order); return .handled
        case .downArrow: moveSelection(1, extend: shift, order: model.order); return .handled
        case .rightArrow:
            if let id = state.primaryID, !id.contains("/"),
               sessions.first(where: { $0.id == id })?.subagents.isEmpty == false {
                withAnimation(.easeInOut(duration: 0.15)) { _ = state.expanded.insert(id) }
            }
            return .handled
        case .leftArrow:
            guard let id = state.primaryID else { return .handled }
            if let parent = id.split(separator: "/").first, id.contains("/") {
                state.select(String(parent))
                state.scrollRequest = .init(id: String(parent), center: false)
            } else {
                withAnimation(.easeInOut(duration: 0.15)) { _ = state.expanded.remove(id) }
            }
            return .handled
        case .delete, .deleteForward:
            let targets = sessions.filter { state.selection.contains($0.id) && !context.status(of: $0).isLive }
            if !targets.isEmpty { state.pendingTrash = targets }
            return .handled
        case .escape:
            guard let primary = state.primaryID, state.selection.count > 1 else { return .ignored }
            state.select(primary)
            return .handled
        default:
            if press.modifiers.contains(.command), press.characters.lowercased() == "a" {
                let all = model.order.filter { !$0.contains("/") }
                state.selection = Set(all)
                if state.primaryID == nil || !all.contains(state.primaryID!) { state.primaryID = all.first }
                return .handled
            }
            return .ignored
        }
    }

    private func hover(_ id: String, _ inside: Bool) {
        if inside { hoveredID = id } else if hoveredID == id { hoveredID = nil }
    }

    private func toggleExpanded(_ id: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if state.expanded.contains(id) {
                state.expanded.remove(id)
                if let primary = state.primaryID, primary.hasPrefix(id + "/") { state.select(id) }
            } else {
                state.expanded.insert(id)
            }
        }
    }

    private func toggleTaskGroup(_ taskID: String) {
        if prefs.expandedTaskGroups.contains(taskID) { prefs.expandedTaskGroups.remove(taskID) }
        else { prefs.expandedTaskGroups.insert(taskID) }
    }

    /// Keep something selected: the first row when nothing is (first visit, or the selected
    /// session went away).
    private func ensureSelection(_ model: SessionListModel) {
        if let id = state.primaryID {
            let sessionID = id.split(separator: "/").first.map(String.init) ?? id
            if sessions.contains(where: { $0.id == sessionID }) { return }
        }
        if let first = model.order.first { state.select(first) }
    }

    /// Make a row visible whatever hides it — a filter, a folded group, a collapsed parent —
    /// then select it and bring it to the middle. Deep links land here.
    private func reveal(_ id: String) {
        let sessionID = id.split(separator: "/").first.map(String.init) ?? id
        guard let s = sessions.first(where: { $0.id == sessionID }) else { return }
        if !state.timeFilter.includes(s.modifiedAt) { state.timeFilter = .all }
        if s.task != nil, !prefs.showTaskSessions { prefs.showTaskSessions = true }
        var extra: [String] = []
        if let g = context.group(of: s) { extra.append(g.name) }
        if !SessionListing.matches(s, query: state.query, extra: extra) { state.query = "" }
        if prefs.tab == .groups {
            if let g = context.group(of: s) {
                if g.isCollapsed { actions.setGroupCollapsed(g.id, false, s.groupKey) }
            } else if let ref = s.task, prefs.automaticTaskGroups {
                prefs.expandedTaskGroups.insert(ref.taskID)
            } else {
                prefs.ungroupedCollapsed = false
            }
        }
        if id != sessionID { state.expanded.insert(sessionID) }
        state.select(id)
        DispatchQueue.main.async { state.scrollRequest = .init(id: id, center: true) }
    }

    // MARK: - Groups and drops

    /// The group file a new group goes in: the open project's, or — across all projects — the
    /// project of the sessions it is made from (or of the selected / newest session).
    private func newGroupKey(for ids: [String]) -> String? {
        if let key = context.projectKey { return key }
        let pool = ids.isEmpty ? state.selectedSessionIDs : ids
        if let s = sessions.first(where: { pool.contains($0.id) }) { return s.groupKey }
        return sessions.first?.groupKey
    }

    private func startNewGroup(ids: [String]) {
        guard let key = newGroupKey(for: ids) else { return }
        state.renamingGroupID = nil
        prefs.tab = .groups
        state.newGroup = .init(key: key, sessionIDs: ids)
    }

    private func drop(_ items: [String], into section: SessionListModel.Section) -> Bool {
        let ids = SessionDragPayload.decode(items)
        guard !ids.isEmpty else { return false }
        if let target = section.dropGroup {
            actions.assign(ids, target.id, target.key)
        } else if section.dropUngroups {
            actions.unassign(ids)
        } else {
            return false
        }
        return true
    }

    // MARK: - Trash

    private var trashBinding: Binding<Bool> {
        Binding(get: { state.pendingTrash != nil }, set: { if !$0 { state.pendingTrash = nil } })
    }

    private var groupDeleteBinding: Binding<Bool> {
        Binding(get: { state.pendingGroupDelete != nil }, set: { if !$0 { state.pendingGroupDelete = nil } })
    }

    private var groupDeleteTitle: String {
        state.pendingGroupDelete.map { "Delete the group “\($0.group.name)”?" } ?? ""
    }

    private var trashTitle: String {
        guard let targets = state.pendingTrash else { return "" }
        return targets.count == 1 ? "Move “\(context.title(of: targets[0]))” to the Trash?"
                                  : "Move \(targets.count) sessions to the Trash?"
    }

    private var trashMessage: String {
        guard let targets = state.pendingTrash else { return "" }
        let subagents = targets.reduce(0) { $0 + $1.subagents.count }
        let what = targets.count == 1 ? "The transcript" : "The transcripts"
        let subs = subagents == 0 ? "" : " and \(subagents) subagent transcript\(subagents == 1 ? "" : "s")"
        return "\(what)\(subs) go to the Trash, where Put Back restores them. Summaries and group assignments are removed."
    }

    private func performTrash(_ model: SessionListModel) {
        guard let targets = state.pendingTrash else { return }
        state.pendingTrash = nil
        actions.trash(targets)
        // Select what follows the trashed rows, so the keyboard keeps its place. (The list may
        // be filtered to nothing while the selection panel trashes — then there is no "next".)
        guard !model.order.isEmpty else { state.selection = []; state.primaryID = nil; return }
        let gone = Set(targets.map(\.id))
        let remaining = model.order.filter { id in !gone.contains(id.split(separator: "/").first.map(String.init) ?? id) }
        let lastIndex = model.order.lastIndex { gone.contains($0) } ?? 0
        let next = model.order[lastIndex...].first { remaining.contains($0) } ?? remaining.last
        if let next { state.select(next) } else { state.selection = []; state.primaryID = nil }
    }

    // MARK: - Misc

    private func clearFilters() {
        state.timeFilter = .all
        prefs.showTaskSessions = true
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// Makes a row or header a drop target for its section's group (or for "Ungrouped").
private struct DropTargetModifier: ViewModifier {
    let section: SessionListModel.Section
    @Binding var dropTarget: String?
    let onDrop: ([String], SessionListModel.Section) -> Bool

    func body(content: Content) -> some View {
        if section.dropGroup != nil || section.dropUngroups {
            content.dropDestination(for: String.self) { items, _ in
                onDrop(items, section)
            } isTargeted: { inside in
                if inside { dropTarget = section.id } else if dropTarget == section.id { dropTarget = nil }
            }
        } else {
            content
        }
    }
}

/// Inline name editor for creating or renaming a group. Return commits, Esc cancels; clicking
/// away commits a valid name and otherwise cancels, so an editor is never left hanging open.
struct GroupNameField: View {
    let initial: String
    let placeholder: String
    /// nil = accepted (the caller closes the editor); otherwise shown under the field.
    let commit: (String) -> GroupNameError?
    let cancel: () -> Void

    @State private var text = ""
    @State private var error: GroupNameError?
    @State private var finished = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(error == nil ? Color.accentColor.opacity(0.7) : Color.red.opacity(0.8)))
                .focused($focused)
                .onSubmit(submit)
                .onExitCommand { finished = true; cancel() }
                .onChange(of: text) { error = nil }
            if let error {
                Text(error.message).font(.caption2).foregroundStyle(.red)
            }
        }
        .onAppear {
            text = initial
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: focused) { _, isFocused in
            guard !isFocused, !finished else { return }
            finished = true
            if text.trimmingCharacters(in: .whitespaces).isEmpty || commit(text) != nil { cancel() }
        }
    }

    private func submit() {
        if let e = commit(text) { error = e } else { finished = true }
    }
}

extension TimePreset {
    var menuTitle: String {
        switch self {
        case .today: return "Today"
        case .week: return "Last 7 Days"
        case .month: return "Last 30 Days"
        case .quarter: return "Last 3 Months"
        }
    }
}

extension TimeFilter {
    var menuLabel: String {
        switch self {
        case .all: return "Any Time"
        case .preset(let p): return p.menuTitle
        case .custom(let from, let to):
            return "\(from.formatted(.dateTime.month(.abbreviated).day()))–\(to.formatted(.dateTime.month(.abbreviated).day()))"
        }
    }
}

extension GroupColor {
    var swiftUIColor: Color {
        switch self {
        case .red:    return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green:  return .green
        case .teal:   return .teal
        case .blue:   return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink:   return .pink
        }
    }
}
