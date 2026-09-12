import Foundation

public enum TaskPhase: String, Codable, CaseIterable, Sendable {
    case brainstorm, writeSpec, createPlan, implement, codeReview

    public var producesArtifact: Bool {
        switch self {
        case .brainstorm, .writeSpec, .createPlan, .codeReview: return true
        case .implement: return false   // session capture instead
        }
    }
    public var title: String {
        switch self {
        case .brainstorm:  return "Brainstorm"
        case .writeSpec:   return "Write Spec"
        case .createPlan:  return "Create Plan"
        case .implement:   return "Implement"
        case .codeReview:  return "Code Review"
        }
    }
    public var shortTitle: String {
        switch self {
        case .brainstorm:  return "Brainstorm"
        case .writeSpec:   return "Spec"
        case .createPlan:  return "Plan"
        case .implement:   return "Impl"
        case .codeReview:  return "Review"
        }
    }
    /// Slash-command name (the `claudepit-task-<x>.md` file). NOT `rawValue` — the files were
    /// named spec/plan/review, not writeSpec/createPlan/codeReview. Keep both sides in sync here.
    public var commandName: String {
        switch self {
        case .brainstorm:  return "brainstorm"
        case .writeSpec:   return "spec"
        case .createPlan:  return "plan"
        case .implement:   return "implement"
        case .codeReview:  return "review"
        }
    }
    public var systemImage: String {
        switch self {
        case .brainstorm:  return "lightbulb"
        case .writeSpec:   return "doc.text"
        case .createPlan:  return "list.bullet.rectangle"
        case .implement:   return "hammer"
        case .codeReview:  return "magnifyingglass"
        }
    }
}

public enum TaskStatus: String, Codable, Sendable {
    case backlog, running, awaitingReview, blocked, failed, done

    public var label: String {
        switch self {
        case .backlog:        return "backlog"
        case .running:        return "running"
        case .awaitingReview: return "awaiting review"
        case .blocked:        return "blocked"
        case .failed:         return "failed"
        case .done:           return "done"
        }
    }
}

public enum Priority: String, Codable, Sendable, CaseIterable {
    case low, normal, high, urgent

    public var label: String {
        switch self {
        case .low: return "Low"; case .normal: return "Normal"
        case .high: return "High"; case .urgent: return "Urgent"
        }
    }
    /// Sort weight (urgent highest).
    public var rank: Int {
        switch self { case .low: return 0; case .normal: return 1; case .high: return 2; case .urgent: return 3 }
    }
}

public struct TaskWorktree: Codable, Sendable, Equatable {
    public var branch: String
    public var path: String
    public var paneID: String?
    public var tabID: String?
    public init(branch: String, path: String, paneID: String? = nil, tabID: String? = nil) {
        self.branch = branch; self.path = path; self.paneID = paneID; self.tabID = tabID
    }
}

public struct ReviewFinding: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var severity: String    // "high" | "med" | "low"
    public var spawnedTaskID: String?
    public init(id: String, title: String, detail: String, severity: String, spawnedTaskID: String? = nil) {
        self.id = id; self.title = title; self.detail = detail
        self.severity = severity; self.spawnedTaskID = spawnedTaskID
    }
}

/// A structured refinement proposed by the brainstorm phase. Each one either tightens a requirement,
/// rewrites the description, or adds a tag — the user accepts/rejects them one-by-one (VS-Code-style).
public struct BrainstormSuggestion: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case requirement, description, tag }
    public var id: String            // deterministic (fnv1aHex of kind+"|"+value)
    public var kind: Kind
    public var value: String         // the requirement text / new description / tag
    public var rationale: String     // why (shown as detail)
    public var accepted: Bool?       // nil = pending, true = accepted, false = dismissed
    public init(id: String, kind: Kind, value: String, rationale: String, accepted: Bool? = nil) {
        self.id = id; self.kind = kind; self.value = value
        self.rationale = rationale; self.accepted = accepted
    }
}

public struct TaskLinks: Codable, Sendable, Equatable {
    public var brainstormPath: String?
    public var brainstormSuggestions: [BrainstormSuggestion]
    public var specPath: String?
    public var planPath: String?
    public var reviewPath: String?
    public var sessionIDs: [String]
    public var reviewFindings: [ReviewFinding]
    public init(brainstormPath: String? = nil, brainstormSuggestions: [BrainstormSuggestion] = [],
                specPath: String? = nil, planPath: String? = nil,
                reviewPath: String? = nil, sessionIDs: [String] = [],
                reviewFindings: [ReviewFinding] = []) {
        self.brainstormPath = brainstormPath; self.brainstormSuggestions = brainstormSuggestions
        self.specPath = specPath; self.planPath = planPath
        self.reviewPath = reviewPath; self.sessionIDs = sessionIDs
        self.reviewFindings = reviewFindings
    }
}

