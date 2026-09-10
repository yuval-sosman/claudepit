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
    @State private var expandedFinding: String? = nil
    @State private var attachmentsReload = 0

    /// Source-Control-style sheets size to a stable fraction of the SCREEN (not NSApp.keyWindow,
    /// which flips to the sheet's own small window once it becomes key → the "opens large then
    /// shrinks" bug).
    private var reviewSheetSize: CGSize {
        #if canImport(AppKit)
        if let vis = (NSApp.keyWindow ?? NSApp.mainWindow)?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            return CGSize(width: max(900, vis.width * 0.8), height: max(560, vis.height * 0.85))
        }
        #endif
        return CGSize(width: 900, height: 560)
    }

    private var slug: String { app.activePath.map { Paths.slug(for: $0) } ?? "" }

    /// Which edit form is open (drives the .sheet). Edit main vs. new draft.
    private enum EditSheet: Identifiable { case main, draft; var id: Int { self == .main ? 0 : 1 } }
    private var canEditVersions: Bool { task.status == .backlog }

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
        .sheet(isPresented: $showBrainstormSheet) {
            ReviewChangesSheet(source: BrainstormChangeSource(taskID: task.id, projectSlug: slug, title: task.name)) {
                app.loadTasks(); showBrainstormSheet = false
            }
            .frame(width: reviewSheetSize.width, height: reviewSheetSize.height)
        }
        .confirmationDialog("Delete \"\(task.name)\"?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { app.deleteTask(task); onDismiss?() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This cannot be undone.") }
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
    // All request-field editing happens via the Edit / New Draft version cards (backlog only) —
    // these sections never mutate the task; only Attachments is interactive.
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
            fieldSection("Attachments") { attachmentsEditor }
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
                if canEditVersions {
                    Button { editSheet = .main } label: {
                        Label("Edit", systemImage: "pencil").font(.caption)
                    }.buttonStyle(.bordered).controlSize(.small).help("Edit the main version")
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
            Label("Waiting on your reply in Herdr", systemImage: "bubble.left.and.bubble.right")
                .foregroundStyle(.secondary)
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Text("Phase failed.").foregroundStyle(.secondary)
                Button("Retry") { app.retryTask(task) }.buttonStyle(.borderedProminent).tint(.orange).controlSize(.small)
            }
        case .running:
            HStack(spacing: 8) {
                Label("Running in Herdr", systemImage: "waveform")
                    .foregroundStyle(.secondary)
                Spacer()
                openInHerdrButton
            }
        case .awaitingReview:
            awaitingPanel
        case .backlog:
            let can = TaskTransition.canRun(task, allTasks: app.tasks)
            Button("Run") { app.startTask(task) }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(!can)
                .help(can ? "" : "Blocked by: " + TaskTransition.unmetDependencies(task, allTasks: app.tasks).map(depName).joined(separator: ", "))
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
        case .implement, .verify:
            implementVerifyPanel
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
                    Button { showBrainstormSheet = true } label: {
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

    private var implementVerifyPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if task.phase == .verify, let passed = task.links.verifyPassed {
                Label(passed ? "Verification passed" : "Verification failed",
                      systemImage: passed ? "checkmark.shield.fill" : "xmark.shield.fill")
                    .foregroundStyle(passed ? .green : .red)
            }
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

    private var codeReviewPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(task.links.reviewFindings) { finding in findingRow(finding) }
        }
    }

    private func findingRow(_ f: ReviewFinding) -> some View {
        let spawned = f.spawnedTaskID
        return VStack(alignment: .leading, spacing: 4) {
            Button { expandedFinding = expandedFinding == f.id ? nil : f.id } label: {
                HStack(spacing: 8) {
                    Text(f.severity.uppercased()).font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(severityColor(f.severity).opacity(0.25), in: Capsule())
                        .foregroundStyle(severityColor(f.severity))
                    Text(f.title).font(.callout).lineLimit(1)
                    Spacer()
                    if let tid = spawned {
                        Button { app.focusTaskID = tid; app.selected = .tasks } label: {
                            Text("Created →").font(.caption).foregroundStyle(Color.accentColor)
                        }.buttonStyle(.plain)
                    } else {
                        Button("Create dependent task") { app.createTaskFromFinding(parent: task, finding: f) }
                            .controlSize(.small)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expandedFinding == f.id {
                Text(f.detail).font(.caption).foregroundStyle(.secondary).padding(.leading, 8)
            }
        }
        .padding(8)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }

    private func severityColor(_ s: String) -> Color {
        switch s { case "high": return .red; case "med", "medium": return .orange; default: return .secondary }
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
        if task.status == .awaitingReview, task.phase != nil {
            HStack(spacing: 8) {
                openInHerdrButton
                nextButton
                Spacer()
            }
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
