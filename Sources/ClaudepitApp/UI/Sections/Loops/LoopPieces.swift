import SwiftUI
import ClaudepitCore

// Pieces the Loops page's cards share: how a state looks, the cadence badge, countdowns, and the
// fire timeline drawn on both the overview and a loop's own card.

extension LoopState {
    var color: Color {
        switch self {
        case .scheduled: .green
        case .running: .blue
        case .blocked: .red
        case .due: .orange
        case .paused: .yellow
        case .missed, .failed, .notRunning: .orange
        case .external: .purple
        case .completed, .cancelled, .stopped, .lapsed, .expired: .secondary
        }
    }

    var icon: String {
        switch self {
        case .scheduled: "clock"
        case .due: "hourglass"
        case .running: "play.circle.fill"
        case .blocked: "hand.raised.fill"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        case .cancelled: "xmark.circle"
        case .stopped: "stop.circle"
        case .lapsed: "moon.zzz"
        case .missed: "exclamationmark.circle"
        case .expired: "calendar.badge.exclamationmark"
        case .failed: "exclamationmark.triangle"
        case .notRunning: "pause.rectangle"
        case .external: "desktopcomputer"
        }
    }

    /// What the state means, for its tooltip.
    var explanation: String {
        switch self {
        case .scheduled: "Its session is open; it fires at its next time, when the session is idle"
        case .due: "Its time has come — it fires as soon as the session finishes its current turn"
        case .running: "Its iteration is the turn running in the session right now"
        case .blocked: "Its session stopped on a permission prompt or a question — nothing fires until you answer it"
        case .paused: "Its session closed. Resuming the session brings it back (cron loops only, until they expire)"
        case .completed: "A one-time task that fired and deleted itself"
        case .cancelled: "Cancelled"
        case .stopped: "Claude ended this self-paced loop — the work was done or couldn't progress"
        case .lapsed: "Ended without being stopped: Claude didn't re-arm it, or its session closed"
        case .missed: "Its time passed while nothing could fire it"
        case .expired: "Recurring loops last 7 days; this one reached the limit"
        case .failed: "Claude Code rejected the request to schedule it"
        case .notRunning: "Saved, but nothing will run it as things stand"
        case .external: "Managed by the Claude Desktop app"
        }
    }
}

extension LoopRecord.Kind {
    var icon: String {
        switch self {
        case .recurring: "arrow.triangle.2.circlepath"
        case .oneShot: "alarm"
        case .selfPaced: "dial.medium"
        case .durable: "doc.badge.clock"
        case .desktop: "desktopcomputer"
        }
    }
}

/// The list's cadence chip: "5m", "auto", "once", in the state's colour.
struct LoopBadge: View {
    let record: LoopRecord

    var body: some View {
        let color = record.state.isActive ? record.state.color : Color.secondary
        Text(record.badge)
            .font(.system(size: 10.5, weight: .semibold).monospaced())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: 44, height: 20)
            .foregroundStyle(color)
            .background(color.opacity(record.state.isActive ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                if record.state == .running || record.state == .due || record.state == .blocked {
                    Circle().fill(record.state.color).frame(width: 6, height: 6).offset(x: 2, y: -2)
                }
            }
            .help("\(record.kind.label) · \(record.cadence)")
    }
}

enum LoopTime {
    /// "in 4m 12s", "in 3h 5m", "now".
    static func until(_ date: Date, now: Date) -> String {
        let s = date.timeIntervalSince(now)
        if s < 1 { return "now" }
        return "in " + LoopCadence.duration(s.rounded(.up))
    }

    /// "4m ago", "2h 10m ago".
    static func ago(_ date: Date, now: Date) -> String {
        let s = now.timeIntervalSince(date)
        if s < 5 { return "just now" }
        return LoopCadence.duration(s) + " ago"
    }

    /// "14:32:05" today, "Oct 2, 09:03" otherwise.
    static func clock(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? (TranscriptFormat.clock(date.timeIntervalSince1970) ?? "")
            : (TranscriptFormat.dayClock(date.timeIntervalSince1970) ?? "")
    }

    /// The list row's time phrase: when it fires next, or when it ended.
    static func phrase(_ r: LoopRecord, now: Date) -> String {
        if r.state == .running { return r.lastFire.map { "since \(ago($0.time, now: now).replacingOccurrences(of: " ago", with: ""))" } ?? "starting" }
        if r.state == .paused {
            // It can't fire until the session is resumed; a one-shot says when it would.
            if let next = r.nextFire { return "if resumed, fires \(clock(next, now: now))" }
            return "closed \(ago(r.lastActivity, now: now))"
        }
        if r.state.isActive || r.kind == .durable, let next = r.nextFire {
            if next <= now { return "due \(ago(next, now: now))" }
            return (r.nextFireIsEstimate ? "~" : "") + until(next, now: now)
        }
        if let ended = r.endedAt { return ago(ended, now: now) }
        return ago(r.lastActivity, now: now)
    }
}

// MARK: - Timeline

/// One row of the timeline: a loop's past fires (solid), its projected fires (hollow), and the
/// window its next fire may land in (the task's jitter).
struct LoopTimelineLane: Identifiable {
    let id: String
    var title: String
    var color: Color
    var past: [Date] = []
    var future: [Date] = []
    var windows: [DateInterval] = []
    /// The next fire is an estimate (a self-paced loop's fallback).
    var estimate = false
}

