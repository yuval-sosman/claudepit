import Foundation

/// Reconciles Claudepit's own hook registrations inside a `settings.json` hooks array.
///
/// The registered command embeds an absolute path (`bash '/Users/<me>/.claude/claudepit-*.sh'`),
/// so a checkout that moves between machines — or is shared with someone else — carries
/// registrations pointing at a home directory that no longer exists. Matching on the exact
/// command string would treat those as unrelated and append a second entry beside them,
/// leaving one dead hook per machine that fails with exit 127 on every fire.
///
/// So identity is the script *filename*, not the full path: any registration naming one of
/// our scripts is ours to replace, whatever home it points at. Nothing is persisted about
/// "this machine" — the current home is re-derived on each launch, which keeps the checkout
/// portable rather than pinning it to whoever ran it first.
public enum HookRegistration {

    /// True when `command` invokes the managed script `scriptName`, from any home directory.
    public static func isManaged(_ command: String, scriptName: String) -> Bool {
        command.contains(scriptName)
    }

    /// Drop every registration of `scriptName` from `entries`, whatever home path it points at.
    ///
    /// Hooks belonging to someone else are preserved even when they share an entry with ours;
    /// an entry is removed outright only once it has no hooks left.
    public static func prune(_ entries: [[String: Any]],
                             scriptName: String) -> (entries: [[String: Any]], removed: Int) {
        var out: [[String: Any]] = []
        var removed = 0
        for entry in entries {
            guard let hooks = entry["hooks"] as? [[String: Any]] else { out.append(entry); continue }
            let kept = hooks.filter { !isManaged(($0["command"] as? String) ?? "", scriptName: scriptName) }
            removed += hooks.count - kept.count
            if kept.isEmpty { continue }
            var e = entry
            e["hooks"] = kept
            out.append(e)
        }
        return (out, removed)
    }

    /// Prune stale registrations of `scriptName` and leave `command` registered exactly once.
    ///
    /// `changed` is false when the input was already exactly right, so callers can skip the
    /// write — which makes repeated launches idempotent instead of reshuffling the file.
    public static func reconcile(_ entries: [[String: Any]],
                                 scriptName: String,
                                 command: String,
                                 matcher: String = "*") -> (entries: [[String: Any]], changed: Bool) {
        let exactMatches = entries.reduce(0) { acc, entry in
            acc + ((entry["hooks"] as? [[String: Any]]) ?? [])
                .filter { ($0["command"] as? String) == command }.count
        }
        let (pruned, removed) = prune(entries, scriptName: scriptName)
        var out = pruned
        out.append(["matcher": matcher, "hooks": [["type": "command", "command": command]]])
        // Already correct iff the sole managed hook we pruned was this exact command sitting
        // alone in its own entry — in which case the re-append restores the original count.
        let changed = !(removed == 1 && exactMatches == 1 && out.count == entries.count)
        return (out, changed)
    }
}
