import SwiftUI
import AppKit
import ClaudepitCore

/// Which of the Source Control sheet's lists a row is in. A partly staged file is in two.
enum ChangeList: String {
    case conflicts, staged, changes

    var title: String {
        switch self { case .conflicts: "MERGE CONFLICTS"; case .staged: "STAGED CHANGES"; case .changes: "CHANGES" }
    }

    init(_ ref: ChangeSelection) { self = ref.conflicted ? .conflicts : (ref.staged ? .staged : .changes) }
}

/// "+12 −3" for a file or a block; "binary" when git counts no lines.
struct LineStatText: View {
    let stat: LineStat?
    var font: Font = .caption2.monospacedDigit()

    var body: some View {
        if let stat {
            if stat.binary {
                Text("binary").font(font).foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 4) {
                    if stat.added > 0 { Text("+\(stat.added)").foregroundStyle(TranscriptStyle.added.opacity(0.9)) }
                    if stat.removed > 0 { Text("−\(stat.removed)").foregroundStyle(TranscriptStyle.removed.opacity(0.9)) }
                }
                .font(font)
            }
        }
    }
}

/// The conflicted row's status letter — "!" in the badge column, the kind on hover.
struct ConflictMark: View {
    let kind: MergeConflictKind
    var body: some View {
        Text("!").font(.caption2.monospaced().bold()).foregroundStyle(.red).frame(width: 14)
            .help("Conflict — \(kind.summary.lowercased())")
    }
}

/// One file in a list. Its stage / discard buttons replace its line counts while the row is
/// hovered or selected, so a long list reads as names and sizes rather than a wall of icons; the
/// same actions are in the row's right-click menu and on Space / ⌫.
struct SourceControlFileRow<Menu: View>: View {
    let file: StagedFile
    let list: ChangeList
    let name: String
    /// Under a folder heading in the tree layout.
    let indent: CGFloat
    let isSelected: Bool
    let listFocused: Bool
    let busy: Bool
    let onSelect: () -> Void
    /// Stage, unstage, or (a conflict) mark resolved.
    let onPrimary: () -> Void
    /// nil for a conflict — its resolutions live in the diff panel.
    let onDiscard: (() -> Void)?
    @ViewBuilder let menu: () -> Menu

    @State private var hovering = false

    private var stat: LineStat? { list == .staged ? file.stagedStat : file.unstagedStat }
    private var showActions: Bool { hovering || isSelected }
    private var idSuffix: String { "\(list.rawValue)-\(file.path)" }

    var body: some View {
        HStack(spacing: 6) {
            // A Button, not a tap gesture: synthetic clicks reach a Button but never a bare
            // TapGesture. The stage/discard icons sit beside it, not inside it.
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    if let kind = file.conflict { ConflictMark(kind: kind) } else { ChangeBadge(change: file.change) }
                    Text(name)
                        .font(.caption.monospaced())
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .layoutPriority(1)
                    if let orig = file.origPath {
                        Text("← \((orig as NSString).lastPathComponent)")
                            .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(helpText)
            .debugFrame("sc-row-\(idSuffix)")

            ZStack(alignment: .trailing) {
                LineStatText(stat: stat).opacity(showActions ? 0 : 1)
                HStack(spacing: 6) {
                    switch list {
                    case .conflicts:
                        icon("checkmark.circle", "Mark Resolved (Space)", onPrimary).debugFrame("sc-row-primary-\(idSuffix)")
                    case .staged:
                        icon("minus.circle", "Unstage (Space)", onPrimary).debugFrame("sc-row-primary-\(idSuffix)")
                    case .changes:
                        icon("plus.circle", "Stage (Space)", onPrimary).debugFrame("sc-row-primary-\(idSuffix)")
                    }
                    if let onDiscard {
                        icon("arrow.uturn.backward.circle",
                             list == .staged ? "Discard all its changes (⌫)" : "Discard (⌫)", onDiscard)
                            .debugFrame("sc-row-discard-\(idSuffix)")
                    }
                }
                .opacity(showActions ? 1 : 0)
                .allowsHitTesting(showActions)
            }
            .fixedSize()
        }
        .padding(.leading, 10 + indent).padding(.trailing, 10).padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(listFocused ? 0.2 : 0.12) : (hovering ? Color.white.opacity(0.04) : .clear),
                    in: RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 4)
        .onHover { hovering = $0 }
        .contextMenu { menu() }
    }

