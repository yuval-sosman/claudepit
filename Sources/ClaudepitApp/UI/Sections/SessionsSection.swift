import SwiftUI
import ClaudepitCore
import AppKit

struct SessionsSection: View {
    @ObservedObject var app: AppState
    @State private var selectedID: String?
    @State private var expandedIDs: Set<String> = []

    private enum SessionViewMode: String { case recent, groups }
    @AppStorage("sessionsViewMode") private var viewMode: SessionViewMode = .recent

    @State private var search: String = ""
    @State private var timeFilter: TimeFilter = .all
    @State private var showTimeFilter: Bool = false
    @State private var showDiscover = false
    @State private var appWindowWidth: CGFloat = 1100
    @State private var appWindowHeight: CGFloat = 800
    @State private var scrollProxy: ScrollViewProxy? = nil
    @State private var showNewGroupForSession: String? = nil
    @State private var newGroupName: String = ""
    @State private var newGroupColor: GroupColor = .blue
    @State private var showManageGroups = false
    @State private var cachedGroups: [SessionGroup] = []
    @State private var editingGroupID: String? = nil
    @State private var editingGroupName: String = ""

    var body: some View {
        MasterDetailLayout(listWidth: 300) {
            listCard
        } detail: {
            detailCard
        }
        .onAppear {
            app.reloadSessions()
            applyDiscoverIntent()
            if let focusID = app.focusSessionID {
                selectedID = focusID
                app.focusSessionID = nil
            } else if selectedID == nil {
                selectedID = app.sessions.first?.id
            }
            reloadGroups()
        }
        .onChange(of: app.sessions.count) { reloadGroups() }
        .onChange(of: app.activePath) { reloadGroups() }
        .onChange(of: app.openDiscoverSheet) { applyDiscoverIntent() }
        .onChange(of: app.focusSessionID) { _, id in
            guard let id else { return }
            selectedID = id
            app.focusSessionID = nil
            // If focusing a subagent (id = "parentID/subagentID"), expand the parent first.
            if id.contains("/") {
                let parentID = String(id.prefix(upTo: id.firstIndex(of: "/")!))
                expandedIDs.insert(parentID)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                scrollProxy?.scrollTo(id, anchor: .center)
            }
        }
        .onChange(of: selectedID) { _, id in
            reloadBullets(for: id)
            app.selectedSessionID = id
            if let id { scrollProxy?.scrollTo(id, anchor: .center) }
        }
        .textSelection(.disabled)
    }

    /// Home's one-shot "open Discover" intent (documented focus pattern — the consumer clears it).
    private func applyDiscoverIntent() {
        guard app.openDiscoverSheet else { return }
        app.openDiscoverSheet = false
        // Same capture as the toolbar Discover button: the sheet's frame is sized from these.
        appWindowWidth = NSApp.keyWindow?.frame.width ?? 1100
        appWindowHeight = NSApp.keyWindow?.frame.height ?? 800
        showDiscover = true
    }

    private func reloadGroups() {
        cachedGroups = GroupStore.shared.load(projectSlug: currentProjectSlug).groups
    }

    private func reloadBullets(for sessionID: String?) {
        guard let id = sessionID,
              let idx = app.sessions.firstIndex(where: { $0.id == id }) else { return }
        let slug = app.sessions[idx].projectSlug
        app.sessions[idx].bulletSummary = SummaryStore.shared.load(projectSlug: slug, sessionID: id)
    }

    // MARK: List card (left, narrow)

