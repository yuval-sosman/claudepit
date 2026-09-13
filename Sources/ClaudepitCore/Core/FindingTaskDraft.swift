import Foundation

/// Builds the task draft for a set of review findings.
///
/// Both creation paths go through here — the sheet's one-click "Create fix task" and the
/// pre-filled New Task form — so the task you get after editing the form is the same task you
/// would have got without opening it. Pure: no filesystem, no dates, no actor.
public enum FindingTaskDraft {

    /// Severity → priority, matching the review command's vocabulary (high = Critical,
    /// med = Important, low = Minor). Anything unrecognised is `.low`, never higher.
    public static func priority(for severity: String) -> Priority {
        switch ReviewFinding(id: "", title: "", detail: "", severity: severity).severityRank {
        case 0: return .high
        case 1: return .normal
        default: return .low
        }
    }

    /// The highest priority among the findings (`.low` for an empty set).
    public static func priority(for findings: [ReviewFinding]) -> Priority {
        findings.map { priority(for: $0.severity) }.max { $0.rank < $1.rank } ?? .low
    }

    /// Findings in the order they should be read and listed: severity first, original order within.
    public static func sorted(_ findings: [ReviewFinding]) -> [ReviewFinding] {
        findings.enumerated()
            .sorted { ($0.element.severityRank, $0.offset) < ($1.element.severityRank, $1.offset) }
            .map(\.element)
    }

    /// Task summary. A single finding keeps its own title — renaming it would break the reader's
    /// link back to the review; several become one named batch.
    public static func name(for findings: [ReviewFinding], parentName: String) -> String {
        let items = sorted(findings)
        if items.count == 1 { return items[0].title }
        let parent = parentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = parent.isEmpty ? "" : " from \"\(parent)\""
        return "Fix \(items.count) review findings\(suffix)"
    }

    /// Markdown body: one bullet per finding carrying its severity, title and full detail. The
    /// detail is indented under its bullet so the list still renders as a list.
    public static func description(for findings: [ReviewFinding], parentName: String) -> String {
        let parent = parentName.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [String] = []
        out.append(parent.isEmpty
                   ? "From a code review:"
                   : "From the code review of \"\(parent)\":")
        out.append("")
        for f in sorted(findings) {
            out.append("- **[\(f.severityLabel)]** \(f.title)")
            // Indent every line, blank ones included, so a multi-paragraph body stays inside its
            // bullet instead of closing the list.
            func indented(_ text: String) {
                for line in text.components(separatedBy: "\n") { out.append(line.isEmpty ? "" : "  \(line)") }
            }
            if !(f.locations ?? []).isEmpty {
                out.append("  _\((f.locations ?? []).map(\.display).joined(separator: ", "))_")
            }
            if f.isStructured {
                // Keep the three questions apart — the fix agent acts on `Fix`, and folding it into
                // one paragraph is exactly what made the old findings unusable as a brief.
                if let w = f.what { out.append(""); indented("**What.** " + w) }
                if let w = f.why  { out.append(""); indented("**Why it matters.** " + w) }
                if let w = f.fix  { out.append(""); indented("**Fix.** " + w) }
            } else {
                let detail = f.detail.trimmingCharacters(in: .whitespacesAndNewlines)
                if !detail.isEmpty { indented(detail) }
            }
            out.append("")
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One requirement per finding — the acceptance list the fix agent works through. The first
    /// location rides along so each line is actionable on its own, without cross-referencing the
    /// description.
    public static func requirements(for findings: [ReviewFinding]) -> [String] {
        sorted(findings).map { f in
            let site = f.locations?.first.map { " (\($0.display))" } ?? ""
            return "[\(f.severityLabel)] \(f.title)\(site)"
        }
    }

    /// The whole draft as the `TaskVersion` the New Task form prefills from.
    ///
    /// `fixNow` decides the dependency: a continuation carries none (a `dependsOn` edge gates on
    /// the parent reaching `.done`, which never happens while it sits in Review), a successor
    /// depends on the parent as any follow-on task would.
    public static func version(for findings: [ReviewFinding],
                               parent: ProjectTask, fixNow: Bool) -> TaskVersion {
        TaskVersion(id: "findings", label: "From findings", createdAt: parent.updatedAt,
                    name: name(for: findings, parentName: parent.name),
                    topic: parent.topic ?? "",
                    description: description(for: findings, parentName: parent.name),
                    requirements: requirements(for: findings),
                    priority: priority(for: findings),
                    tags: parent.tags,
                    dependsOn: fixNow ? [] : [parent.id])
    }

    /// The whole task a set of findings produces — the one place its shape is decided.
    ///
    /// Pure: `now` and `id` are injected rather than read, so the shape can be asserted in full.
    /// `phase` stays nil on purpose — Home's pipeline counts the ends by status and the middle by
    /// phase, so a task carrying both is counted twice in the strip, and `TaskRunner.runPhase`
    /// falls back to `plannedPhases.first` anyway.
    public static func task(for findings: [ReviewFinding], parent: ProjectTask,
                            fixNow: Bool, now: TimeInterval,
                            id: String = String(UUID().uuidString.prefix(8).lowercased())) -> ProjectTask {
        let v = version(for: findings, parent: parent, fixNow: fixNow)
        var t = ProjectTask(id: id)
        t.name = v.name
        t.topic = v.topic.isEmpty ? nil : v.topic
        t.description = v.description
        t.requirements = v.requirements
        t.priority = v.priority
        t.tags = v.tags
        t.dependsOn = v.dependsOn
        t.plannedPhases = plannedPhases(fixNow: fixNow)
        t.status = .backlog
        t.phase = nil
        t.createdAt = now
        t.updatedAt = now
        guard fixNow else { return t }
        // Share the parent's checkout: the implementation under review is UNCOMMITTED there, so a
        // fresh worktree off trunk would not contain the code the findings point at. Pane and tab
        // are deliberately not inherited — every phase opens its own.
        t.worktree = parent.worktree.map { TaskWorktree(branch: $0.branch, path: $0.path) }
        t.followUp = TaskFollowUp(parentTaskID: parent.id,
                                  findingIDs: findings.map(\.id),
                                  resumeSessionID: parent.links.sessionIDs.last,
                                  parentReviewPath: parent.links.reviewPath,
                                  parentSpecPath: parent.links.specPath,
                                  parentPlanPath: parent.links.planPath)
        return t
    }

    /// The phases a task built from findings plans. A fix task skips brainstorm/spec/plan — the
    /// findings are already the spec — but keeps a review pass so the fix is checked like any
    /// other change.
    public static func plannedPhases(fixNow: Bool) -> [TaskPhase] {
        fixNow ? [.implement, .codeReview] : ProjectTask.defaultPhases
    }
}
