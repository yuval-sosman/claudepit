import SwiftUI
import ClaudepitCore

/// Home's Claude Code card: how close the account is to its limits — the CLI's `/usage` panel
/// (limit gauges, usage-credits state, and the "What's contributing to your limits usage?"
/// insights from the print-mode report), with the CLI version beside the header.
///
/// Only limits live here. What the work cost is Home's Usage card (counted from transcripts,
/// per project or for all of them), and the year of activity is the Activity card — this card
/// used to repeat both from the CLI's stats cache (per-model tokens, tokens per day, token
/// totals), which put the same questions on Home twice with different numbers.
///
/// Data comes from the caches the CLI keeps in `~/.claude.json` plus the app-persisted report
/// text; Refresh runs `/usage` non-interactively to rewrite them. State lives on `AppState` — a
/// section's `@State` dies on every section switch, and an in-flight refresh would be orphaned.
struct HomeLimitsCard: View {
    @ObservedObject var app: AppState

    @State private var failure: String?
    /// Collapsed by default — the insights are reference material, not glanceable status.
    /// Cosmetic only, so `@State` is fine: re-entering Home resets it to collapsed, which is
    /// exactly the default the user asked for.
    @State private var insightsExpanded = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let snap = app.usageSnapshot {
                    gaugeStack(snap)
                    creditsLine(snap)
                } else {
                    Text("No usage data yet — Refresh runs `/usage` to fetch it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let report = app.usageReport, !report.windows.isEmpty {
                    collapsibleSectionHeader("What's using your limits", expanded: $insightsExpanded)
                    if insightsExpanded { insightsStack(report) }
                }
                if let failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                footer
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Header + refresh

    private var header: some View {
        HStack(spacing: 8) {
            Text("Claude Code").font(.headline)
            if let version = app.claudeVersion {
                Text("v\(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { refresh() } label: {
                if app.isRefreshingUsage {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: Icon.refresh).font(.caption)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(app.isRefreshingUsage || signedOut)
            .help(signedOut ? "Sign in first — /usage needs a logged-in CLI"
                            : "Run /usage to refresh the cached numbers")
        }
    }

    private var signedOut: Bool { app.claudeAuth?.needsSignIn == true }

    private func refresh() {
        failure = nil
        Task {
            let result = await app.refreshUsage()
            if result.failed { failure = result.text }
        }
    }

    /// Same look as `sectionHeader`, but the whole row toggles `expanded`.
    private func collapsibleSectionHeader(_ title: String, expanded: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.15)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(expanded.wrappedValue ? .degrees(90) : .zero)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded.wrappedValue ? "Collapse" : "Expand")
        }
    }

    // MARK: - Limits

    /// One visual language for every window — the two headline gauges and the model-scoped
    /// weekly rows all render the same labeled bar, so the card reads as one list. The rows and
    /// the drawing both live in `UsageGaugeStack`, shared with the menu bar panel.
    private func gaugeStack(_ snap: UsageSnapshot) -> some View {
        UsageGaugeStack(gauges: snap.gauges)
    }

    @ViewBuilder private func creditsLine(_ snap: UsageSnapshot) -> some View {
        if let extra = snap.extraUsage {
            Text(extra.isEnabled
                 ? "Usage credits: on" + (extra.utilization.map { " · \($0)% used" } ?? "")
                 : "Usage credits are off")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Contributing insights

    private func insightsStack(_ report: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(report.windows) { window in insightBlock(window) }
        }
    }

    private func insightBlock(_ window: UsageReport.InsightWindow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.label).font(.caption.weight(.semibold))
                if window.requests != nil || window.sessions != nil {
                    Text([window.requests.map { "\($0) requests" },
                          window.sessions.map { "\($0) sessions" }]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(window.behaviors, id: \.self) { behavior in
                Text("•  \(behavior)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !window.topSkills.isEmpty { rankedTable("Skills", window.topSkills) }
            if !window.topSubagents.isEmpty { rankedTable("Subagents", window.topSubagents) }
        }
    }

    /// The CLI renders these as an aligned two-column table ("Skills   % of usage") — a wrapped
    /// prose line loses that scanability, so each item gets its own name/percent row.
    private func rankedTable(_ title: String, _ items: [UsageReport.RankedItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            ForEach(items, id: \.name) { item in
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("\(item.percent)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 4) {
            if let snap = app.usageSnapshot {
                Text("updated \(snap.fetchedAt.formatted(.relative(presentation: .named)))")
                    .foregroundStyle(snap.isStale() ? Color.orange : Color.secondary)
            }
        }
        .font(.caption2)
    }}
