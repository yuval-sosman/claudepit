import Foundation
@testable import ClaudepitCore

/// `Subprocess` — the guarantees that stop a hung child from wedging the Tasks pipeline — plus the
/// `TaskStore.update` no-op rule that stops the FileWatcher looping on the app's own writes.
func subprocessChecks() -> [Bool] {
    var results: [Bool] = []

    func sh(_ script: String, timeout: TimeInterval = Subprocess.defaultTimeout) -> Subprocess.Result? {
        Subprocess.runSync("/bin/sh", ["-c", script], timeout: timeout)
    }

    results.append(check("captures stdout and stderr separately") {
        // `Herdr.run` depends on the separation: herdr writes its `{"error":…}` payloads to stderr
        // and leaves stdout empty, which is how a failed command becomes nil for `TaskRunner`.
        let out = try require(sh("printf out; printf err >&2"))
        try expectEqual(out.stdout, "out", "stdout")
        try expectEqual(out.stderr, "err", "stderr")
    })

    results.append(check("a non-zero exit is a Result, not a nil") {
        let out = try require(sh("exit 3"))
        try expectEqual(out.exitCode, 3, "exit code")
        try expect(!out.ok, "not ok")
        try expect(!out.timedOut, "did not time out")
    })

    results.append(check("nil only when the process could not be launched") {
        try expect(Subprocess.runSync("/nonexistent/binary", []) == nil, "missing binary → nil")
    })

    results.append(check("a child that outgrows the pipe buffer does not deadlock") {
        // THE bug this type exists for: a pipe holds ~64KB, so reading only *after*
        // `waitUntilExit()` hangs forever on a bigger child — it blocks in write(), never exits,
        // and the wait never returns. `standardError` with no reader at all is the same trap.
        try expectEqual(try require(sh("yes abcdefghij | head -c 300000")).stdout.utf8.count,
                        300_000, "large stdout")
        try expectEqual(try require(sh("yes abcdefghij | head -c 300000 >&2")).stderr.utf8.count,
                        300_000, "large stderr")
        let both = try require(sh("yes a | head -c 200000; yes b | head -c 200000 >&2"))
        try expectEqual(both.stdout.utf8.count, 200_000, "large stdout alongside")
        try expectEqual(both.stderr.utf8.count, 200_000, "large stderr alongside")
    })

    results.append(check("a child that never exits is killed at the ceiling") {
        let started = Date()
        let hung = try require(sh("sleep 60", timeout: 1))
        let elapsed = Date().timeIntervalSince(started)
        try expect(hung.timedOut, "reported as timed out")
        try expect(!hung.ok, "a timed-out call is not ok")
        try expect(elapsed < 20, "returned in \(elapsed)s rather than running to completion")
    })

    results.append(check("output written before the ceiling survives the kill") {
        // A phase that printed its CLAUDEPIT_ARTIFACT: marker before hanging must not lose it.
        try expectEqual(try require(sh("printf partial; sleep 60", timeout: 1)).stdout,
                        "partial", "partial stdout")
    })

    results.append(check("a fast child is unaffected by a generous ceiling") {
        try expect(try require(sh("printf quick", timeout: 30)).ok, "ok")
    })

    // MARK: - TaskStore.update must not write when nothing changed

    results.append(check("TaskStore.update writes nothing when the mutation changes nothing") {
        // A no-op write bumps updatedAt → FileWatcher → reload() → loadTasks() → back into
        // update(). That loop is exactly what `healArtifactLinks` closed by never persisting the
        // `reviewFindings` it had just derived, and it ran the app's whole reload cycle several
        // times a second for as long as a reviewed task was on the board.
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskStore(root: root)

        try store.save(ProjectTask(id: "t1", name: "One", updatedAt: 100), projectSlug: "proj")
        try store.update(id: "t1", projectSlug: "proj") { $0.name = "One" }      // same value
        try expectEqual(store.load(id: "t1", projectSlug: "proj")?.updatedAt, 100,
                        "a no-op mutation leaves updatedAt alone")

        try store.update(id: "t1", projectSlug: "proj") { $0.name = "Two" }      // real change
        let after = try require(store.load(id: "t1", projectSlug: "proj"))
        try expectEqual(after.name, "Two", "a real mutation is persisted")
        try expect(after.updatedAt > 100, "a real mutation bumps updatedAt")
    })

    results.append(check("a heal that finds nothing new never rewrites the file") {
        // The write-back's own shape: fill only what is missing, so it converges after one pass.
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskStore(root: root)
        try store.save(ProjectTask(id: "t2", updatedAt: 100,
                                   links: TaskLinks(specPath: "/spec.md")), projectSlug: "proj")
        for _ in 0..<3 {
            try store.update(id: "t2", projectSlug: "proj") {
                $0.links.specPath = $0.links.specPath ?? "/other.md"
            }
        }
        try expectEqual(store.load(id: "t2", projectSlug: "proj")?.updatedAt, 100, "never rewritten")
    })

    return results
}

/// Unwrap or fail the check — `XCTUnwrap` for this harness.
private func require<T>(_ value: T?, _ label: String = "value") throws -> T {
    guard let value else { throw CheckFailure(message: "expected a \(label), got nil") }
    return value
}
