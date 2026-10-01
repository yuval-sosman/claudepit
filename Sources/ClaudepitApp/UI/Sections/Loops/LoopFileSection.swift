import SwiftUI
import AppKit
import ClaudepitCore

/// The overview's loop.md card: this project's and your loop.md — which one a bare `/loop` here
/// runs, its text (and where the CLI cuts it), and what you can do with it in place: write or edit
/// it, ask Claude about it and review a rewrite it suggests as a diff, start a loop on it, copy it
/// to the other scope, reveal it, or move it to the Trash. Plain data and closures, like the rest
/// of the page: every write goes through `LoopActions.saveLoopFile`, which refuses to overwrite a
/// file that changed since the edit began.
struct LoopFileSection: View {
    let project: LoopFile?
    let user: LoopFile?
    var hasProject = true
    var projectName: String?
    /// Working directory for Ask's `claude -p` calls — the active project.
    var cwd: URL?
    var actions = LoopActions()
    /// Open in this mode (the snapshot tool).
    var initialMode: Mode = .show

    enum Mode: Equatable { case show, edit, ask, review }

    @State private var picked: LoopFile.Scope?
    @State private var mode: Mode = .show
    @State private var draft = ""
    /// The text the edit (or Claude's rewrite) started from — nil when it writes a new file.
    @State private var base: String?
    @State private var rewrite: (text: String, diff: [PlanDiffLine])?
    @State private var problem: String?
    @State private var expanded = false

    private static let foldLines = 14

    /// What Ask tells Claude the content is — its label alone doesn't say.
    private static let about = "This loop.md is what a bare /loop (or /loop <interval> with no prompt) in Claude Code "
        + "runs at every iteration, in place of the built-in maintenance prompt. It is read fresh at each fire, "
        + "runs unattended, and is cut at 25,000 bytes. Good instructions say what to check, what to do about "
        + "it, what needs a person, and when to do nothing."

    private static let builtIn = "continue unfinished work, tend this branch's pull request (review comments, "
        + "failed CI, conflicts), then cleanup passes — it never starts new initiatives"

    // MARK: Scope

    private var scope: LoopFile.Scope {
        guard hasProject else { return .user }
        if let picked { return picked }
        return project != nil || user == nil ? .project : .user
    }

    private var file: LoopFile? { scope == .project ? project : user }
    private var otherScope: LoopFile.Scope { scope == .project ? .user : .project }
    private var other: LoopFile? { scope == .project ? user : project }
    /// A bare `/loop` here runs this one: the project's always wins.
    private var inUse: Bool { file != nil && (scope == .project || project == nil) }
    private var here: String { projectName.map { "in \($0)" } ?? "here" }

    private func name(_ s: LoopFile.Scope) -> String { s == .project ? "this project's loop.md" : "your loop.md" }

    // MARK: Body

