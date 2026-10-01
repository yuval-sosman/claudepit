import SwiftUI
import ClaudepitCore
#if canImport(AppKit)
import AppKit
#endif

/// The ONE place that renders "Update from <base>", the in-progress-merge block and the
/// outcome of the last run — hosted by both the Worktrees page's "Base branch" section
/// (`WorktreeDetailView`'s `baseSync` slot) and `TaskDetailView`'s WORKTREE row, so the two can
/// never disagree.
///
/// Three parts, in this order: (a) the action row, (b) the merge-state block, driven ENTIRELY
/// by what git says (`wt.mergeInProgress`) and never by the transient outcome, (c) the outcome
/// line for the run that just finished.
struct UpdateFromBaseControl: View {
    @ObservedObject var app: AppState
    /// Must be re-read from `app.worktrees` on every render by the host — the merge block is
    /// driven by these fields, so a captured stale value would freeze the conflict UI.
    let wt: WorktreeInfo
    /// Disables the button while the host is running another git mutation of its own
    /// (the Worktrees page passes its unlock/remove in flight) — a transient busy flag with nothing to
    /// explain. A *reason* the user should see goes through `disabledReason` instead, which is
    /// how BOTH hosts pass the live-agent case.
    var externallyDisabled: Bool = false
    /// Why the action is unavailable, when the host knows a *reason* worth showing rather than a
    /// transient busy flag. Non-nil BOTH disables the button and explains itself — it becomes the
    /// button's tooltip and is appended to the visible state line, so a dead button never reads as
    /// a bug (AC12). Both hosts supply the same string for the live-agent case, which is the one
    /// they must never disagree about.
    var disabledReason: String? = nil
    /// When true, auto-start once on appear if `app.pendingWorktreeUpdatePath == wt.path`.
    var autoStartFromPending: Bool = false
    /// The task that owns this worktree, when a task does. Only used to name the merge agent, so
    /// that `HomeAgents` attributes it to the task like any other `task-<id>-*` agent. The
    /// Worktrees host leaves it nil and gets a path-derived name.
    var taskID: String? = nil

    /// The one wording for the live-agent case, shared by every host so they cannot drift. Mirrors
    /// the board pill's tooltip at `TaskCardView`'s behind-pill.
    static let liveAgentReason = "An agent is working in this worktree — merge after it stops."

    @State private var busy = false
    @State private var outcome: WorktreeUpdateOutcome?
    @State private var fetchFailed = false
    @State private var abortError: String?
    @State private var showReviewChanges = false
    /// Whether the run that produced `outcome` went through the stashing path. `.conflicted` means
    /// two different things across the two paths — "your work is untouched, we never started" vs
    /// "we started, hit conflicts, and put everything back" — and the second needs saying.
    @State private var lastRunStashed = false
    @State private var mergeAgentError: String?
    // ponytail: captured once on tap — keyWindow resolves to the sheet after it opens.
    @State private var capturedSheetSize = CGSize(width: 900, height: 560)

