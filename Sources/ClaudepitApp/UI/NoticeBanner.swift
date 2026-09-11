import SwiftUI
import ClaudepitCore

/// The app's one warning-banner style: a tinted capsule row with an icon, a short
/// message, and optional trailing controls. Extracted from `TasksSection`'s
/// "herdr not found" notice so the auth notice can't drift into a second look.
///
/// Outer padding is deliberately left to the call site — margins are the containing
/// section's business, not the banner's.
struct NoticeBanner<Trailing: View>: View {
    let text: String
    var systemImage: String = "exclamationmark.triangle.fill"
    var tint: Color = .orange
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Label(text, systemImage: systemImage)
                .font(.caption).foregroundStyle(tint)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension NoticeBanner where Trailing == EmptyView {
    init(text: String,
         systemImage: String = "exclamationmark.triangle.fill",
         tint: Color = .orange) {
        self.init(text: text, systemImage: systemImage, tint: tint, trailing: { EmptyView() })
    }
}

/// "claude is signed out" notice with the actions to fix it. Shared so the copy and
/// the fallback behaviour stay identical wherever it appears — the window-wide
/// placement in `ContentView`, and again inside `DiscoverSheet`, since a sheet covers
/// the window and would otherwise hide it.
struct ClaudeSignInBanner: View {
    @ObservedObject var app: AppState

    var body: some View {
        NoticeBanner(text: message) {
            if app.isCheckingClaudeAuth {
                ProgressView().controlSize(.small)
            } else if app.signInNeedsTerminal {
                // No herdr to host an interactive login, and no in-app terminal.
                Button("Copy command") { app.copySignInCommand() }
            } else {
                Button("Sign in") { app.signInToClaude() }
            }
            Button("Recheck") { app.refreshClaudeAuth(force: true) }
        }
        .controlSize(.small)
    }

    private var message: String {
        app.signInNeedsTerminal
            ? "Claude is signed out — run `\(ClaudeAuth.signInCommand)` in a terminal, then Recheck."
            : "Claude is signed out — Ask, Discover and Context need a login."
    }
}