/// Fires against a time axis — the overview's "next hours" across loops, and a loop's own
/// recent past and near future. Plain Canvas drawing: lanes, hour ticks, a "now" line.
struct LoopTimeline: View {
    let lanes: [LoopTimelineLane]
    let window: DateInterval
    let now: Date
    var laneHeight: CGFloat = 20
    var labelWidth: CGFloat = 0
    var onSelect: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                if labelWidth > 0 {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lanes) { lane in
                            Button { onSelect?(lane.id) } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(lane.color).frame(width: 6, height: 6)
                                    Text(lane.title).font(.caption).lineLimit(1).truncationMode(.tail)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: labelWidth - 8, height: laneHeight, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(onSelect == nil)
                            .help(lane.title)
                        }
                    }
                    .frame(width: labelWidth, alignment: .leading)
                }
                Canvas { ctx, size in draw(ctx, size) }
                    .frame(height: max(laneHeight, laneHeight * CGFloat(lanes.count)))
            }
            axis
        }
    }

    private var axis: some View {
        GeometryReader { geo in
            let width = geo.size.width - labelWidth
            ForEach(ticks(), id: \.self) { t in
                Text(t.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .position(x: labelWidth + x(t, width: width), y: 6)
            }
        }
        .frame(height: 12)
    }

    private func x(_ d: Date, width: CGFloat) -> CGFloat {
        let span = window.duration
        guard span > 0 else { return 0 }
        return CGFloat(d.timeIntervalSince(window.start) / span) * width
    }

    /// Tick marks at a round step giving 4–8 of them.
    private func ticks() -> [Date] {
        let steps: [TimeInterval] = [300, 600, 900, 1800, 3600, 7200, 10_800, 21_600, 43_200, 86_400]
        let step = steps.first { window.duration / $0 <= 8 } ?? 86_400
        let first = (window.start.timeIntervalSince1970 / step).rounded(.up) * step
        return stride(from: first, through: window.end.timeIntervalSince1970, by: step).map { Date(timeIntervalSince1970: $0) }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width
        for t in ticks() {
            let px = x(t, width: w)
            ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: 0)); $0.addLine(to: CGPoint(x: px, y: size.height)) },
                       with: .color(.white.opacity(0.06)), lineWidth: 1)
        }
        for (i, lane) in lanes.enumerated() {
            let midY = laneHeight * (CGFloat(i) + 0.5)
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: midY)); $0.addLine(to: CGPoint(x: w, y: midY)) },
                       with: .color(.white.opacity(0.08)), lineWidth: 1)
            for win in lane.windows where win.end > window.start && win.start < window.end {
                let x0 = max(0, x(win.start, width: w)), x1 = min(w, x(win.end, width: w))
                let rect = CGRect(x: x0, y: midY - 5, width: max(2, x1 - x0), height: 10)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(lane.color.opacity(0.18)))
            }
            // A frequent loop over a long window would draw one smear of overlapping rings: dots
            // shrink to fit the closest pair, down to a point.
            let xs = (lane.past + lane.future).filter { window.contains($0) }.map { x($0, width: w) }.sorted()
            let gap = zip(xs, xs.dropFirst()).map { $1 - $0 }.filter { $0 > 0.5 }.min() ?? .infinity
            let r = min(4, max(1.25, gap * 0.36))
            for d in lane.past where window.contains(d) {
                let c = CGRect(x: x(d, width: w) - r * 0.9, y: midY - r * 0.9, width: r * 1.8, height: r * 1.8)
                ctx.fill(Path(ellipseIn: c), with: .color(lane.color.opacity(0.85)))
            }
            for (j, d) in lane.future.enumerated() where window.contains(d) {
                let c = CGRect(x: x(d, width: w) - r, y: midY - r, width: r * 2, height: r * 2)
                var style = StrokeStyle(lineWidth: r < 2.5 ? 1 : 1.5)
                if lane.estimate && j == 0 { style.dash = [2, 2] }
                ctx.stroke(Path(ellipseIn: c), with: .color(lane.color), style: style)
            }
        }
        if window.contains(now) {
            let px = x(now, width: w)
            ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: 0)); $0.addLine(to: CGPoint(x: px, y: size.height)) },
                       with: .color(.accentColor.opacity(0.9)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
        }
    }
}

/// A small explained fact: label column, value, optional detail underneath.
struct LoopFactRow<Value: View>: View {
    let label: String
    var detail: String? = nil
    @ViewBuilder var value: () -> Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.caption).foregroundStyle(.tertiary).frame(width: 78, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                value()
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A callout explaining a state, with an optional action — the top of a loop's card.
struct LoopCallout<Actions: View>: View {
    let icon: String
    let color: Color
    let title: String
    var text: String? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                if let text {
                    Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                actions()
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.28), lineWidth: 1))
    }
}

extension LoopCallout where Actions == EmptyView {
    init(icon: String, color: Color, title: String, text: String? = nil) {
        self.init(icon: icon, color: color, title: title, text: text) { EmptyView() }
    }
}

/// One of the dialog's or the overview's notes: icon by level, text, fix buttons.
struct LoopNoteRow: View {
    let note: LoopPreview.Note
    var apply: ((LoopPreview.Fix) -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon).font(.system(size: 10.5)).foregroundStyle(color).frame(width: 14)
            VStack(alignment: .leading, spacing: 4) {
                Text(note.text).font(.caption).foregroundStyle(note.level == .info ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let apply, !note.fixes.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(note.fixes.enumerated()), id: \.offset) { _, fix in
                            Button(fix.label) { apply(fix.fix) }
                                .buttonStyle(.bordered).controlSize(.mini)
                                .debugFrame("loop-fix-\(fix.label)")
                        }
                    }
                }
            }
        }
    }

    private var icon: String {
        switch note.level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch note.level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
