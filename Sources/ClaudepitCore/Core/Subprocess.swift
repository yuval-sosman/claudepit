import Foundation

/// One bounded, deadlock-free way to run a child process.
///
/// Every call site used to hand-roll the same four lines — `Process`, one `Pipe`, an undrained
/// `standardError`, `waitUntilExit()`, *then* `readDataToEndOfFile()`. That shape has two ways to
/// hang forever, and a hang here is not a slow call: the Swift task awaiting it is suspended on a
/// `withCheckedContinuation` that will never resume, and nothing upstream can cancel it. In the
/// Tasks pipeline that parks the task's id in `AppState.driving` for the life of the process, so a
/// card sits on "Running" with a finished agent and no poller will ever look at it again.
///
/// The two hangs:
///
/// 1. **Pipe-buffer deadlock.** A pipe holds ~64KB. Read *after* `waitUntilExit()` and a child that
///    writes more than that blocks in `write()`, so it never exits, so the wait never returns. An
///    undrained `standardError` pipe is the same trap with no reader at all. Both pipes are
///    therefore drained concurrently, on their own threads, *while* the child runs.
/// 2. **A child that simply never exits.** `waitUntilExit()` is not interruptible, so the only
///    lever is killing the process — hence the hard `timeout` ceiling (SIGTERM, then SIGKILL).
///
/// `runSync` blocks its thread; never call it from the main thread or a SwiftUI view body (see
/// `Herdr.available()` for the abort that causes).
public enum Subprocess {

    public struct Result: Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
        /// The ceiling fired and we killed the child. `stdout` holds whatever it managed to write.
        public let timedOut: Bool

        public var ok: Bool { exitCode == 0 && !timedOut }

        public init(stdout: String, stderr: String, exitCode: Int32, timedOut: Bool) {
            self.stdout = stdout; self.stderr = stderr
            self.exitCode = exitCode; self.timedOut = timedOut
        }
    }

    /// Ceiling for an ordinary call. Deliberately generous — it is a stuck-process backstop, not a
    /// latency budget. Calls that legitimately run longer (`herdr agent wait --timeout 1800000`)
    /// pass their own.
    public static let defaultTimeout: TimeInterval = 120

    /// Grace between SIGTERM and SIGKILL once the ceiling fires.
    private static let killGrace: TimeInterval = 2

    /// How long to wait for the drain threads after the child exits. A grandchild that inherited
    /// the write end keeps the pipe open past the child's death, so this cannot be unbounded.
    private static let drainGrace: TimeInterval = 5

    /// Run `executable` off the calling thread. Returns nil only when the process could not be
    /// launched at all (missing binary, bad cwd) — a non-zero exit is a `Result`, not a nil.
    public static func run(_ executable: String, _ args: [String], cwd: URL? = nil,
                           environment: [String: String]? = nil,
                           timeout: TimeInterval = defaultTimeout) async -> Result? {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(returning: runSync(executable, args, cwd: cwd,
                                               environment: environment, timeout: timeout))
            }
        }
    }

    /// Blocking core. See the type comment for why the ordering here is not incidental.
    public static func runSync(_ executable: String, _ args: [String], cwd: URL? = nil,
                               environment: [String: String]? = nil,
                               timeout: TimeInterval = defaultTimeout) -> Result? {
        let p = Process()
        p.executableURL = URL(filePath: executable)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if let environment { p.environment = environment }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        // No inherited stdin: a child that decides to prompt would otherwise block on a terminal
        // this process does not have, and sit there until the ceiling kills it.
        p.standardInput = FileHandle.nullDevice

        do { try p.run() } catch { return nil }

        // The drain threads and the ceiling both touch this while the child runs; Swift 6 needs
        // the shared mutable state behind one lock-guarded reference rather than captured `var`s.
        let state = State(process: p)

        let drained = DispatchGroup()
        for (pipe, isStdout) in [(outPipe, true), (errPipe, false)] {
            drained.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                state.record(data, isStdout: isStdout)
                drained.leave()
            }
        }

        let ceiling = DispatchWorkItem { state.expire(killAfter: killGrace) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: ceiling)

        p.waitUntilExit()
        ceiling.cancel()
        _ = drained.wait(timeout: .now() + drainGrace)

        let (out, err, timedOut) = state.snapshot()
        return Result(stdout: String(data: out, encoding: .utf8) ?? "",
                      stderr: String(data: err, encoding: .utf8) ?? "",
                      exitCode: p.terminationStatus,
                      timedOut: timedOut)
    }

    /// Lock-guarded box for the state the drain threads and the ceiling share with `runSync`.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var out = Data(), err = Data()
        private var timedOut = false

        init(process: Process) { self.process = process }

        func record(_ data: Data, isStdout: Bool) {
            lock.lock(); defer { lock.unlock() }
            if isStdout { out = data } else { err = data }
        }

        /// The ceiling fired: SIGTERM now, SIGKILL if it is still alive after the grace.
        func expire(killAfter grace: TimeInterval) {
            lock.lock()
            guard process.isRunning else { lock.unlock(); return }
            timedOut = true
            lock.unlock()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [process] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }

        func snapshot() -> (Data, Data, Bool) {
            lock.lock(); defer { lock.unlock() }
            return (out, err, timedOut)
        }
    }
}