/// One of a task's editable request fields — used by the versions-compare UI for per-field Accept.
public enum VersionField: Sendable, Hashable { case name, topic, description, requirements, priority, tags, dependsOn }

/// A full alternate copy of a task's editable request fields. The live "main" version is the
/// task's own top-level fields; these are extra proposals compared against it (only while backlog).
public struct TaskVersion: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var createdAt: TimeInterval
    public var name: String
    public var topic: String
    public var description: String
    public var requirements: [String]
    public var priority: Priority
    public var tags: [String]
    public var dependsOn: [String]
    public init(id: String = String(UUID().uuidString.prefix(8).lowercased()),
                label: String = "", createdAt: TimeInterval = 0,
                name: String = "", topic: String = "", description: String = "",
                requirements: [String] = [], priority: Priority = .normal,
                tags: [String] = [], dependsOn: [String] = []) {
        self.id = id; self.label = label; self.createdAt = createdAt
        self.name = name; self.topic = topic; self.description = description
        self.requirements = requirements; self.priority = priority
        self.tags = tags; self.dependsOn = dependsOn
    }

    /// Fields that differ from a baseline version (canonically ordered). Drives the "N changed"
    /// badge and lets the compare UI surface only what actually differs.
    public func changedFields(vs base: TaskVersion) -> [VersionField] {
        var out: [VersionField] = []
        if name != base.name { out.append(.name) }
        if topic != base.topic { out.append(.topic) }
        if description != base.description { out.append(.description) }
        if requirements != base.requirements { out.append(.requirements) }
        if priority != base.priority { out.append(.priority) }
        if tags != base.tags { out.append(.tags) }
        if dependsOn != base.dependsOn { out.append(.dependsOn) }
        return out
    }
}

public struct ProjectTask: Codable, Identifiable, Sendable, Equatable {
    public var version: Int
    public var id: String
    public var name: String
    public var topic: String?                 // free-text topic ("" / nil = none). Optional for Codable back-compat.
    public var description: String            // markdown, may embed attachments/*.png
    public var phase: TaskPhase?              // nil = not started (Backlog) or done
    public var status: TaskStatus
    public var priority: Priority
    public var tags: [String]
    public var dependsOn: [String]            // task ids this task waits on
    public var plannedPhases: [TaskPhase]
    public var requirements: [String]
    public var suggestions: [TaskVersion]?    // alternate proposals vs main. Optional for Codable back-compat.
    public var worktree: TaskWorktree?
    public var createdAt: TimeInterval
    public var updatedAt: TimeInterval
    public var links: TaskLinks

    public static let defaultPhases: [TaskPhase] = [.writeSpec, .createPlan, .implement, .codeReview]

    public init(version: Int = 2,
                id: String = String(UUID().uuidString.prefix(8).lowercased()),
                name: String = "", topic: String? = nil, description: String = "",
                phase: TaskPhase? = nil, status: TaskStatus = .backlog,
                priority: Priority = .normal, tags: [String] = [], dependsOn: [String] = [],
                plannedPhases: [TaskPhase] = ProjectTask.defaultPhases,
                requirements: [String] = [], suggestions: [TaskVersion]? = nil,
                worktree: TaskWorktree? = nil,
                createdAt: TimeInterval = 0, updatedAt: TimeInterval = 0,
                links: TaskLinks = TaskLinks()) {
        self.version = version; self.id = id; self.name = name; self.topic = topic
        self.description = description
        self.phase = phase; self.status = status; self.priority = priority
        self.tags = tags; self.dependsOn = dependsOn; self.plannedPhases = plannedPhases
        self.requirements = requirements; self.suggestions = suggestions; self.worktree = worktree
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.links = links
    }

    public static var empty: ProjectTask { ProjectTask() }

    // MARK: - Versions

    public var hasSuggestions: Bool { !(suggestions ?? []).isEmpty }

    /// The live main version projected from the top-level fields (no stored duplication).
    public var mainVersion: TaskVersion {
        TaskVersion(id: "main", label: "Main", createdAt: createdAt,
                    name: name, topic: topic ?? "", description: description,
                    requirements: requirements, priority: priority, tags: tags, dependsOn: dependsOn)
    }

    /// A proposal version = main with every *pending* brainstorm suggestion applied on top. Lets the
    /// brainstorm phase reuse the versions-compare UI without creating a stored suggestion version.
    /// (requirement → append if new, description → replace, tag → append if new.)
    public var brainstormProposal: TaskVersion {
        var v = mainVersion
        v.id = "brainstorm"; v.label = "Brainstorm"
        for s in links.brainstormSuggestions where s.accepted == nil {
            switch s.kind {
            case .requirement: if !v.requirements.contains(s.value) { v.requirements.append(s.value) }
            case .description: v.description = s.value
            case .tag:         if !v.tags.contains(s.value) { v.tags.append(s.value) }
            }
        }
        return v
    }

