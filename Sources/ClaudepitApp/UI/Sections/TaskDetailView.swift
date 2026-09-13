import SwiftUI
import ClaudepitCore
import AppKit

struct TaskDetailView: View {
    let task: ProjectTask
    @ObservedObject var app: AppState
    var onDismiss: (() -> Void)? = nil

    @State private var showDeleteConfirm = false
    @State private var showVersionsSheet = false
    @State private var showBrainstormSheet = false
    @State private var editSheet: EditSheet? = nil
    @State private var cloning = false
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var showFindingsSheet = false
    /// A follow-up the user chose to edit before creating. Rendered as the inline New Task form,
    /// the same way Clone and Edit already are — a modal on top of the findings sheet would not
    /// match anything else in the app.
    @State private var pendingFollowUp: PendingFollowUp? = nil
    @State private var attachmentsReload = 0

    /// Sheet geometry. Matches `WorktreeCard.openReviewChanges`, so the findings and Source Control
    /// sheets come up the same size.
    ///
    /// Three rules, each one a bug that happened:
    /// - **Prefer `NSApp.mainWindow`.** Once a sheet is up, `NSApp.keyWindow` IS the sheet, so
    ///   sizing off it gives the "opens large then shrinks" bug. A sheet is never *main*, so
    ///   `mainWindow` stays the document window and is safe to read at any time.
    /// - **Never fall back to the screen.** `visibleFrame * 0.7` is far wider than a windowed app,
    ///   so any failure to resolve the window produced a sheet overflowing its parent — which is
    ///   exactly what shipped. A fixed modest default is always safe; the window only shrinks it.
    /// - **Don't depend on the tap-time capture surviving.** This view is rebuilt whenever the
    ///   watcher reloads tasks, which can reset `@State`; the capture is a seed, not the source.
    @State private var capturedSheetSize = CGSize(width: 900, height: 560)

    private var reviewSheetSize: CGSize {
        #if canImport(AppKit)
        if let f = NSApp.mainWindow?.frame, f.width > 200, f.height > 200 { return inset(f.size) }
        #endif
        return capturedSheetSize
    }

    private func inset(_ s: CGSize) -> CGSize {
        CGSize(width: max(700, s.width * 0.92), height: max(480, s.height * 0.92))
    }

    private func captureSheetSize() {
        #if canImport(AppKit)
        guard let f = (NSApp.mainWindow ?? NSApp.keyWindow)?.frame, f.width > 200, f.height > 200
        else { return }
        capturedSheetSize = inset(f.size)
        #endif
    }

    private var slug: String { app.activePath.map { Paths.slug(for: $0) } ?? "" }

    /// A follow-up task drafted from review findings, waiting to be edited and saved.
    private struct PendingFollowUp: Identifiable {
        let draft: ProjectTask
        let findings: [ReviewFinding]
        var id: String { draft.id }
    }

    /// Which edit form is open (drives the .sheet). Edit main vs. new draft.
    private enum EditSheet: Identifiable { case main, draft; var id: Int { self == .main ? 0 : 1 } }
    /// New Draft + the compare-versions sheet: suggestion versions stay Backlog-only.
    private var canEditVersions: Bool { task.status == .backlog }
    /// Edit main: also allowed in the Brainstorm column, minus `.running`/`.blocked`.
    private var canEditMain: Bool { task.allowsMainEdit }

    /// Edit/draft form rendered INLINE in this same side panel (not a modal sheet),
    /// so it matches the create-task side screen exactly.
    @ViewBuilder
    private func editForm(_ which: EditSheet) -> some View {
        GlassCard {
            NewTaskSheet(app: app, onClose: {
                // Returning from New Draft: jump straight to the compare view so the
                // freshly-created version is visible — otherwise the save is invisible.
                let wasDraft = which == .draft
                editSheet = nil
                if wasDraft { showVersionsSheet = true }
            }, editing: task.mainVersion, taskID: task.id, draftMode: which == .draft)
        }
    }

    /// Clone prefill: main version with a [DRAFT] summary prefix. Stays in create mode (no taskID).
    private var clonePrefill: TaskVersion {
        var v = task.mainVersion
        v.name = "[DRAFT] " + task.name
        return v
    }

