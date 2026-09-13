import Foundation

public struct TaskStore: Sendable {
    private let root: URL

    public static let shared = TaskStore(root: Paths.projectsRoot)

    public init(root: URL) {
        self.root = root
    }

    private func tasksRoot(projectSlug: String) -> URL {
        root.appending(path: projectSlug).appending(path: "tasks")
    }

    private func taskDir(projectSlug: String, id: String) -> URL {
        tasksRoot(projectSlug: projectSlug).appending(path: id)
    }

    private func taskFile(projectSlug: String, id: String) -> URL {
        taskDir(projectSlug: projectSlug, id: id).appending(path: "task.json")
    }

    public func loadAll(projectSlug: String) -> [ProjectTask] {
        let root = tasksRoot(projectSlug: projectSlug)
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var out: [ProjectTask] = []
        for dir in dirs {
            let file = dir.appending(path: "task.json")
            guard let data = try? Data(contentsOf: file) else { continue }
            if let t = Self.decode(data) { out.append(t) }
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Plain decode, then the v2 removed-phase remap, then the lossy v1 remap.
    static func decode(_ data: Data) -> ProjectTask? {
        if let t = try? JSONDecoder().decode(ProjectTask.self, from: data) { return t }
        if let t = remapRemovedPhases(data) { return t }
        return remapV1(data)
    }

    /// v2 tasks written before the `verify` phase was removed still carry it in `phase` /
    /// `plannedPhases`, so a plain decode fails. Strip it — a task parked AT verify falls forward
    /// to codeReview (the phase that replaced it in the pipeline) — and decode again, losslessly
    /// for every other field. The next save writes clean JSON.
    static func remapRemovedPhases(_ data: Data) -> ProjectTask? {
        guard var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var touched = false
        if var planned = obj["plannedPhases"] as? [String], planned.contains("verify") {
            planned.removeAll { $0 == "verify" }
            obj["plannedPhases"] = planned; touched = true
        }
        if obj["phase"] as? String == "verify" { obj["phase"] = "codeReview"; touched = true }
        // `autoRunRetried` holds phase raw values too, so it needs the same strip — otherwise the
        // next retired phase resurrects exactly the decode failure this function exists to fix.
        if var retried = obj["autoRunRetried"] as? [String], retried.contains("verify") {
            retried.removeAll { $0 == "verify" }
            obj["autoRunRetried"] = retried; touched = true
        }
        guard touched, let clean = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return try? JSONDecoder().decode(ProjectTask.self, from: clean)
    }

    /// v1 tasks used removed enum cases (`created`/`done`) and a non-optional `phase`, so a plain
    /// decode fails. Remap the few fields we need; drop `autoAdvance`/`herdrPaneID`.
    static func remapV1(_ data: Data) -> ProjectTask? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else { return nil }
        var t = ProjectTask(id: id)
        t.name = obj["name"] as? String ?? ""
        t.description = obj["description"] as? String ?? ""
        t.requirements = obj["requirements"] as? [String] ?? []
        t.createdAt = obj["createdAt"] as? TimeInterval ?? 0
        t.updatedAt = obj["updatedAt"] as? TimeInterval ?? 0
        switch obj["phase"] as? String {
        case "created":                        t.phase = nil;         t.status = .backlog
        case "done":                           t.phase = nil;         t.status = .done
        case "writeSpec":                      t.phase = .writeSpec;  t.status = .awaitingReview
        case "createPlan":                     t.phase = .createPlan; t.status = .awaitingReview
        case "implement":                      t.phase = .implement;  t.status = .awaitingReview
        case "codeReview":                     t.phase = .codeReview; t.status = .awaitingReview
        default:                               t.phase = nil;         t.status = .backlog
        }
        if let links = obj["links"] as? [String: Any] {
            t.links.specPath = links["specPath"] as? String
            t.links.planPath = links["planPath"] as? String
            t.links.reviewPath = links["reviewPath"] as? String
            t.links.sessionIDs = links["sessionIDs"] as? [String] ?? []
        }
        return t
    }

    public func save(_ task: ProjectTask, projectSlug: String) throws {
        let dir = taskDir(projectSlug: projectSlug, id: task.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = taskFile(projectSlug: projectSlug, id: task.id)
        let tmp = dir.appending(path: "task.json.tmp")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(task)
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
    }

    public func delete(id: String, projectSlug: String) {
        try? FileManager.default.removeItem(at: taskDir(projectSlug: projectSlug, id: id))
    }

    /// Read one task, applying the same migration chain as `loadAll`. Returns nil when the file is
    /// missing or undecodable.
    public func load(id: String, projectSlug: String) -> ProjectTask? {
        guard let data = try? Data(contentsOf: taskFile(projectSlug: projectSlug, id: id)) else { return nil }
        return Self.decode(data)
    }

    /// Re-read from disk, mutate, bump updatedAt, atomic save — so UI edits never clobber runner-written fields.
    /// Read-modify-write one task. **A mutation that changes nothing writes nothing.**
    ///
    /// That guard is load-bearing, not an optimisation. `updatedAt` is bumped on every write, the
    /// FileWatcher is watching this directory, and a watcher event runs `AppState.reload()` —
    /// which calls `loadTasks()`, which runs the heal/merge passes that call back into here. Any
    /// caller that mutates unconditionally therefore closes a loop and the app reloads forever
    /// (sessions rescanned, watcher torn down and rebuilt, several times a second). One such
    /// caller — `healArtifactLinks` failing to persist `reviewFindings`, so heal never converged —
    /// is exactly how that shipped. Making the *store* refuse a no-op write retires the whole
    /// class of bug rather than the one instance.
    public func update(id: String, projectSlug: String, _ mutate: (inout ProjectTask) -> Void) throws {
        guard let original = load(id: id, projectSlug: projectSlug) else { return }
        var t = original
        mutate(&t)
        guard t != original else { return }
        t.updatedAt = Date().timeIntervalSince1970
        try save(t, projectSlug: projectSlug)
    }
}
