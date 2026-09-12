import Foundation
@testable import ClaudepitCore

func homeTaskPipelineChecks() -> [Bool] {
    var results: [Bool] = []

    func task(_ id: String, phase: TaskPhase?, _ status: TaskStatus) -> ProjectTask {
        ProjectTask(id: id, name: id, phase: phase, status: status)
    }

    results.append(check("always seven buckets, Backlog → Done, even with no tasks") {
        let out = buildTaskPipeline(tasks: [])
        try expectEqual(out.map(\.id),
                        ["backlog", "brainstorm", "writeSpec", "createPlan", "implement", "codeReview", "done"],
                        "fixed scale")
        try expectEqual(out.map(\.title),
                        ["Backlog", "Brainstorm", "Spec", "Plan", "Impl", "Review", "Done"], "titles")
        try expectEqual(out.map(\.count), [0, 0, 0, 0, 0, 0, 0], "all zero")
    })

    results.append(check("the ends count by status, the middle by phase — no task counted twice") {
        // `phase` is nil for both backlog and done, so neither can leak into a middle bucket.
        let out = buildTaskPipeline(tasks: [
            task("b1", phase: nil, .backlog),
            task("b2", phase: nil, .backlog),
            task("d1", phase: nil, .done),
            task("r1", phase: .implement, .running),
        ])
        try expectEqual(out.map(\.count), [2, 0, 0, 0, 1, 0, 1], "2 backlog, 1 implement, 1 done")
        try expectEqual(out.reduce(0) { $0 + $1.count }, 4, "every task counted exactly once")
    })

    results.append(check("inFlight accents a phase holding running/blocked/awaitingReview work") {
        for status in [TaskStatus.running, .blocked, .awaitingReview] {
            let out = buildTaskPipeline(tasks: [task("t", phase: .createPlan, status)])
            guard let plan = out.first(where: { $0.kind == .phase(.createPlan) }) else {
                throw CheckFailure(message: "no createPlan bucket")
            }
            try expect(plan.inFlight, "\(status.rawValue) is in flight")
        }
    })

    results.append(check("a failed task fills its bucket without accenting it") {
        let out = buildTaskPipeline(tasks: [task("t", phase: .codeReview, .failed)])
        guard let review = out.first(where: { $0.kind == .phase(.codeReview) }) else {
            throw CheckFailure(message: "no codeReview bucket")
        }
        try expectEqual(review.count, 1, "counted")
        try expect(!review.inFlight, "failed is not in flight")
    })

    results.append(check("the end buckets are never in flight — they are terminal statuses") {
        let out = buildTaskPipeline(tasks: [task("b", phase: nil, .backlog),
                                            task("d", phase: nil, .done),
                                            task("r", phase: .implement, .running)])
        try expect(!out[0].inFlight, "backlog")
        try expect(!out[6].inFlight, "done")
    })

    return results
}
