import SwiftUI
import AppKit
import ClaudepitCore

/// What the Worktrees list and detail know about each worktree beyond the scan: who it belongs
/// to, what is live in it, and its colour. Plain data, so both views render without `AppState`
/// (the DEBUG `--snapshot-pages worktrees` tool draws them offscreen).
struct WorktreePageContext {
    /// Worktree path → the tasks working there, the one that created it first
    /// (`WorktreeListing.tasks(in:from:)`). A fix task shares its parent's checkout.
    var tasks: [String: [WorktreeTaskRef]] = [:]
    /// Worktree path → the herdr agent whose cwd it is (`AppState.worktreeAgentName`).
    var liveAgents: [String: String] = [:]
    /// Worktree name → colour slot (`AppState.worktreeColorSlots`), the colour its sessions wear.
    var colorSlots: [String: Int] = [:]
    /// herdr is installed: Resume and Open in herdr are offered.
    var herdrAvailable = false
    /// A project is open (with none, there is nothing to scan).
    var hasProject = true

    /// Worktree path → the creating task's name: what the list calls the worktree and searches.
    var taskNames: [String: String] { tasks.compactMapValues { $0.first?.name } }

    func color(_ wt: WorktreeInfo) -> Color { WorktreePalette.color(slot: colorSlots[wt.name]) }
    func title(_ wt: WorktreeInfo) -> String { WorktreeListing.title(of: wt, taskName: tasks[wt.path]?.first?.name) }
    func activity(_ wt: WorktreeInfo) -> WorktreeActivity {
        WorktreeListing.activity(of: wt, liveAgent: liveAgents[wt.path])
    }
}

/// A task working in a worktree, as the page names and links it.
struct WorktreeTaskRef: Equatable {
    let id: String
    let name: String
    /// Fixes another task's review findings in that task's checkout.
    let isFix: Bool

    init(_ task: ProjectTask) { id = task.id; name = task.name; isFix = task.followUp != nil }
    init(id: String, name: String, isFix: Bool = false) { self.id = id; self.name = name; self.isFix = isFix }
}

/// Everything the page can do to a worktree. Shared by the list's row menus and the detail card's
/// header, so the two always offer the same actions.
struct WorktreeActions {
    /// Rescan, fetching the base branch first (the explicit gesture skips the 5-minute throttle).
    var refresh: () -> Void = {}
    /// Open `.claude/worktrees` in Finder. nil: no project.
    var openFolder: (() -> Void)? = nil
    /// Present the Source Control sheet.
    var sourceControl: (WorktreeInfo) -> Void = { _ in }
    /// Show the owning session on the Sessions page.
    var openSession: (WorktreeInfo) -> Void = { _ in }
    /// Resume the owning session in herdr, or focus its pane when one is open. nil: no herdr.
    var resumeSession: ((WorktreeInfo) -> Void)? = nil
    /// Open a herdr tab in the worktree and run `git checkout <branch>` there — a shell in the
    /// checkout, and the way back onto the branch after a detour. nil: no herdr.
    var openInHerdr: ((WorktreeInfo) -> Void)? = nil
    /// Show a task on the Tasks page, by id.
    var openTask: (String) -> Void = { _ in }
    /// Release a stale lock.
    var unlock: (WorktreeInfo) -> Void = { _ in }
    /// Ask to remove the worktree (the page confirms first).
    var remove: (WorktreeInfo) -> Void = { _ in }
}

/// The Worktrees page's left card: the active project's worktrees under "Needs attention" /
/// "Live" / "Idle", named by their task where a task made them, with search and ↑/↓ — the same
/// list family as Sessions, Plans and Memory (`PageList.swift`). Plain data and closures.
struct WorktreeListView: View {
    let worktrees: [WorktreeInfo]
    let context: WorktreePageContext
    @Binding var selection: String?
    @Binding var query: String
    /// One-shot from a deep link: scroll this worktree (by path) into view, then cleared.
    @Binding var revealRequest: String?
    var actions = WorktreeActions()

