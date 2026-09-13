import Foundation

/// A file in `git status`, split by staged (index) vs unstaged (worktree) state.
/// Reuses `ChangedFile.Change` for the badge/color mapping.
public struct StagedFile: Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let change: ChangedFile.Change
    public let staged: Bool
    public let unstaged: Bool
    public let untracked: Bool
    public init(path: String, change: ChangedFile.Change, staged: Bool, unstaged: Bool, untracked: Bool) {
        self.path = path; self.change = change
        self.staged = staged; self.unstaged = unstaged; self.untracked = untracked
    }
}

/// What `WorktreeStager.updateFromBase` did. `.dirty` and the "already merging" `.failed`
/// mean NOTHING was attempted — the worktree is untouched.
public enum WorktreeUpdateOutcome: Equatable, Sendable {
    /// n uncommitted TRACKED changes — nothing was attempted.
    case dirty(Int)
    /// HEAD did not move: the base held no new commits.
    case upToDate
    /// HEAD moved — fast-forward or merge commit.
    case merged
    /// The merge left these paths unmerged; `MERGE_HEAD` is live.
    case conflicted([String])
    /// git's own stderr (or stdout when stderr is empty).
    case failed(String)
}

/// The ONLY place that mutates git state (WorktreeInspector stays read-only).
/// Shells out to `git -C <dir> …`; every op returns (ok, message) so the UI
/// can surface failures.
public enum WorktreeStager {

    // MARK: - Pure parser

    /// Parse `git status --porcelain=v1 -z`. Record = "XY <path>\0"; X = index,
    /// Y = worktree. Rename (X == 'R') emits a second \0 field (old path) to skip.
    static func parseStatusV1(_ raw: String) -> [StagedFile] {
        let fields = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var out: [StagedFile] = []
        var i = 0
        while i < fields.count {
            let rec = fields[i]
            guard rec.count >= 3 else { i += 1; continue }
            let x = rec[rec.startIndex]
            let y = rec[rec.index(rec.startIndex, offsetBy: 1)]
            let path = String(rec[rec.index(rec.startIndex, offsetBy: 3)...])

            if x == "?" && y == "?" {
                out.append(StagedFile(path: path, change: .untracked,
                                      staged: false, unstaged: true, untracked: true))
                i += 1
                continue
            }
            let staged = x != " " && x != "?"
            let unstaged = y != " " && y != "?"
            // Choose the change kind from the meaningful column (index preferred).
            let code = staged ? x : y
            let change: ChangedFile.Change
            switch code {
            case "A": change = .added
            case "D": change = .deleted
            case "R", "C": change = .renamed
            default: change = .modified
            }
            if x == "R" || x == "C" || y == "R" || y == "C" { i += 1 } // skip old-path field
            out.append(StagedFile(path: path, change: change,
                                  staged: staged, unstaged: unstaged, untracked: false))
            i += 1
        }
        return out
    }

    // MARK: - Async git (mutating)

    public static func status(at dir: String) async -> [StagedFile] {
        let files = parseStatusV1(await git(["status", "--porcelain=v1", "-z"], at: dir).out)
        // Expand untracked directory entries (path ends with "/") into individual files.
        var expanded: [StagedFile] = []
        for f in files {
            if f.untracked && f.path.hasSuffix("/") {
                let r = await git(["ls-files", "--others", "--exclude-standard", f.path], at: dir)
                let children = r.out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                if !children.isEmpty {
                    for child in children {
                        expanded.append(StagedFile(path: child, change: .untracked, staged: false, unstaged: true, untracked: true))
                    }
                    continue
                }
            }
            expanded.append(f)
        }
        return expanded
    }

    public static func diff(at dir: String, path: String, staged: Bool, untracked: Bool = false) async -> String {
        if untracked {
            // --no-index ignores -C, so we need an absolute path; exit code 1 is normal (differences found)
            let abs = (dir as NSString).appendingPathComponent(path)
            let r = await git(["diff", "--no-index", "--", "/dev/null", abs], at: dir)
            return r.out
        }
        let args = staged ? ["diff", "--cached", "--", path] : ["diff", "--", path]
        return await git(args, at: dir).out
    }

    public static func stageFile(at dir: String, path: String) async -> (ok: Bool, message: String) {
        let r = await git(["add", "--", path], at: dir); return (r.ok, r.err)
    }

    public static func unstageFile(at dir: String, path: String) async -> (ok: Bool, message: String) {
        let r = await git(["reset", "-q", "HEAD", "--", path], at: dir); return (r.ok, r.err)
    }

    public static func discardFile(at dir: String, path: String, untracked: Bool) async -> (ok: Bool, message: String) {
        if untracked {
            let full = (dir as NSString).appendingPathComponent(path)
            do { try FileManager.default.removeItem(atPath: full); return (true, "") }
            catch { return (false, "delete failed: \(error.localizedDescription)") }
        }
        let r = await git(["checkout", "--", path], at: dir); return (r.ok, r.err)
    }