    var body: some View {
        Group {
            if cloning {
                GlassCard {
                    NewTaskSheet(app: app, onClose: { cloning = false; app.loadTasks() },
                                 prefill: clonePrefill)
                }
            } else if let pending = pendingFollowUp {
                GlassCard {
                    NewTaskSheet(app: app, onClose: { pendingFollowUp = nil; app.loadTasks() },
                                 prefill: pending.draft.mainVersion,
                                 createSeed: .init(draft: pending.draft,
                                                   parent: task,
                                                   findingIDs: pending.findings.map(\.id)))
                }
            } else if let which = editSheet {
                editForm(which)
            } else {
                detailContent
            }
        }
        .sheet(isPresented: $showVersionsSheet) {
            TaskVersionsSheet(taskID: task.id, app: app) { showVersionsSheet = false }
                .frame(width: 820, height: 620)
        }
        .sheet(isPresented: $showFindingsSheet) {
            ReviewFindingsSheet(task: task, app: app, onCreateAndEdit: { draft, findings in
                // Set the draft first, then dismiss: the form renders in this same view, so
                // flipping the sheet off first would show it behind a still-live sheet.
                pendingFollowUp = PendingFollowUp(draft: draft, findings: findings)
                showFindingsSheet = false
            }, onClose: { showFindingsSheet = false })
            .frame(width: reviewSheetSize.width, height: reviewSheetSize.height)
        }
        .sheet(isPresented: $showBrainstormSheet) {
            ReviewChangesSheet(source: BrainstormChangeSource(taskID: task.id, projectSlug: slug, title: task.name)) {
                app.loadTasks(); showBrainstormSheet = false
            }
            .frame(width: reviewSheetSize.width, height: reviewSheetSize.height)
        }
        .confirmationDialog("Delete \"\(task.name)\"?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { app.deleteTask(task); onDismiss?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    /// Delete confirmation copy. A shared worktree is kept — `deleteTask` refuses to remove one
    /// another task is still checked out at — so promising a removal here would be a lie.
    private var deleteMessage: String {
        guard let wt = task.worktree else { return "This cannot be undone." }
        if app.worktreeIsShared(path: wt.path, excluding: task.id) {
            return "Its git worktree is kept — another task is working in it. This cannot be undone."
        }
        return "This also removes its git worktree and any uncommitted changes in it. This cannot be undone."
    }

    private var detailContent: some View {
        GlassCard {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    phaseActions
                    actionPanel
                    fieldSections
                }
                .padding(20)
            }
        }
    }

