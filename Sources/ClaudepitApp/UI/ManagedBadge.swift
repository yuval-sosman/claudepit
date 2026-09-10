import SwiftUI
import ClaudepitCore

/// Marks a settings entry that Claudepit installs and re-asserts on every launch, so an edit made
/// in place would be silently reverted. Clicking it deep-links to the owning card in App Settings
/// via the one-shot focus field (no nav history — see CLAUDE.md "Cross-Section Deep Links").
///
/// Teal, to sit apart from the scope palette (global blue / project green / local orange /
/// plugin purple) — this is an ownership marker, not a precedence one.
struct ManagedBadge: View {
    let owner: ManagedConfig
    @ObservedObject var app: AppState

    var body: some View {
        Button {
            app.focusManagedConfigID = owner.id
            app.selected = .appConfig
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "gearshape.2").font(.system(size: 9, weight: .bold))
                Text("Claudepit").font(.caption2).bold()
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.teal.opacity(0.22), in: Capsule())
            .foregroundStyle(Color.teal)
        }
        .buttonStyle(.plain)
        .help("Installed by Claudepit — edits here are overwritten. Click to manage.")
    }
}
