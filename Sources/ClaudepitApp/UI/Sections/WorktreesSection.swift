import SwiftUI
import ClaudepitCore
#if canImport(AppKit)
import AppKit
#endif

struct WorktreesSection: View {
    @ObservedObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Worktrees").font(.title2).bold()
                Spacer()
                Button { app.reloadWorktrees() } label: {
                    Image(systemName: Icon.refresh).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh worktrees")
            }

            if app.worktrees.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(app.worktrees) { wt in
                                WorktreeCard(app: app, wt: wt,
                                             focused: app.focusWorktreeName == wt.name)
                                    .id(wt.name)
                            }
                        }
                    }
                    .onAppear {
                        applyFocus(proxy: proxy)
                    }
                    .onChange(of: app.focusWorktreeName) { _, _ in applyFocus(proxy: proxy) }
                }
            }
        }
        .onAppear { app.reloadWorktrees() }
    }

    private func applyFocus(proxy: ScrollViewProxy) {
        guard let name = app.focusWorktreeName else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(name, anchor: .top) }
            app.focusWorktreeName = nil
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("No worktrees").font(.body).foregroundStyle(.secondary)
            Text("Start one with `claude --worktree <name>`.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

private struct WorktreeCard: View {
    @ObservedObject var app: AppState
    let wt: WorktreeInfo
    var focused: Bool = false
    @State private var expanded = false

    // Lazily-loaded inspector data (fetched on expand).
    @State private var changedFiles: [ChangedFile] = []
    @State private var changesLimit = 5
    @State private var recentCommits: [RecentCommit] = []
    @State private var recentExpanded = false
    @State private var recentLimit = 5
    @State private var remoteWebURL: String?
    @State private var commitInfo: CommitInfo?
    @State private var expandedDiffPath: String?
    @State private var diffText: [String: String] = [:]
    @State private var showReviewChanges = false
    @State private var showChangeLegend = false
    @State private var cleanupBusy = false
    @State private var cleanupError: String?
    @State private var confirmRemove = false
    // ponytail: captured once on tap — keyWindow resolves to the sheet after it opens, causing shrink
    @State private var capturedSheetSize: CGSize = CGSize(width: 900, height: 560)

    private func openReviewChanges() {
        #if canImport(AppKit)
        if let win = NSApp.keyWindow ?? NSApp.mainWindow {
            let f = win.frame
            capturedSheetSize = CGSize(width: max(900, f.width * 0.92), height: max(560, f.height * 0.92))
        }
        #endif
        showReviewChanges = true
    }

    // Owning-session bullet summary (shown in an expandable section, like Recent Commits).
    @State private var summaryExpanded = false

    var body: some View {
        ExpandableCard(expanded: $expanded) {
            HStack(spacing: 10) {
                // State dot: green = running now, gray ring = idle/unbound.
                Circle()
                    .fill(wt.bindingState == .active ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 9, height: 9)
                HStack(spacing: 6) {
                    Text(wt.name).font(.headline)
                    Text(statusPhrase).font(.caption).foregroundStyle(statusColor)
                    if wt.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption2).foregroundStyle(.secondary)
                            .help("Locked")
                    }
                }
                Spacer()
                // Actions — visible even when the card is collapsed.
                HStack(spacing: 12) {
                    if !wt.isClean {
                        Button { openReviewChanges() } label: {
                            Label("Source Control", systemImage: "rectangle.split.2x1")
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.caption)
                        .help("Open Source Control")
                    }
                    if !wt.branch.isEmpty, WorktreeResumer.available() {
                        Button { Task { await WorktreeResumer.checkout(branch: wt.branch, cwd: wt.path) } } label: {
                            Label("Checkout", systemImage: "arrow.triangle.branch")
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.caption)
                        .help("git checkout \(wt.branch) in a new tab")
                    }
                    if let sid = wt.ownerSessionID {
                        let focusID = wt.ownerSubagentID.map { "\(sid)/\($0)" } ?? sid
                        Button { app.focusSessionID = focusID; app.selected = .sessions } label: {
                            Label("Navigate to Session", systemImage: Icon.jump)
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.caption)
                        .help("Navigate to Session")
                    }
                    if let sid = wt.ownerSessionID, WorktreeResumer.available() {
                        Button { Task { await WorktreeResumer.resume(sessionID: sid, cwd: wt.path, label: wt.name, existingPaneID: app.herdrSessions[sid]?.paneID) } } label: {
                            Label("Resume Session", systemImage: "play.circle")
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.caption)
                        .help(app.herdrSessions[sid] != nil ? "Focus existing herdr pane" : "Resume Session")
                    }
                }
                // Quiet trailing metadata — only what's actionable.
                if wt.aheadCount > 0 {
                    Label("\(wt.aheadCount) ahead", systemImage: "arrow.up")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("\(wt.aheadCount) commit\(wt.aheadCount == 1 ? "" : "s") not pushed to upstream")
                }
            }
        } detail: {
            VStack(alignment: .leading, spacing: 10) {
                // Owning session's bullet summary — collapsed by default like Recent Commits.
                if let bullets = owningSessionBullets, !bullets.isEmpty {
                    DisclosureGroup(isExpanded: $summaryExpanded) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(bullets.enumerated()), id: \.offset) { _, b in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•").foregroundStyle(.tertiary)
                                    Text(b).font(.caption).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(.top, 2)
                    } label: {
                        SectionHeaderLabel("Session Summary", icon: "text.alignleft")
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    SectionHeaderLabel("Path", icon: "folder")
                    HStack(spacing: 6) {
                        FilePathLabel(url: URL(filePath: wt.path))
                        Button { copyToPasteboard(wt.path) } label: {
                            Image(systemName: Icon.copyPath).font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Copy path")
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    SectionHeaderLabel("Branch", icon: "arrow.triangle.branch")
                    Text(wt.branch.isEmpty ? "detached" : wt.branch)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }

                // Changed files (only when dirty) — tap a row to expand its diff.
                if let c = app.worktreeLastCommit[wt.path], changedFiles.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
                        Text("COMMITTED").font(.caption2).fontWeight(.bold).foregroundStyle(.secondary).tracking(0.6)
                        Text(c.hash).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        Spacer()
                    }
                    Text(c.subject).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if !changedFiles.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil.circle")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        Text("CHANGES")
                            .font(.caption).fontWeight(.bold).foregroundStyle(.secondary)
                            .textCase(.uppercase).tracking(0.6)
                        Button { showChangeLegend.toggle() } label: {
                            Image(systemName: "info.circle.fill")
                                .font(.caption).foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showChangeLegend, arrowEdge: .bottom) { ChangeLegendPopover() }
                        Spacer()
                        Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                    }
                    ForEach(changedFiles.prefix(changesLimit)) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Button { toggleDiff(f) } label: {
                                HStack(spacing: 6) {
                                    Text(badge(f.change)).font(.caption2.monospaced().bold())
                                        .foregroundStyle(badgeColor(f.change)).frame(width: 14)
                                    Text(f.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            if expandedDiffPath == f.path, let raw = diffText[f.path] {
                                DiffView(lines: diffLinesFromUnified(raw, path: f.path),
                                         isSwift: f.path.hasSuffix(".swift"),
                                         isMarkdown: f.path.hasSuffix(".md"),
                                         language: GenericHighlighter.language(forExtension: (f.path as NSString).pathExtension))
                            }
                        }
                    }
                    if changedFiles.count > changesLimit {
                        Button { changesLimit += 10 } label: {
                            Label("More", systemImage: "ellipsis").font(.caption)
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                }

                // HEAD COMMIT — same row format as Recent Commits rows.
                SectionHeaderLabel("Head Commit", icon: "point.topleft.down.to.point.bottomright.curvepath")
                if let c = commitInfo {
                    let url = remoteWebURL.map { "\($0)/commit/\(c.shortHash)" }
                    Button {
                        if let url, let u = URL(string: url) {
                            #if canImport(AppKit)
                            NSWorkspace.shared.open(u)
                            #endif
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(c.shortHash).font(.caption2.monospaced())
                                .foregroundStyle(url != nil ? Color.accentColor : Color.secondary.opacity(0.6))
                            Text(c.subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text(c.relativeDate).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(url == nil)
                    .help(url == nil ? "No remote to open" : "Open commit in browser")
                } else {
                    Text("No commit info").font(.caption).foregroundStyle(.tertiary)
                }

                // Recent commits (read-only history) — collapsed by default.
                if !recentCommits.isEmpty {
                    DisclosureGroup(isExpanded: $recentExpanded) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(recentCommits) { c in
                                commitRow(c)
                            }
                            if recentCommits.count >= recentLimit {
                                Button {
                                    recentLimit += 10
                                    Task { recentCommits = await WorktreeInspector.recentCommits(at: wt.path, limit: recentLimit) }
                                } label: {
                                    Label("More", systemImage: "ellipsis").font(.caption)
                                }
                                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.top, 2)
                    } label: {
                        SectionHeaderLabel("Recent Commits", icon: "clock")
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text("WORKTREE STATE").font(.caption).fontWeight(.bold).foregroundStyle(.secondary)
                        .tracking(0.6)
                    Image(systemName: wt.isLocked ? "lock.fill" : "lock.open")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(wt.isLocked ? .orange : .secondary)
                        .help(wt.isLocked ? "Locked" : "Unlocked")
                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                }
                cleanupSection
            }
            .task(id: expanded) {
                guard expanded else { return }
                // Resolve the remote first so commit rows are clickable on first render.
                remoteWebURL = await WorktreeInspector.remoteWebURL(at: wt.path)
                changedFiles = await WorktreeInspector.changedFiles(at: wt.path)
                if !changedFiles.isEmpty { app.worktreeLastCommit.removeValue(forKey: wt.path) }
                recentCommits = await WorktreeInspector.recentCommits(at: wt.path, limit: recentLimit)
                commitInfo = await WorktreeInspector.commitInfo(at: wt.path)
            }
        }
        // Card text/icons run small (all .caption tiers); nudge everything up one
        // step in a single place instead of touching ~30 font call sites.
        .dynamicTypeSize(.xLarge)
        // Sheet + alert must live on the always-present card root, not the detail VStack
        // (which isn't in the tree when collapsed), so they work even when card is closed.
        .sheet(isPresented: $showReviewChanges) {
            ReviewChangesSheet(source: GitChangeSource(worktreePath: wt.path, title: wt.name)) {
                Task {
                    changedFiles = await WorktreeInspector.changedFiles(at: wt.path)
                    commitInfo = await WorktreeInspector.commitInfo(at: wt.path)
                    recentCommits = await WorktreeInspector.recentCommits(at: wt.path, limit: recentLimit)
                    if changedFiles.isEmpty, let info = commitInfo {
                        app.worktreeLastCommit[wt.path] = (info.shortHash, info.subject)
                    }
                }
            }
            .frame(width: capturedSheetSize.width, height: capturedSheetSize.height)
        }
        .alert("Remove this worktree?", isPresented: $confirmRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                runCleanup { await WorktreeStager.remove(worktreePath: wt.path, force: !wt.isClean) }
            }
        } message: {
            Text(wt.isClean
                 ? "Runs `git worktree remove` on \(wt.name). The working directory is deleted; the branch is kept."
                 : "Force-removes \(wt.name) with \(wt.dirtyCount) uncommitted file\(wt.dirtyCount == 1 ? "" : "s"). The working directory and its uncommitted changes are permanently deleted; the branch is kept.")
        }
        .onAppear { if focused { expanded = true }; autoOpenReviewIfTargeted() }
        .onChange(of: focused) { _, isFocused in if isFocused { expanded = true } }
        .onChange(of: app.autoOpenReviewWorktree) { _, _ in autoOpenReviewIfTargeted() }
    }

    /// One-shot: when this card is the auto-open target, expand it and present the
    /// Source Control sheet (deep-link from a task's "Review changes" button). Clears
    /// the flag on the next tick so it fires once — mirrors WorktreesSection.applyFocus.
    private func autoOpenReviewIfTargeted() {
        guard app.autoOpenReviewWorktree == wt.name else { return }
        expanded = true
        openReviewChanges()
        DispatchQueue.main.async { app.autoOpenReviewWorktree = nil }
    }

    /// Worktree-state verdict + lock-aware action, on one line. Locked & in use →
    /// no action. Locked & stale (idle + dead pid) → Unlock. Unlocked+clean → Remove.
    @ViewBuilder private var cleanupSection: some View {
        HStack(spacing: 8) {
            switch wt.lockState {
            case .lockedLive(let pid):
                stateText(wt.isActive
                            ? "Locked and in use by an active session"
                            : "Locked by a running process (pid \(pid))")
            case .lockedStale(let pid):
                pillButton("Unlock", icon: "lock.open.fill") {
                    runCleanup { await WorktreeStager.unlock(worktreePath: wt.path) }
                }
                stateText("Locked, but the owning process is gone" + (pid.map { " (pid \($0))" } ?? "") + " and no session is active")
            case .unlocked:
                if wt.isClean {
                    pillButton("Remove Worktree", icon: Icon.delete) { confirmRemove = true }
                    stateText("Safe to remove — no uncommitted work")
                } else {
                    pillButton("Remove Worktree", icon: Icon.delete) { confirmRemove = true }
                    stateText("This worktree is unlocked but has uncommitted files. Removing it will permanently discard that work.", color: .orange)
                }
            }
            Spacer(minLength: 0)
        }
        if let err = cleanupError {
            Text(err).font(.caption2).foregroundStyle(.red)
        }
    }

    private func stateText(_ s: String, color: Color = .primary) -> some View {
        Text(s).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    /// App pill button (matches PluginsSection "Reload Plugins"): leading icon + text,
    /// tinted translucent background. Icon lives in the button, not the label text.
    private func pillButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .medium))
                Text(title).font(.caption).fontWeight(.medium)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
        .disabled(cleanupBusy)
    }

    /// Run a git mutation, then refresh the worktree list (state may have changed:
    /// unlock flips lockState; remove drops the card).
    private func runCleanup(_ op: @escaping () async -> (ok: Bool, message: String)) {
        cleanupBusy = true; cleanupError = nil
        Task {
            let r = await op()
            cleanupBusy = false
            if r.ok { app.reloadWorktrees() }
            else { cleanupError = r.message.isEmpty ? "git command failed" : r.message }
        }
    }

    @ViewBuilder private func commitRow(_ c: RecentCommit) -> some View {
        let url = remoteWebURL.map { "\($0)/commit/\(c.fullHash)" }
        Button {
            if let url, let u = URL(string: url) {
                #if canImport(AppKit)
                NSWorkspace.shared.open(u)
                #endif
            }
        } label: {
            HStack(spacing: 6) {
                Text(c.shortHash).font(.caption2.monospaced())
                    .foregroundStyle(url != nil ? Color.accentColor : Color.secondary.opacity(0.6))
                Text(c.subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(c.relativeDate).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .help(url == nil ? "No remote to open" : "Open commit in browser")
    }

    private func toggleDiff(_ f: ChangedFile) {
        let path = f.path
        if expandedDiffPath == path {
            expandedDiffPath = nil
        } else {
            expandedDiffPath = path
            if diffText[path] == nil {
                Task { diffText[path] = await WorktreeInspector.diff(at: wt.path, path: path, untracked: f.change == .untracked) }
            }
        }
    }

    private func badge(_ c: ChangedFile.Change) -> String {
        switch c {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "?"
        }
    }

    private func badgeColor(_ c: ChangedFile.Change) -> Color {
        switch c {
        case .added, .untracked: return .green
        case .deleted: return .red
        case .renamed: return .blue
        case .modified: return .orange
        }
    }

    /// The owning session's stored bullet summary — same data the Sessions page
    /// shows (already stamped onto `app.sessions` by SessionScanner).
    private var owningSessionBullets: [String]? {
        guard let sid = wt.ownerSessionID else { return nil }
        return app.sessions.first { $0.id == sid }?.bulletSummary?.bullets
    }

    // The dot encodes live-vs-not; the branch lives on the detail HEAD line.
    // So the collapsed caption carries only the word the gray dot can't disambiguate.
    private var statusPhrase: String {
        switch wt.bindingState {
        case .active:  return "Running now"
        case .idle:    return "Idle"
        case .unbound: return "Unbound"
        }
    }

    private var statusColor: Color {
        wt.bindingState == .active ? .green : .secondary
    }

    private func copyToPasteboard(_ s: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
    }
}

private struct ChangeLegendPopover: View {
    private let items: [(String, String, Color)] = [
        ("M", "modified",       .orange),
        ("A", "added (staged)", .green),
        ("D", "deleted",        .red),
        ("R", "renamed",        .blue),
        ("?", "untracked",      .green),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.0) { badge, label, color in
                HStack(spacing: 8) {
                    Text(badge).font(.caption2.monospaced().bold())
                        .foregroundStyle(color).frame(width: 14)
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
    }
}
