import SwiftUI
import ClaudepitCore

struct DiscoverSheet: View {
    @ObservedObject var app: AppState
    let projectSlug: String
    @Environment(\.dismiss) private var dismiss

    enum Timeframe: String, CaseIterable {
        case oneWeek = "1w"
        case twoWeeks = "2w"
        case oneMonth = "1m"
        case threeMonths = "3m"
        case all = "All"

        var since: Date {
            let now = Date()
            switch self {
            case .oneWeek:      return now.addingTimeInterval(-7 * 86400)
            case .twoWeeks:     return now.addingTimeInterval(-14 * 86400)
            case .oneMonth:     return now.addingTimeInterval(-30 * 86400)
            case .threeMonths:  return now.addingTimeInterval(-90 * 86400)
            case .all:          return Date(timeIntervalSince1970: 0)
            }
        }
    }

    @State private var query: String = ""
    @State private var timeframe: Timeframe = .twoWeeks
    @State private var results: [DiscoverResult] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var hasSearched = false
    @State private var expandedResultIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.2)
            VStack(spacing: 12) {
                // A sheet covers ContentView, so the window-wide banner is invisible
                // behind it — and this sheet is the one modal that spawns `claude -p`.
                if app.claudeAuth?.needsSignIn == true { ClaudeSignInBanner(app: app) }
                queryField
                if let err = errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
            Divider().opacity(0.1)
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 520, minHeight: 400)
        .background(.ultraThinMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 15)).foregroundStyle(Color.accentColor)
            Text("Discover sessions")
                .font(.headline)
            Spacer()
            timeframePicker
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var timeframePicker: some View {
        HStack(spacing: 2) {
            ForEach(Timeframe.allCases, id: \.self) { tf in
                Button {
                    timeframe = tf
                } label: {
                    Text(tf.rawValue)
                        .font(.caption).fontWeight(timeframe == tf ? .semibold : .regular)
                        .foregroundStyle(timeframe == tf ? .primary : .secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(timeframe == tf ? Color.accentColor.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Query Field

    private var queryField: some View {
        HStack(spacing: 8) {
            Image(systemName: Icon.search).foregroundStyle(.secondary)
            TextField("What were you working on? e.g. \"auth bug fix\"…", text: $query)
                .textFieldStyle(.plain)
                .onSubmit { runSearch() }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: Icon.clearField).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        if isLoading {
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if hasSearched && results.isEmpty {
            emptyResultsState
        } else if !results.isEmpty {
            resultList
        } else {
            emptyIdleState
        }
    }

    private var emptyIdleState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Describe what you were working on")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Press Enter to search your last \(timeframe.rawValue) of sessions")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyResultsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.magnifyingglass")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No matching sessions found")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Try a different query or expand the timeframe")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultList: some View {
        ScrollView {
            VStack(spacing: 2) {
                Text("\(results.count) session\(results.count == 1 ? "" : "s") found")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 8)
                ForEach(results) { result in
                    resultRow(result)
                }
            }
            .padding(.bottom, 12)
        }
    }

    // MARK: - Result Row

    private func resultRow(_ result: DiscoverResult) -> some View {
        let session = app.sessions.first(where: { $0.id == result.id })
        let isExpanded = expandedResultIDs.contains(result.id)
        let bullets = session?.bulletSummary?.bullets ?? []

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // Expand chevron — only shown when bullets exist
                if !bullets.isEmpty {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                } else {
                    Spacer().frame(width: 12)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(session?.title ?? result.id)
                        .font(.subheadline).bold().lineLimit(1)
                    Text(result.reason)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    if let s = session {
                        Text(relative(s.modifiedAt))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    scoreDots(result.score)
                }

                // Open session button
                Button {
                    if session != nil {
                        app.focusSessionID = result.id
                        app.selected = .sessions
                        dismiss()
                    }
                } label: {
                    Image(systemName: Icon.jump)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            if isExpanded && !bullets.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").font(.caption2).foregroundStyle(.tertiary)
                            Text(bullet).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 36).padding(.trailing, 14).padding(.bottom, 10)
            }
        }
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !bullets.isEmpty else { return }
            if expandedResultIDs.contains(result.id) {
                expandedResultIDs.remove(result.id)
            } else {
                expandedResultIDs.insert(result.id)
            }
        }
    }

    private func scoreDots(_ score: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Circle()
                    .fill(i < (score + 1) / 2 ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }

    // MARK: - Search

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        errorMessage = nil
        isLoading = true
        hasSearched = false
        Task {
            do {
                let found = try await DiscoverRunner.shared.search(
                    query: q, projectSlug: projectSlug, since: timeframe.since,
                    cwd: app.activePath)
                await MainActor.run {
                    results = found
                    isLoading = false
                    hasSearched = true
                }
            } catch DiscoverError.claudeNotFound {
                await MainActor.run {
                    errorMessage = "claude CLI not found — make sure it's installed and on PATH"
                    isLoading = false
                    hasSearched = true
                }
            } catch DiscoverError.noSummaryData {
                await MainActor.run {
                    results = []
                    isLoading = false
                    hasSearched = true
                }
            } catch DiscoverError.processFailed(let code, let msg) {
                let signedOut = ClaudeAuth.isNotLoggedIn(msg)
                if signedOut { NotificationCenter.default.post(name: .claudeAuthSuspect, object: nil) }
                await MainActor.run {
                    errorMessage = signedOut
                        ? "Claude is signed out — run `\(ClaudeAuth.signInCommand)`."
                        : "claude exited with code \(code): \(msg.prefix(200))"
                    isLoading = false
                    hasSearched = true
                }
            } catch DiscoverError.invalidJSON(let raw) {
                await MainActor.run {
                    errorMessage = "Unexpected response format. Raw: \(raw.prefix(80))…"
                    isLoading = false
                    hasSearched = true
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                    hasSearched = true
                }
            }
        }
    }
}
