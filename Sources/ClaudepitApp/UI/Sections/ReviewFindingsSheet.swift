import SwiftUI
import ClaudepitCore
import AppKit

/// Severity colour, shared by the sheet and the panel banner.
func findingSeverityColor(_ f: ReviewFinding) -> Color {
    switch f.severityRank {
    case 0: return .red
    case 1: return .orange
    default: return .secondary
    }
}

/// Triage view for a code review's findings.
///
/// Replaces the per-row buttons that used to live in the task detail panel: ten findings in a
/// 250pt column truncated to a few words each, one expandable at a time, each with its own Create
/// button. Here the full text is readable, several findings can be ticked off at once, and they
/// become ONE task — which is how review findings actually arrive.
///
/// **One page, not master/detail.** A split view put a one-sentence finding in a half-width pane
/// and left most of the sheet empty, and still cost a click per finding to read. This is a single
/// scrolling stack of cards — severity, title and full detail in place — which is how the
/// brainstorm suggestions read, and how a review is actually skimmed.
struct ReviewFindingsSheet: View {
    let task: ProjectTask
    @ObservedObject var app: AppState
    /// Hand the draft back to the caller to edit instead of saving it. The caller dismisses.
    var onCreateAndEdit: (ProjectTask, [ReviewFinding]) -> Void
    var onClose: () -> Void

    @State private var selected: Set<String> = []
    @State private var showCreated = false

    private var all: [ReviewFinding] { FindingTaskDraft.sorted(task.links.reviewFindings) }
    private var createdCount: Int { all.filter { $0.spawnedTaskID != nil }.count }
    /// Rows on offer. Already-triaged findings are hidden by default — they are the ones you are
    /// done with — but stay one toggle away rather than disappearing.
    private var visible: [ReviewFinding] { showCreated ? all : all.filter { $0.spawnedTaskID == nil } }
    private var picked: [ReviewFinding] { all.filter { selected.contains($0.id) } }

