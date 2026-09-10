import SwiftUI
import ClaudepitCore
#if canImport(AppKit)
import AppKit
#endif

struct LoopsSection: View {
    @ObservedObject var app: AppState
    @State private var showAddSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Loops").font(.title2).bold()
                Spacer()
                Button { showAddSheet = true } label: {
                    Image(systemName: Icon.addCircle)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Add loop")

                Button { app.reloadLoops() } label: {
                    Image(systemName: Icon.refresh)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh loops")
            }

            if app.loops.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(app.loops) { entry in
                            LoopRow(entry: entry) { app.deleteLoop(entry) }
                        }
                    }
                }
            }
        }
        .onAppear { app.reloadLoops() }
        .sheet(isPresented: $showAddSheet) {
            AddLoopSheet(app: app)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No active loops")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Use /loop in Claude Code to schedule recurring tasks.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

private struct LoopRow: View {
    let entry: CronEntry
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.intervalLabel)
                .font(.caption.monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(Color.blue)
                .frame(minWidth: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.prompt)
                    .font(.body)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(entry.cron)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(entry.createdAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !entry.recurring {
                        Text("· one-shot")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Menu {
                fileContextMenu(url: entry.sourcePath)
                Divider()
                Button(role: .destructive) { onDelete() } label: {
                    Label("Delete Loop", systemImage: "trash")
                }
            } label: {
                Image(systemName: Icon.moreActions).font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("Loop actions")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.white.opacity(isHovered ? 0.06 : 0.04), in: RoundedRectangle(cornerRadius: 10))
        .onHover { isHovered = $0 }
    }
}

// MARK: - Add Loop Sheet

struct AddLoopSheet: View {
    @ObservedObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    enum ScheduleMode: String, CaseIterable { case interval = "Interval", cron = "Cron" }

    @State private var mode: ScheduleMode = .interval
    @State private var prompt: String = ""
    @State private var isLoading = false
    @State private var error: String? = nil

    // Interval mode
    @State private var intervalValue: String = "10"
    @State private var intervalUnit: String = "m"

    // Cron mode — individual fields
    @State private var cronMinute: String = "*"
    @State private var cronHour: String = "*"
    @State private var cronDay: String = "*"
    @State private var cronMonth: String = "*"
    @State private var cronWeekday: String = "*"

    private let units = ["s", "m", "h", "d"]
    private let unitLabels = ["s": "seconds", "m": "minutes", "h": "hours", "d": "days"]

    private var intervalString: String {
        (intervalValue.isEmpty ? "10" : intervalValue) + intervalUnit
    }

    private var cronString: String {
        "\(cronMinute.isEmpty ? "*" : cronMinute) \(cronHour.isEmpty ? "*" : cronHour) \(cronDay.isEmpty ? "*" : cronDay) \(cronMonth.isEmpty ? "*" : cronMonth) \(cronWeekday.isEmpty ? "*" : cronWeekday)"
    }

    private var intervalValid: Bool {
        guard let n = Int(intervalValue), n > 0 else { return false }
        return units.contains(intervalUnit)
    }

    private var cronValid: Bool {
        let parts = cronString.split(separator: " ")
        return parts.count == 5
    }

    private var scheduleValid: Bool {
        mode == .interval ? intervalValid : cronValid
    }

    private var canSchedule: Bool {
        scheduleValid && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
    }

    private var humanReadable: String {
        if mode == .interval {
            let n = intervalValue.isEmpty ? "10" : intervalValue
            let label = unitLabels[intervalUnit] ?? intervalUnit
            return "Every \(n) \(label)"
        } else {
            return "Cron: \(cronString)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.2)
            VStack(alignment: .leading, spacing: 16) {
                scheduleSection
                promptSection
                if let err = error {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
            Divider().opacity(0.1)
            footer
        }
        .frame(minWidth: 520, minHeight: 380)
        .background(.ultraThinMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .font(.system(size: 15)).foregroundStyle(.blue)
            Text("New Loop").font(.headline)
            Spacer()
            modeToggle
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var modeToggle: some View {
        HStack(spacing: 2) {
            ForEach(ScheduleMode.allCases, id: \.self) { m in
                Button { mode = m } label: {
                    Text(m.rawValue)
                        .font(.caption).fontWeight(mode == m ? .semibold : .regular)
                        .foregroundStyle(mode == m ? .primary : .secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(mode == m ? Color.accentColor.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Schedule section

    @ViewBuilder
    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if mode == .interval {
                intervalEditor
            } else {
                cronEditor
            }
            Text(humanReadable)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
    }

    private var intervalEditor: some View {
        HStack(spacing: 10) {
            TextField("10", text: $intervalValue)
                .textFieldStyle(.plain)
                .font(.title3.monospaced())
                .multilineTextAlignment(.center)
                .frame(width: 72)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(intervalValid || intervalValue.isEmpty
                                  ? Color.white.opacity(0.12) : Color.red.opacity(0.5)))

            // Unit picker
            HStack(spacing: 4) {
                ForEach(units, id: \.self) { u in
                    Button { intervalUnit = u } label: {
                        Text(u)
                            .font(.callout.monospaced())
                            .fontWeight(intervalUnit == u ? .semibold : .regular)
                            .foregroundStyle(intervalUnit == u ? Color.blue : .secondary)
                            .frame(width: 32, height: 32)
                            .background(intervalUnit == u ? Color.blue.opacity(0.15) : Color.white.opacity(0.04),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var cronEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                cronField("Min", text: $cronMinute, hint: "0-59 or *")
                cronField("Hour", text: $cronHour, hint: "0-23 or *")
                cronField("Day", text: $cronDay, hint: "1-31 or *")
                cronField("Month", text: $cronMonth, hint: "1-12 or *")
                cronField("Weekday", text: $cronWeekday, hint: "0-6 or *")
            }
            HStack(spacing: 6) {
                Text("Quick:").font(.caption2).foregroundStyle(.secondary)
                cronPreset("Every hour",   m: "0",    h: "*", d: "*", mo: "*", wd: "*")
                cronPreset("Daily 9am",    m: "0",    h: "9", d: "*", mo: "*", wd: "*")
                cronPreset("Weekdays 9am", m: "0",    h: "9", d: "*", mo: "*", wd: "1-5")
                cronPreset("Every 30m",    m: "*/30", h: "*", d: "*", mo: "*", wd: "*")
            }
        }
    }

    private func cronField(_ label: String, text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField(hint, text: text)
                .textFieldStyle(.plain)
                .font(.callout.monospaced())
                .multilineTextAlignment(.center)
                .frame(minWidth: 52)
                .padding(.horizontal, 6).padding(.vertical, 6)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.10)))
        }
    }

    private func cronPreset(_ label: String, m: String, h: String, d: String, mo: String, wd: String) -> some View {
        Button(label) {
            cronMinute = m; cronHour = h; cronDay = d; cronMonth = mo; cronWeekday = wd
        }
        .buttonStyle(.plain)
        .font(.caption2)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
        .foregroundStyle(.secondary)
    }

    // MARK: - Prompt section

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Prompt").font(.caption).foregroundStyle(.secondary)
            TextField("What should Claude do each run? e.g. \"check CI status and report failures\"", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(4...8)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)
                .padding(.trailing, 8)

            if isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scheduling…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            } else {
                Button("Schedule Loop") { schedule() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(!canSchedule)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    // MARK: - Action

    private func schedule() {
        let pr = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pr.isEmpty, scheduleValid else { return }
        let iv = mode == .interval ? intervalString : cronString
        isLoading = true
        error = nil
        do {
            try app.addLoop(interval: iv, prompt: pr)
            dismiss()
        } catch CronError.invalidInterval(let s) {
            error = "Invalid interval: \(s)"
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }
}
