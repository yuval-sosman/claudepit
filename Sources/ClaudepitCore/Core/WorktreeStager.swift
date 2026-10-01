import Foundation

/// A file in `git status`, split by staged (index) vs unstaged (worktree) state.
/// Reuses `ChangedFile.Change` for the badge/color mapping.
public struct StagedFile: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let change: ChangedFile.Change
    public let staged: Bool
    public let unstaged: Bool
    public let untracked: Bool
    /// A staged rename's (or copy's) source path. Unstaging or discarding a rename has to touch
    /// both paths: resetting only the new one leaves the old path's deletion staged.
    public var origPath: String?
    /// Unmerged — a merge (or a conflicted stash pop) is waiting for this file to be resolved.
    /// A conflicted file is in NEITHER list: `staged` and `unstaged` are both false. Its index
    /// holds the two sides, not a staged version, so neither list's actions apply to it.
    public var conflict: MergeConflictKind?
    /// Lines added/removed in the index (vs HEAD) and in the working tree (vs the index).
    public var stagedStat: LineStat?
    public var unstagedStat: LineStat?

    public init(path: String, change: ChangedFile.Change, staged: Bool, unstaged: Bool, untracked: Bool,
                origPath: String? = nil, conflict: MergeConflictKind? = nil,
                stagedStat: LineStat? = nil, unstagedStat: LineStat? = nil) {
        self.path = path; self.change = change
        self.staged = staged; self.unstaged = unstaged; self.untracked = untracked
        self.origPath = origPath; self.conflict = conflict
        self.stagedStat = stagedStat; self.unstagedStat = unstagedStat
    }

    /// Every path git has to be told about to act on this file as one change.
    public var allPaths: [String] { origPath.map { [$0, path] } ?? [path] }
}

/// `git diff --numstat`'s count for one file. A binary file has no line counts.
public struct LineStat: Equatable, Sendable {
    public let added: Int
    public let removed: Int
    public let binary: Bool
    public init(added: Int, removed: Int, binary: Bool = false) {
        self.added = added; self.removed = removed; self.binary = binary
    }
}

/// An unmerged path's two-letter `git status` code, by what each side did to it. "Current" is
/// this branch (ours), "incoming" the branch being merged in (theirs) — for "Update from main",
/// main.
public enum MergeConflictKind: String, Sendable, CaseIterable {
    case bothModified = "UU", bothAdded = "AA", bothDeleted = "DD"
    case addedByUs = "AU", addedByThem = "UA", deletedByUs = "DU", deletedByThem = "UD"

    public var summary: String {
        switch self {
        case .bothModified: "Changed on both sides"
        case .bothAdded: "Added on both sides"
        case .bothDeleted: "Deleted on both sides"
        case .addedByUs: "Added on this branch only"
        case .addedByThem: "Added by the incoming branch only"
        case .deletedByUs: "Deleted on this branch, changed by the incoming branch"
        case .deletedByThem: "Changed on this branch, deleted by the incoming branch"
        }
    }

    /// One side deleted it: there are no conflict markers to resolve, only keep-or-delete.
    public var isDeletion: Bool { [.bothDeleted, .deletedByUs, .deletedByThem].contains(self) }
}

/// The repository facts the Source Control sheet shows beside its file list.
public struct ChangeContext: Equatable, Sendable {
    /// The checked-out branch, or "detached at <sha>"; nil when unknown.
    public var branch: String?
    /// `MERGE_HEAD` exists: the next commit finishes a merge.
    public var merging: Bool
    /// git's prepared merge message (`MERGE_MSG`, comment lines dropped), to prefill the commit.
    public var mergeMessage: String?
    public init(branch: String? = nil, merging: Bool = false, mergeMessage: String? = nil) {
        self.branch = branch; self.merging = merging; self.mergeMessage = mergeMessage
    }
}

/// Which side of a conflict to take a whole file from (`git checkout --ours/--theirs`).
public enum ConflictSide: Sendable { case current, incoming }

/// A version of a file that git stores — the last commit's or the index's — for showing a binary
/// file (an image) before and after.
public enum StoredVersion: Sendable { case head, index }

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
    /// `updateFromBaseStashing` only: the base merge LANDED, but restoring the stashed work
    /// conflicted in these paths. The stash entry is kept — git only drops it on a clean pop
    /// (verified: a conflicted `stash pop` exits 1 and prints "The stash entry is kept") — so
    /// nothing is lost even if the user walks away.
    case stashConflicted([String])
    /// git's own stderr (or stdout when stderr is empty).
    case failed(String)
}