    // Read-only mirror of the New Task form: same sectioned-card look, values shown as text.
    // All request-field editing happens via the Edit card (Backlog + Brainstorm, see
    // `ProjectTask.allowsMainEdit`) or the New Draft card (Backlog only) — these sections never
    // mutate the task; only Attachments is interactive.
    private var fieldSections: some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldSection("Summary") { Text(task.name).font(.body) }
            if let t = task.topic, !t.isEmpty { fieldSection("Topic") { Text(t).font(.body) } }
            if !task.description.isEmpty {
                fieldSection("Description") {
                    VStack(alignment: .leading, spacing: 12) {
                        MarkdownText(task.description).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        datesRows
                    }
                }
            } else {
                fieldSection("Dates") { datesRows }
            }
            if !task.requirements.isEmpty {
                fieldSection("Requirements") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(task.requirements, id: \.self) { r in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.secondary).padding(.top, 6)
                                Text(r).font(.callout)
                            }
                        }
                    }
                }
            }
            fieldSection("Priority") { Text(task.priority.label).font(.body) }
            fieldSection("Label") { tagsDisplay }
            if !task.dependsOn.isEmpty {
                fieldSection("Dependencies") {
                    FlowLayout(spacing: 6) {
                        ForEach(task.dependsOn, id: \.self) { dep in
                            Button { app.focusTaskID = dep; app.selected = .tasks } label: {
                                Text(depName(dep)).font(.body).foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .help("Open \(depName(dep))")
                        }
                    }
                }
            }
            if task.worktree != nil { fieldSection("Worktree") { worktreeRow } }
            fieldSection("Attachments") { attachmentsEditor }
        }
    }

    /// The task's worktree plus the shared base-sync control. `info` is recomputed in the body
    /// on every render, which is what keeps the control's merge-state block live.
    @ViewBuilder private var worktreeRow: some View {
        let info = task.worktree.flatMap { w in app.worktrees.first { $0.path == w.path } }
        VStack(alignment: .leading, spacing: 8) {
            if let w = task.worktree {
                Text(w.branch.isEmpty ? "detached" : w.branch)
                    .font(.callout.monospaced()).foregroundStyle(.secondary)
                Text(URL(filePath: w.path).lastPathComponent)
                    .font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let info {
                // Same live-agent guard as the board pill (§4.9): a running agent holds the
                // pre-merge file contents in its context. It travels as the *reason* — one input,
                // not two, so the two hosts cannot disagree — and that reason both disables the
                // button and explains why. `autoStartFromPending` respects it too: a pending
                // one-shot on a task whose agent started meanwhile is cleared without running,
                // so the card's guard cannot be bypassed by a race.
                UpdateFromBaseControl(
                    app: app, wt: info,
                    externallyDisabled: false,
                    disabledReason: (task.status == .running || task.status == .blocked)
                        ? UpdateFromBaseControl.liveAgentReason : nil,
                    autoStartFromPending: true)
            } else {
                Text("Worktree not found in the current scan")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Created / Updated as two labeled rows (human-readable date + time).
    private var datesRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            if task.createdAt > 0 { dateRow("Created", task.createdAt) }
            if task.updatedAt > 0 { dateRow("Updated", task.updatedAt) }
        }
    }
    private func dateRow(_ label: String, _ t: TimeInterval) -> some View {
        HStack(spacing: 8) {
            Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(Self.stamp(t)).font(.callout)
        }
    }

    /// Read-only tag chips, styled like a bordered button (per design ref) — not editable here.
    private var tagsDisplay: some View {
        Group {
            if task.tags.isEmpty {
                Text("—").font(.body).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(task.tags, id: \.self) { tag in
                        Text(tag).font(.callout)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    private func fieldSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                if editingName {
                    TextField("Name", text: $nameDraft)
                        .font(.title2).bold().textFieldStyle(.plain)
                        .onSubmit { commitName() }
                } else {
                    Text(task.name).font(.title2).bold()
                        .onTapGesture { nameDraft = task.name; editingName = true }
                }
                Spacer()
                if canEditMain {
                    Button { editSheet = .main } label: {
                        Label("Edit", systemImage: "pencil").font(.caption)
                    }.buttonStyle(.bordered).controlSize(.small).help("Edit the main version")
                }
                if canEditVersions {
                    Button { editSheet = .draft } label: {
                        Label("New Draft", systemImage: "doc.badge.plus").font(.caption)
                    }.buttonStyle(.bordered).controlSize(.small).help("Propose an alternate version to compare against main")
                }
                if task.hasSuggestions {
                    Button { showVersionsSheet = true } label: {
                        Label("Versions v\((task.suggestions?.count ?? 0) + 1)", systemImage: "square.stack.3d.up")
                            .font(.caption)
                    }.buttonStyle(.bordered).controlSize(.small).tint(.purple)
                        .help("Compare versions")
                }
                if let wt = task.worktree {
                    Button {
                        app.focusWorktreeName = URL(filePath: wt.path).lastPathComponent
                        app.selected = .worktrees
                    } label: {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open worktree")
                }
                Button { cloning = true } label: {
                    Image(systemName: "plus.square.on.square").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clone task")
                Button { showDeleteConfirm = true } label: {
                    Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete task")
                if let dismiss = onDismiss {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }
            }
        }
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
    private static func stamp(_ t: TimeInterval) -> String {
        dateFmt.string(from: Date(timeIntervalSince1970: t))
    }

    /// The phase-driven action UI (Run / review / chat / findings). Only meaningful once the task
    /// is out of Backlog; in Backlog it's just the Run button.
    @ViewBuilder
    private var actionPanel: some View {
        reviewPanel
    }

    private func depName(_ id: String) -> String { app.tasks.first { $0.id == id }?.name ?? id }

    // MARK: - Attachments (thumbnails from the task's attachments/ dir; click opens the file)

    private var attachmentsDir: URL { Paths.taskAttachmentsDir(projectSlug: slug, id: task.id) }
    private var attachmentURLs: [URL] {
        _ = attachmentsReload   // depend on the counter so adds refresh the grid
        let items = try? FileManager.default.contentsOfDirectory(at: attachmentsDir,
                        includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return (items ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private var attachmentsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            let urls = attachmentURLs
            if !urls.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(urls, id: \.self) { u in AttachmentThumb(url: u) { removeAttachment(u) } }
                }
            }
            Button { addAttachments() } label: { Label("Add attachment", systemImage: "paperclip") }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func addAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        try? FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
        for src in panel.urls {
            let dst = attachmentsDir.appending(path: src.lastPathComponent)
            try? FileManager.default.copyItem(at: src, to: dst)
        }
        attachmentsReload += 1
    }

    private func removeAttachment(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        attachmentsReload += 1
    }

    // MARK: - Review panel (switch on phase, status)

    @ViewBuilder
    private var reviewPanel: some View {
        switch task.status {
        case .blocked:
            // Used to be a bare label with no control at all — a dead end for a halted auto-run,
            // and not much better for a manual one.
            VStack(alignment: .leading, spacing: 8) {
                Label("Waiting on your reply in Herdr", systemImage: "bubble.left.and.bubble.right")
                    .foregroundStyle(.secondary)
                haltNotice
                HStack(spacing: 8) { openInHerdrButton; runToReviewButton; Spacer() }
            }
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Text("Phase failed.").foregroundStyle(.secondary)
                haltNotice
                HStack(spacing: 8) {
                    Button("Retry") { app.retryTask(task) }
                        .buttonStyle(.borderedProminent).tint(.orange).controlSize(.small)
                    runToReviewButton
                    Spacer()
                }
            }
        case .running:
            HStack(spacing: 8) {
                Label("Running in Herdr", systemImage: "waveform")
                    .foregroundStyle(.secondary)
                Spacer()
                openInHerdrButton
            }
        case .awaitingReview:
            VStack(alignment: .leading, spacing: 8) {
                haltNotice        // covers the pipeline-exhausted and needs-your-input halts
                awaitingPanel
            }
        case .backlog:
            let can = TaskTransition.canRun(task, allTasks: app.tasks)
            // A fix task shares its parent's checkout, so "can run" is also "is the checkout free".
            let busy = app.worktreeBusyName(task)
            VStack(alignment: .leading, spacing: 8) {
                haltNotice
                HStack(spacing: 8) {
                    Button("Run") { app.startTask(task) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(!can || busy != nil)
                        .help(busy.map { "\($0) is running in this worktree" }
                              ?? (can ? "" : "Blocked by: " + TaskTransition.unmetDependencies(task, allTasks: app.tasks).map(depName).joined(separator: ", ")))
                    runToReviewButton
                    Spacer()
                }
            }
        case .done:
            Label("Task complete", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var awaitingPanel: some View {
        switch task.phase {
        case .brainstorm:
            brainstormPanel
        case .writeSpec:
            writeSpecPanel
        case .createPlan:
            createPlanPanel
        case .implement:
            implementPanel
        case .codeReview:
            codeReviewPanel
        case .none:
            nextButton
        }
    }

    // MARK: - Brainstorm suggestions (VS-Code source-control-style accept/reject)

    /// True once the agent has written the brainstorm deliverable — used to end the "…in Herdr" spinner
    /// even when the file parsed to zero suggestions (wrong shape), so the panel is never stuck.
    private var brainstormFileExists: Bool {
        guard let p = task.links.brainstormPath else { return false }
        return FileManager.default.fileExists(atPath: p)
    }

    private var brainstormPanel: some View {
        let pending = task.links.brainstormSuggestions.filter { $0.accepted == nil }
        let acceptedCount = task.links.brainstormSuggestions.filter { $0.accepted == true }.count
        return VStack(alignment: .leading, spacing: 10) {
            if task.links.brainstormSuggestions.isEmpty {
                if brainstormFileExists {
                    // File landed but parsed to zero suggestions — the agent likely wrote the wrong
                    // shape (not a `suggestions:` list). Don't spin forever; point the user to Herdr.
                    Label("No suggestions found in the brainstorm file. Continue in Herdr or move on.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Brainstorming in Herdr — suggestions will appear here when ready.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            } else if !pending.isEmpty {
                // Ready-for-review banner → opens the same diff/compare UI as task versions.
                HStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up.badge.a.fill").font(.title3).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(pending.count) suggestion\(pending.count == 1 ? "" : "s") ready for review")
                            .font(.callout.weight(.semibold))
                        Text("Compare the proposed changes against the task and apply what you want.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { captureSheetSize(); showBrainstormSheet = true } label: {
                        Label("Review changes", systemImage: "arrow.left.arrow.right").font(.callout)
                    }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1))
            } else {
                Label("All \(acceptedCount) suggestion\(acceptedCount == 1 ? "" : "s") reviewed.", systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
            }
        }
    }

    private var writeSpecPanel: some View {
        let specPath = task.links.specPath
        let underTasksRoot: Bool = {
            guard let specPath, let base = app.activePath else { return false }
            let slug = Paths.slug(for: base)
            return specPath.hasPrefix(Paths.tasksRoot(projectSlug: slug).path)
        }()
        return reviewArtifactButton("Review spec", enabled: underTasksRoot,
                                    help: "Spec was not written under the tasks directory") {
            guard let specPath else { return }
            app.returnToSpecTaskID = task.id
            app.focusSpecPath = specPath
            app.selected = .specs
        }
    }

    private var createPlanPanel: some View {
        let planPath = task.links.planPath
        let underPlansRoot = planPath?.hasPrefix(Paths.plansRoot.path) ?? false
        return reviewArtifactButton("Review plan", enabled: underPlansRoot,
                                    help: "Plan was not written under ~/.claude/plans") {
            guard let planPath else { return }
            app.returnToTaskID = task.id
            app.focusPlanPath = planPath
            app.selected = .plans
        }
    }

    private var implementPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if task.worktree != nil {
                Button("Review changes") {
                    guard let wt = task.worktree else { return }
                    let name = URL(filePath: wt.path).lastPathComponent
                    app.focusWorktreeName = name
                    app.autoOpenReviewWorktree = name
                    app.selected = .worktrees
                }.buttonStyle(.borderedProminent).controlSize(.small)
            }
            if !task.links.sessionIDs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(task.links.sessionIDs, id: \.self) { sid in
                        Button { app.focusSessionID = sid; app.selected = .sessions } label: {
                            Label("Open Session \(sid.prefix(8))", systemImage: "terminal").font(.callout)
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    /// Findings banner — the same shape as the brainstorm ready-for-review banner.
    ///
    /// This panel used to render every finding as its own row with its own Create button. In a
    /// 250pt column that truncated each title to a few words and let only one expand at a time, so
    /// ten findings were unreadable. Triage moved to `ReviewFindingsSheet`; what stays here is the
    /// count, so you can see at a glance whether anything is waiting.
    @ViewBuilder
    private var codeReviewPanel: some View {
        let findings = task.links.reviewFindings
        let open = findings.filter { $0.spawnedTaskID == nil }
        let children = app.followUps(of: task)
        VStack(alignment: .leading, spacing: 10) {
            if findings.isEmpty {
                Label(reviewFileExists
                      ? "The review recorded no findings. Open review.md to read it."
                      : "Reviewing in Herdr — findings will appear here when ready.",
                      systemImage: reviewFileExists ? "checkmark.seal" : "hourglass")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "checklist").font(.title3).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(findingsSummary).font(.callout.weight(.semibold))
                        Text(open.isEmpty
                             ? "Every finding has a task."
                             : "Pick the ones to fix — several can go into one task.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { captureSheetSize(); showFindingsSheet = true } label: {
                        Label("Review findings", systemImage: "arrow.left.arrow.right").font(.callout)
                    }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1))
            }
            if !children.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(children.count) follow-up task\(children.count == 1 ? "" : "s")")
                        .font(.caption2).fontWeight(.bold).foregroundStyle(.secondary).tracking(0.5)
                    ForEach(children) { c in
                        Button { app.focusTaskID = c.id; app.selected = .tasks } label: {
                            Label(c.name, systemImage: "arrow.turn.down.right")
                                .font(.caption).lineLimit(1)
                        }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    private var reviewFileExists: Bool {
        guard let p = task.links.reviewPath else { return false }
        return FileManager.default.fileExists(atPath: p)
    }

    /// "10 findings · 1 med · 9 low · 3 triaged" — zero buckets omitted.
    private var findingsSummary: String {
        let all = task.links.reviewFindings
        var parts = ["\(all.count) finding\(all.count == 1 ? "" : "s")"]
        for (label, rank) in [("high", 0), ("med", 1), ("low", 2)] {
            let c = all.filter { $0.severityRank == rank }.count
            if c > 0 { parts.append("\(c) \(label)") }
        }
        let done = all.filter { $0.spawnedTaskID != nil }.count
        if done > 0 { parts.append("\(done) triaged") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Shared bits

    /// The single "Review <artifact>" deep-link button every artifact phase uses.
    private func reviewArtifactButton(_ label: String, enabled: Bool, help: String,
                                      action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(!enabled)
            .help(enabled ? "" : help)
    }

    private var nextButton: some View {
        let isLast = TaskTransition.nextPlannedPhase(after: task.phase, in: task.plannedPhases) == nil
        return Button(isLast ? "Done" : "Next phase") { app.advanceTaskPhase(task) }
            .buttonStyle(.bordered).controlSize(.small)
    }

    @ViewBuilder
    private var openInHerdrButton: some View {
        if let phase = task.phase {
            Button { app.openTaskInHerdr(task, phase: phase) } label: {
                Label("Open in Herdr", systemImage: "terminal").font(.caption)
            }.buttonStyle(.bordered).controlSize(.small)
        }
    }

    /// Shared phase-action row (Open in Herdr + Next phase), shown once right below the task
    /// summary while a phase is awaiting review — same bordered style, so the two match.
    @ViewBuilder
    private var phaseActions: some View {
        if task.isAutoRunning {
            autoRunBanner          // auto-run owns advancement, so Next is deliberately hidden
        } else if task.status == .awaitingReview, task.phase != nil {
            HStack(spacing: 8) {
                openInHerdrButton
                nextButton
                runToReviewButton
                Spacer()
            }
        }
    }

    /// Arm unattended execution. Gated exactly like Run — same dependency and shared-checkout
    /// rules apply, since it is the same launch, just repeated.
    private static let autoRunHelp =
        "Runs each phase back-to-back without asking you anything, and stops at Code Review. "
        + "The agent decides open questions itself and records them under \"Assumptions\" in "
        + "each deliverable."

    /// Explanation for the Run-to-review button: why it is unavailable, or what it will do.
    private var autoRunHelpText: String {
        if let busy = app.worktreeBusyName(task) { return "\(busy) is running in this worktree" }
        let unmet = TaskTransition.unmetDependencies(task, allTasks: app.tasks)
        if !unmet.isEmpty { return "Blocked by: " + unmet.map(depName).joined(separator: ", ") }
        return Self.autoRunHelp
    }

    /// Arm (or re-arm) unattended execution. Renders nothing while a chain is live — the banner
    /// owns that state and offers Stop instead. "Resume" rather than "Run to review" once a halt
    /// has been recorded, since re-arming also restores the retry budget.
    @ViewBuilder
    private var runToReviewButton: some View {
        if !task.isAutoRunning, task.status != .done {
            let can = TaskTransition.canRun(task, allTasks: app.tasks)
            let busy = app.worktreeBusyName(task)
            Button(task.autoRunHaltReason == nil ? "Run to review" : "Resume auto-run") {
                app.armAutoRun(task)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(!can || busy != nil)
            .help(autoRunHelpText)
        }
    }

    private var autoRunBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "forward.end.alt.fill").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-running to Code Review").font(.callout.weight(.semibold))
                Text(task.phase.map { "Currently: \($0.title)" } ?? "Starting…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            openInHerdrButton
            Button("Stop") { app.stopAutoRun(task) }
                .buttonStyle(.bordered).controlSize(.small)
                .help("The phase already running finishes — herdr has no way to stop an agent "
                    + "mid-turn — but nothing new starts after it.")
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1))
    }

    /// Why a halted auto-run stopped. Rendered in every status arm that can hold one, because a
    /// halt is exactly the moment the user needs to know the unattended run gave up.
    @ViewBuilder
    private var haltNotice: some View {
        if !task.isAutoRunning, let why = task.autoRunHaltReason {
            Label("Auto-run stopped: \(why)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    // MARK: - Actions

    private func commitName() {
        editingName = false
        let n = nameDraft.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != task.name else { return }
        try? TaskStore.shared.update(id: task.id, projectSlug: slug) { $0.name = n }
        app.loadTasks()
    }
}

/// One attachment: image → clickable thumbnail (session-transcript style), other → file chip.
/// Click opens the file; the × removes it.
private struct AttachmentThumb: View {
    let url: URL
    let onRemove: () -> Void

    var body: some View {
        content
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                        .foregroundStyle(.white, .black.opacity(0.5))
                }
                .buttonStyle(.plain).padding(2)
            }
            .onTapGesture { NSWorkspace.shared.open(url) }
            .help(url.lastPathComponent)
    }

    @ViewBuilder
    private var content: some View {
        if let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .resizable().aspectRatio(contentMode: .fill)
                .frame(width: 72, height: 72).clipped().cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        } else {
            VStack(spacing: 4) {
                Image(systemName: "doc.fill").font(.title2)
                Text(url.lastPathComponent).font(.system(size: 9)).lineLimit(2)
            }
            .foregroundStyle(.secondary)
            .frame(width: 72, height: 72)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
