import SwiftUI
import ClaudepitCore

/// Task create/edit/draft form. Sectioned: Summary, Topic, Description, Requirements, Priority,
/// Label, Dependencies. One form serves three modes:
///   - create (editing == nil): builds a new ProjectTask.
///   - edit main (editing != nil, !draftMode): updates the task's top-level fields.
///   - new draft (editing != nil, draftMode): appends a new TaskVersion suggestion.
struct NewTaskSheet: View {
    @ObservedObject var app: AppState
    var onClose: () -> Void

    /// Prefill source. nil = create mode. Set for edit-main or new-draft.
    var editing: TaskVersion? = nil
    var taskID: String? = nil
    var draftMode: Bool = false

    /// Clone: seed fields but stay in create mode (no taskID/editing → save() creates a fresh task).
    var prefill: TaskVersion? = nil

    /// A fully-formed task to create, carrying the shape `TaskVersion` cannot express — planned
    /// phases, an inherited worktree, the follow-up link. Used by the review-findings flow so
    /// "Create and edit…" produces exactly the task the one-click button would have, plus edits.
    struct CreateSeed {
        var draft: ProjectTask
        var parent: ProjectTask
        var findingIDs: [String]
    }
    var createSeed: CreateSeed? = nil

    @State private var name = ""
    @State private var topic = ""
    @State private var description = ""
    @State private var requirements: [String] = [""]
    @State private var priority: Priority = .normal
    @State private var tags: [String] = []
    @State private var tagDraft = ""
    @State private var dependsOn: Set<String> = []
    @State private var depFilter = ""
    @State private var depTopicFilter: String? = nil
    @State private var topicOptions: [String] = []

    /// Which pipeline the created task plans. Only shown for a seeded create — an ordinary new
    /// task has no reason to start anywhere but the top.
    @State private var fixNow = true
    @State private var autoRunOnCreate = false
    /// Work in the parent's checkout (where the code under review actually lives, uncommitted).
    @State private var inheritWorktree = true
    /// Resume the parent's implement session. Only resolvable in that worktree's cwd, so it is
    /// forced off — and disabled — when `inheritWorktree` is off.
    @State private var resumeSession = true

    @State private var aiExpanded = false
    @State private var aiIdea = ""
    @State private var aiGenerating = false
    @State private var aiError: String? = nil

    @FocusState private var focusedRequirement: Int?

    private var isEditing: Bool { editing != nil }
    private var titleText: String { isEditing ? (draftMode ? "New Draft" : "Edit Task") : "New Task" }
    private var saveLabel: String { isEditing ? "Save" : "Create" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(titleText).font(.title3).bold()
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if editing == nil { aiSection }
                    summarySection
                    topicSection
                    descriptionSection
                    requirementsSection
                    prioritySection
                    labelSection
                    if !depCandidates(all: true).isEmpty || !dependsOn.isEmpty { dependenciesSection }
                    if !isEditing { workflowSection }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                Button(saveLabel) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { load() }
    }

    // MARK: - Sections