/// The ONLY place that mutates git state (WorktreeInspector stays read-only).
/// Shells out to `git -C <dir> …`; every op returns (ok, message) so the UI
/// can surface failures.
public enum WorktreeStager {

    // MARK: - Pure parser

    /// Parse `git status --porcelain=v1 -z`. Record = "XY <path>\0"; X = index,
    /// Y = worktree. A rename/copy (R/C) is followed by a second \0 field: its source path.
    /// An unmerged pair (UU, AA, DU, …) is a conflict, in neither list.
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
            // Read as staged + unstaged, an unmerged file showed as "M" in BOTH lists, its staged
            // diff was "* Unmerged path" and its unstaged one a combined diff no block could apply.
            if let kind = MergeConflictKind(rawValue: String([x, y])) {
                let change: ChangedFile.Change = kind.isDeletion ? .deleted
                    : (kind == .bothModified ? .modified : .added)
                out.append(StagedFile(path: path, change: change, staged: false, unstaged: false,
                                      untracked: false, conflict: kind))
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
            var origPath: String?
            if x == "R" || x == "C" || y == "R" || y == "C" {
                i += 1
                if i < fields.count { origPath = fields[i] }
            }
            out.append(StagedFile(path: path, change: change,
                                  staged: staged, unstaged: unstaged, untracked: false, origPath: origPath))
            i += 1
        }
        return out
    }

    /// Parse `git diff --numstat -z`, keyed by (new) path. A record is "added\tremoved\tpath\0";
    /// a rename leaves the path empty and follows it with "old\0new\0". A binary file counts "-".
    static func parseNumstatZ(_ raw: String) -> [String: LineStat] {
        let fields = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var out: [String: LineStat] = [:]
        var i = 0
        while i < fields.count {
            let parts = fields[i].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { i += 1; continue }
            var path = parts.count > 2 ? parts[2] : ""
            if path.isEmpty {
                guard i + 2 < fields.count else { break }
                path = fields[i + 2]
                i += 3
            } else {
                i += 1
            }
            let binary = parts[0] == "-" || parts[1] == "-"
            out[path] = LineStat(added: Int(parts[0]) ?? 0, removed: Int(parts[1]) ?? 0, binary: binary)
        }
        return out
    }

    /// An untracked file's whole content counts as added. Read straight off disk — git has no
    /// numstat for a file it doesn't track. Large files are not read, and say nothing.
    static func untrackedStat(_ url: URL) -> LineStat? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size <= 4 << 20, let data = try? Data(contentsOf: url) else { return nil }
        if data.prefix(8000).contains(0) { return LineStat(added: 0, removed: 0, binary: true) }
        var lines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        if let last = data.last, last != 0x0A { lines += 1 }
        return LineStat(added: lines, removed: 0)
    }

    /// git's prepared merge message without its "# Conflicts:" comment block.
    static func cleanMergeMessage(_ raw: String) -> String? {
        let kept = raw.components(separatedBy: "\n").filter { !$0.hasPrefix("#") }
        let text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// `git checkout` / `add` / `reset` take any number of paths; split very long lists so one
    /// call never nears the argument-length limit.
    static func chunks(_ paths: [String], of size: Int = 400) -> [[String]] {
        stride(from: 0, to: paths.count, by: size).map { Array(paths[$0..<min($0 + size, paths.count)]) }
    }

    // MARK: - Async git (mutating)

    /// Every changed file, untracked folders expanded to their files (`-uall`), with line counts.
    public static func status(at dir: String) async -> [StagedFile] {
        let files = parseStatusV1(await git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: dir).out)
        guard !files.isEmpty else { return [] }
        let unstagedStats = parseNumstatZ(await git(["diff", "--numstat", "-z"], at: dir).out)
        let stagedStats = parseNumstatZ(await git(["diff", "--cached", "-M", "--numstat", "-z"], at: dir).out)
        return files.map { f in
            var f = f
            if f.conflict != nil { return f }
            if f.untracked {
                f.unstagedStat = untrackedStat(URL(filePath: dir).appending(path: f.path))
            } else {
                if f.staged { f.stagedStat = stagedStats[f.path] }
                if f.unstaged { f.unstagedStat = unstagedStats[f.path] }
            }
            return f
        }
    }

    /// One side of a file's diff. A staged rename diffs both paths, so git shows it as a rename
    /// with only its edits rather than as a whole new file; a conflict diffs against HEAD — what
    /// the merge commit will change on this branch — since its index holds no single version.
    public static func diff(at dir: String, file: StagedFile, staged: Bool) async -> String {
        if file.conflict != nil { return await git(["diff", "HEAD", "--", file.path], at: dir).out }
        if staged, let orig = file.origPath {
            return await git(["diff", "--cached", "-M", "--", orig, file.path], at: dir).out
        }
        return await diff(at: dir, path: file.path, staged: staged, untracked: file.untracked)
    }

    public static func diff(at dir: String, path: String, staged: Bool, untracked: Bool = false) async -> String {
        if untracked {
            // A path RELATIVE to the worktree, so the patch names the file as git does. `-C`
            // resolves it from any cwd (verified). An absolute path made "Stage Block" add an index
            // entry at "Users/…/file" — a phantom file — instead of staging this one. Exit 1 is
            // normal here: --no-index exits 1 when the files differ.
            return await git(["diff", "--no-index", "--", "/dev/null", path], at: dir).out
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

    /// Stage several files in one `git add -A` per chunk. `-A` so a deleted file stages its deletion.
    public static func stageFiles(at dir: String, _ files: [StagedFile]) async -> (ok: Bool, message: String) {
        await eachChunk(files.flatMap(\.allPaths)) { await git(["add", "-A", "--"] + $0, at: dir) }
    }

    /// Unstage several files — both paths of a rename, or its old path's deletion stays staged.
    public static func unstageFiles(at dir: String, _ files: [StagedFile]) async -> (ok: Bool, message: String) {
        await eachChunk(files.flatMap(\.allPaths)) { await git(["reset", "-q", "HEAD", "--"] + $0, at: dir) }
    }

    /// Throw away unstaged changes — the working tree goes back to the index. An untracked file
    /// moves to the Trash (`toTrash`), since git holds no copy of it to restore.
    public static func discardFile(at dir: String, path: String, untracked: Bool, toTrash: Bool = true) async -> (ok: Bool, message: String) {
        if untracked { return remove(path, in: dir, toTrash: toTrash) }
        let r = await git(["checkout", "--", path], at: dir); return (r.ok, r.err)
    }

    /// `discardFile` for several files: one `git checkout` for the tracked ones, the Trash for the rest.
    public static func discardFiles(at dir: String, _ files: [StagedFile], toTrash: Bool = true) async -> (ok: Bool, message: String) {
        var failures: [String] = []
        let tracked = files.filter { !$0.untracked }.map(\.path)
        let r = await eachChunk(tracked) { await git(["checkout", "--"] + $0, at: dir) }
        if !r.ok { failures.append(r.message) }
        for f in files where f.untracked {
            let r = remove(f.path, in: dir, toTrash: toTrash)
            if !r.ok { failures.append(r.message) }
        }
        return failures.isEmpty ? (true, "") : (false, failures.joined(separator: "\n"))
    }

    /// Throw away ALL of a file's changes, staged and unstaged, back to HEAD — what Discard means
    /// on a Staged row. (`git checkout -- path` restores from the index, so on a staged file it
    /// was a silent no-op.) A file HEAD doesn't have (added, or a rename's new path) is unstaged
    /// and moved to the Trash; a rename's old path comes back from HEAD.
    public static func discardAllChanges(at dir: String, file: StagedFile, toTrash: Bool = true) async -> (ok: Bool, message: String) {
        if file.untracked { return remove(file.path, in: dir, toTrash: toTrash) }
        if file.change == .added || file.origPath != nil {
            if let orig = file.origPath {
                let r = await git(["checkout", "HEAD", "--", orig], at: dir)
                if !r.ok { return (false, r.err) }
            }
            let r = await git(["rm", "-q", "--cached", "-f", "--", file.path], at: dir)
            if !r.ok { return (false, r.err) }
            let onDisk = FileManager.default.fileExists(atPath: URL(filePath: dir).appending(path: file.path).path)
            return onDisk ? remove(file.path, in: dir, toTrash: toTrash) : (true, "")
        }
        let r = await git(["checkout", "HEAD", "--", file.path], at: dir); return (r.ok, r.err)
    }

    /// `path` as git stores it at `version`, copied byte for byte to a temp file (named with the
    /// file's extension, so an image loader recognises it); nil when git has no such version.
    public static func storedCopy(at dir: String, path: String, _ version: StoredVersion) async -> URL? {
        let ext = (path as NSString).pathExtension
        let out = FileManager.default.temporaryDirectory
            .appending(path: "claudepit-sc-\(UUID().uuidString)\(ext.isEmpty ? "" : ".\(ext)")")
        // `git show` writes the blob to stdout, which `Subprocess` reads as text — fine for a diff,
        // ruinous for a PNG — so the shell sends the bytes straight to the file. Every path goes in
        // as an argument, never into the script.
        let script = #"exec git -C "$1" show "$2" > "$3""#
        let ref = version == .head ? "HEAD:\(path)" : ":\(path)"
        guard let r = await Subprocess.run("/bin/sh", ["-c", script, "sh", dir, ref, out.path], timeout: 60), r.ok else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }

    // MARK: Conflicts

    /// Mark conflicts resolved: stage what is on disk, or the deletion when the file is gone
    /// (`git add` refuses a path that no longer exists).
    public static func markResolved(at dir: String, _ files: [StagedFile]) async -> (ok: Bool, message: String) {
        let root = URL(filePath: dir)
        let present = files.filter { FileManager.default.fileExists(atPath: root.appending(path: $0.path).path) }
        let gone = files.filter { !FileManager.default.fileExists(atPath: root.appending(path: $0.path).path) }
        var failures: [String] = []
        let a = await eachChunk(present.map(\.path)) { await git(["add", "--"] + $0, at: dir) }
        if !a.ok { failures.append(a.message) }
        let d = await eachChunk(gone.map(\.path)) { await git(["rm", "-q", "--"] + $0, at: dir) }
        if !d.ok { failures.append(d.message) }
        return failures.isEmpty ? (true, "") : (false, failures.joined(separator: "\n"))
    }

    /// Replace a conflicted file with one side's whole version. It stays conflicted until it is
    /// marked resolved, so the person sees the result first. Fails (git's words) when that side
    /// has no version — it deleted the file.
    public static func takeSide(at dir: String, path: String, _ side: ConflictSide) async -> (ok: Bool, message: String) {
        let r = await git(["checkout", side == .current ? "--ours" : "--theirs", "--", path], at: dir)
        return (r.ok, r.err)
    }

    /// Resolve a conflict by deleting the file (index and disk).
    public static func deleteConflicted(at dir: String, path: String) async -> (ok: Bool, message: String) {
        let r = await git(["rm", "-q", "-f", "--", path], at: dir); return (r.ok, r.err)
    }

    /// Branch, and whether a merge is waiting to be committed (with git's prepared message).
    public static func context(at dir: String) async -> ChangeContext {
        var c = ChangeContext()
        let branch = await git(["symbolic-ref", "--short", "-q", "HEAD"], at: dir)
        if branch.ok, !branch.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            c.branch = branch.out.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let sha = await git(["rev-parse", "--short", "HEAD"], at: dir).out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { c.branch = "detached at \(sha)" }
        }
        c.merging = await git(["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], at: dir).ok
        if c.merging {
            // A linked worktree's MERGE_MSG lives in its own git dir, not `<dir>/.git/`.
            let rel = await git(["rev-parse", "--git-path", "MERGE_MSG"], at: dir).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !rel.isEmpty {
                let url = rel.hasPrefix("/") ? URL(filePath: rel) : URL(filePath: dir).appending(path: rel)
                c.mergeMessage = (try? String(contentsOf: url, encoding: .utf8)).flatMap(cleanMergeMessage)
            }
        }
        return c
    }

    // MARK: Helpers

    private static func remove(_ path: String, in dir: String, toTrash: Bool) -> (ok: Bool, message: String) {
        let url = URL(filePath: dir).appending(path: path)
        do {
            if toTrash { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            else { try FileManager.default.removeItem(at: url) }
            return (true, "")
        } catch {
            return (false, "\(toTrash ? "Couldn't move \(path) to the Trash" : "Couldn't delete \(path)"): \(error.localizedDescription)")
        }
    }

    /// Run `op` over the paths in chunks, keeping every failure's message.
    private static func eachChunk(_ paths: [String],
                                  _ op: ([String]) async -> (ok: Bool, out: String, err: String)) async -> (ok: Bool, message: String) {
        var failures: [String] = []
        for chunk in chunks(paths) {
            let r = await op(chunk)
            if !r.ok { failures.append(gitMessage(r, fallback: "git failed")) }
        }
        return failures.isEmpty ? (true, "") : (false, failures.joined(separator: "\n"))
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

    /// `updateFromBase`, but a dirty tree no longer refuses: stash the tracked changes, merge,
    /// then restore them. This is the one-click answer to the dead end the plain path leaves —
    /// "3 uncommitted changes — commit or discard first" is the single most common state of a
    /// task worktree that is mid-implement and drifting behind its base.
    ///
    /// **Every failure path restores the worktree to exactly its prior state.** A conflicted base
    /// merge aborts and pops, so the user is never left holding both a half-merge and a stash —
    /// that is a worse dead end than the one this exists to remove, and the Claude merge agent is
    /// the answer for that case.
    ///
    /// Untracked files are deliberately NOT stashed (no `-u`): they never blocked `updateFromBase`
    /// either, and a task worktree's `.claude/commands/*` are git-excluded, so `-u` would sweep
    /// them for nothing.
    public static func updateFromBaseStashing(worktreePath: String, baseRef: String) async -> WorktreeUpdateOutcome {
        // 1. Already mid-merge? Same verdict as the plain path, and attempt nothing.
        if await git(["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], at: worktreePath).ok {
            let unmerged = await unmergedPaths(worktreePath)
            return unmerged.isEmpty
                ? .failed("A merge is already in progress — commit or abort it first")
                : .conflicted(unmerged)
        }
        // 2. Nothing tracked to stash → this IS the plain path. One behaviour for the clean case
        //    means no caller ever has to decide which function to call.
        let st = await git(["status", "--porcelain", "--untracked-files=no"], at: worktreePath)
        if st.out.split(separator: "\n", omittingEmptySubsequences: true).isEmpty {
            return await updateFromBase(worktreePath: worktreePath, baseRef: baseRef)
        }
        // 3. Stash. The exit code cannot be trusted: `git stash push` with nothing to save prints
        //    "No local changes to save" and exits **0** (verified). Compare the stash ref instead
        //    — if it did not move, nothing was saved and popping later would restore the WRONG
        //    entry (or fail), so refuse before touching the branch.
        let stashBefore = await stashRef(worktreePath)
        let push = await git(["stash", "push", "--message", "claudepit: update from \(baseRef)"], at: worktreePath)
        let stashAfter = await stashRef(worktreePath)
        guard stashAfter != stashBefore, stashAfter != nil else {
            return .failed(gitMessage(push, fallback: "git stash push saved nothing — the worktree was left untouched"))
        }
        // 4. Merge. Decide by HEAD sha, never by matching "Already up to date" (git localizes it).
        let before = await head(worktreePath)
        let m = await git(["merge", "--no-edit", baseRef], at: worktreePath)
        guard m.ok else {
            // Restore exactly: abort the half-merge, then put the user's work back.
            let unmerged = await unmergedPaths(worktreePath)
            _ = await git(["merge", "--abort"], at: worktreePath)
            let pop = await git(["stash", "pop"], at: worktreePath)
            if !pop.ok {
                return .failed(gitMessage(pop, fallback: "the merge was aborted but your stashed changes could not be restored — they are safe in `git stash list`"))
            }
            if !unmerged.isEmpty { return .conflicted(unmerged) }
            return .failed(gitMessage(m, fallback: "git merge failed"))
        }
        let after = await head(worktreePath)
        // 5. Restore. A conflicted pop KEEPS the stash entry, so the user's work survives even if
        //    they abandon the conflict half-resolved.
        let pop = await git(["stash", "pop"], at: worktreePath)
        if !pop.ok {
            let unmerged = await unmergedPaths(worktreePath)
            if !unmerged.isEmpty { return .stashConflicted(unmerged) }
            return .failed(gitMessage(pop, fallback: "merged \(baseRef), but your stashed changes could not be restored — they are safe in `git stash list`"))
        }
        return before == after ? .upToDate : .merged
    }

    /// The current stash tip, or nil when the stash is empty.
    private static func stashRef(_ dir: String) async -> String? {
        let r = await git(["rev-parse", "--quiet", "--verify", "refs/stash"], at: dir)
        let sha = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.ok && !sha.isEmpty) ? sha : nil
    }

    /// git's own words for a failure — stderr, else stdout, else the caller's fallback.
    private static func gitMessage(_ r: (ok: Bool, out: String, err: String), fallback: String) -> String {
        let err = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? fallback : out
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

    /// A stuck-process backstop, not a latency budget: `commit` runs the repo's own hooks, and a
    /// pre-commit hook that runs a test suite can legitimately take minutes.
    static let gitCeiling: TimeInterval = 1800

    // ponytail: write counterpart to WorktreeInspector.git — mutates state on purpose.
    // Returns exit-ok plus captured stdout/stderr so the UI can show git's own error text.
    // Through `Subprocess`: the hand-rolled copy read stdout to the end before touching stderr,
    // so a git that filled the stderr pipe first (a chatty hook) deadlocked the button forever.
    private static func git(_ args: [String], at dir: String) async -> (ok: Bool, out: String, err: String) {
        guard let r = await Subprocess.run("/usr/bin/env", ["git", "-C", dir] + args, timeout: gitCeiling) else {
            return (false, "", "could not launch git")
        }
        let err = r.timedOut ? "git \(args.first ?? "") did not finish in \(Int(gitCeiling / 60)) minutes" : r.stderr
        return (r.ok, r.stdout, err)
    }
}
