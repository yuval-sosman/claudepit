import Foundation
@testable import ClaudepitCore

/// Pure-function checks only. Nothing here may call `ClaudeAuth.status()` — the
/// checking machine's login state is not a fixture.
func claudeAuthChecks() -> [Bool] {
    [
        check("decode_loggedIn") {
            let json = """
            {"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty",
             "email":"user@example.com","orgId":"o-1","orgName":"Example Org",
             "subscriptionType":"max"}
            """
            guard let s = ClaudeAuth.decode(stdout: json) else {
                throw CheckFailure(message: "failed to decode logged-in payload")
            }
            try expectEqual(s.state, .loggedIn, "state")
            try expectEqual(s.email, "user@example.com", "email")
            try expectEqual(s.orgName, "Example Org", "orgName")
            try expectEqual(s.subscriptionType, "max", "subscriptionType")
            try expect(s.isLoggedIn && !s.needsSignIn, "logged in must not prompt sign in")
        },
        check("decode_loggedOut") {
            // The CLI exits 1 in this case but still prints this payload, which is why
            // the decode — not the exit code — decides the state.
            let json = #"{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}"#
            guard let s = ClaudeAuth.decode(stdout: json) else {
                throw CheckFailure(message: "failed to decode logged-out payload")
            }
            try expectEqual(s.state, .loggedOut, "state")
            try expect(s.needsSignIn, "logged out must prompt sign in")
            try expect(s.email == nil, "no email when logged out")
        },
        check("decode_apiKeyUserCountsAsLoggedIn") {
            // With ANTHROPIC_API_KEY set the CLI reports loggedIn:true and nulls the
            // account fields — so no special-casing is needed, but the optionals must
            // tolerate explicit nulls.
            let json = """
            {"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty",
             "apiKeySource":"ANTHROPIC_API_KEY","email":null,"orgId":null,
             "orgName":null,"subscriptionType":null}
            """
            guard let s = ClaudeAuth.decode(stdout: json) else {
                throw CheckFailure(message: "failed to decode api-key payload")
            }
            try expectEqual(s.state, .loggedIn, "state")
            try expect(s.email == nil && s.subscriptionType == nil, "null fields decode to nil")
        },
        check("decode_rejectsNonPayload") {
            // Both must be nil so the caller reports .checkFailed rather than telling a
            // user with a too-old CLI that they are signed out.
            try expect(ClaudeAuth.decode(stdout: "") == nil, "empty output")
            try expect(ClaudeAuth.decode(stdout: "   \n ") == nil, "blank output")
            try expect(ClaudeAuth.decode(stdout: "error: unknown command 'auth'") == nil, "old CLI")
            try expect(ClaudeAuth.decode(stdout: #"{"apiProvider":"firstParty"}"# ) == nil,
                       "payload without loggedIn")
        },
        check("isNotLoggedIn_matchesRealMessage") {
            try expect(ClaudeAuth.isNotLoggedIn("Not logged in · Please run /login"),
                       "must match the CLI's actual wording")
            try expect(ClaudeAuth.isNotLoggedIn("OAuth token has expired"), "expired token")
            try expect(!ClaudeAuth.isNotLoggedIn("error: unknown option '--safe-mode'"),
                       "an old CLI is not a logged-out CLI")
            try expect(!ClaudeAuth.isNotLoggedIn(""), "empty is not a sign-out signal")
        },
        check("checkFailedIsNotLoggedOut") {
            let failed = ClaudeAuthStatus(state: .checkFailed("boom"))
            let missing = ClaudeAuthStatus(state: .cliNotFound)
            // Only .loggedOut drives the banner; these two must stay silent.
            try expect(!failed.needsSignIn, "checkFailed must not prompt sign in")
            try expect(!missing.needsSignIn, "cliNotFound must not prompt sign in")
            try expect(!failed.isLoggedIn && !missing.isLoggedIn, "neither is logged in")
        },
    ]
}
