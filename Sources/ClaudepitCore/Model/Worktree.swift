import Foundation

public enum WorktreeBinding: Equatable { case active, idle, unbound }

/// Lock classification for the Cleanup UI. A worktree can be unlocked, locked by a
/// live process (leave it alone), or locked by a dead one (stale — safe to unlock).
public enum WorktreeLock: Equatable {
    case unlocked
    case lockedLive(pid: Int32)
    case lockedStale(pid: Int32?)   // pid nil = locked with no pid in the reason
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
    public var ownerSessionID: String?
    /// Set when the worktree belongs to a subagent; the subagent's own ID for resume/navigate.
    public var ownerSubagentID: String?
    public var isActive: Bool

    public init(name: String, path: String, branch: String, head: String,
                isLocked: Bool, lockReason: String = "", dirtyCount: Int, aheadCount: Int,
                ownerSessionID: String? = nil, ownerSubagentID: String? = nil, isActive: Bool = false) {
        self.name = name; self.path = path; self.branch = branch; self.head = head
        self.isLocked = isLocked; self.lockReason = lockReason
        self.dirtyCount = dirtyCount; self.aheadCount = aheadCount
        self.ownerSessionID = ownerSessionID; self.ownerSubagentID = ownerSubagentID; self.isActive = isActive
    }

    public var isClean: Bool { dirtyCount == 0 }

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