    @FocusState private var listFocused: Bool
    @State private var hoveredPath: String?
    @State private var searchFocusToken = 0
    @State private var keyScroll: String?

    var body: some View {
        let sections = WorktreeListing.sections(worktrees, query: query, taskNames: context.taskNames,
                                                liveAgents: context.liveAgents)
        VStack(spacing: 0) {
            header
            if !worktrees.isEmpty { searchRow(sections) }
            if !context.hasProject {
                PageListEmptyState(icon: "arrow.triangle.branch", title: "No project open",
                                   detail: "Open a project to see its git worktrees.")
            } else if worktrees.isEmpty {
                PageListEmptyState(icon: "arrow.triangle.branch", title: "No worktrees",
                                   detail: "Each task works in its own worktree, and claude --worktree <name> starts one "
                                         + "by hand. They appear here while they exist.")
            } else if sections.isEmpty {
                PageListEmptyState(icon: Icon.search, title: "No worktrees match “\(query)”",
                                   detail: "Search reads names, branches, task names and paths.") {
                    Button("Clear Search") { query = "" }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else {
                list(sections)
            }
        }
    }

    // MARK: Header and search

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Worktrees").font(.headline)
            Text("\(worktrees.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            Spacer()
            if let openFolder = actions.openFolder {
                iconButton(Icon.revealInFinder, help: "Open .claude/worktrees in Finder", action: openFolder)
            }
            iconButton(Icon.refresh, help: "Rescan worktrees and fetch the base branch", action: actions.refresh)
                .debugFrame("worktree-refresh")
        }
        .padding(.leading, 16).padding(.trailing, 10)
        .padding(.top, 12).padding(.bottom, 8)
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 22, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func searchRow(_ sections: [WorktreeListing.Section]) -> some View {
        PageListSearchField(text: $query, placeholder: "Search worktrees",
                            help: "Searches names, branches, task names and paths (⌥⌘F)",
                            focusToken: searchFocusToken,
                            onArrowDown: {
                                listFocused = true
                                if let first = sections.first?.items.first { selection = first.path; keyScroll = first.path }
                            },
                            onLeave: { listFocused = true })
            .debugFrame("worktree-search")
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .background {
                Button("") { searchFocusToken += 1 }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .opacity(0).frame(width: 0, height: 0)
            }
    }

    // MARK: List

    private func list(_ sections: [WorktreeListing.Section]) -> some View {
        let order = sections.flatMap { $0.items.map(\.path) }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        SwiftUI.Section {
                            ForEach(section.items) { wt in row(wt) }
                        } header: {
                            PageListSectionHeader(title: section.group.title, count: section.items.count,
                                                  help: sectionHelp(section.group))
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in
                let delta: Int
                switch press.key {
                case .upArrow: delta = -1
                case .downArrow: delta = 1
                default: return .ignored
                }
                if let next = PageListKeys.step(selection, by: delta, in: order) {
                    selection = next
                    keyScroll = next
                }
                return .handled
            }
            .onAppear { reveal(proxy) }
            .onChange(of: revealRequest) { reveal(proxy) }
            .onChange(of: keyScroll) { _, path in
                guard let path else { return }
                proxy.scrollTo(path)
                keyScroll = nil
            }
        }
    }

    private func sectionHelp(_ group: WorktreeListing.Group) -> String {
        switch group {
        case .attention: return "A merge left half-done, or a lock whose owner is gone"
        case .live: return "A session is running here, or an agent or process holds the worktree"
        case .idle: return "Nothing is working in these right now"
        }
    }

    private func row(_ wt: WorktreeInfo) -> some View {
        let activity = context.activity(wt)
        let color = context.color(wt)
        return PageListRow(
            title: context.title(wt),
            titleLines: 2,
            subtitle: wt.branch.isEmpty ? "detached HEAD" : wt.branch,
            meta: meta(wt, activity: activity),
            isSelected: selection == wt.path,
            isFocused: listFocused,
            isHovered: hoveredPath == wt.path,
            help: "\(wt.name)\n\(wt.path)\nThe stripe is this worktree's colour — its sessions wear it on the Sessions page",
            edgeColor: color,
            onTap: {
                selection = wt.path
                listFocused = true
            }
        ) {
            EmptyView()
        } markers: {
            if WorktreeListing.needsAttention(wt) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9)).foregroundStyle(.orange)
                    .help(WorktreeListing.attentionReason(wt) ?? "")
            }
            if wt.isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .help(wt.lockReason.isEmpty ? "Locked" : "Locked: \(wt.lockReason)")
            }
        } menuItems: {
            WorktreeMenuItems(wt: wt, context: context, actions: actions)
        }
        .id(wt.path)
        .debugFrame("worktree-row-\(wt.name)")
        .onHover { inside in
            if inside { hoveredPath = wt.path } else if hoveredPath == wt.path { hoveredPath = nil }
        }
    }

    /// "Running now · 3 changes · 2 behind main" — the status in its colour, then the facts that
    /// call for action (attention and behind) in orange, the rest quiet.
    private func meta(_ wt: WorktreeInfo, activity: WorktreeActivity) -> Text {
        var text = Text(activity.label)
            .foregroundColor(activity == .running ? .green : activity.isLive ? .primary.opacity(0.7) : nil)
        for fact in WorktreeListing.facts(of: wt) {
            let loud = fact == WorktreeListing.attentionReason(wt) || fact.contains(" behind ")
            text = text + Text(" · ") + Text(fact).foregroundColor(loud ? .orange : nil)
        }
        return text
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let path = revealRequest else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(path, anchor: .center) }
            revealRequest = nil
        }
    }
}

