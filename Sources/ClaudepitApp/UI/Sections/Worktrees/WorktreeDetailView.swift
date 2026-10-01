import SwiftUI
import AppKit
import ClaudepitCore

/// The owning session as the detail card shows it: its title and its stored bullet summary.
struct WorktreeSessionBrief {
    var title: String
    var bullets: [String]
    /// The session is open in a herdr pane: Resume focuses it rather than starting another.
    var hasHerdrPane = false
}

/// One worktree, read top to bottom: what it is and who works in it (header), how it stands
/// against the base branch, what is uncommitted (Changes), what its session did, its commits,
/// and the worktree itself — path, lock, removal. Plain data and closures; the
/// base-sync control, which needs `AppState`, arrives through the `baseSync` slot.
struct WorktreeDetailView<BaseSync: View>: View {
    let wt: WorktreeInfo
    let context: WorktreePageContext
    var session: WorktreeSessionBrief? = nil
    /// Set after Source Control committed everything: the hash and subject it made.
    var lastCommit: (hash: String, subject: String)? = nil
    /// A lock/remove git call is running.
    var isBusy = false
    var cleanupError: String? = nil
    var actions = WorktreeActions()
    /// The changes reloaded and are not empty, so the "committed" confirmation no longer holds.
    var onDirtyAgain: () -> Void = {}
    @ViewBuilder var baseSync: () -> BaseSync

    // Read lazily from git: on appear, and again whenever the scan says something moved.
    @State private var loaded = false
    @State private var changedFiles: [ChangedFile] = []
    @State private var changesLimit = 8
    @State private var commits: [RecentCommit] = []
    @State private var commitLimit = 5
    @State private var head: CommitInfo?
    @State private var remoteWebURL: String?
    @State private var expandedDiffPath: String?
    @State private var diffText: [String: String] = [:]
    @State private var showChangeLegend = false
    @State private var summaryExpanded = true

    /// Wide enough for a diff, narrow enough to read.
    static var readingWidth: CGFloat { 900 }

    private var activity: WorktreeActivity { context.activity(wt) }
    private var tasks: [WorktreeTaskRef] { context.tasks[wt.path] ?? [] }

    /// Everything in the scan that changes what git would answer. A worktree whose agent is
    /// editing changes this on each rescan, so the changes list never goes stale while it is open.
    private var scanKey: String {
        [wt.path, wt.head, "\(wt.dirtyCount)", "\(wt.trackedDirtyCount)", "\(wt.aheadCount)",
         "\(wt.behindCount)", "\(wt.mergeInProgress)", wt.conflictedFiles.joined(separator: ",")]
            .joined(separator: "|")
    }