    private var groups: [(label: String, items: [ReviewFinding])] {
        [("HIGH", 0), ("MED", 1), ("LOW", 2)].compactMap { label, rank in
            let items = visible.filter { $0.severityRank == rank }
            return items.isEmpty ? nil : (label, items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            findingsList
            Divider().opacity(0.2)
            bottomBar
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "checklist").font(.system(size: 15)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Code review findings").font(.headline)
                Text(summaryLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if createdCount > 0 {
                Toggle("Show triaged (\(createdCount))", isOn: $showCreated)
                    .toggleStyle(.checkbox).font(.caption).foregroundStyle(.secondary)
            }
            if let p = task.links.reviewPath, FileManager.default.fileExists(atPath: p) {
                Button("Open review.md") { NSWorkspace.shared.open(URL(filePath: p)) }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    /// "10 findings · 1 med · 9 low · 1 triaged" — zero buckets omitted, "1 finding" singular.
    private var summaryLine: String {
        let n = all.count
        var parts = ["\(n) finding\(n == 1 ? "" : "s")"]
        for (label, rank) in [("high", 0), ("med", 1), ("low", 2)] {
            let c = all.filter { $0.severityRank == rank }.count
            if c > 0 { parts.append("\(c) \(label)") }
        }
        if createdCount > 0 { parts.append("\(createdCount) triaged") }
        return parts.joined(separator: " · ")
    }

    // MARK: - The list
    //
    // One page, every finding readable in place. A master/detail split put a one-sentence detail
    // in a half-width pane and left most of the sheet empty; these read like the brainstorm
    // suggestions — a stack of cards you skim top to bottom and tick off as you go.

    private var findingsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(groups, id: \.label) { g in
                    groupHeader(g.label, items: g.items)
                    ForEach(g.items) { card($0) }
                }
                if visible.isEmpty {
                    Text(all.isEmpty ? "No findings recorded." : "Every finding has a task.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func groupHeader(_ title: String, items: [ReviewFinding]) -> some View {
        let ids = Set(items.map(\.id))
        let allOn = !ids.isEmpty && ids.isSubset(of: selected)
        return HStack(spacing: 6) {
            Text(title).font(.caption2).fontWeight(.bold).foregroundStyle(.secondary).tracking(0.6)
            Text("\(items.count)").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button(allOn ? "None" : "Select all") {
                if allOn { selected.subtract(ids) } else { selected.formUnion(ids) }
            }
            .font(.caption2).foregroundStyle(.secondary).buttonStyle(.plain)
        }
        .padding(.top, 4)
    }

    /// One finding, whole: severity, category, location, and the What / Why / Fix the review wrote.
    /// Clicking anywhere selects it.
    private func card(_ f: ReviewFinding) -> some View {
        let isOn = selected.contains(f.id)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .font(.system(size: 14))
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 8) {
                cardHeader(f)
                if !(f.locations ?? []).isEmpty { locationRow(f) }
                if f.isStructured {
                    if let w = f.what { fieldBlock("WHAT", w) }
                    if let w = f.why { fieldBlock("WHY IT MATTERS", w) }
                    if let w = f.fix { fieldBlock("FIX", w, accent: true) }
                } else if !f.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Legacy finding: one blob, no sections to lay out.
                    MarkdownText(f.detail).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isOn ? Color.accentColor.opacity(0.10) : .white.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isOn ? Color.accentColor.opacity(0.45) : .white.opacity(0.08), lineWidth: 1))
        .opacity(f.spawnedTaskID == nil ? 1 : 0.65)
        .contentShape(Rectangle())
        .onTapGesture { toggle(f) }
    }

    private func cardHeader(_ f: ReviewFinding) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(f.severityLabel).font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(findingSeverityColor(f).opacity(0.25), in: Capsule())
                .foregroundStyle(findingSeverityColor(f))
            if let c = f.category {
                Text(c.uppercased()).font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.white.opacity(0.08), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            // No line limit: reading the finding without clicking is the point.
            Text(f.title).font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let r = f.ruleID {
                Text(r).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .help("This finding's label in review.md")
            }
            if let tid = f.spawnedTaskID {
                Button { app.focusTaskID = tid; app.selected = .tasks; onClose() } label: {
                    Label("Task", systemImage: "arrow.turn.down.right").font(.caption2)
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .help("A task already covers this finding")
            }
        }
    }

    /// file:line chips. Clicking opens the file in the worktree when it resolves there.
    private func locationRow(_ f: ReviewFinding) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(f.locations ?? []) { loc in
                Button { open(loc) } label: {
                    Text(loc.display).font(.caption2.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(resolve(loc) == nil ? "Not found in the worktree" : "Open \(loc.file)")
            }
        }
    }

    /// A labelled section — the layout the whole redesign is for: What / Why / Fix as three
    /// scannable blocks rather than one run-on sentence.
    private func fieldBlock(_ label: String, _ text: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, weight: .bold)).tracking(0.6)
                .foregroundStyle(accent ? Color.accentColor.opacity(0.9) : Color.secondary.opacity(0.7))
            MarkdownText(text).font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Locations are repo-relative; resolve against the reviewed task's worktree, else the project.
    private func resolve(_ loc: FindingLocation) -> URL? {
        let roots = [task.worktree?.path, app.activePath?.path].compactMap { $0 }
        for r in roots {
            let u = URL(filePath: r).appending(path: loc.file)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    private func open(_ loc: FindingLocation) {
        guard let u = resolve(loc) else { return }
        NSWorkspace.shared.open(u)
    }

    private func toggle(_ f: ReviewFinding) {
        if selected.contains(f.id) { selected.remove(f.id) } else { selected.insert(f.id) }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text(selected.isEmpty ? "Select the findings to fix"
                                  : "\(selected.count) of \(visible.count) selected")
                .font(.callout).foregroundStyle(.secondary)
            if selected.count > 1 {
                Text("→ one task").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Close") { onClose() }.controlSize(.large)
            Menu {
                // Two Texts in a menu button render as title + subtitle on macOS. The two options
                // differ in ways nobody can guess from their names — say what they do.
                Button { create(fixNow: true) } label: {
                    Text("Create fix task")
                    Text("Implement → Review, in this task's worktree\(resumeNote). No dependency — runs now.")
                }
                .disabled(!fixAvailable)
                Button { create(fixNow: false) } label: {
                    Text("Create full task")
                    Text("Spec → Plan → Implement → Review, in a fresh worktree. Waits for this task to be done.")
                }
                Divider()
                Button("Create and edit…") {
                    onCreateAndEdit(app.followUpDraft(parent: task, findings: picked, fixNow: fixAvailable),
                                    picked)
                }
            } label: {
                Text(fixAvailable ? "Create fix task" : "Create full task")
            } primaryAction: {
                create(fixNow: fixAvailable)
            }
            .menuStyle(.button).buttonStyle(.borderedProminent).controlSize(.large)
            .fixedSize()
            .disabled(selected.isEmpty)
            .help(createHelp)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    /// A fix task needs its command installed. With `/claudepit-task-fix` switched off in App
    /// Settings the task would launch and fail with nothing but "Phase failed", so the primary
    /// action becomes the full pipeline instead.
    private var fixAvailable: Bool { app.fixCommandEnabled }

    /// Spelled out in the menu, because "continues the session" is only true when one was captured.
    private var resumeNote: String {
        task.links.sessionIDs.isEmpty ? "" : ", continuing its implementation session"
    }

    private var createHelp: String {
        if selected.isEmpty { return "Select one or more findings" }
        if !fixAvailable { return "The /claudepit-task-fix command is switched off in App Settings" }
        if task.worktree == nil { return "Fixes run in a fresh worktree — this task has none to inherit" }
        if task.links.sessionIDs.isEmpty {
            return "Runs in this task's worktree. No implement session was captured, so it starts a fresh one."
        }
        return "Implement → Review, in this task's worktree, continuing its implementation session"
    }

    private func create(fixNow: Bool) {
        guard !picked.isEmpty else { return }
        app.createTaskFromFindings(parent: task, findings: picked, fixNow: fixNow)
        onClose()
    }
}