    private var helpText: String {
        var parts = [file.path]
        if let orig = file.origPath { parts.append("Renamed from \(orig)") }
        if let kind = file.conflict { parts.append(kind.summary) }
        return parts.joined(separator: "\n")
    }

    private func icon(_ system: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: system).font(.caption).foregroundStyle(.secondary) }
            .buttonStyle(.plain).help(help).disabled(busy)
    }
}

/// A list's heading: its name, count, and actions on the whole list.
struct SourceControlGroupHeader<Actions: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.caption2).fontWeight(.bold).foregroundStyle(.secondary).tracking(0.6)
            Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            Spacer()
            HStack(spacing: 10) { actions() }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
    }
}

/// A full-width message strip under the header: an error, a confirmation that something worked,
/// or the merge in progress.
struct SourceControlBanner<Trailing: View>: View {
    enum Tone { case error, success, warning }
    let tone: Tone
    let text: String
    var onDismiss: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    private var color: Color {
        switch tone { case .error: .red; case .success: TranscriptStyle.added; case .warning: .orange }
    }
    private var icon: String {
        switch tone {
        case .error: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "arrow.triangle.merge"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).font(.caption)
            Text(text).font(.caption).foregroundStyle(tone == .error ? color : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing()
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(color.opacity(0.08))
    }
}

extension SourceControlBanner where Trailing == EmptyView {
    init(tone: Tone, text: String, onDismiss: (() -> Void)? = nil) {
        self.init(tone: tone, text: text, onDismiss: onDismiss) { EmptyView() }
    }
}

/// A small accent-coloured text button — the hunk and file actions.
struct SourceControlTextButton: View {
    let title: String
    var role: ButtonRole? = nil
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(title, role: role, action: action).buttonStyle(.plain).font(.caption2.weight(.medium))
            .foregroundStyle(role == .destructive ? Color.red.opacity(0.9) : Color.accentColor)
            .disabled(busy)
    }
}

/// Unsent commit messages by worktree, so closing the sheet (Esc is one key away) doesn't throw
/// one away. In memory only: a draft outlives the sheet, not the app.
@MainActor
enum CommitDrafts {
    static var store: [String: String] = [:]
}

#if DEBUG
/// The interaction harness can't click an alert's button, so it sets this: every confirmation
/// reports its title here and runs as if confirmed.
private struct AutoConfirmKey: EnvironmentKey {
    static let defaultValue: (@Sendable (String) -> Void)? = nil
}
/// What the sheet is showing, for the interaction harness to assert on — a SwiftUI view's
/// `@State` can't be read from outside, and a reported frame outlives the view that drew it.
struct SourceControlProbeState: Equatable, Sendable {
    var focused: ChangeSelection?
    var files: [StagedFile]
    /// The selection the diff panel's rows belong to (nil while loading).
    var diffRef: ChangeSelection?
    var hunks: Int
    var conflicts: Int?
    /// Image versions shown for a binary file (before and/or after).
    var images: Int
    var commitMessage: String
    var merging: Bool
    var notice: String?
    var error: String?
    var busy: Bool
}

private struct ProbeKey: EnvironmentKey {
    static let defaultValue: (@Sendable (SourceControlProbeState) -> Void)? = nil
}

extension EnvironmentValues {
    var sourceControlAutoConfirm: (@Sendable (String) -> Void)? {
        get { self[AutoConfirmKey.self] }
        set { self[AutoConfirmKey.self] = newValue }
    }
    var sourceControlProbe: (@Sendable (SourceControlProbeState) -> Void)? {
        get { self[ProbeKey.self] }
        set { self[ProbeKey.self] = newValue }
    }
}
#endif