    var body: some View {
        // No base to compare against (detached HEAD, no main/master, no origin) -> nothing to
        // offer. A legitimate repo shape, so this is silent, not an error.
        if wt.baseRef.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                actionRow
                if wt.mergeInProgress { mergeStateBlock }
                outcomeLine
            }
            .sheet(isPresented: $showReviewChanges) {
                ReviewChangesSheet(source: GitChangeSource(worktreePath: wt.path, title: wt.name)) {
                    app.reloadWorktrees()
                }
                .frame(width: capturedSheetSize.width, height: capturedSheetSize.height)
            }
            .onAppear { startIfPending() }
            .onChange(of: app.pendingWorktreeUpdatePath) { _, _ in startIfPending() }
        }
    }

    // MARK: - (a) action row

    /// Pills on their own rows, state line beneath. Three pills plus the sentence do not fit one
    /// line in the task panel's narrow column, and wrapping the text mid-row pushed the pills
    /// around as the state changed.
    ///
    /// `FlowLayout`, not an `HStack`: an HStack compresses its children to fit, which shrank
    /// "Update from main" into a two-line pill. Flowing to a second row keeps every label on one
    /// line at whatever width the host gives us.
    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 8) {
                // A non-nil reason is itself disabling: belt-and-braces, so a host that supplies
                // one cannot accidentally leave the button live by forgetting the boolean.
                pill("Update from \(wt.baseBranch)", icon: "arrow.down.circle",
                     disabled: standardGate || !wt.canUpdateFromBase) { run() }
                    .help(effectiveReason ?? "Fetch \(wt.baseRef) and merge it into this worktree")
                // Only offered when it is the thing the plain button cannot do. Hidden mid-merge:
                // there is nothing to stash past, and the merge-state block below owns that case.
                if wt.trackedDirtyCount > 0 && !wt.mergeInProgress {
                    pill("Stash & update", icon: "archivebox.circle",
                         disabled: standardGate) { runStashing() }
                        .help(effectiveReason
                              ?? "Stash your \(wt.trackedDirtyCount) uncommitted change\(wt.trackedDirtyCount == 1 ? "" : "s"), merge \(wt.baseRef), then restore them")
                }
                if offerClaudeMerge {
                    pill(mergeAgentLive ? "Open merge in herdr" : "Merge with Claude",
                         icon: mergeAgentLive ? "arrow.up.forward.app" : "sparkles",
                         disabled: busy || externallyDisabled
                                   || (!mergeAgentLive && (disabledReason != nil || liveAgentName != nil))) {
                        launchMergeAgent()
                    }
                    .help(claudeMergeHelp)
                }
            }
            Text(stateLine)
                .font(.caption)
                .foregroundStyle(stateLineColor)
                .fixedSize(horizontal: false, vertical: true)
            if let mergeAgentError {
                Text(mergeAgentError).font(.caption2).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The gate every *git-mutating* pill shares.
    private var standardGate: Bool { busy || externallyDisabled || effectiveReason != nil }

    /// Worth offering whenever there is a merge to do or something in the way of doing it. Not
    /// shown on a clean, up-to-date worktree, where it would only be noise.
    private var offerClaudeMerge: Bool {
        wt.mergeInProgress || wt.trackedDirtyCount > 0 || wt.isBehindBase
    }

    /// Any herdr agent live in this checkout. The hosts each guard on their own proxy for this
    /// (`wt.isActive`/lock state, or `task.status`), and neither sees the merge agent we launch
    /// ourselves — so the control checks directly rather than trusting the host to have noticed.
    private var liveAgentName: String? { app.worktreeAgentName(path: wt.path) }
    private var mergeAgentName: String {
        TaskRunner.mergeAgentName(taskID: taskID, worktreePath: wt.path)
    }
    private var mergeAgentLive: Bool { liveAgentName == mergeAgentName }

    /// The host's reason, else one the control worked out for itself.
    private var effectiveReason: String? {
        if let disabledReason { return disabledReason }
        if mergeAgentLive { return "Claude is merging this worktree — open the pane to follow it." }
        if liveAgentName != nil { return Self.liveAgentReason }
        return nil
    }

    private var claudeMergeHelp: String {
        if mergeAgentLive { return "Focus the herdr pane where Claude is merging this worktree" }
        if let disabledReason { return disabledReason }
        if let liveAgentName { return "\(liveAgentName) is working in this worktree — merge after it stops." }
        return "Open a Claude agent in herdr to merge \(wt.baseRef) and resolve the conflicts"
    }

    /// The reason is appended rather than replacing the chain: the user needs BOTH facts — how
    /// stale the worktree is and why they cannot act on it yet. It also lands in the *visible*
    /// line because macOS can swallow hover on a disabled control, so the tooltip alone would
    /// leave the button looking broken.
    private var stateLine: String {
        guard let effectiveReason else { return baseStateLine }
        return "\(baseStateLine). \(effectiveReason)"
    }

    /// First match wins, so a conflicted worktree is never described merely as dirty.
    private var baseStateLine: String {
        if wt.mergeInProgress { return "Merge in progress — resolve or abort below" }
        if wt.trackedDirtyCount > 0 {
            // Names the way out rather than the obstacle: "commit or discard first" was a dead
            // end that sent the user off to a terminal, which is the whole reason Stash & update
            // exists. The pill it names is rendered right above this line.
            return "\(wt.trackedDirtyCount) uncommitted change\(wt.trackedDirtyCount == 1 ? "" : "s") — use Stash & update, or commit them first"
        }
        if wt.behindCount > 0 {
            return "\(wt.behindCount) commit\(wt.behindCount == 1 ? "" : "s") behind \(wt.baseBranch)"
        }
        return "Up to date with \(wt.baseBranch)"
    }

    private var stateLineColor: Color {
        (wt.mergeInProgress || wt.trackedDirtyCount > 0 || wt.behindCount > 0) ? .orange : .secondary
    }

    // MARK: - (b) merge-state block — gated on git, not on `outcome`

    /// Rendered iff `wt.mergeInProgress`. Gating on the flag rather than on a non-empty path
    /// list is deliberate: once the user stages resolutions the list goes empty while the merge
    /// is still live, and a path-list gate would strand them with no way out. It also means the
    /// block survives a refresh, a section switch and a relaunch, and appears for a merge
    /// started in a terminal.
    private var mergeStateBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if wt.conflictedFiles.isEmpty {
                Text("Merge resolved — commit it to finish")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Label("Conflicted (\(wt.conflictedFiles.count) file\(wt.conflictedFiles.count == 1 ? "" : "s"))",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.orange)
                ForEach(wt.conflictedFiles, id: \.self) { p in
                    Text(p).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            HStack(spacing: 8) {
                Button("Abort Merge") { abort() }
                    .buttonStyle(.bordered).controlSize(.small).tint(.red)
                    .disabled(busy)
                    .help("git merge --abort — restores HEAD and the working tree to the pre-merge state")
                Button("Review changes") { openReviewChanges() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Open Source Control to stage resolutions and commit the merge")
                Spacer(minLength: 0)
            }
            if let err = abortError {
                Text(err).font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(.leading, 2)
    }

    // MARK: - (c) outcome line

    @ViewBuilder private var outcomeLine: some View {
        if let outcome { outcomeBody(outcome) }
    }

    /// The unwrapped value is switched in its own builder on purpose: `switch` over an
    /// `Optional<WorktreeUpdateOutcome>` with bare `case .merged` patterns is a compile hazard,
    /// and nesting a second `switch` inside a `@ViewBuilder` body reads worse than this.
    @ViewBuilder private func outcomeBody(_ o: WorktreeUpdateOutcome) -> some View {
        switch o {
        case .upToDate:
            // `wt` is re-read every render, so the counts quoted here are the post-reload ones.
            Text("Already up to date with \(wt.baseBranch)."
                 + (fetchFailed && wt.baseRef.hasPrefix("origin/")
                    ? " — could not reach origin, compared against the last fetched \(wt.baseRef)" : ""))
                .font(.caption).foregroundStyle(.secondary)
        case .merged:
            Text("Merged \(wt.baseRef). Now \(freshBehind) behind, \(freshAhead) ahead of \(wt.baseBranch).")
                .font(.caption).foregroundStyle(.secondary)
        case .dirty(let n):
            Text("\(n) uncommitted change\(n == 1 ? "" : "s") — use Stash & update, or commit them first")
                .font(.caption).foregroundStyle(.orange)
        case .failed(let msg):
            Text(msg).font(.caption2).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .conflicted(let paths):
            if lastRunStashed {
                // The stashing path aborts and pops on conflict, so there is NO merge-state block
                // to explain this one — without a line here the click would look like it did
                // nothing at all.
                Text("\(wt.baseBranch) conflicts with this branch in \(paths.count) file\(paths.count == 1 ? "" : "s"). "
                     + "Nothing was changed — your uncommitted work is back exactly as it was. "
                     + "Use Merge with Claude to resolve it.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Deliberately nothing: the merge-state block above already shows the paths and
                // the buttons after the reload. Rendering both would duplicate the list.
                EmptyView()
            }
        case .stashConflicted(let paths):
            Text("Merged \(wt.baseRef), but restoring your changes conflicted in \(paths.count) "
                 + "file\(paths.count == 1 ? "" : "s"). Your work is safe — git kept the stash entry. "
                 + "Resolve the conflicts, then drop it.")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Read off `app.worktrees` in the BODY, not captured at outcome time: `reloadWorktrees()`
    /// is async, so the fresh numbers only exist after it publishes — and because `app` is
    /// observed, that publish re-renders this view with them.
    private var refreshed: WorktreeInfo? { app.worktrees.first { $0.path == wt.path } }
    private var freshBehind: Int { refreshed?.behindCount ?? wt.behindCount }
    private var freshAhead: Int { refreshed?.aheadCount ?? wt.aheadCount }

    // MARK: - actions

    /// Fetch (when there is an origin) then merge. The explicit action ALWAYS fetches,
    /// ignoring the scan's 5-minute throttle — the user asked for the *latest* base. A failed
    /// fetch does not abort the merge; it merges against the refs on disk and says so.
    private func run() { merge(stashing: false) }

    /// Stash the uncommitted tracked changes, merge, restore them. Same fetch-then-merge shape as
    /// `run()` — only the stager call differs, so the two share one function rather than drifting.
    private func runStashing() { merge(stashing: true) }

    private func merge(stashing: Bool) {
        guard !busy else { return }
        busy = true; outcome = nil; fetchFailed = false; abortError = nil; mergeAgentError = nil
        lastRunStashed = stashing
        let path = wt.path, ref = wt.baseRef, base = wt.baseBranch
        let root = app.activePath?.path
        Task {
            if ref.hasPrefix("origin/"), let root {
                // A plain `await`: `GitBase.fetchBase` is async and runs git through
                // `Subprocess`, which hops to `DispatchQueue.global()` itself. This `Task`
                // inherits the main actor, but suspending on the `await` does not block it.
                let ok = await GitBase.fetchBase(repoRoot: root, base: base)
                fetchFailed = !ok
            }
            outcome = stashing
                ? await WorktreeStager.updateFromBaseStashing(worktreePath: path, baseRef: ref)
                : await WorktreeStager.updateFromBase(worktreePath: path, baseRef: ref)
            busy = false
            app.reloadWorktrees()   // refreshes counts, merge state and conflicted files
        }
    }

    /// Hand the merge to a Claude agent in herdr. Fire-and-forget by design: nothing here polls
    /// it, and the agent's own pane is where the user watches it. Clicking again while it lives
    /// only focuses that pane (Core enforces it too — this is not the only caller).
    private func launchMergeAgent() {
        guard !busy else { return }
        mergeAgentError = nil
        let conflicted = wt.conflictedFiles
        app.openMergeAgent(worktreePath: wt.path, branch: wt.branch,
                           baseRef: wt.baseRef, baseBranch: wt.baseBranch,
                           taskID: taskID, conflicted: conflicted) { ok in
            if !ok {
                mergeAgentError = "Could not start the merge agent. Check that herdr is running and "
                                + "that Task Command: Merge From Base is enabled in App Settings."
            }
        }
    }

    private func abort() {
        guard !busy else { return }
        busy = true; abortError = nil
        let path = wt.path
        Task {
            let r = await WorktreeStager.abortMerge(worktreePath: path)
            busy = false
            if r.ok { outcome = nil; app.reloadWorktrees() }
            else { abortError = r.message.isEmpty ? "git merge --abort failed" : r.message }
        }
    }

    /// One-shot consumption of `app.pendingWorktreeUpdatePath`. The pending flag is cleared
    /// even when `externallyDisabled` or a `disabledReason` is set — a task whose agent started
    /// meanwhile must not have the card's live-agent guard bypassed by this race, and since that
    /// guard now travels as the reason, the reason has to block the auto-start too.
    private func startIfPending() {
        guard autoStartFromPending, app.pendingWorktreeUpdatePath == wt.path else { return }
        app.pendingWorktreeUpdatePath = nil
        guard !externallyDisabled, effectiveReason == nil, wt.canUpdateFromBase, !busy else { return }
        run()
    }

    private func openReviewChanges() {
        #if canImport(AppKit)
        if let win = NSApp.keyWindow ?? NSApp.mainWindow {
            let f = win.frame
            capturedSheetSize = CGSize(width: max(900, f.width * 0.92), height: max(560, f.height * 0.92))
        }
        #endif
        showReviewChanges = true
    }

    /// The Worktrees page's `PillButton`, so Unlock/Remove and these read as one family. It takes
    /// its `disabled` per call — the old shared helper baked in the card's busy flag, which is
    /// why this control once kept a private copy.
    private func pill(_ title: String, icon: String, disabled: Bool,
                      action: @escaping () -> Void) -> some View {
        PillButton(title: title, icon: icon, disabled: disabled, action: action)
    }
}
