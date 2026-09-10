import Foundation

/// Abstraction the review sheet renders against, so BOTH a git worktree and a
/// brainstorm-suggestion set drive the SAME `ReviewChangesSheet` UI with the same
/// Stage / Discard / Commit terminology. Git ops map 1:1 to WorktreeStager; the
/// brainstorm backend treats each suggestion as a one-file, one-hunk change.
public protocol ChangeSource: Sendable {
    /// Title shown after the sheet's "Source Control ·" prefix.
    var title: String { get }
    /// Verb on the confirm button (git: "Commit"; brainstorm: "Apply").
    var commitVerb: String { get }
    /// Whether the commit bar shows a message field (git yes, brainstorm no).
    var needsCommitMessage: Bool { get }

    func status() async -> [StagedFile]
    func diff(path: String, staged: Bool, untracked: Bool) async -> String
    func stageFile(path: String) async -> (ok: Bool, message: String)
    func unstageFile(path: String) async -> (ok: Bool, message: String)
    func discardFile(path: String, untracked: Bool) async -> (ok: Bool, message: String)
    func applyHunk(patch: String, reverse: Bool, cached: Bool) async -> (ok: Bool, message: String)
    func commit(message: String) async -> (ok: Bool, message: String)
}

public extension ChangeSource {
    var commitVerb: String { "Commit" }
    var needsCommitMessage: Bool { true }
}

/// Git backend — a thin adapter binding a worktree path to `WorktreeStager`.
public struct GitChangeSource: ChangeSource {
    public let worktreePath: String
    public let title: String
    public init(worktreePath: String, title: String) {
        self.worktreePath = worktreePath; self.title = title
    }
    public func status() async -> [StagedFile] { await WorktreeStager.status(at: worktreePath) }
    public func diff(path: String, staged: Bool, untracked: Bool) async -> String {
        await WorktreeStager.diff(at: worktreePath, path: path, staged: staged, untracked: untracked)
    }
    public func stageFile(path: String) async -> (ok: Bool, message: String) {
        await WorktreeStager.stageFile(at: worktreePath, path: path)
    }
    public func unstageFile(path: String) async -> (ok: Bool, message: String) {
        await WorktreeStager.unstageFile(at: worktreePath, path: path)
    }
    public func discardFile(path: String, untracked: Bool) async -> (ok: Bool, message: String) {
        await WorktreeStager.discardFile(at: worktreePath, path: path, untracked: untracked)
    }
    public func applyHunk(patch: String, reverse: Bool, cached: Bool) async -> (ok: Bool, message: String) {
        await WorktreeStager.applyHunk(at: worktreePath, patch: patch, reverse: reverse, cached: cached)
    }
    public func commit(message: String) async -> (ok: Bool, message: String) {
        await WorktreeStager.commit(at: worktreePath, message: message)
    }
}

/// Brainstorm backend — each pending/accepted suggestion is a one-file, one-hunk change.
/// Stage = accept (apply to task), Unstage = revert to pending, Discard = dismiss, Commit = close.
/// Dismissed suggestions drop out of `status()` (like a discarded file).
public struct BrainstormChangeSource: ChangeSource {
    public let taskID: String
    public let projectSlug: String
    public let title: String
    public var commitVerb: String { "Done" }
    public var needsCommitMessage: Bool { false }

    public init(taskID: String, projectSlug: String, title: String) {
        self.taskID = taskID; self.projectSlug = projectSlug; self.title = title
    }

    private func task() -> ProjectTask? { TaskStore.shared.loadAll(projectSlug: projectSlug).first { $0.id == taskID } }
    private func suggestions() -> [BrainstormSuggestion] { task()?.links.brainstormSuggestions ?? [] }
    private func pending() -> [BrainstormSuggestion] { suggestions().filter { $0.accepted == nil } }

    /// The whole task is ONE "file" so the review reads as one file with many hunks
    /// (not many separate files). Its display name doubles as the file path.
    private var filePath: String { "\(title) — brainstorm" }

