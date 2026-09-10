import Foundation

public struct TaskStore: Sendable {
    public static let shared = TaskStore()
    public init() {}

    public func loadAll(projectSlug: String) -> [ProjectTask] {
        let root = Paths.tasksRoot(projectSlug: projectSlug)
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var out: [ProjectTask] = []
        for dir in dirs {
            let file = dir.appending(path: "task.json")
            guard let data = try? Data(contentsOf: file) else { continue }
            if let t = try? JSONDecoder().decode(ProjectTask.self, from: data) {
                out.append(t)
            } else if let t = Self.remapV1(data) {
                out.append(t)
            }
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
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
        let dir = Paths.taskDir(projectSlug: projectSlug, id: task.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = Paths.taskFile(projectSlug: projectSlug, id: task.id)
        let tmp = dir.appending(path: "task.json.tmp")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(task)
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
    }

    public func delete(id: String, projectSlug: String) {
        try? FileManager.default.removeItem(at: Paths.taskDir(projectSlug: projectSlug, id: id))
    }

    /// Re-read from disk, mutate, bump updatedAt, atomic save — so UI edits never clobber runner-written fields.
    public func update(id: String, projectSlug: String, _ mutate: (inout ProjectTask) -> Void) throws {
        let file = Paths.taskFile(projectSlug: projectSlug, id: id)
        let data = try Data(contentsOf: file)
        let existing = (try? JSONDecoder().decode(ProjectTask.self, from: data)) ?? Self.remapV1(data)
        guard var t = existing else { return }
        mutate(&t)
        t.updatedAt = Date().timeIntervalSince1970
        try save(t, projectSlug: projectSlug)
    }
}