    /// Collapsed by default — a one-line header so the AI option doesn't dominate the form
    /// for users filling it by hand. Mirrors `section()`'s container styling with a
    /// chevron-toggle header (the DiscoverSheet/PluginsSection expansion idiom).
    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { aiExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: aiExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(aiExpanded ? Color.accentColor : .secondary)
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    Text("CREATE WITH AI").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    // Generation keeps running while collapsed — surface it in the header.
                    if aiGenerating && !aiExpanded { ProgressView().controlSize(.small) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if aiExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Describe the task in your own words — Claude fills in the form below.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $aiIdea)
                        .font(.body)
                        .frame(minHeight: 70)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.10), lineWidth: 1))
                    HStack(spacing: 8) {
                        Button {
                            generateWithAI()
                        } label: {
                            Label("Generate", systemImage: "sparkles")
                        }
                        .disabled(aiGenerating || aiIdea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if aiGenerating {
                            ProgressView().controlSize(.small)
                            Text("Generating…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let err = aiError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private var summarySection: some View {
        section("Summary", required: true) {
            TextField("Short summary of the task", text: $name).textFieldStyle(.roundedBorder)
        }
    }

    private var topicSection: some View {
        section("Topic") {
            HStack(spacing: 6) {
                TextField("Type or pick a topic", text: $topic).textFieldStyle(.roundedBorder)
                if !topicOptions.isEmpty {
                    Menu {
                        ForEach(topicOptions, id: \.self) { t in Button(t) { topic = t } }
                    } label: {
                        Image(systemName: "chevron.down").font(.caption)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
        }
    }

    private var descriptionSection: some View {
        section("Description") {
            TextEditor(text: $description)
                .font(.body)
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.10), lineWidth: 1))
        }
    }

    private var requirementsSection: some View {
        section("Requirements") {
            // No explicit "Add" button — pressing Return on the last row appends a new one.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(requirements.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        Image(systemName: "circle").font(.system(size: 6)).foregroundStyle(.secondary)
                        TextField("Requirement", text: $requirements[i])
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedRequirement, equals: i)
                            .onSubmit { if i == requirements.count - 1 { addRequirement() } }
                        Button { removeRequirement(i) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .disabled(requirements.count == 1 && requirements[0].isEmpty)
                    }
                }
            }
        }
    }

    private var prioritySection: some View {
        section("Priority", required: true) {
            Picker("", selection: $priority) {
                ForEach(Priority.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
        }
    }

    private var labelSection: some View {
        section("Label") {
            VStack(alignment: .leading, spacing: 6) {
                if !tags.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text(tag).font(.callout)
                                Button { tags.removeAll { $0 == tag } } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                                    .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                TextField("Add label and press return", text: $tagDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addTag() }
            }
        }
    }

    private var dependenciesSection: some View {
        section("Dependencies") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(depCandidates(all: false)) { t in
                            Button {
                                if dependsOn.contains(t.id) { dependsOn.remove(t.id) } else { dependsOn.insert(t.id) }
                            } label: {
                                Label(t.name, systemImage: dependsOn.contains(t.id) ? "checkmark" : "")
                            }
                        }
                    } label: {
                        Label(dependsOn.isEmpty ? "Add dependency" : "\(dependsOn.count) selected", systemImage: "arrow.triangle.branch")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton).fixedSize()

                    if !depTopics.isEmpty {
                        Menu {
                            Button("All topics") { depTopicFilter = nil }
                            ForEach(depTopics, id: \.self) { t in Button(t) { depTopicFilter = t } }
                        } label: {
                            Label(depTopicFilter ?? "Topic", systemImage: "tag").font(.caption)
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                }
                TextField("Search tasks…", text: $depFilter).textFieldStyle(.roundedBorder)

                if !dependsOn.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(Array(dependsOn), id: \.self) { id in
                            HStack(spacing: 3) {
                                Text(depName(id)).font(.caption)
                                Button { dependsOn.remove(id) } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                                    .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.white.opacity(0.08), in: Capsule())
                        }
                    }
                }
            }
        }
    }

    /// Pipeline + continuation controls. The auto-run toggle applies to every new task; the
    /// pipeline picker and continuation controls only to a follow-up drafted from review findings.
    @ViewBuilder
    private var workflowSection: some View {
        section("Workflow") {
            VStack(alignment: .leading, spacing: 10) {
                if let seed = createSeed {
                    Picker("", selection: $fixNow) {
                        Text("Fix now — Implement → Review").tag(true)
                        Text("Full — Spec → Plan → Implement → Review").tag(false)
                    }
                    .pickerStyle(.radioGroup).labelsHidden()

                    if seed.draft.followUp != nil {
                        Divider().opacity(0.2)
                        Text("Continues \"\(seed.parent.name)\"")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Toggle("Work in its worktree", isOn: $inheritWorktree)
                            .toggleStyle(.checkbox).font(.callout)
                            .disabled(seed.draft.worktree == nil)
                            .help(seed.draft.worktree == nil
                                  ? "That task has no worktree to inherit"
                                  : "The code under review is uncommitted there — a fresh worktree would not contain it")
                        Toggle("Resume its implementation session", isOn: $resumeSession)
                            .toggleStyle(.checkbox).font(.callout)
                            .disabled(!inheritWorktree || seed.draft.followUp?.resumeSessionID == nil)
                            .help(seed.draft.followUp?.resumeSessionID == nil
                                  ? "No implement session was captured for that task"
                                  : "The agent picks up with the full implementation context")
                        if !inheritWorktree && resumeSession {
                            // Belt and braces for the disabled state: --resume only resolves in
                            // the cwd the session was recorded under.
                            Text("A session can only be resumed in its own worktree.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Divider().opacity(0.2)
                }
                Toggle("Run to review automatically", isOn: $autoRunOnCreate)
                    .toggleStyle(.checkbox).font(.callout)
                Text("Runs each phase back-to-back without asking you anything, and stops at "
                   + "Code Review.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Section container

    private func section<Content: View>(_ title: String, required: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                if required { Text("*").font(.caption2.weight(.semibold)).foregroundStyle(.red) }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Dependency candidates

    /// Exclude the task being edited (can't depend on itself). `all` ignores the search/topic filters.
    private func depCandidates(all: Bool) -> [ProjectTask] {
        app.tasks.filter { t in
            t.id != taskID &&
            (all || depFilter.isEmpty || t.name.localizedCaseInsensitiveContains(depFilter)) &&
            (all || depTopicFilter == nil || (t.topic ?? "") == depTopicFilter)
        }
    }

    private var depTopics: [String] {
        Array(Set(app.tasks.compactMap { $0.topic }.filter { !$0.isEmpty })).sorted()
    }

    // MARK: - Actions

    private func addTag() {
        let t = tagDraft.trimmingCharacters(in: .whitespaces); tagDraft = ""
        guard !t.isEmpty, !tags.contains(t) else { return }
        tags.append(t)
    }
    private func addRequirement() {
        requirements.append("")
        focusedRequirement = requirements.count - 1
    }
    private func removeRequirement(_ i: Int) {
        requirements.remove(at: i)
        if requirements.isEmpty { requirements = [""] }
    }
    private func depName(_ id: String) -> String { app.tasks.first { $0.id == id }?.name ?? id }

    private func generateWithAI() {
        let idea = aiIdea.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idea.isEmpty, !aiGenerating else { return }
        aiError = nil
        aiGenerating = true
        // Snapshot everything the background task needs before leaving the main actor.
        let topics = topicOptions
        let candidates = app.tasks.filter { $0.status != .done }
            .map { TaskDraftRunner.Candidate(id: $0.id, name: $0.name, topic: $0.topic) }
        // All ids, not just the offered candidates — the manual dependency menu allows
        // any task, so sanitization must never drop a real id.
        let validIDs = Set(app.tasks.map(\.id))
        let cwd = app.activePath
        Task {
            do {
                let draft = try await TaskDraftRunner.generate(
                    idea: idea, topics: topics, candidates: candidates,
                    validTaskIDs: validIDs, cwd: cwd)
                await MainActor.run { apply(draft); aiGenerating = false }
            } catch TaskDraftError.claudeNotFound {
                await MainActor.run {
                    aiError = "claude CLI not found — make sure it's installed and on PATH"
                    aiGenerating = false
                }
            } catch TaskDraftError.processFailed(let code, let message) {
                let signedOut = ClaudeAuth.isNotLoggedIn(message)
                if signedOut { NotificationCenter.default.post(name: .claudeAuthSuspect, object: nil) }
                await MainActor.run {
                    aiError = signedOut
                        ? "Claude is signed out — run `\(ClaudeAuth.signInCommand)`."
                        : "Generation failed (exit \(code)): \(message.prefix(200))"
                    aiGenerating = false
                }
            } catch TaskDraftError.invalidJSON {
                await MainActor.run {
                    aiError = "Claude returned an unexpected format — try Generate again."
                    aiGenerating = false
                }
            } catch {
                await MainActor.run {
                    aiError = error.localizedDescription
                    aiGenerating = false
                }
            }
        }
    }

    private func apply(_ draft: TaskVersion) {
        name = draft.name
        topic = draft.topic
        description = draft.description
        requirements = draft.requirements.isEmpty ? [""] : draft.requirements   // keep one editable row
        priority = draft.priority
        tags = draft.tags
        dependsOn = Set(draft.dependsOn)
    }

    private func load() {
        topicOptions = app.activePath.map { TopicStore.shared.load(projectSlug: Paths.slug(for: $0)) } ?? []
        if let seed = createSeed {
            fixNow = !seed.draft.plannedPhases.contains(.createPlan)
            inheritWorktree = seed.draft.worktree != nil
            resumeSession = seed.draft.followUp?.resumeSessionID != nil
        }
        if let p = prefill, editing == nil {
            name = p.name; topic = p.topic; description = p.description
            requirements = p.requirements.isEmpty ? [""] : p.requirements
            priority = p.priority; tags = p.tags; dependsOn = Set(p.dependsOn)
        }
        guard let e = editing else { return }
        name = e.name
        topic = e.topic
        description = e.description
        requirements = e.requirements.isEmpty ? [""] : e.requirements
        priority = e.priority
        tags = e.tags
        dependsOn = Set(e.dependsOn)
    }

    private func save() {
        guard let base = app.activePath else { return }
        let slug = Paths.slug(for: base)
        let cleanReqs = requirements.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let cleanTopic = topic.trimmingCharacters(in: .whitespaces)
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        try? TopicStore.shared.add(cleanTopic, projectSlug: slug)

        if let tid = taskID, isEditing {
            if draftMode {
                let v = TaskVersion(label: "Draft", createdAt: Date().timeIntervalSince1970,
                                    name: cleanName, topic: cleanTopic, description: description,
                                    requirements: cleanReqs, priority: priority,
                                    tags: tags, dependsOn: Array(dependsOn))
                if let t = app.tasks.first(where: { $0.id == tid }) { app.saveSuggestion(t, v) }
            } else {
                try? TaskStore.shared.update(id: tid, projectSlug: slug) { t in
                    t.name = cleanName; t.topic = cleanTopic; t.description = description
                    t.requirements = cleanReqs; t.priority = priority
                    t.tags = tags; t.dependsOn = Array(dependsOn)
                }
                app.loadTasks()
            }
            onClose(); return
        }

        let now = Date().timeIntervalSince1970

        // Seeded create (review findings): start from the draft so plannedPhases, the inherited
        // worktree and the follow-up link survive, then overwrite only the fields this form edits.
        if let seed = createSeed {
            var t = seed.draft
            t.name = cleanName
            t.topic = cleanTopic.isEmpty ? nil : cleanTopic
            t.description = description
            t.requirements = cleanReqs
            t.priority = priority
            t.tags = tags
            t.dependsOn = Array(dependsOn)
            t.plannedPhases = FindingTaskDraft.plannedPhases(fixNow: fixNow)
            if !inheritWorktree {
                // Forking fresh: the session cannot be resumed anywhere but its own worktree, so
                // the two settings fall together.
                t.worktree = nil
                t.followUp?.resumeSessionID = nil
            } else if !resumeSession {
                t.followUp?.resumeSessionID = nil
            }
            t.createdAt = now
            t.updatedAt = now
            app.saveFollowUp(t, parent: seed.parent, findingIDs: seed.findingIDs)
            // Arm through AppState rather than setting t.autoRun here, so there is one code path
            // for arming: the same guards, retry-budget reset and poll-timer kick.
            if autoRunOnCreate { app.armAutoRun(t) }
            onClose(); return
        }

        let task = ProjectTask(
            name: cleanName, topic: cleanTopic.isEmpty ? nil : cleanTopic, description: description,
            phase: nil, status: .backlog, priority: priority,
            tags: tags, dependsOn: Array(dependsOn),
            requirements: cleanReqs,
            createdAt: now, updatedAt: now)
        try? TaskStore.shared.save(task, projectSlug: slug)
        app.loadTasks()
        if autoRunOnCreate { app.armAutoRun(task) }
        onClose()
    }
}