    private func suggestion(byID id: String) -> BrainstormSuggestion? { suggestions().first { $0.id == id } }
    private func kindDir(_ k: BrainstormSuggestion.Kind) -> String {
        switch k { case .requirement: return "Requirements"; case .description: return "Description"; case .tag: return "Labels" }
    }

    public func status() async -> [StagedFile] {
        // One unstaged file representing all pending suggestions; empty when nothing pending.
        guard !pending().isEmpty else { return [] }
        return [StagedFile(path: filePath, change: .modified, staged: false, unstaged: true, untracked: false)]
    }

    /// All pending suggestions as consecutive hunks of ONE file. Each hunk header carries the
    /// suggestion id + kind label as its `@@ … @@ <heading>` so `applyHunk` can map a block back
    /// to its suggestion (git allows arbitrary trailing text after the second `@@`).
    public func diff(path p: String, staged: Bool, untracked: Bool) async -> String {
        let t = task()
        var out = ["diff --git a/\(filePath) b/\(filePath)", "--- a/\(filePath)", "+++ b/\(filePath)"]
        for s in pending() {
            let before = s.kind == .description ? (t?.description ?? "") : ""
            let old = before.isEmpty ? [] : before.components(separatedBy: "\n")
            let new = s.value.components(separatedBy: "\n")
            // Heading = "<KindDir> · <id>" — id lets applyHunk resolve the suggestion unambiguously.
            out.append("@@ -1,\(old.count) +1,\(new.count) @@ \(kindDir(s.kind)) · \(s.id)")
            out += old.map { "-" + $0 }
            out += new.map { "+" + $0 }
        }
        return out.joined(separator: "\n") + "\n"
    }

    public func stageFile(path p: String) async -> (ok: Bool, message: String) {
        for s in pending() { _ = setAccepted(s.id, true) }; return (true, "")
    }
    public func unstageFile(path p: String) async -> (ok: Bool, message: String) { (true, "") }
    public func discardFile(path p: String, untracked: Bool) async -> (ok: Bool, message: String) {
        for s in pending() { _ = setAccepted(s.id, false) }; return (true, "")
    }

    /// A single hunk == one suggestion, identified by the id in its `@@ … @@ <dir> · <id>` heading.
    public func applyHunk(patch: String, reverse: Bool, cached: Bool) async -> (ok: Bool, message: String) {
        guard let id = Self.suggestionID(fromPatch: patch) else { return (false, "no suggestion in hunk") }
        if !cached { return setAccepted(id, false) }        // Discard Block = dismiss
        return setAccepted(id, reverse ? nil : true)         // Unstage Block = pending, Stage Block = accept
    }

    public func commit(message: String) async -> (ok: Bool, message: String) { (true, "") }

    // MARK: - Persistence

    private func setAccepted(_ id: String, _ value: Bool?) -> (ok: Bool, message: String) {
        guard let s = suggestion(byID: id) else { return (false, "unknown suggestion") }
        do {
            try TaskStore.shared.update(id: taskID, projectSlug: projectSlug) { t in
                if value == true { t.applyBrainstorm(s) }
                if let i = t.links.brainstormSuggestions.firstIndex(where: { $0.id == s.id }) {
                    t.links.brainstormSuggestions[i].accepted = value
                }
            }
            return (true, "")
        } catch { return (false, "\(error.localizedDescription)") }
    }

    // MARK: - Hunk-heading id recovery

    /// Read the suggestion id from a single-hunk patch's `@@ … @@ <KindDir> · <id>` heading.
    static func suggestionID(fromPatch patch: String) -> String? {
        for line in patch.components(separatedBy: "\n") where line.hasPrefix("@@") {
            // header form: "@@ -1,0 +1,1 @@ Requirements · <id>"
            guard let range = line.range(of: " · ") else { return nil }
            let id = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? nil : id
        }
        return nil
    }
}


