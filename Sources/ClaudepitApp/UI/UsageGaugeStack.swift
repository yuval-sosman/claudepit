import SwiftUI
import ClaudepitCore

/// The `/usage` limit bars — Session (5h), Week (all models), and one per model-scoped weekly
/// window — in the one visual language every surface that shows them uses.
///
/// Shared by Home's Claude Code card and the menu bar panel. The rows themselves come from
/// `UsageSnapshot.gauges`, so the two surfaces cannot disagree about labels, order, or coloring;
/// this only decides how big they are drawn.
struct UsageGaugeStack: View {
    let gauges: [UsageGauge]
    /// Menu bar sizing: smaller type and a thinner bar, for a 320pt panel rather than a card.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 9 : 12) {
            if gauges.isEmpty {
                Text("No window data in the cache.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(gauges) { row($0) }
            }
        }
    }

    private func row(_ gauge: UsageGauge) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(gauge.label).font(compact ? .caption : .subheadline).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(gauge.percent)%")
                    .font((compact ? Font.caption : .subheadline).monospacedDigit().weight(.semibold))
                    .foregroundStyle(UsageGaugeStack.tint(gauge.level))
            }
            UsageBar(fraction: gauge.fraction, tint: UsageGaugeStack.tint(gauge.level),
                     height: compact ? 4 : 6)
            if let resetsAt = gauge.resetsAt {
                // The CLI prints "Resets Sep 14 at 12am (Asia/Jerusalem)"; the absolute stamp is
                // already in local time here, so the timezone name would be noise.
                Text("resets \(resetsAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
                     + " · \(resetsAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    static func tint(_ level: UsageWindow.Level) -> Color {
        switch level {
        case .normal:   return .accentColor
        case .warning:  return .orange
        case .critical: return .red
        }
    }
}

/// A capsule track that reads at a glance where the stock linear `ProgressView` all but vanishes
/// on the dark glass background. Also used for the per-model share bars in the Stats section.
struct UsageBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                if fraction > 0 {
                    Capsule().fill(tint)
                        .frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
                }
            }
        }
        .frame(height: height)
    }
}
