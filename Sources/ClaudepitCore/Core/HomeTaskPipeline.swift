import Foundation

/// One column of Home's task pipeline.
///
/// The strip reads left to right across a task's whole life, but its two ends are *statuses* rather
/// than phases: `phase` is nil for both backlog and done (`Model/Task.swift`), so neither can ever be
/// a `TaskPhase` column. Counting by status at the ends and by phase in the middle partitions the
/// task list exactly once — a backlog or done task has no phase to leak into a middle bucket, and a
/// task with a phase is never backlog or done.
public struct TaskPipelineBucket: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case backlog, phase(TaskPhase), done }
    public let kind: Kind
    public let title: String
    public let count: Int
    /// Some task in this bucket is running/blocked/awaitingReview — the view accents the badge.
    /// Only ever true on a phase bucket: the end buckets are defined by terminal statuses.
    public let inFlight: Bool

    public var id: String {
        switch kind {
        case .backlog:       return "backlog"
        case .phase(let p):  return p.rawValue
        case .done:          return "done"
        }
    }

    public init(kind: Kind, title: String, count: Int, inFlight: Bool) {
        self.kind = kind; self.title = title; self.count = count; self.inFlight = inFlight
    }
}

/// Always returns the same seven buckets, in order, zero counts included — the strip is a fixed
/// scale the eye can read at a glance, not a list that reflows as work moves through it.
public func buildTaskPipeline(tasks: [ProjectTask]) -> [TaskPipelineBucket] {
    var out: [TaskPipelineBucket] = [
        TaskPipelineBucket(kind: .backlog, title: "Backlog",
                           count: tasks.filter { $0.status == .backlog }.count, inFlight: false)
    ]

    for phase in TaskPhase.allCases {
        let here = tasks.filter { $0.phase == phase }
        out.append(TaskPipelineBucket(
            kind: .phase(phase),
            title: phase.shortTitle,
            count: here.count,
            inFlight: here.contains {
                $0.status == .running || $0.status == .blocked || $0.status == .awaitingReview
            }))
    }

    out.append(TaskPipelineBucket(kind: .done, title: "Done",
                                  count: tasks.filter { $0.status == .done }.count, inFlight: false))
    return out
}
