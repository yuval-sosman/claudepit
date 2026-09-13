import Foundation

public enum WorktreeBinding: Equatable { case active, idle, unbound }

/// Lock classification for the Cleanup UI. A worktree can be unlocked, locked by a
/// live process (leave it alone), or locked by a dead one (stale — safe to unlock).
public enum WorktreeLock: Equatable {
    case unlocked
    case lockedLive(pid: Int32)
    case lockedStale(pid: Int32?)   // pid nil = locked with no pid in the reason

    /// True while the lock is held — by a live process, or by an active session regardless of the
    /// lock's own pid. `lockedStale` is deliberately false: its owner is provably gone. The merge
    /// gate uses this rather than `isActive` alone because a task agent carries no
    /// `agent_session`, so `ownerSessionID` may only ever arrive via the cwd fallback.
    public var isLockedLive: Bool {
        if case .lockedLive = self { return true }
        return false
    }
}

public struct WorktreeInfo: Identifiable, Equatable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let branch: String
    public let head: String
    public let isLocked: Bool
    public let lockReason: String
    public let dirtyCount: Int
    public let aheadCount: Int
    /// Commits on `baseRef` that are not in this worktree. 0 when there is no base to compare
    /// against (see `baseRef`), which is why `isBehindBase` gates on the ref, not the count.
    public let behindCount: Int
    /// `git status --porcelain` lines that do NOT start with "??". The merge gate uses this,
    /// not `dirtyCount`: an untracked scratch file is routine in an agent's worktree and does
    /// not stop a merge, whereas git itself refuses only when one would actually be overwritten.
    public let trackedDirtyCount: Int
    /// Display name of the base branch, e.g. "main". Empty when no base is resolvable.
    public let baseBranch: String
    /// The merge target, e.g. "origin/main" or "main". Carried alongside `baseBranch` rather
    /// than re-derived where needed, because resolving it costs a subprocess and the UI is
    /// forbidden from spawning one. Empty when no base is resolvable.
    public let baseRef: String
    /// Re-derived from `MERGE_HEAD` on every scan, never cached: a merge can be started (or
    /// finished) in a terminal, and the conflict UI must survive a relaunch.
    public let mergeInProgress: Bool
    /// Unmerged paths (`git diff --diff-filter=U`). Legitimately EMPTY while `mergeInProgress`
    /// is true — that is the state after the user stages resolutions but before committing.
    public let conflictedFiles: [String]
    public var ownerSessionID: String?
    /// Set when the worktree belongs to a subagent; the subagent's own ID for resume/navigate.
    public var ownerSubagentID: String?
    public var isActive: Bool

    public init(name: String, path: String, branch: String, head: String,
                isLocked: Bool, lockReason: String = "", dirtyCount: Int, aheadCount: Int,
                behindCount: Int = 0, trackedDirtyCount: Int = 0,
                baseBranch: String = "", baseRef: String = "",
                mergeInProgress: Bool = false, conflictedFiles: [String] = [],
                ownerSessionID: String? = nil, ownerSubagentID: String? = nil, isActive: Bool = false) {
        self.name = name; self.path = path; self.branch = branch; self.head = head
        self.isLocked = isLocked; self.lockReason = lockReason
        self.dirtyCount = dirtyCount; self.aheadCount = aheadCount
        self.behindCount = behindCount; self.trackedDirtyCount = trackedDirtyCount
        self.baseBranch = baseBranch; self.baseRef = baseRef
        self.mergeInProgress = mergeInProgress; self.conflictedFiles = conflictedFiles
        self.ownerSessionID = ownerSessionID; self.ownerSubagentID = ownerSubagentID; self.isActive = isActive
    }

    /// Unchanged meaning — untracked files included. Remove Worktree and the Source Control
    /// button still key off this; only the MERGE gate uses `trackedDirtyCount`.
    public var isClean: Bool { dirtyCount == 0 }

    /// True when there is a base to compare against and HEAD is missing commits from it.
    public var isBehindBase: Bool { !baseRef.isEmpty && behindCount > 0 }

    /// The update action is runnable: a base exists, no merge is already in flight, and nothing
    /// TRACKED is uncommitted. Untracked files do not block — git refuses on its own if one
    /// would actually be overwritten, and that lands as `.failed` with git's own message.
    public var canUpdateFromBase: Bool {
        !baseRef.isEmpty && !mergeInProgress && trackedDirtyCount == 0
    }

    public var bindingState: WorktreeBinding {
        if ownerSessionID != nil { return isActive ? .active : .idle }
        return .unbound
    }

    /// Pid embedded in a lock reason like "...(pid 23121 start ...)", if any.
    public var lockPID: Int32? { Self.parsePID(from: lockReason) }

    /// Classify the lock: unlocked / held (still in use) / stale (safe to unlock).
    /// A lock is stale only when its pid is dead AND the worktree isn't actively
    /// bound — an active session can keep a worktree in use even after the process
    /// that first locked it has exited. A lock with no parseable pid is never stale
    /// (can't prove it's idle+dead).
    public var lockState: WorktreeLock {
        guard isLocked else { return .unlocked }
        if isActive { return .lockedLive(pid: lockPID ?? -1) }   // in use regardless of lock pid
        guard let pid = lockPID else { return .lockedLive(pid: -1) }
        return Self.processAlive(pid) ? .lockedLive(pid: pid) : .lockedStale(pid: pid)
    }

    static func parsePID(from reason: String) -> Int32? {
        // Match "pid <n>" anywhere in the reason string.
        guard let r = reason.range(of: #"pid\s+(\d+)"#, options: .regularExpression) else { return nil }
        let digits = reason[r].drop { !$0.isNumber }
        return Int32(digits)
    }

    /// kill(pid, 0) probes existence without signalling. ponytail: pid can be recycled
    /// (a different live process reusing the number) — acceptable heuristic for a manual
    /// unlock prompt; the user still confirms.
    static func processAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM   // EPERM = alive but not ours
    }
}