    /// Whether the current phase still has something waiting on the USER.
    /// Only meaningful while `status == .awaitingReview` — that status means "the agent stopped",
    /// which is not the same as "you still owe it something".
    ///
    /// The test is **"does it still need you"**, not "have you looked at it yet". A phase that
    /// produced its deliverable is finished: the card reads Phase done and Next is the obvious move.
    /// It must not keep claiming to be Waiting merely because the spec/plan/review hasn't been
    /// opened — that made Waiting mean everything, and so nothing.
    ///
    /// Two things genuinely still want you: brainstorm suggestions left undecided (the one phase
    /// with an in-app accept/dismiss flow), and a phase parked here without its deliverable.
    /// A non-nil link is the artifact test — every writer of these paths (`TaskRunner.routeArtifact`,
    /// `TaskTransition.healArtifactLinks`) sets one only for a file that exists, which keeps this
    /// property pure enough to call from a SwiftUI view body.
    public var phaseNeedsReview: Bool {
        switch phase {
        case .none: return false
        case .brainstorm:
            // Zero parsed suggestions counts as outstanding: the deliverable landed in a shape we
            // couldn't read, and the panel asks the user to continue in herdr or move on.
            let s = links.brainstormSuggestions
            return s.isEmpty || s.contains { $0.accepted == nil }
        case .writeSpec:  return links.specPath == nil
        case .createPlan: return links.planPath == nil
        case .codeReview: return links.reviewPath == nil
        case .implement:  return false   // no deliverable of its own — landing here means it finished
        }
    }

    /// Whether the main version's request fields (summary / topic / description / requirements /
    /// priority / labels / dependencies) may still be edited by hand — drives the detail view's
    /// Edit button.
    ///
    /// Two board columns qualify: **Backlog** (nothing has run yet) and **Brainstorm** (the one
    /// phase whose job *is* refining the request, so a hand-correction is in scope). Every later
    /// column is locked — spec/plan/implement/review all argue from a request already handed to an
    /// agent, and editing it there would put the artifacts and the request out of sync.
    ///
    /// Inside Brainstorm a live agent vetoes: `.running`/`.blocked` mean herdr already holds the
    /// old description in its prompt, so the edit would silently never reach it. It unlocks again
    /// once the phase lands in `.awaitingReview`/`.failed`.
    ///
    /// Narrower than the suggestion-version rule (`New Draft` / `TaskVersionsSheet`), which stays
    /// Backlog-only.
    public var allowsMainEdit: Bool {
        switch status {
        case .done, .running, .blocked:          return false
        case .backlog, .awaitingReview, .failed: return phase == nil || phase == .brainstorm
        }
    }

    /// Fields touched by pending brainstorm suggestions — drives the "ready for review" affordance.
    public var pendingBrainstormFields: Set<VersionField> {
        var out: Set<VersionField> = []
        for s in links.brainstormSuggestions where s.accepted == nil {
            switch s.kind {
            case .requirement: out.insert(.requirements)
            case .description: out.insert(.description)
            case .tag:         out.insert(.tags)
            }
        }
        return out
    }

    /// Apply one brainstorm suggestion's value to main (requirement → append if new,
    /// description → replace, tag → append if new). Shared by AppState + the review backend.
    public mutating func applyBrainstorm(_ s: BrainstormSuggestion) {
        switch s.kind {
        case .requirement: if !requirements.contains(s.value) { requirements.append(s.value) }
        case .description: description = s.value
        case .tag:         if !tags.contains(s.value) { tags.append(s.value) }
        }
    }

    /// Copy one field from a suggestion onto main (per-field Accept).
    public mutating func applyField(_ field: VersionField, from v: TaskVersion) {        switch field {
        case .name:         name = v.name
        case .topic:        topic = v.topic
        case .description:  description = v.description
        case .requirements: requirements = v.requirements
        case .priority:     priority = v.priority
        case .tags:         tags = v.tags
        case .dependsOn:    dependsOn = v.dependsOn
        }
    }

    /// "Make main": copy the suggestion's fields onto the top-level fields, keep the old main as a
    /// fresh suggestion, and drop the promoted one. `now` stamps the retained old-main version.
    public mutating func promote(_ v: TaskVersion, now: TimeInterval) {
        let oldMain = mainVersion
        name = v.name; topic = v.topic; description = v.description
        requirements = v.requirements; priority = v.priority; tags = v.tags; dependsOn = v.dependsOn
        var rest = (suggestions ?? []).filter { $0.id != v.id }
        rest.append(TaskVersion(label: "Former main", createdAt: now,
                                name: oldMain.name, topic: oldMain.topic, description: oldMain.description,
                                requirements: oldMain.requirements, priority: oldMain.priority,
                                tags: oldMain.tags, dependsOn: oldMain.dependsOn))
        suggestions = rest
    }
}
