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
                    summarySection
                    topicSection
                    descriptionSection
                    requirementsSection
                    prioritySection
                    labelSection
                    if !depCandidates(all: true).isEmpty || !dependsOn.isEmpty { dependenciesSection }
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

    private func load() {
        topicOptions = app.activePath.map { TopicStore.shared.load(projectSlug: Paths.slug(for: $0)) } ?? []
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
        let task = ProjectTask(
            name: cleanName, topic: cleanTopic.isEmpty ? nil : cleanTopic, description: description,
            phase: nil, status: .backlog, priority: priority,
            tags: tags, dependsOn: Array(dependsOn),
            requirements: cleanReqs,
            createdAt: now, updatedAt: now)
        try? TaskStore.shared.save(task, projectSlug: slug)
        app.loadTasks()
        onClose()
    }
}