    var body: some View {
        GlassCard {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.15)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // Where the branch stands against its base first (a merge left half-done
                        // shows its conflicts here), then what is uncommitted.
                        baseSection
                        changesSection
                        summarySection
                        commitsSection
                        worktreeSection
                    }
                    .frame(maxWidth: Self.readingWidth, alignment: .topLeading)
                    .padding(.horizontal, 20).padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                // A vertical ScrollView reports its content's minimum width as its own, and a few
                // pills that never shrink then pushed the whole page past a narrow window's edge.
                .frame(minWidth: 0, maxWidth: .infinity)
            }
        }
        .task(id: scanKey) { await load() }
        .onChange(of: commitLimit) { Task { commits = await WorktreeInspector.recentCommits(at: wt.path, limit: commitLimit) } }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Widest first: title and buttons on one row; then the buttons under the title; then
            // icon-only buttons — at the window's minimum width the detail card is ~270 pt.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    titleLabel.frame(minWidth: 120, idealWidth: 200, maxWidth: .infinity, alignment: .leading)
                    headerActions(compact: false).fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    titleLabel.frame(minWidth: 0, idealWidth: 100, maxWidth: .infinity, alignment: .leading)
                    headerActions(compact: false).fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    titleLabel.frame(minWidth: 0, idealWidth: 100, maxWidth: .infinity, alignment: .leading)
                    headerActions(compact: true).fixedSize()
                }
            }
            FlowLayout(spacing: 10) {
                HeaderFact(icon: activity == .running ? "circle.fill" : "circle", text: activity.label,
                           help: activity.detail, color: activity == .running ? .green : .secondary)
                if let reason = WorktreeListing.attentionReason(wt) {
                    HeaderFact(icon: "exclamationmark.triangle.fill", text: reason, help: reason, color: .orange)
                }
                if context.title(wt) != wt.name {
                    // The tag the Sessions page shows on this worktree's sessions, in its colour.
                    WorktreeTag(name: wt.name, color: context.color(wt))
                }
                // Not a `HeaderFact`: those never shrink, and a task branch outruns a narrow card.
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9.5))
                    Text(wt.branch.isEmpty ? "detached HEAD" : wt.branch).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("Branch checked out in this worktree: \(wt.branch.isEmpty ? "detached HEAD" : wt.branch)")
                if wt.isBehindBase {
                    HeaderFact(icon: "arrow.down", text: "\(wt.behindCount) behind \(wt.baseBranch)",
                               help: "\(plural(wt.behindCount, "commit")) on \(wt.baseRef) not in this worktree",
                               color: .orange)
                }
                if wt.aheadCount > 0 {
                    HeaderFact(icon: "arrow.up", text: "\(wt.aheadCount) ahead",
                               help: "\(plural(wt.aheadCount, "commit")) ahead of \(wt.baseBranch.isEmpty ? "the base branch" : wt.baseBranch)")
                }
                if !wt.isClean {
                    HeaderFact(icon: "pencil", text: plural(wt.dirtyCount, "change"),
                               help: "\(wt.trackedDirtyCount) tracked, \(wt.dirtyCount - wt.trackedDirtyCount) untracked")
                }
                if wt.isLocked {
                    HeaderFact(icon: "lock.fill", text: "Locked", help: wt.lockReason.isEmpty ? "Locked" : wt.lockReason)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
    }

    private var titleLabel: some View {
        HStack(spacing: 8) {
            Circle().fill(context.color(wt)).frame(width: 9, height: 9)
                .help("This worktree's colour — its sessions wear it on the Sessions page")
            Text(context.title(wt)).font(.headline).lineLimit(1).truncationMode(.tail)
                .help(context.title(wt))
        }
    }

    private func headerActions(compact: Bool) -> some View {
        HStack(spacing: 6) {
            HeaderButton(title: wt.isClean ? "Source Control" : "Source Control · \(wt.dirtyCount)",
                         icon: "rectangle.split.2x1",
                         help: "Stage, discard and commit this worktree's changes", compact: compact) {
                actions.sourceControl(wt)
            }
            .debugFrame("worktree-source-control")
            if wt.ownerSessionID != nil {
                HeaderButton(title: "Session", icon: Icon.jump, help: "Show the session that worked here",
                             compact: compact) {
                    actions.openSession(wt)
                }
                if let resume = actions.resumeSession {
                    let focus = session?.hasHerdrPane == true
                    HeaderButton(title: focus ? "Focus" : "Resume", icon: focus ? "terminal" : "play.circle",
                                 help: focus ? "Focus the herdr pane this session is open in"
                                             : "Resume this session in a new herdr tab", compact: compact) {
                        resume(wt)
                    }
                }
            }
            if let task = tasks.first {
                HeaderButton(title: "Task", icon: "checklist", help: "Show the task “\(task.name)”",
                             compact: compact) {
                    actions.openTask(task.id)
                }
            }
            HeaderMenu {
                WorktreeMenuItems(wt: wt, context: context, actions: actions, includePrimary: false)
            }
        }
    }

    // MARK: Changes

    private var changesSection: some View {
        DetailSection(title: "Changes", icon: "pencil.circle",
                      count: changedFiles.isEmpty ? nil : changedFiles.count) {
            Button { showChangeLegend.toggle() } label: {
                Image(systemName: Icon.info).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("What the letters mean")
            .popover(isPresented: $showChangeLegend, arrowEdge: .bottom) { ChangeLegendPopover() }
            Spacer(minLength: 0)
            if !changedFiles.isEmpty {
                Button("Review & Commit…") { actions.sourceControl(wt) }
                    .buttonStyle(.link).font(.caption)
                    .help("Open Source Control to stage, discard and commit")
            }
        } content: {
            if !loaded {
                Text("Reading git…").font(.caption).foregroundStyle(.tertiary)
            } else if changedFiles.isEmpty {
                if let lastCommit {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
                        Text("Committed").font(.caption.weight(.semibold))
                        Text(lastCommit.hash).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        Text(lastCommit.subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Text("No uncommitted changes").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(changedFiles.prefix(changesLimit)) { f in changeRow(f) }
                }
                if changedFiles.count > changesLimit {
                    let hidden = changedFiles.count - changesLimit
                    Button(hidden <= 10 ? "Show \(hidden) more" : "Show 10 more of \(hidden)") {
                        changesLimit += 10
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    private func changeRow(_ f: ChangedFile) -> some View {
        let open = expandedDiffPath == f.path
        let dir = (f.path as NSString).deletingLastPathComponent
        return VStack(alignment: .leading, spacing: 4) {
            Button { toggleDiff(f) } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? Icon.chevronExpanded : Icon.chevronCollapsed)
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 10)
                    ChangeBadge(change: f.change)
                    // The name keeps its room; the folder gives way first, from its start.
                    Text((f.path as NSString).lastPathComponent)
                        .font(.caption.monospaced()).foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.middle)
                        .layoutPriority(1)
                    if !dir.isEmpty {
                        Text(dir).font(.caption.monospaced()).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3).padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Hide the diff" : "Show the diff of \(f.path)")
            .contextMenu { fileContextMenu(url: URL(filePath: wt.path).appending(path: f.path)) }
            if open {
                if let raw = diffText[f.path] {
                    if raw.isEmpty {
                        Text("No text diff — binary, empty, or already staged as-is.")
                            .font(.caption).foregroundStyle(.tertiary).padding(.leading, 20)
                    } else {
                        DiffView(lines: diffLinesFromUnified(raw, path: f.path),
                                 isSwift: f.path.hasSuffix(".swift"),
                                 isMarkdown: f.path.hasSuffix(".md"),
                                 language: GenericHighlighter.language(forExtension: (f.path as NSString).pathExtension))
                    }
                } else {
                    ProgressView().controlSize(.small).padding(.leading, 20)
                }
            }
        }
    }

    // MARK: Base branch

    @ViewBuilder private var baseSection: some View {
        // No base to compare against (detached HEAD, no main/master, no origin) — the control
        // draws nothing, so neither does its section.
        if !wt.baseRef.isEmpty {
            DetailSection(title: "Base branch · \(wt.baseBranch)", icon: "arrow.triangle.merge",
                          tint: wt.mergeInProgress ? .orange : nil) {
                Spacer(minLength: 0)
            } content: {
                baseSync()
            }
        }
    }

    // MARK: Session

    @ViewBuilder private var summarySection: some View {
        if let session, !session.bullets.isEmpty {
            DetailSection(title: "Session summary", icon: "text.alignleft") {
                Text(session.title).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 0)
                Button(summaryExpanded ? "Hide" : "Show") {
                    withAnimation(.easeInOut(duration: 0.15)) { summaryExpanded.toggle() }
                }
                .buttonStyle(.link).font(.caption)
            } content: {
                if summaryExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(session.bullets.enumerated()), id: \.offset) { _, b in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").foregroundStyle(.tertiary)
                                Text(b).font(.callout).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Commits

    private var commitsSection: some View {
        DetailSection(title: "Commits", icon: "point.topleft.down.to.point.bottomright.curvepath") {
            Spacer(minLength: 0)
            if remoteWebURL == nil && loaded {
                Text("no web remote").font(.caption2).foregroundStyle(.tertiary)
                    .help("origin isn't a GitHub, GitLab or Bitbucket remote, so commits don't link anywhere")
            }
        } content: {
            if !loaded {
                Text("Reading git…").font(.caption).foregroundStyle(.tertiary)
            } else if commits.isEmpty, let head {
                commitRow(hash: head.shortHash, full: head.shortHash, subject: head.subject,
                          date: head.relativeDate, isHead: true)
            } else if commits.isEmpty {
                Text("No commit info").font(.caption).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(commits.enumerated()), id: \.element.id) { i, c in
                        commitRow(hash: c.shortHash, full: c.fullHash, subject: c.subject,
                                  date: c.relativeDate, isHead: i == 0)
                        if i == 0, let head, !head.body.isEmpty {
                            Text(head.body).font(.caption).foregroundStyle(.tertiary)
                                .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 64).padding(.bottom, 4)
                        }
                    }
                }
                if commits.count >= commitLimit {
                    Button("Show more") { commitLimit += 10 }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    private func commitRow(hash: String, full: String, subject: String, date: String, isHead: Bool) -> some View {
        let url = remoteWebURL.flatMap { URL(string: "\($0)/commit/\(full)") }
        return Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 8) {
                Text(hash).font(.caption.monospaced())
                    .foregroundStyle(url != nil ? Color.accentColor : Color.secondary)
                    .frame(width: 56, alignment: .leading)
                Text(subject).font(.caption).foregroundStyle(.primary.opacity(isHead ? 1 : 0.75)).lineLimit(1)
                    .layoutPriority(1)
                if isHead {
                    Text("HEAD").font(.system(size: 8.5, weight: .bold))
                        .fixedSize()
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .foregroundStyle(.secondary)
                        .background(.white.opacity(0.08), in: Capsule())
                }
                Spacer(minLength: 8)
                if isHead, let author = head?.author, !author.isEmpty {
                    Text(author).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Text(date).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .help(url == nil ? "\(full) — no web remote to open it on" : "Open \(hash) in the browser")
    }

    // MARK: Worktree

    private var worktreeSection: some View {
        DetailSection(title: "Worktree", icon: "folder") {
            Spacer(minLength: 0)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                labeled("Path") {
                    FilePathLabel(url: URL(filePath: wt.path))
                    smallIcon(Icon.copyPath, help: "Copy path") { copy(wt.path) }
                    smallIcon(Icon.revealInFinder, help: "Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: wt.path)])
                    }
                }
                labeled("Branch") {
                    Text(wt.branch.isEmpty ? "detached HEAD at \(wt.head)" : wt.branch)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if !wt.branch.isEmpty {
                        smallIcon(Icon.copyPath, help: "Copy branch name") { copy(wt.branch) }
                    }
                }
                if !tasks.isEmpty {
                    labeled(tasks.count == 1 ? "Task" : "Tasks") {
                        FlowLayout(spacing: 8) {
                            ForEach(tasks, id: \.id) { task in
                                Button { actions.openTask(task.id) } label: {
                                    Text(task.isFix ? "\(task.name) (fix)" : task.name)
                                        .font(.caption).lineLimit(1)
                                }
                                .buttonStyle(.link)
                                .help("Show this task on the Tasks page")
                            }
                        }
                    }
                }
                labeled("Lock") { lockLine }
                Divider().opacity(0.15).padding(.vertical, 2)
                cleanupRow
                if let cleanupError {
                    Text(cleanupError).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var lockLine: some View {
        switch wt.lockState {
        case .unlocked:
            Text("Not locked").font(.caption).foregroundStyle(.secondary)
        case .lockedLive(let pid):
            Text(wt.isActive ? "Locked, and in use by an active session"
                 : pid > 0 ? "Locked by a running process (pid \(pid))"
                 : "Locked" + (wt.lockReason.isEmpty ? "" : " — \(wt.lockReason)"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .lockedStale(let pid):
            Text("Locked, but the owning process\(pid.map { " (pid \($0))" } ?? "") is gone and no session is active")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Lock-aware: held → nothing to do here; stale → Unlock; unlocked → Remove, with what it
    /// will cost said beside the button.
    @ViewBuilder private var cleanupRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            switch wt.lockState {
            case .lockedLive:
                Text("Unlock and remove become available once nothing holds the worktree.")
                    .font(.caption).foregroundStyle(.tertiary)
            case .lockedStale:
                PillButton(title: "Unlock", icon: "lock.open.fill", disabled: isBusy) { actions.unlock(wt) }
                    .help("git worktree unlock — the process that locked it is gone")
                Text("Unlock it to make it removable.").font(.caption).foregroundStyle(.secondary)
            case .unlocked:
                PillButton(title: "Remove Worktree…", icon: Icon.delete, tint: .red, disabled: isBusy) {
                    actions.remove(wt)
                }
                .debugFrame("worktree-remove")
                Text(wt.isClean ? "Safe to remove — no uncommitted work. The branch is kept."
                     : "Has \(plural(wt.dirtyCount, "uncommitted file")). Removing it discards them for good; the branch is kept.")
                    .font(.caption).foregroundStyle(wt.isClean ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isBusy { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
        }
    }

    // MARK: Pieces

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.tertiary).frame(width: 46, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func smallIcon(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: 18, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: Data

    private func load() async {
        // Remote first so commit rows are clickable on first render.
        remoteWebURL = await WorktreeInspector.remoteWebURL(at: wt.path)
        let files = await WorktreeInspector.changedFiles(at: wt.path)
        changedFiles = files
        if !files.isEmpty, lastCommit != nil { onDirtyAgain() }
        // A file that changed again has a different diff; drop what was read so an open one
        // re-reads, and a file that is gone closes.
        diffText = [:]
        if let open = expandedDiffPath {
            if let f = files.first(where: { $0.path == open }) { readDiff(f) } else { expandedDiffPath = nil }
        }
        commits = await WorktreeInspector.recentCommits(at: wt.path, limit: commitLimit)
        head = await WorktreeInspector.commitInfo(at: wt.path)
        loaded = true
    }

    private func toggleDiff(_ f: ChangedFile) {
        if expandedDiffPath == f.path {
            expandedDiffPath = nil
        } else {
            expandedDiffPath = f.path
            // Always re-read: an agent can edit an already-changed file again without moving any
            // count the scan key watches, and a cached diff would then be stale.
            readDiff(f)
        }
    }

    private func readDiff(_ f: ChangedFile) {
        let dir = wt.path
        Task { diffText[f.path] = await WorktreeInspector.diff(at: dir, path: f.path, untracked: f.change == .untracked) }
    }
}

/// The worktree's short tag in its colour — the same capsule its sessions wear on the Sessions
/// page (`WorktreePill`), without the click: here it would only filter to itself.
struct WorktreeTag: View {
    let name: String
    let color: Color

    var body: some View {
        Text(WorktreeLabel.short(name))
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .foregroundStyle(color)
            .background(color.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 0.5))
            .fixedSize()
            .help("Worktree \(name) — its sessions carry this tag on the Sessions page")
    }
}

/// A titled block of the detail card: a small header row (title, count, trailing accessories)
/// over its content, on a faint panel.
struct DetailSection<Accessory: View, Content: View>: View {
    let title: String
    let icon: String
    var count: Int? = nil
    var tint: Color? = nil
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tint ?? .secondary)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(tint ?? .secondary)
                    .lineLimit(1).fixedSize()
                if let count {
                    Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                accessory()
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if let tint {
                RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.35), lineWidth: 1)
            }
        }
    }
}

/// The page's pill button (matches Plugins' "Reload Plugins" and the base-sync control's pills).
struct PillButton: View {
    let title: String
    let icon: String
    var tint: Color = .blue
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .medium))
                Text(title).font(.caption).fontWeight(.medium).fixedSize()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

/// A changed file's one-letter status, coloured, with its meaning on hover.
struct ChangeBadge: View {
    let change: ChangedFile.Change

    var body: some View {
        Text(Self.letter(change)).font(.caption2.monospaced().bold())
            .foregroundStyle(Self.color(change)).frame(width: 14)
            .help(Self.meaning(change))
    }

    static func letter(_ c: ChangedFile.Change) -> String {
        switch c { case .modified: "M"; case .added: "A"; case .deleted: "D"; case .renamed: "R"; case .untracked: "?" }
    }
    static func color(_ c: ChangedFile.Change) -> Color {
        switch c { case .added, .untracked: .green; case .deleted: .red; case .renamed: .blue; case .modified: .orange }
    }
    static func meaning(_ c: ChangedFile.Change) -> String {
        switch c {
        case .modified: "Modified"
        case .added: "Added (staged)"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .untracked: "Untracked — new, not yet added to git"
        }
    }
}

/// The key to the change letters (the ⓘ beside "Changes").
struct ChangeLegendPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach([ChangedFile.Change.modified, .added, .deleted, .renamed, .untracked], id: \.self) { c in
                HStack(spacing: 8) {
                    ChangeBadge(change: c)
                    Text(ChangeBadge.meaning(c)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
    }
}