    var body: some View {
        DetailSection(title: "loop.md", icon: "doc.text") {
            if inUse {
                Text("in use").font(.caption2.weight(.semibold)).foregroundStyle(.green)
                    .help("A bare /loop \(here) runs this file")
            }
            Spacer(minLength: 0)
            if hasProject { scopePicker }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                status
                switch mode {
                case .show:
                    if let file { toolbar(file); textView(file) } else { emptyState }
                case .edit:
                    editor
                case .ask:
                    if let file { askPanel(file) } else { emptyState }
                case .review:
                    reviewPanel
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: picked) { leave() }
        .onAppear(perform: applyInitialMode)
    }

    private var scopePicker: some View {
        Picker("", selection: Binding(get: { scope }, set: { picked = $0 })) {
            Text(project == nil ? "Project · none" : "Project").tag(LoopFile.Scope.project)
            Text(user == nil ? "User · none" : "User").tag(LoopFile.Scope.user)
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
        .disabled(mode != .show)
        .help("This project's .claude/loop.md, or yours in ~/.claude — the project's wins")
        .debugFrame("loopfile-scope")
    }

    /// One line on what this file does here, and its facts.
    private var status: some View {
        let text: String = {
            switch (scope, file != nil) {
            case (.project, true):
                return "A bare /loop (or /loop <interval> with no prompt) \(here) runs it at every iteration, read fresh each time."
            case (.user, true) where project != nil:
                return "Not used \(here): this project's own loop.md wins. Projects without one run this."
            case (.user, true):
                return "A bare /loop runs it in every project without its own loop.md\(hasProject ? " — this one included" : "")."
            case (.project, false):
                return "None — a bare /loop \(here) runs "
                    + (user != nil ? "your loop.md (User)." : "the built-in maintenance prompt: \(Self.builtIn).")
            case (.user, false):
                return "None — projects without their own loop.md run the built-in maintenance prompt: \(Self.builtIn)."
            }
        }()
        return VStack(alignment: .leading, spacing: 3) {
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let file {
                HStack(spacing: 10) {
                    HeaderFact(icon: "doc", text: ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file),
                               help: "\(file.size.formatted()) bytes — the CLI reads the first 25,000",
                               color: file.isTruncated ? .orange : .secondary)
                    if let modified = file.modifiedAt {
                        HeaderFact(icon: "clock", text: "edited " + LoopTime.ago(modified, now: Date()),
                                   help: modified.formatted(date: .complete, time: .shortened))
                    }
                    Text(file.url.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption.monospaced()).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(file.url.path(percentEncoded: false))
                }
            }
        }
    }

    // MARK: Show

    private func toolbar(_ file: LoopFile) -> some View {
        HStack(spacing: 6) {
            HeaderButton(title: "Edit", icon: "pencil",
                         help: file.isComplete ? "Edit it here — saved when you press Save (⌘S)"
                                               : "Over 1 MB — too large to edit here; open it in an editor") {
                beginEditing(file.text, base: file.text)
            }
            .disabled(!file.isComplete)
            .debugFrame("loopfile-edit")
            HeaderButton(title: "Ask", icon: "bubble.left.and.text.bubble.right",
                         help: "Ask Claude about it — and have it suggest a rewrite you review as a diff") {
                problem = nil
                mode = .ask
            }
            .debugFrame("loopfile-ask")
            if inUse {
                HeaderButton(title: "Start Loop", icon: "play",
                             help: "New Loop with no prompt — a bare /loop, which runs this file") {
                    var seed = LoopDraft()
                    seed.task = .defaultPrompt
                    actions.newLoop(seed)
                }
                .debugFrame("loopfile-start")
            }
            HeaderButton(title: "Delete", icon: "trash", help: "Move \(name(scope)) to the Trash") {
                actions.trashLoopFile(file)
            }
            .debugFrame("loopfile-delete")
            Spacer(minLength: 0)
            HeaderMenu {
                Button { actions.open(file.url) } label: { Label("Open in Editor", systemImage: "square.and.pencil") }
                Button { actions.reveal(file.url) } label: { Label("Reveal in Finder", systemImage: "folder") }
                Button { actions.copy(file.url.path(percentEncoded: false)) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
                Button { actions.copy(file.text) } label: { Label("Copy Text", systemImage: "doc.on.clipboard") }
                if hasProject {
                    Divider()
                    Button { copyToOther(file) } label: {
                        Label(otherScope == .user ? "Copy to Your loop.md" : "Copy to This Project", systemImage: "arrow.right.doc.on.clipboard")
                    }
                    .disabled(other != nil)
                }
            }
            .debugFrame("loopfile-more")
        }
    }

    private func textView(_ file: LoopFile) -> some View {
        let delivered = file.deliveredText
        let lines = delivered.split(separator: "\n", omittingEmptySubsequences: false)
        let folds = lines.count > Self.foldLines + 2
        return VStack(alignment: .leading, spacing: 6) {
            if delivered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Empty file.").font(.callout).foregroundStyle(.tertiary)
            } else {
                Text(folds && !expanded ? lines.prefix(Self.foldLines).joined(separator: "\n") : delivered)
                    .font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if file.isTruncated && (!folds || expanded) {
                HStack(spacing: 6) {
                    Image(systemName: "scissors").font(.caption2)
                    Text("The CLI stops reading here — \((file.size - file.deliveredText.utf8.count).formatted()) bytes past the limit")
                        .font(.caption2.weight(.semibold))
                    Rectangle().fill(.orange.opacity(0.4)).frame(height: 1)
                }
                .foregroundStyle(.orange)
                Text(file.cutText.prefix(800)).font(.callout.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !file.isComplete {
                Text("Over 1 MB — only the start is shown. Open it in an editor to change it.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if folds {
                Button(expanded ? "Show less" : "Show all \(lines.count) lines") { expanded.toggle() }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Write One…") { beginEditing(LoopFile.template + "\n", base: nil) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .help("Start from an example — nothing is written until you press Create")
                    .debugFrame("loopfile-write")
                if let other, other.isComplete {
                    Button("Start From \(otherScope == .user ? "Yours" : "the Project's")") {
                        beginEditing(other.text, base: nil)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Copy \(name(otherScope)) into the editor")
                }
            }
        }
    }

    // MARK: Edit

    /// The file moved on since the edit began: written by an agent or another editor, or removed.
    private var drifted: Bool { base == nil ? file != nil : file?.text != base }

    private var editor: some View {
        let bytes = draft.utf8.count
        return VStack(alignment: .leading, spacing: 8) {
            if drifted {
                LoopCallout(icon: "exclamationmark.triangle.fill", color: .orange,
                            title: file == nil ? "loop.md was removed while you edit" : "loop.md changed on disk while you edit",
                            text: "Saving now would overwrite what's there.") {
                    HStack(spacing: 6) {
                        Button("Reload — Discard Mine") { beginEditing(file?.text ?? "", base: file?.text) }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button("Overwrite") { save(draft, base: base, force: true) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            TextEditor(text: $draft)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 260)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12)))
                .debugFrame("loopfile-editor")
            HStack(spacing: 8) {
                Text("\(bytes.formatted()) / 25,000 bytes" + (bytes > LoopFile.byteLimit ? " — the CLI cuts the rest" : ""))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(bytes > LoopFile.byteLimit ? Color.orange : Color.secondary)
                Spacer(minLength: 0)
                Button("Cancel") { leave() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                    .debugFrame("loopfile-cancel")
                Button(base == nil ? "Create" : "Save") { save(draft, base: base) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(base != nil && draft == base && !drifted)
                    .debugFrame("loopfile-save")
            }
            Text("Write it as if typed after /loop: what to check, what to do about it, what needs you, and when to do nothing. "
                 + "Each fire reads it fresh, so a saved edit applies from the next iteration.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Ask

    private func askPanel(_ file: LoopFile) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            PlanQAPanel(planContent: file.text, cwd: cwd, title: "Ask about \(name(scope))", planPath: file.url,
                        contentLabel: "loop.md",
                        onPlanImproved: { improved, _ in
                            rewrite = (improved, planDiffLines(from: file.text, to: improved))
                            base = file.text
                            mode = .review
                        },
                        growsWithContent: true, focusOnAppear: true, about: Self.about, suggestsRewrites: true,
                        rewriteSubject: "loop.md — the instructions a bare /loop runs at every iteration")
                .frame(maxHeight: 380)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            Button("Done") { leave() }.controlSize(.small).debugFrame("loopfile-ask-done")
        }
    }

    @ViewBuilder private var reviewPanel: some View {
        if let rewrite {
            VStack(alignment: .leading, spacing: 8) {
                Text("Claude's rewrite — nothing is saved until you do.").font(.callout.weight(.semibold))
                PlanDiffView(lines: rewrite.diff)
                    .frame(height: 260)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Discard") { leave() }.controlSize(.small)
                    Button("Edit Before Saving") { beginEditing(rewrite.text, base: base) }.controlSize(.small)
                    Button("Save Rewrite") { save(rewrite.text, base: base) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        }
    }

    // MARK: Doing

    private func beginEditing(_ text: String, base: String?) {
        draft = text
        self.base = base
        problem = nil
        mode = .edit
    }

    private func leave() {
        mode = .show
        rewrite = nil
        problem = nil
        expanded = false
    }

    private func save(_ text: String, base: String?, force: Bool = false) {
        do {
            try actions.saveLoopFile(scope, text, base, force)
            leave()
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func copyToOther(_ file: LoopFile) {
        do {
            try actions.saveLoopFile(otherScope, file.text, nil, false)
            picked = otherScope
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Couldn't copy: \(error.localizedDescription)"
        }
    }

    private func applyInitialMode() {
        switch initialMode {
        case .show: break
        case .edit: beginEditing(file?.text ?? LoopFile.template + "\n", base: file?.text)
        case .ask: if file != nil { mode = .ask }
        case .review:
            guard let file else { return }
            let improved = file.text + "\nIf nothing changed since the last iteration, reply \"quiet\" and stop.\n"
            rewrite = (improved, planDiffLines(from: file.text, to: improved))
            base = file.text
            mode = .review
        }
    }
}
