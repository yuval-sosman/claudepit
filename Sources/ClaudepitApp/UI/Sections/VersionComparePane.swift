import SwiftUI
import ClaudepitCore

/// Shared "compare a proposal against Main" pane, used by BOTH the task Versions sheet and the
/// Brainstorm review. Pure data + closures — no AppState dependency — so changing the diff/edit UI
/// here updates both call sites at once. `draft` is the editable proposal; `main` is the baseline.
struct VersionComparePane: View {
    let main: TaskVersion
    @Binding var draft: TaskVersion
    var editable: Bool = true
    /// Footer "adopt everything" affordance. Brainstorm hides it (accept is per-field).
    var showPromote: Bool = true
    var promoteLabel: String = "Make this the Main version"
    var promoteSubtitle: String = "Replaces Main with these values; the old Main is kept as a suggestion."
    var headerTitle: String = "This suggestion"
    var explainer: String = "Edit a field below, then Apply to Main to copy just that field — or use the footer to adopt everything."
    /// Copy one field's current draft value into Main.
    var onApplyField: (VersionField) -> Void
    /// Adopt the whole proposal.
    var onPromote: () -> Void = {}
    var depName: (String) -> String = { $0 }

    @State private var showUnchanged = false
    @State private var tagDraft = ""

    static let allFields: [VersionField] = [.name, .topic, .description, .requirements, .priority, .tags, .dependsOn]
    private var changed: [VersionField] { draft.changedFields(vs: main) }
    private var unchanged: [VersionField] {
        let c = Set(changed); return VersionComparePane.allFields.filter { !c.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                compareHeader
                if changed.isEmpty {
                    Label("No changes vs Main.", systemImage: "equal.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
                } else {
                    ForEach(changed, id: \.self) { f in fieldBlock(f) }
                }
                unchangedDisclosure
                if showPromote { footer }
            }
            .padding(18)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Header

    private var compareHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(headerTitle).font(.headline).lineLimit(1)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 3) { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow); Text("Main").font(.subheadline) }
            }
            HStack(spacing: 12) {
                legendDot(Color(red: 1, green: 0.35, blue: 0.35), "Main")
                legendDot(Color(red: 0.35, green: 0.9, blue: 0.45), "Suggestion")
                Spacer()
                Text("\(changed.count) field\(changed.count == 1 ? "" : "s") changed").font(.caption).foregroundStyle(.secondary)
            }
            if editable {
                Text(explainer).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.bottom, 2)
    }

    private func legendDot(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 7, height: 7); Text(label).font(.caption2).foregroundStyle(.secondary) }
    }

    // MARK: - Per-field block

    private func fieldBlock(_ field: VersionField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(fieldTitle(field)).font(.subheadline.bold())
                Spacer()
                if editable {
                    Button { onApplyField(field) } label: {
                        Label("Apply to Main", systemImage: "arrow.left.circle").font(.caption)
                    }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                    .help("Copy this field's value into the Main version")
                }
            }
            fieldBody(field)
        }
        .padding(12)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1))
    }

    @ViewBuilder
    private func fieldBody(_ field: VersionField) -> some View {
        switch field {
        case .name:
            textDiff(main.name, draft.name)
            TextField("Summary", text: $draft.name).textFieldStyle(.roundedBorder).disabled(!editable)
        case .topic:
            textDiff(main.topic, draft.topic)
            TextField("Topic", text: $draft.topic).textFieldStyle(.roundedBorder).disabled(!editable)
        case .description:
            textDiff(main.description, draft.description)
            TextEditor(text: $draft.description)
                .font(.body).frame(minHeight: 100).scrollContentBackground(.hidden)
                .padding(6).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.10), lineWidth: 1))
                .disabled(!editable)
        case .requirements:
            itemDiff(main: main.requirements, value: draft.requirements)
            if editable { requirementsEditor }
        case .priority:
            HStack(spacing: 8) {
                Text(main.priority.label).foregroundStyle(Color(red: 1, green: 0.35, blue: 0.35))
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $draft.priority) {
                    ForEach(Priority.allCases, id: \.self) { Text($0.label).tag($0) }
                }.labelsHidden().fixedSize().disabled(!editable)
            }
        case .tags:
            itemDiff(main: main.tags, value: draft.tags)
            if editable { chipsEditor }
        case .dependsOn:
            itemDiff(main: main.dependsOn.map(depName), value: draft.dependsOn.map(depName))
        }
    }

    private func fieldTitle(_ f: VersionField) -> String {
        switch f {
        case .name: return "Summary"; case .topic: return "Topic"; case .description: return "Description"
        case .requirements: return "Requirements"; case .priority: return "Priority"
        case .tags: return "Label"; case .dependsOn: return "Dependencies"
        }
    }

    private func textDiff(_ from: String, _ to: String) -> some View {
        PlanDiffView(lines: planDiffLines(from: from, to: to))
            .frame(maxHeight: 160)
            .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Added (green) / removed (red) / kept (secondary) item rows for list fields.
    private func itemDiff(main: [String], value: [String]) -> some View {
        let mainSet = Set(main), valueSet = Set(value)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(value, id: \.self) { item in
                Text((mainSet.contains(item) ? "  " : "+ ") + item)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(mainSet.contains(item) ? .secondary : Color(red: 0.35, green: 0.9, blue: 0.45))
            }
            ForEach(main.filter { !valueSet.contains($0) }, id: \.self) { item in
                Text("- " + item)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.35))
            }
            if value.isEmpty && main.isEmpty { Text("—").font(.caption).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8).background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var requirementsEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(draft.requirements.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    TextField("Requirement", text: Binding(
                        get: { draft.requirements.indices.contains(i) ? draft.requirements[i] : "" },
                        set: { v in if draft.requirements.indices.contains(i) { draft.requirements[i] = v } }))
                        .textFieldStyle(.roundedBorder)
                    Button { if draft.requirements.indices.contains(i) { draft.requirements.remove(at: i) } } label: {
                        Image(systemName: "xmark").font(.system(size: 9))
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            Button { draft.requirements.append("") } label: {
                Label("Add requirement", systemImage: "plus").font(.caption)
            }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
        }
    }

    private var chipsEditor: some View {
        TextField("Add label and press return", text: $tagDraft).textFieldStyle(.roundedBorder)
            .onSubmit {
                let t = tagDraft.trimmingCharacters(in: .whitespaces); tagDraft = ""
                guard !t.isEmpty, !draft.tags.contains(t) else { return }
                draft.tags.append(t)
            }
    }

    // MARK: - Unchanged (collapsed)

    @ViewBuilder
    private var unchangedDisclosure: some View {
        if !unchanged.isEmpty {
            DisclosureGroup(isExpanded: $showUnchanged) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(unchanged, id: \.self) { f in
                        HStack(alignment: .top, spacing: 8) {
                            Text(fieldTitle(f)).font(.caption.bold()).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                            Text(unchangedValue(f)).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                            Spacer()
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("\(unchanged.count) unchanged field\(unchanged.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    private func unchangedValue(_ f: VersionField) -> String {
        switch f {
        case .name: return main.name
        case .topic: return main.topic.isEmpty ? "—" : main.topic
        case .description: return main.description.isEmpty ? "—" : main.description
        case .requirements: return main.requirements.isEmpty ? "—" : "\(main.requirements.count) item(s)"
        case .priority: return main.priority.label
        case .tags: return main.tags.isEmpty ? "—" : main.tags.joined(separator: ", ")
        case .dependsOn: return main.dependsOn.isEmpty ? "—" : "\(main.dependsOn.count) dep(s)"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.2)
            HStack {
                if editable {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Adopt this whole version").font(.caption.bold())
                        Text(promoteSubtitle).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button { onPromote() } label: {
                        Label(promoteLabel, systemImage: "arrow.up.circle.fill")
                    }.buttonStyle(.borderedProminent)
                } else {
                    Spacer()
                }
            }
        }
        .padding(.top, 6)
    }
}