    /// Apply a single-hunk patch (from `buildPatch`). cached => `--cached`
    /// (stage/unstage the hunk in the index); reverse => `-R` (unstage/discard).
    public static func applyHunk(at dir: String, patch: String, reverse: Bool, cached: Bool) async -> (ok: Bool, message: String) {
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("claudepit-hunk-\(UUID().uuidString).patch")
        do { try patch.write(toFile: tmp, atomically: true, encoding: .utf8) }
        catch { return (false, "write patch failed: \(error.localizedDescription)") }
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        var args = ["apply", "--whitespace=nowarn"]
        if cached { args.append("--cached") }
        if reverse { args.append("-R") }
        args.append(tmp)
        let r = await git(args, at: dir); return (r.ok, r.err)
    }

    public static func commit(at dir: String, message: String) async -> (ok: Bool, message: String) {
        let r = await git(["commit", "-m", message], at: dir); return (r.ok, r.err.isEmpty ? r.out : r.err)
    }

    /// Release a lock so the worktree can be removed. Runs from inside the worktree.
    public static func unlock(worktreePath: String) async -> (ok: Bool, message: String) {
        let r = await git(["worktree", "unlock", worktreePath], at: worktreePath); return (r.ok, r.err)
    }

    /// Remove the worktree. Must run from OUTSIDE it (git refuses from within), so
    /// we run in its parent directory. Also best-effort deletes the orphaned Claude Code
    /// session folder(s) the worktree's own cwd would have created — a removed worktree
    /// leaves ~/.claude/projects/<slug> behind otherwise. Two slug candidates because
    /// Claude Code's own slugging (both '/' and '.' become '-') differs from Paths.slug
    /// (only '/') for any path containing ".claude/worktrees" — see WorktreeScanner.merge.
    public static func remove(worktreePath: String, force: Bool = false) async -> (ok: Bool, message: String) {
        let parent = (worktreePath as NSString).deletingLastPathComponent
        let r = await git(["worktree", "remove"] + (force ? ["--force"] : []) + [worktreePath], at: parent)
        if r.ok {
            for slug in Set([Paths.slug(for: URL(filePath: worktreePath)), WorktreeScanner.claudeSlug(for: worktreePath)]) {
                try? FileManager.default.removeItem(at: Paths.projectsRoot.appending(path: slug))
            }
        }
        return (r.ok, r.err)
    }

    /// Merge the project's base branch into a task worktree. Does NOT fetch — the fetch is the
    /// caller's (the UI control's), which keeps this purely local and its tests offline.
    ///
    /// Order matters: "already merging" is checked BEFORE the dirty gate, because a conflicted
    /// worktree is also dirty and must never be reported as merely dirty.
    public static func updateFromBase(worktreePath: String, baseRef: String) async -> WorktreeUpdateOutcome {
        // 1. Already mid-merge? Report it and attempt nothing.
        if await git(["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], at: worktreePath).ok {
            let unmerged = await unmergedPaths(worktreePath)
            return unmerged.isEmpty
                ? .failed("A merge is already in progress — commit or abort it first")
                : .conflicted(unmerged)
        }
        // 2. Tracked changes? Refuse. Untracked files alone do NOT block: git aborts on its
        //    own if one would be overwritten, which lands in step 5 as .failed with git's
        //    explanation of which file is in the way. Counting the same non-"??" lines as
        //    WorktreeInfo.trackedDirtyCount keeps the disabled button and this refusal aligned.
        let st = await git(["status", "--porcelain", "--untracked-files=no"], at: worktreePath)
        let tracked = st.out.split(separator: "\n", omittingEmptySubsequences: true).count
        if tracked > 0 { return .dirty(tracked) }
        // 3-5. Merge, then decide by HEAD sha — NOT by matching "Already up to date", which
        //      git localizes.
        let before = await head(worktreePath)
        let m = await git(["merge", "--no-edit", baseRef], at: worktreePath)
        if m.ok {
            let after = await head(worktreePath)
            return before == after ? .upToDate : .merged
        }
        let unmerged = await unmergedPaths(worktreePath)
        if !unmerged.isEmpty { return .conflicted(unmerged) }
        let err = m.err.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = m.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(err.isEmpty ? (out.isEmpty ? "git merge failed" : out) : err)
    }

    /// `git merge --abort`. Matches the (ok, message) convention of `unlock`/`remove`.
    public static func abortMerge(worktreePath: String) async -> (ok: Bool, message: String) {
        let r = await git(["merge", "--abort"], at: worktreePath); return (r.ok, r.err)
    }

    private static func unmergedPaths(_ dir: String) async -> [String] {
        let r = await git(["diff", "--name-only", "--diff-filter=U"], at: dir)
        return r.out.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func head(_ dir: String) async -> String {
        await git(["rev-parse", "HEAD"], at: dir).out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ponytail: write counterpart to WorktreeInspector.git — mutates state on purpose.
    // Returns exit-ok plus captured stdout/stderr so the UI can show git's own error text.
    private static func git(_ args: [String], at dir: String) async -> (ok: Bool, out: String, err: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(filePath: "/usr/bin/env")
                p.arguments = ["git", "-C", dir] + args
                let outPipe = Pipe(); let errPipe = Pipe()
                p.standardOutput = outPipe; p.standardError = errPipe
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: (false, "", "spawn failed: \(error.localizedDescription)")); return
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (
                    p.terminationStatus == 0,
                    String(data: outData, encoding: .utf8) ?? "",
                    String(data: errData, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}
