import Foundation

/// "Brainstorm in herdr" for a plan or spec: a Claude session in a new herdr pane with the
/// document attached and the prompt typed but **not sent** — the person adds their ask and
/// presses Return. `TaskRunner.openBrainstormAgent` types it with `pane send-text`, which writes
/// literal text with no Enter (verified against herdr 0.8.2: the draft sits in Claude's input,
/// the agent stays idle).
public enum DocumentBrainstorm {
    /// One agent per document, so a second click focuses the conversation already under way
    /// instead of typing the draft into it again. Passed through `Herdr.agentName`: herdr caps
    /// names at 32 characters, and a plan's slug is often longer than that on its own.
    public static func agentName(noun: String, tag: String) -> String {
        Herdr.agentName("brainstorm-\(noun)-\(tag)")
    }

    /// The draft, on ONE line: `send-text` types characters, so a newline would press Return and
    /// send it. The document goes in as an `@path` mention — Claude Code attaches the file's
    /// contents when the prompt is sent — and the draft ends at "My ask: ", where the cursor waits.
    public static func draft(noun: String, path: String) -> String {
        let oneLine = path.components(separatedBy: .newlines).joined(separator: " ")
        return "Brainstorm this \(noun) with me: @\(oneLine) — read it, then think it through with me "
            + "before changing anything. My ask: "
    }
}
