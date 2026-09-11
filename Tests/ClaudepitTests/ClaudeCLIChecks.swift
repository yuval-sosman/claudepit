import Foundation
@testable import ClaudepitCore

func claudeCLIChecks() -> [Bool] {
    [
        check("printArgs_isolatesWithoutBreakingAuth") {
            let args = ClaudeCLI.printArgs(claudePath: "/opt/homebrew/bin/claude")
            try expectEqual(args.first, "/opt/homebrew/bin/claude", "binary path leads argv")
            try expect(args.contains("-p"), "missing -p")
            try expect(args.contains("--safe-mode"), "missing --safe-mode")
            try expect(args.contains("--no-session-persistence"), "missing --no-session-persistence")
            // The regression this whole change exists to prevent: --bare disables
            // OAuth/keychain auth, so every call fails with "Not logged in".
            try expect(!args.contains("--bare"), "--bare must never be passed")
        },
        check("printArgs_appendsExtra") {
            let args = ClaudeCLI.printArgs(claudePath: "claude", extra: ["--output-format", "text"])
            try expectEqual(Array(args.suffix(2)), ["--output-format", "text"], "extra args appended")
        },
        check("resumeArgs_shapeAndNoBare") {
            let args = ClaudeCLI.resumeArgs(
                claudePath: "claude", sessionID: "abc-123", command: "/context",
                extra: ["--no-session-persistence"])
            try expectEqual(Array(args.prefix(4)), ["claude", "-r", "abc-123", "-p"], "resume shape")
            try expect(args.contains("--safe-mode"), "missing --safe-mode")
            try expectEqual(args.last, "/context", "slash command goes last")
            try expect(!args.contains("--bare"), "--bare must never be passed")
        },
        check("environment_neverAddsConfigDir") {
            let env = ClaudeCLI.environment(parent: ["USER": "someone", "HOME": "/Users/someone"])
            // Setting CLAUDE_CONFIG_DIR at all — even to the default — switches the
            // keychain lookup to a path-hashed service name that holds no credentials.
            try expect(env["CLAUDE_CONFIG_DIR"] == nil, "must not inject CLAUDE_CONFIG_DIR")
        },
        check("environment_preservesInheritedConfigDirAndUser") {
            let env = ClaudeCLI.environment(
                parent: ["USER": "someone", "CLAUDE_CONFIG_DIR": "/custom/dir"])
            // A user who exports it globally has credentials under that hashed entry;
            // stripping it would break them. We just never add one ourselves.
            try expectEqual(env["CLAUDE_CONFIG_DIR"], "/custom/dir", "inherited value kept")
            // The keychain account name is derived from USER — dropping it fails
            // exactly like being logged out.
            try expectEqual(env["USER"], "someone", "USER preserved")
        },
        check("environment_pathIsAugmentedAndDeduped") {
            let env = ClaudeCLI.environment(parent: ["PATH": "/usr/bin"])
            let path = env["PATH"] ?? ""
            try expect(path.contains("/opt/homebrew/bin"), "fallback dirs added")
            let parts = path.split(separator: ":").map(String.init)
            try expectEqual(parts.count, Set(parts).count, "PATH has duplicate entries")
        },
        check("failureMessage_prefersStderrThenStdout") {
            // An unknown flag reports on stderr...
            try expectEqual(
                ClaudeCLI.failureMessage(stdout: "", stderr: "error: unknown option '--safe-mode'\n"),
                "error: unknown option '--safe-mode'", "stderr used when present")
            // ...but "Not logged in" arrives on stdout with an empty stderr, which is
            // exactly the case the old stderr-only handling threw away.
            try expectEqual(
                ClaudeCLI.failureMessage(stdout: "Not logged in · Please run /login\n", stderr: ""),
                "Not logged in · Please run /login", "stdout used when stderr empty")
            try expectEqual(
                ClaudeCLI.failureMessage(stdout: "out", stderr: "err"), "err", "stderr wins")
            try expectEqual(
                ClaudeCLI.failureMessage(stdout: "  \n", stderr: " "), "", "both blank → empty")
        },
    ]
}
