import SwiftUI
import ClaudepitCore

/// One plan or spec, read like a document: its title and facts, Ask (questions about it, and
/// Claude's suggested rewrites, shown as a diff to accept or dismiss), and the text itself in a
/// readable column. Plain data and closures, never `AppState`, so it renders offscreen.
struct DocumentDetailView: View {
    let kind: DocumentKind
    let doc: MarkdownDoc
    /// Working directory for the Ask panel's `claude -p` calls — the active project.
    let cwd: URL?
    var now: Date = Date()
    /// Set when a task's page linked here: offers the way back.
    var backToTask: (() -> Void)? = nil
    /// Open the task this document belongs to (a spec's). nil: no Task button.
    var openTask: (() -> Void)? = nil
    /// nil: no Move to Trash (a spec belongs to its task).
    var onTrash: (() -> Void)? = nil
    /// The file was rewritten on disk (an accepted improvement).
    var onChanged: () -> Void = {}
    /// Open Claude in a new herdr pane with this document attached and the prompt typed, not sent;
    /// reports whether it opened. nil: herdr isn't installed.
    var brainstorm: ((@escaping @MainActor (Bool) -> Void) -> Void)? = nil
    /// Open the Ask panel as the view appears (the snapshot tool).
    var initiallyAsking = false

    @State private var showQA = false
    /// Claude's rewrite awaiting review, and its diff — computed once, not on every render.
    @State private var pending: (text: String, diff: [PlanDiffLine])?
    @State private var writeError: String?
    @State private var brainstormState = BrainstormState.idle

    private enum BrainstormState { case idle, opening, failed }

    /// Wide enough for a table, narrow enough to read a paragraph without losing the line.
    static let readingWidth: CGFloat = 860

    var body: some View {
        GeometryReader { geo in
            GlassCard {
                VStack(spacing: 0) {
                    header
                    if let pending { reviewBanner(pending.diff) }
                    Divider().opacity(0.15)

                    if showQA && pending == nil {
                        PlanQAPanel(planContent: doc.text, cwd: cwd, title: "Ask about this \(kind.noun)",
                                    planPath: doc.url, contentLabel: kind.noun,
                                    onPlanImproved: { newContent, _ in
                                        pending = (newContent, planDiffLines(from: doc.text, to: newContent))
                                        writeError = nil
                                        showQA = false
                                    },
                                    focusOnAppear: true)
                        .frame(height: geo.size.height * 0.4)
                        Divider().opacity(0.15)
                    }

                    if let pending {
                        PlanDiffView(lines: pending.diff)
                    } else {
                        ScrollView {
                            MarkdownText(doc.text)
                                .frame(maxWidth: Self.readingWidth, alignment: .topLeading)
                                .padding(.horizontal, 24).padding(.vertical, 18)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .onAppear { if initiallyAsking { showQA = true } }
        .onChange(of: doc.id) {
            showQA = false
            pending = nil
            writeError = nil
            brainstormState = .idle
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let backToTask {
                Button(action: backToTask) {
                    Label("Back to task", systemImage: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(doc.title).font(.headline).lineLimit(1).truncationMode(.tail)
                    .help(doc.title)
                Spacer(minLength: 8)
                actions
            }
            FlowLayout(spacing: 10) {
                HeaderFact(icon: "doc.text", text: kind.fileLabel(doc), help: doc.url.path)
                HeaderFact(icon: "clock", text: modifiedLabel,
                           help: "Last changed " + doc.modifiedAt.formatted(date: .complete, time: .shortened))
                HeaderFact(icon: "text.alignleft", text: "\(doc.words.formatted()) words",
                           help: "About \(max(1, doc.words / 230)) min to read")
                if brainstormState == .failed {
                    HeaderFact(icon: "exclamationmark.triangle", text: "Claude didn't start in herdr",
                               help: "herdr opened no session — is it running? Try again in a moment.", color: .red)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
    }

    private var modifiedLabel: String {
        let day = SessionTimeLabel.text(for: doc.modifiedAt, now: now, inDateSection: false)
        return Calendar.current.isDate(doc.modifiedAt, inSameDayAs: now) && day != "now" ? "Today, \(day)" : day
    }

    private var actions: some View {
        HStack(spacing: 6) {
            HeaderButton(title: "Ask", icon: "bubble.left.and.text.bubble.right",
                         help: showQA ? "Close the questions panel"
                                      : "Ask Claude about this \(kind.noun) — and have it suggest a rewrite you can review",
                         isOn: showQA) {
                showQA.toggle()
            }
            .disabled(pending != nil)
            HeaderButton(title: brainstormState == .opening ? "Opening…" : "Brainstorm", icon: "terminal",
                         help: brainstorm == nil
                             ? "herdr isn't installed — it's needed to open the session"
                             : "Open Claude in a new herdr pane with this \(kind.noun) attached and the prompt "
                               + "typed for you — add your ask and press Return. Nothing is sent before that.") {
                guard let brainstorm else { return }
                brainstormState = .opening
                brainstorm { ok in brainstormState = ok ? .idle : .failed }
            }
            .disabled(brainstorm == nil || brainstormState == .opening)
            if let openTask {
                HeaderButton(title: "Task", icon: "checklist", help: "Open the task this \(kind.noun) belongs to",
                             action: openTask)
            }
            HeaderButton(title: "Open", icon: Icon.openFile, help: "Open in your default editor") {
                NSWorkspace.shared.open(doc.url)
            }
            HeaderMenu {
                Button { NSWorkspace.shared.activateFileViewerSelecting([doc.url]) } label: {
                    Label("Reveal in Finder", systemImage: Icon.revealInFinder)
                }
                Button { copy(doc.url.path) } label: { Label("Copy Path", systemImage: Icon.copyPath) }
                Button { copy(doc.text) } label: { Label("Copy as Markdown", systemImage: "doc.richtext") }
                if let onTrash {
                    Divider()
                    Button(role: .destructive, action: onTrash) { Label("Move to Trash", systemImage: Icon.delete) }
                }
            }
        }
    }

    // MARK: Suggested rewrite

    private func reviewBanner(_ diff: [PlanDiffLine]) -> some View {
        let added = diff.filter { if case .added = $0 { return true } else { return false } }.count
        let removed = diff.filter { if case .removed = $0 { return true } else { return false } }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars").foregroundStyle(Color.accentColor)
                Text("Suggested rewrite").font(.callout.weight(.semibold))
                Text("+\(added)").foregroundStyle(.green)
                    + Text("  −\(removed)").foregroundStyle(.red)
                Spacer()
                Button("Dismiss") { pending = nil; writeError = nil }
                    .controlSize(.small)
                Button("Accept") { accept() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Overwrite \(kind.fileLabel(doc)) with the rewrite")
            }
            .font(.system(size: 11).monospacedDigit())
            if let writeError {
                Text(writeError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    private func accept() {
        guard let improved = pending?.text else { return }
        do {
            try improved.write(to: doc.url, atomically: true, encoding: .utf8)
            pending = nil
            writeError = nil
            onChanged()
        } catch {
            writeError = "Couldn't save the \(kind.noun): \(error.localizedDescription)"
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
