import SwiftUI
import ClaudepitCore

/// One session in the list: title, an optional summary line, and one meta line, with a single
/// live-status slot in front and the actions menu showing on hover.
struct SessionRowView<MenuItems: View>: View {
    let session: SessionSummary
    let context: SessionListContext
    let prefs: SessionListPrefs
    /// Recent shows each row's own day in its section header, so the time can be shorter.
    let inDateSection: Bool
    let isSelected: Bool
    let isFocused: Bool
    let isHovered: Bool
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    /// Show only this worktree's sessions.
    var onWorktreeTap: (String) -> Void = { _ in }
    @ViewBuilder let menuItems: () -> MenuItems

    /// The worktree the session ran in (its cwd), or the one it is bound to.
    private var worktree: String? { session.worktreeName ?? context.boundWorktrees[session.id] }

    var body: some View {
        let status = context.status(of: session)
        HStack(alignment: .center, spacing: 6) {
            disclosure.frame(width: 10)
            SessionStatusGlyph(status: status).frame(width: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if prefs.tab == .recent, let g = context.group(of: session) {
                        Circle().fill(g.color.swiftUIColor).frame(width: 7, height: 7)
                            .help("In group “\(g.name)”")
                    }
                    Text(context.title(of: session))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                if prefs.showSummaries, let bullet = session.bulletSummary?.bullets.first {
                    Text(bullet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    if let ref = session.task { PhasePill(label: ref.phaseLabel) }
                    if let wt = worktree {
                        WorktreePill(name: wt) { onWorktreeTap(wt) }
                            .debugFrame("worktree-pill-\(session.id)")
                    }
                    meta.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            Menu { menuItems() } label: {
                Image(systemName: Icon.moreActions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovered || isSelected ? 1 : 0)
            .help("Session actions")
        }
        .padding(.leading, 6).padding(.trailing, 6).padding(.vertical, 6)
        .background(background, in: RoundedRectangle(cornerRadius: 8))
        // A worktree session carries its worktree's colour down its leading edge, so every
        // session of one worktree reads as a set while scanning.
        .overlay(alignment: .leading) {
            if let wt = worktree {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(WorktreePalette.color(for: wt))
                    .frame(width: 3)
                    .padding(.vertical, 5)
            }
        }
        .padding(.horizontal, 6)
        .help(tooltip(status: status))
    }

    /// Always 10pt wide, chevron or not, so every title starts at the same x.
    @ViewBuilder private var disclosure: some View {
        if session.subagents.isEmpty {
            Color.clear.frame(height: 10)
        } else {
            Button(action: onToggleExpand) {
                Image(systemName: Icon.chevronCollapsed)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide subagents" : "Show \(session.subagents.count) subagent\(session.subagents.count == 1 ? "" : "s")")
        }
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(isFocused ? 0.26 : 0.16) }
        if isHovered { return Color.white.opacity(0.05) }
        return .clear
    }

    /// `claudepit · 12m ago · 8 prompts · $3.40 · ✦2 · ⑂ task-x` — one Text so it truncates as one.
    private var meta: Text {
        var parts: [Text] = []
        if context.projectKey == nil { parts.append(Text(session.projectName)) }
        parts.append(Text(SessionTimeLabel.text(for: session.modifiedAt, now: context.now, inDateSection: inDateSection)))
        if let stat = context.stats[session.id] {
            if stat.prompts > 0 { parts.append(Text("\(stat.prompts) prompt\(stat.prompts == 1 ? "" : "s")")) }
            if stat.cost >= 0.005 { parts.append(Text(Money.compact(stat.cost))) }
        }
        if !session.subagents.isEmpty {
            parts.append(Text("\(Image(systemName: "sparkles"))\u{2009}\(session.subagents.count)"))
        }
        return parts.dropFirst().reduce(parts[0]) { $0 + Text(" · ") + $1 }
    }

    private func tooltip(status: SessionLiveStatus) -> String {
        var lines = [context.title(of: session)]
        if let bullets = session.bulletSummary?.bullets, !bullets.isEmpty {
            lines.append(contentsOf: bullets.prefix(4).map { "• \($0)" })
        }
        var facts = ["Last written \(session.modifiedAt.formatted(date: .abbreviated, time: .shortened))",
                     ByteCountFormatter.string(fromByteCount: Int64(session.fileSize), countStyle: .file)]
        if let label = status.label { facts.insert(label, at: 0) }
        if let wt = worktree { facts.append("worktree \(wt)") }
        lines.append(facts.joined(separator: " · "))
        return lines.joined(separator: "\n")
    }
}

/// A subagent under its expanded session.
struct SubagentRowView: View {
    let sub: SubagentSummary
    let isSelected: Bool
    let isFocused: Bool
    let isHovered: Bool

    var body: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 26)
            Image(systemName: "sparkles").font(.caption2).foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text(sub.agentType).font(.caption.weight(.semibold))
                if !sub.description.isEmpty, sub.description != sub.agentType {
                    Text(sub.description).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(isFocused ? 0.26 : 0.16)
                    : isHovered ? Color.white.opacity(0.05) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 6)
        .help("\(sub.agentType) subagent\(sub.description.isEmpty ? "" : " — \(sub.description)")")
    }
}

/// The single live indicator: working (pulsing green), waiting for you (orange hand), open in
/// herdr but idle (terminal), or nothing.
struct SessionStatusGlyph: View {
    let status: SessionLiveStatus

    var body: some View {
        Group {
            switch status {
            case .working: PulsingDot(color: .green)
            case .waiting:
                Image(systemName: "hand.raised.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange)
            case .open:
                Image(systemName: "terminal").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            // Fixed size: a bare Color.clear is flexible and swells to fill its container.
            case .none: Color.clear.frame(width: 7, height: 7)
            }
        }
        .help(status.label ?? "")
    }
}

extension SessionLiveStatus {
    var label: String? {
        switch self {
        case .working: return "Working"
        case .waiting: return "Waiting for you"
        case .open: return "Open in herdr, idle"
        case .none: return nil
        }
    }
}

struct PulsingDot: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .background(Circle().fill(color.opacity(0.35)).scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 1))
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

/// One colour per worktree (stable across launches — `WorktreeLabel.colorIndex`). Soft tones, so
/// none reads as an error (the system pink renders a hot red here), and none near the colours
/// that already mean something in the list: green (working), orange (waiting) and the accent
/// (selection). Phase pills are neutral, so in a row's meta line colour only means "which worktree".
enum WorktreePalette {
    static let colors: [Color] = [
        Color(red: 0.96, green: 0.58, blue: 0.80),   // rose
        Color(red: 0.42, green: 0.80, blue: 0.98),   // sky
        Color(red: 0.98, green: 0.82, blue: 0.38),   // amber
        Color(red: 0.74, green: 0.62, blue: 1.00),   // lavender
        Color(red: 0.55, green: 0.90, blue: 0.80),   // seafoam
    ]

    static func color(for worktree: String) -> Color {
        colors[WorktreeLabel.colorIndex(for: worktree, paletteSize: colors.count)]
    }
}

/// The worktree a session ran in, in that worktree's colour. Clicking it shows only that
/// worktree's sessions.
struct WorktreePill: View {
    let name: String
    let action: () -> Void

    var body: some View {
        let color = WorktreePalette.color(for: name)
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 8, weight: .bold))
                Text(WorktreeLabel.short(name)).lineLimit(1)
            }
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 0.5))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help("Worktree \(name) — click to show only its sessions")
    }
}

struct PhasePill: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(.secondary)
            .background(Color.white.opacity(0.09), in: Capsule())
            .help("Task phase: \(label)")
    }
}

enum SessionTimeLabel {
    nonisolated(unsafe) private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// Under a date header the day is already said: today reads relative ("12 min. ago"),
    /// yesterday as a time, the last week as weekday + time, older as the date. Without one
    /// (the Groups tab), anything before today names its day.
    static func text(for date: Date, now: Date, inDateSection: Bool, calendar: Calendar = .current) -> String {
        let age = now.timeIntervalSince(date)
        if age < 60 { return "now" }
        if calendar.isDate(date, inSameDayAs: now) { return relative.localizedString(for: date, relativeTo: now) }
        let time = date.formatted(date: .omitted, time: .shortened)
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return inDateSection ? time : "Yesterday \(time)" }
        if age < 7 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear ? date.formatted(.dateTime.month(.abbreviated).day())
                        : date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