/// The actions one worktree offers, as menu items — the list row's "…" and right-click menus and
/// the detail card's "…" capsule all draw this, so they can never offer different things.
struct WorktreeMenuItems: View {
    let wt: WorktreeInfo
    let context: WorktreePageContext
    let actions: WorktreeActions
    /// The detail header already has buttons for these; its menu leaves them out.
    var includePrimary = true

    var body: some View {
        if includePrimary {
            Button { actions.sourceControl(wt) } label: {
                Label(wt.isClean ? "Source Control" : "Source Control (\(wt.dirtyCount))",
                      systemImage: "rectangle.split.2x1")
            }
            if wt.ownerSessionID != nil {
                Button { actions.openSession(wt) } label: { Label("Show Session", systemImage: Icon.jump) }
                if let resume = actions.resumeSession {
                    Button { resume(wt) } label: { Label("Resume Session in herdr", systemImage: "play.circle") }
                }
            }
            ForEach(context.tasks[wt.path] ?? [], id: \.id) { task in
                Button { actions.openTask(task.id) } label: {
                    Label("Show Task “\(task.name)”", systemImage: "checklist")
                }
            }
            Divider()
        }
        if let openInHerdr = actions.openInHerdr, !wt.branch.isEmpty {
            Button { openInHerdr(wt) } label: {
                Label("Check Out \(wt.branch) in herdr", systemImage: "terminal")
            }
        }
        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: wt.path)]) } label: {
            Label("Reveal in Finder", systemImage: Icon.revealInFinder)
        }
        Button { copy(wt.path) } label: { Label("Copy Path", systemImage: Icon.copyPath) }
        if !wt.branch.isEmpty {
            Button { copy(wt.branch) } label: { Label("Copy Branch Name", systemImage: "arrow.triangle.branch") }
        }
        Divider()
        if case .lockedStale = wt.lockState {
            Button { actions.unlock(wt) } label: { Label("Unlock", systemImage: "lock.open") }
        }
        Button(role: .destructive) { actions.remove(wt) } label: {
            Label("Remove Worktree…", systemImage: Icon.delete)
        }
        .disabled(wt.isLocked)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
