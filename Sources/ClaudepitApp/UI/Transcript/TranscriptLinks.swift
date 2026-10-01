import SwiftUI
import ClaudepitCore

/// A small always-visible link on a row: tinted, labelled, outside the row's toggle.
struct RowLinkButton: View {
    let title: String
    let icon: String
    var isOn = false
    var tint: Color = .accentColor
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(title)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(isOn ? 0.24 : (hover ? 0.17 : 0.09)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// "Ask" and "Plans" on any row about a plan file: ask Claude about the plan right here, or open
/// it on the Plans page. A plan file that has since been deleted says so instead of offering
/// links that lead nowhere.
struct PlanLinks: View {
    let path: String
    /// The row's id; the Q&A panel's open state is kept beside the row's own.
    let id: String
    let actions: TranscriptActions
    @ObservedObject var expansion: TranscriptExpansion

    var body: some View {
        if let open = actions.openPlan {
            if FileManager.default.fileExists(atPath: path) {
                HStack(spacing: 4) {
                    let asking = expansion.isPanelOpen(PlanQASlot.key(id))
                    RowLinkButton(title: "Ask", icon: asking ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.text.bubble.right",
                                  isOn: asking, help: asking ? "Close the questions about this plan" : "Ask Claude about this plan") {
                        expansion.togglePanel(PlanQASlot.key(id))
                        if !asking { expansion.requestReveal(PlanQASlot.key(id)) }
                    }
                    // The Plans page lists ~/.claude/plans only; a plan kept elsewhere (a custom
                    // plans directory) would land on nothing.
                    if path.hasPrefix(Paths.plansRoot.path + "/") {
                        RowLinkButton(title: "Plans", icon: Icon.jump,
                                      help: "Show \(TranscriptFormat.fileName(path)) on the Plans page") { open(path) }
                    }
                }
            } else {
                Text("plan file deleted")
                    .font(TranscriptStyle.caption).foregroundStyle(.tertiary)
                    .help("\(TranscriptFormat.path(path)) no longer exists, so it can't be opened in Plans")
            }
        }
    }
}

/// The inline "ask about this plan" conversation, right under the title line of the row whose
/// Ask link opened it. It starts compact and grows with the conversation, and its question
/// field takes focus as it opens.
struct PlanQASlot: View {
    let path: String
    let id: String
    let actions: TranscriptActions
    @ObservedObject var expansion: TranscriptExpansion

    static func key(_ id: String) -> String { id + "/qa" }

    var body: some View {
        if actions.openPlan != nil, expansion.isPanelOpen(Self.key(id)),
           let content = try? String(contentsOfFile: path, encoding: .utf8) {
            // Focus only on the click that opened it (its reveal is still pending then) — not
            // each time the lazy list rebuilds the row, which would steal the search field's focus.
            PlanQAPanel(planContent: content, cwd: actions.cwd, growsWithContent: true,
                        focusOnAppear: expansion.reveal == Self.key(id))
                .frame(maxHeight: 380)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.12)))
                .padding(.leading, 30).padding(.trailing, 6).padding(.top, 2).padding(.bottom, 8)
                .background(alignment: .top) {
                    // What the transcript scrolls into view as the panel opens: the panel plus
                    // room below it for the floating "End"/"Latest" button, which would
                    // otherwise land on the Send button.
                    Color.clear.id(Self.key(id)).padding(.bottom, -44)
                }
        }
    }
}