    private var listCard: some View {
        GlassCard {
            VStack(spacing: 0) {

                HStack(spacing: 0) {
                    ForEach([SessionViewMode.recent, .groups], id: \.self) { mode in
                        Button {
                            viewMode = mode
                        } label: {
                            Text(mode == .recent ? "Recent" : "Groups")
                                .font(.body)
                                .fontWeight(viewMode == mode ? .semibold : .regular)
                                .foregroundStyle(viewMode == mode ? .primary : .secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .overlay(alignment: .bottom) {
                                    if viewMode == mode {
                                        Rectangle()
                                            .fill(Color.accentColor)
                                            .frame(height: 2)
                                            .cornerRadius(1)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    manageGroupsButton
                }
                .padding(.leading, 16)
                .padding(.trailing, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)

                HStack(spacing: 6) {
                    searchBox
                    Button { showTimeFilter = true } label: {
                        Image(systemName: timeFilter.isActive
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(timeFilter.isActive ? Color.accentColor : .secondary)
                            .frame(maxHeight: .infinity)
                            .padding(.horizontal, 8)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help("Filter by date")
                    .popover(isPresented: $showTimeFilter, arrowEdge: .bottom) {
                        TimeFilterPopover(filter: $timeFilter)
                    }
                    Button {
                        appWindowWidth = NSApp.keyWindow?.frame.width ?? 1100
                        appWindowHeight = NSApp.keyWindow?.frame.height ?? 800
                        showDiscover = true
                    } label: {
                        Image(systemName: "sparkle.magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxHeight: .infinity)
                            .padding(.horizontal, 8)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help("Discover sessions by description")
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

                if timeFilter.isActive {
                    HStack(spacing: 4) {
                        Text(timeFilter.label)
                        Button { timeFilter = .all } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.2), in: Capsule())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                }

                if filteredSessions.isEmpty {
                    EmptyState("No sessions found.")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                switch viewMode {
                                case .recent: recentRows
                                case .groups: groupRows
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .onAppear { scrollProxy = proxy }
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { showNewGroupForSession != nil },
            set: { if !$0 { showNewGroupForSession = nil } }
        )) {
            if let sessID = showNewGroupForSession,
               let s = app.sessions.first(where: { $0.id == sessID }) {
                NewGroupSheet(
                    name: $newGroupName,
                    color: $newGroupColor,
                    onSave: {
                        if let g = try? GroupStore.shared.createGroup(
                            name: newGroupName, color: newGroupColor, projectSlug: s.projectSlug) {
                            try? GroupStore.shared.assign(sessionID: sessID, groupID: g.id, projectSlug: s.projectSlug)
                            app.reloadSessions()
                            viewMode = .groups
                        }
                        showNewGroupForSession = nil
                    },
                    onCancel: { showNewGroupForSession = nil }
                )
                .frame(width: 280)
            }
        }
        .sheet(isPresented: $showDiscover) {
            DiscoverSheet(app: app, projectSlug: currentProjectSlug)
                .frame(width: appWindowWidth * 0.65, height: appWindowHeight * 0.75)
        }
    }

    @ViewBuilder private var recentRows: some View {
        ForEach(grouped, id: \.slug) { group in
            if app.activePath == nil {
                Text(group.slug)
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 10)
            }
            ForEach(group.sessions) { s in
                row(s)
                    .id(s.id)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedID = s.id }
                if expandedIDs.contains(s.id) {
                    ForEach(s.subagents) { sub in
                        subagentRow(sub, parentID: s.id)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedID = subagentSelectionID(parentID: s.id, subagentID: sub.id) }
                    }
                }
            }
        }
    }


    @ViewBuilder private var groupRows: some View {
        let assigned = Dictionary(grouping: filteredSessions.filter { $0.groupID != nil },
                                  by: { $0.groupID! })
        let ungrouped = filteredSessions.filter { $0.groupID == nil }

        ForEach(cachedGroups) { g in
            let sessions = (assigned[g.id] ?? []).sorted { $0.modifiedAt > $1.modifiedAt }
            groupHeader(g, count: sessions.count)
            ForEach(sessions) { s in
                row(s).id(s.id).contentShape(Rectangle()).onTapGesture { selectedID = s.id }
                if expandedIDs.contains(s.id) {
                    ForEach(s.subagents) { sub in
                        subagentRow(sub, parentID: s.id)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedID = subagentSelectionID(parentID: s.id, subagentID: sub.id) }
                    }
                }
            }
        }

        if !ungrouped.isEmpty {
            Text("Ungrouped")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 10)
            ForEach(ungrouped.sorted { $0.modifiedAt > $1.modifiedAt }) { s in
                row(s).id(s.id).contentShape(Rectangle()).onTapGesture { selectedID = s.id }
                if expandedIDs.contains(s.id) {
                    ForEach(s.subagents) { sub in
                        subagentRow(sub, parentID: s.id)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedID = subagentSelectionID(parentID: s.id, subagentID: sub.id) }
                    }
                }
            }
        }
    }

    private func groupHeader(_ g: SessionGroup, count: Int) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(g.color.swiftUIColor)
                .frame(width: 9, height: 9)
            Text(g.name)
                .font(.caption2).bold().foregroundStyle(.primary)
            Text("\(count)")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button {
                editingGroupName = g.name
                editingGroupID = g.id
            } label: {
                Image(systemName: Icon.edit)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: Binding(
                get: { editingGroupID == g.id },
                set: { if !$0 { editingGroupID = nil } }
            ), arrowEdge: .trailing) {
                GroupEditPopover(
                    group: g,
                    name: $editingGroupName,
                    onRename: { name in
                        try? GroupStore.shared.renameGroup(id: g.id, name: name, projectSlug: currentProjectSlug)
                        reloadGroups(); app.reloadSessions()
                    },
                    onRecolor: { color in
                        try? GroupStore.shared.recolorGroup(id: g.id, color: color, projectSlug: currentProjectSlug)
                        reloadGroups(); app.reloadSessions()
                    },
                    onDelete: {
                        try? GroupStore.shared.deleteGroup(id: g.id, projectSlug: currentProjectSlug)
                        editingGroupID = nil
                        reloadGroups(); app.reloadSessions()
                    }
                )
            }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 2)
    }

    private var currentProjectSlug: String {
        if let base = app.activePath { return Paths.slug(for: base) }
        return app.sessions.first?.projectSlug ?? ""
    }

    private func row(_ s: SessionSummary) -> some View {
        let isSelected = s.id == selectedID
        let hasSubagents = !s.subagents.isEmpty
        let isExpanded = expandedIDs.contains(s.id)
        return HStack(spacing: 8) {
            // left slot: fixed 18pt to keep all text aligned
            HStack(spacing: 3) {
                if hasSubagents {
                    Button {
                        if isExpanded { expandedIDs.remove(s.id) }
                        else { expandedIDs.insert(s.id) }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if viewMode == .recent, let gid = s.groupID, let g = cachedGroups.first(where: { $0.id == gid }) {
                    Circle().fill(g.color.swiftUIColor).frame(width: 7, height: 7)
                }
            }
            .frame(width: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).lineLimit(1).font(.subheadline).bold()
                Text("\(s.turnCount) turns · \(relative(s.modifiedAt))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let wt = app.worktrees.first(where: { $0.ownerSessionID == s.id }) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .help("Bound to worktree \(wt.name)")
            }
            if let entry = app.herdrSessions[s.id] {
                // ponytail: herdr rests at "blocked" whenever awaiting user input (end-of-turn or AskUserQuestion)
                let waiting = entry.status == "blocked"
                Image(systemName: waiting ? "hand.raised.fill" : "terminal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(entry.status == "working" ? Color.green
                                     : waiting ? Color.orange : Color.secondary)
                    .help(waiting ? "Waiting for you · herdr pane \(entry.paneID)"
                                  : "Open in herdr pane \(entry.paneID) · \(entry.status)")
            }
            if s.isActive {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.green)
            }
            Menu {
                Button { NSWorkspace.shared.open(s.fileURL) } label: { Label("Open Transcript", systemImage: Icon.openFile) }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([s.fileURL])
                } label: { Label("Reveal in Finder", systemImage: Icon.revealInFinder) }
                Button {
                    let pb = NSPasteboard.general; pb.clearContents(); pb.setString(s.fileURL.path, forType: .string)
                } label: { Label("Copy Path", systemImage: Icon.copyPath) }
                Divider()
                groupMenuItems(for: s)
                Divider()
                if WorktreeResumer.available() {
                    let herdrPane = app.herdrSessions[s.id]?.paneID
                    let resumeCwd = app.worktrees.first { $0.ownerSessionID == s.id }?.path
                        ?? app.activePath?.path
                    if let pane = herdrPane, let cwd = resumeCwd {
                        Button {
                            Task { await WorktreeResumer.resume(sessionID: s.id, cwd: cwd, label: s.title, existingPaneID: pane) }
                        } label: { Label("Focus in Herdr", systemImage: "terminal") }
                        Divider()
                    } else if herdrPane == nil, let cwd = resumeCwd {
                        Button {
                            Task { await WorktreeResumer.resume(sessionID: s.id, cwd: cwd, label: s.title) }
                        } label: { Label("Resume Session in Herdr", systemImage: "play.circle") }
                        Divider()
                    }
                }
                Button("Copy Session ID") { copy(s.id) }
                Button("Copy Resume Command") { copy("claude --resume \(s.id)") }
                Divider()
                Button(role: .destructive) {
                    try? FileManager.default.trashItem(at: s.fileURL, resultingItemURL: nil)
                    app.reloadSessions()
                } label: { Label("Move to Trash", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.22) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 6)
    }

    private func subagentRow(_ sub: SubagentSummary, parentID: String) -> some View {
        let sid = subagentSelectionID(parentID: parentID, subagentID: sub.id)
        let isSelected = selectedID == sid
        return HStack(spacing: 6) {
            Spacer().frame(width: 28)
            Image(systemName: "sparkles")
                .font(.caption2).foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text(sub.agentType).font(.caption).bold().foregroundStyle(.primary)
                if !sub.description.isEmpty {
                    Text(sub.description).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let wt = app.worktrees.first(where: { $0.ownerSessionID == parentID }) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.accentColor.opacity(0.7))
                    .help("Runs in parent's worktree \(wt.name)")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.22) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 6)
        .id(sid)
    }

    // MARK: Detail card (right, wide)

    @ViewBuilder private var detailCard: some View {
        GlassCard {
            if let id = selectedID {
                if let (parent, sub) = resolveSubagent(id) {
                    SessionDetailView(
                        app: app,
                        summary: subagentAsSummary(sub),
                        parentSummary: parent,
                        onOpenSubagent: { tapped in
                            expandedIDs.insert(parent.id)
                            selectedID = subagentSelectionID(parentID: parent.id, subagentID: tapped.id)
                        },
                        onBack: { selectedID = parent.id }
                    )
                    .id(id)
                    .padding(16)
                } else if let s = app.sessions.first(where: { $0.id == id }) {
                    SessionDetailView(
                        app: app,
                        summary: s,
                        onOpenSubagent: { sub in
                            expandedIDs.insert(s.id)
                            selectedID = subagentSelectionID(parentID: s.id, subagentID: sub.id)
                        }
                    )
                    .id(s.id)
                    .padding(16)
                } else {
                    EmptyState("Select a session")
                }
            } else {
                EmptyState("Select a session")
            }
        }
    }

    // MARK: Helpers

    private func subagentSelectionID(parentID: String, subagentID: String) -> String {
        "\(parentID)/\(subagentID)"
    }

    private func resolveSubagent(_ selectionID: String) -> (SessionSummary, SubagentSummary)? {
        guard selectionID.contains("/") else { return nil }
        let parts = selectionID.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let parentID = String(parts[0])
        let subID = String(parts[1])
        guard let parent = app.sessions.first(where: { $0.id == parentID }),
              let sub = parent.subagents.first(where: { $0.id == subID }) else { return nil }
        return (parent, sub)
    }

    private func subagentAsSummary(_ sub: SubagentSummary) -> SessionSummary {
        SessionSummary(
            id: sub.id,
            fileURL: sub.fileURL,
            projectSlug: "",
            title: sub.description.isEmpty ? sub.agentType : sub.description,
            modifiedAt: Date(timeIntervalSince1970: 0),
            turnCount: 0,
            isActive: false,
            subagents: []
        )
    }

    private var filteredSessions: [SessionSummary] {
        app.sessions
            .filter { s in
                search.isEmpty ||
                s.title.localizedCaseInsensitiveContains(search) ||
                s.projectSlug.localizedCaseInsensitiveContains(search)
            }
            .filter { timeFilter.includes($0.modifiedAt) }
    }

    private var searchBox: some View {
        HStack(spacing: 6) {
            Image(systemName: Icon.search).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Filter sessions…", text: $search)
                .textFieldStyle(.plain)
                .font(.caption)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: Icon.clearField)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }

    private var grouped: [(slug: String, sessions: [SessionSummary])] {
        // With a project active, worktree sessions carry a different slug
        // (…--claude-worktrees-…). Grouping by slug would sink them into a
        // second bucket rendered last; instead show one time-sorted list.
        // Slug grouping is only meaningful in the all-projects view.
        if app.activePath != nil {
            return [("", filteredSessions.sorted { $0.modifiedAt > $1.modifiedAt })]
        }
        let dict = Dictionary(grouping: filteredSessions, by: \.projectSlug)
        return dict.keys.sorted().map {
            (slug: $0, sessions: dict[$0]!.sorted { $0.modifiedAt > $1.modifiedAt })
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }

    private var manageGroupsButton: some View {
        Button {
            showManageGroups = true
        } label: {
            Image(systemName: "folder.badge.gear")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showManageGroups, arrowEdge: .trailing) {
            ManageGroupsPanel(
                projectSlug: currentProjectSlug,
                onChanged: { app.reloadSessions() }
            )
            .frame(width: 280, height: 320)
        }
    }

    @ViewBuilder
    private func groupMenuItems(for s: SessionSummary) -> some View {
        let pg = GroupStore.shared.load(projectSlug: s.projectSlug)
        Menu("Move to Group") {
            ForEach(pg.groups) { g in
                Button {
                    try? GroupStore.shared.assign(sessionID: s.id, groupID: g.id, projectSlug: s.projectSlug)
                    app.reloadSessions()
                    viewMode = .groups
                } label: {
                    HStack {
                        Circle().fill(g.color.swiftUIColor).frame(width: 8, height: 8)
                        Text(g.name)
                    }
                }
            }
            Divider()
            Button("New Group…") {
                showNewGroupForSession = s.id
                newGroupName = ""
                newGroupColor = .blue
            }
        }
        if s.groupID != nil {
            Button("Remove from Group") {
                try? GroupStore.shared.unassign(sessionID: s.id, projectSlug: s.projectSlug)
                app.reloadSessions()
            }
        }
    }
}

private struct GroupEditPopover: View {
    let group: SessionGroup
    @Binding var name: String
    let onRename: (String) -> Void
    let onRecolor: (GroupColor) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                TextField("Group name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onRename(name); dismiss() }
                Button { onRename(name); dismiss() } label: {
                    Image(systemName: "checkmark").font(.caption).foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                Button { name = group.name; dismiss() } label: {
                    Image(systemName: "xmark").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                ForEach(GroupColor.allCases, id: \.self) { c in
                    ZStack {
                        Circle().fill(c.swiftUIColor).frame(width: 20, height: 20)
                        if c == group.color {
                            Circle().stroke(Color.primary, lineWidth: 2).frame(width: 22, height: 22)
                        }
                    }
                    .onTapGesture { onRecolor(c) }
                }
            }
            Divider()
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete Group", systemImage: Icon.delete)
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
        .padding(14)
        .frame(width: 260)
    }
}

private struct NewGroupSheet: View {
    @Binding var name: String
    @Binding var color: GroupColor
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Group").font(.headline)
            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)
            colorPicker
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Create") { onSave() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    private var colorPicker: some View {
        HStack(spacing: 8) {
            ForEach(GroupColor.allCases, id: \.self) { c in
                ZStack {
                    Circle().fill(c.swiftUIColor).frame(width: 20, height: 20)
                    if c == color {
                        Circle().stroke(Color.primary, lineWidth: 2).frame(width: 22, height: 22)
                    }
                }
                .onTapGesture { color = c }
            }
        }
    }
}

private struct ManageGroupsPanel: View {
    let projectSlug: String
    let onChanged: () -> Void

    @State private var groups: [SessionGroup] = []
    @State private var editingName: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Manage Groups")
                .font(.headline)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($groups) { $g in
                        groupRow($g)
                        Divider().padding(.leading, 16)
                    }
                }
            }
            Divider()
            Button {
                if let ng = try? GroupStore.shared.createGroup(
                    name: "New Group", color: .blue, projectSlug: projectSlug) {
                    groups.append(ng)
                    editingName[ng.id] = ng.name
                    onChanged()
                }
            } label: {
                Label("New Group", systemImage: Icon.add)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        }
        .onAppear { reload() }
    }

    private func reload() {
        groups = GroupStore.shared.load(projectSlug: projectSlug).groups
        for g in groups { editingName[g.id] = g.name }
    }

    private func groupRow(_ g: Binding<SessionGroup>) -> some View {
        HStack(spacing: 10) {
            colorSwatches(g)
            TextField("", text: Binding(
                get: { editingName[g.id] ?? g.name.wrappedValue },
                set: { editingName[g.id] = $0 }
            ))
            .textFieldStyle(.plain)
            .onSubmit {
                let newName = editingName[g.id] ?? g.name.wrappedValue
                try? GroupStore.shared.renameGroup(id: g.id, name: newName, projectSlug: projectSlug)
                g.name.wrappedValue = newName
                onChanged()
            }
            Spacer()
            Button {
                try? GroupStore.shared.deleteGroup(id: g.id, projectSlug: projectSlug)
                reload()
                onChanged()
            } label: {
                Image(systemName: Icon.delete).font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func colorSwatches(_ g: Binding<SessionGroup>) -> some View {
        Menu {
            ForEach(GroupColor.allCases, id: \.self) { c in
                Button {
                    try? GroupStore.shared.recolorGroup(id: g.id, color: c, projectSlug: projectSlug)
                    g.color.wrappedValue = c
                    onChanged()
                } label: {
                    Label(c.rawValue.capitalized, systemImage: "circle.fill")
                }
            }
        } label: {
            Circle().fill(g.color.wrappedValue.swiftUIColor).frame(width: 14, height: 14)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
