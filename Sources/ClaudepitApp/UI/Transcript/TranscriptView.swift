import SwiftUI
import ClaudepitCore

/// What the transcript can do outside itself — open a subagent, jump into another section.
/// Plain values rather than `AppState`, so the view renders anywhere (the debug snapshot too).
struct TranscriptActions {
    /// Open the subagent an Agent call (by tool-use id) spawned; nil when there's no transcript.
    var openSubagent: ((String) -> Void)? = nil
    var hasSubagent: (String) -> Bool = { _ in false }
    /// Where a skill / agent / MCP call's name links to in the app, if anywhere.
    var sectionLink: (ToolInvocation) -> (() -> Void)? = { _ in nil }
    /// Show a plan file in the Plans section.
    var openPlan: ((String) -> Void)? = nil
    /// Working directory for inline Q&A about a plan.
    var cwd: URL? = nil
}

/// Which rows are open. One store for the whole transcript — row views are recycled as they
/// scroll, so state kept in a row would reset. `mode` is the page's choice of what starts open;
/// `toggled` holds the rows the reader flipped from it.
@MainActor
final class TranscriptExpansion: ObservableObject {
    /// `.edits`: each row as its own default says — file edits open with their diffs, everything
    /// else on one line. `.all`: every row open, folded tool runs and long text included. There is
    /// deliberately no "collapse all": `.edits` is the compact view.
    enum Mode { case edits, all }
    @Published private(set) var mode: Mode = .edits
    @Published private(set) var toggled: Set<String> = []
    /// Panels a row's link opened (a plan's Q&A). Tools, not content — no mode opens them.
    @Published private(set) var panels: Set<String> = []

    func isExpanded(_ id: String, default open: Bool = false) -> Bool {
        (mode == .all || open) != toggled.contains(id)
    }

    func toggle(_ id: String) {
        if toggled.contains(id) { toggled.remove(id) } else { toggled.insert(id) }
    }

    /// Open a row regardless of the mode (a jump into a folded run).
    func open(_ id: String, default d: Bool = false) {
        if !isExpanded(id, default: d) { toggle(id) }
    }

    /// Switch what starts open. Rows the reader flipped by hand go back to the new mode, so
    /// choosing the current mode again is a reset.
    func setMode(_ m: Mode) { mode = m; toggled = [] }

    func isPanelOpen(_ id: String) -> Bool { panels.contains(id) }
    func togglePanel(_ id: String) {
        if panels.contains(id) { panels.remove(id) } else { panels.insert(id) }
    }

    /// A panel that just opened inside a row (a plan's Q&A), for the list to bring into view.
    @Published private(set) var reveal: String?
    func requestReveal(_ id: String) { reveal = id }
    func clearReveal() { reveal = nil }
}

/// Scroll facts the rail and the jump button need. Kept out of `TranscriptView`'s own state so a
/// scroll re-renders those two small views, not the list.
@MainActor
final class TranscriptScrollTracker: ObservableObject {
    @Published var topRowID: String?
    /// The end of the transcript is on screen.
    @Published var atBottom = false
    /// A live view keeps the newest activity in sight only while this holds. The reader
    /// scrolling down into the end, or an explicit jump there (opening a live session, Latest,
    /// the rail's bottom), sets it; scrolling away or following a link elsewhere clears it.
    /// Content arriving below never clears it — that is what it follows.
    ///
    /// Starts **false**. It used to start true and only an upward scroll cleared it, so a session
    /// opened while idle and read from the top down — never scrolled up — was still "following"
    /// when it came alive, and every write threw the reader to the end ("it scrolls down every
    /// few seconds"). `--follow-test` covers both directions.
    var following = false
    /// The reader's hand is on the list (a drag, a swipe still coasting): never move it under them.
    var userScrolling = false
}

struct TranscriptView: View {
    let model: TranscriptModel
    var actions = TranscriptActions()
    /// A live session: follow new activity while the reader is at the bottom.
    var isLive = false

    @State private var filters: Set<TranscriptFilter> = []
    @State private var query = ""
    @State private var appliedQuery = ""
    @State private var rows: [TranscriptRow] = []
    /// The model generation `rows` was computed for. The loader can publish a *shorter* model
    /// (the file was rewritten); rows from the old one would index past its end.
    @State private var rowsGeneration = -1
    @State private var firstResponseIDs: Set<String> = []
    @State private var didInitialScroll = false
    /// A link is landing: the filters it cleared must not send the list back to the top.
    @State private var jumping = false
    @StateObject private var expansion = TranscriptExpansion()
    /// Held, not observed: a scroll updates it many times a second, and only the rail and the
    /// jump button (which observe it themselves) should redraw for that — not the whole list.
    @State private var tracker = TranscriptScrollTracker()
    @FocusState private var searchFocused: Bool

    init(model: TranscriptModel, actions: TranscriptActions = TranscriptActions(), isLive: Bool = false) {
        self.model = model
        self.actions = actions
        self.isLive = isLive
    }

    /// Row to bring to the top once the rows first load (the snapshot tool's `--scroll-to`).
    private var initialScrollID: String?
    /// A row whose rail mark to show hovered (the snapshot tool's `--hover-row`).
    private var railHover: String?
    /// A panel to bring into view after the first scroll, as an Ask click does (`--reveal`).
    private var debugReveal: String?

    #if DEBUG
    /// The snapshot tool's entry: start from a given expansion, filter set, search and position.
    init(model: TranscriptModel, actions: TranscriptActions = TranscriptActions(), snapshotExpansion: TranscriptExpansion,
         snapshotFilters: Set<TranscriptFilter>, snapshotQuery: String, scrollTo: String? = nil,
         railHover: String? = nil, reveal: String? = nil) {
        self.model = model
        self.actions = actions
        self.initialScrollID = scrollTo
        self.railHover = railHover
        self.debugReveal = reveal
        _expansion = StateObject(wrappedValue: snapshotExpansion)
        _filters = State(initialValue: snapshotFilters)
        _query = State(initialValue: snapshotQuery)
        _appliedQuery = State(initialValue: snapshotQuery)
    }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    HStack(spacing: Self.railGap) {
                        list(proxy)
                        TranscriptRail(model: model, rows: currentRows, tracker: tracker, hoverRow: railHover) { rowID in
                            tracker.following = false
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(rowID, anchor: .top) }
                        } onTop: {
                            tracker.following = false
                            if let first = rows.first?.id { proxy.scrollTo(first, anchor: .top) }
                        } onBottom: {
                            tracker.following = true
                            proxy.scrollTo(Self.bottomID, anchor: .bottom)
                        }
                    }
                    JumpToLatest(tracker: tracker, isLive: isLive) {
                        tracker.following = true
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                    .padding(.trailing, Self.rowsTrailingInset).padding(.bottom, 10)
                }
                // Every rebuild, not just a longer one: a result landing in place can move a row
                // into (or out of) the active filter.
                .onChange(of: model.generation) { _, _ in
                    recompute()
                    // Follow new activity only for a reader parked at the end — never one who
                    // scrolled up or is scrolling now (that was the "jumps by itself" bug: an
                    // end marker the lazy list still held counted as "at the end").
                    if isLive, tracker.following, !tracker.userScrolling {
                        DispatchQueue.main.async { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                }
                .onChange(of: expansion.reveal) { _, id in
                    guard let id else { return }
                    tracker.following = false
                    // After the panel has laid out; nil anchor scrolls only as far as needed.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: nil) }
                        expansion.clearReveal()
                    }
                }
                .onChange(of: rows.first?.id) { _, _ in
                    guard !didInitialScroll, !rows.isEmpty else { return }
                    didInitialScroll = true
                    if let target = initialScrollID {
                        tracker.following = false
                        DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
                        if let reveal = debugReveal {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { expansion.requestReveal(reveal) }
                        }
                    } else if isLive {
                        tracker.following = true
                        DispatchQueue.main.async { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                }
                // A session coming alive under a reader already parked at the end follows from
                // there; anyone else stays where they are.
                .onChange(of: isLive) { _, live in
                    if live, tracker.atBottom, !tracker.userScrolling { tracker.following = true }
                }
                .onChange(of: filters) { _, _ in recompute(); if !jumping { scrollToTop(proxy) } }
                .onChange(of: appliedQuery) { _, _ in recompute(); if !jumping { scrollToTop(proxy) } }
            }
        }
        .onAppear { recompute() }
        .onChange(of: expansion.toggled) { _, _ in recompute() }
        .onChange(of: expansion.mode) { _, _ in recompute() }
        .task(id: query) {
            // Debounce: filtering a large transcript per keystroke would stutter typing.
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(180)) }
            guard !Task.isCancelled else { return }
            appliedQuery = query
        }
    }

    static let bottomID = "transcript-bottom"

    private var isFiltered: Bool { !filters.isEmpty || !appliedQuery.isEmpty }

    /// The rows for the model on screen right now — `rows`, unless a rebuild landed and
    /// `recompute()` (run from onChange, after this body) hasn't caught up yet.
    private var currentRows: [TranscriptRow] {
        if rowsGeneration == model.generation { return rows }
        let exp = expansion
        return model.visibleRows(filters: filters, query: appliedQuery, runExpanded: { exp.isExpanded($0) })
    }

    private func recompute() {
        let exp = expansion
        rowsGeneration = model.generation
        rows = model.visibleRows(filters: filters, query: appliedQuery,
                                 runExpanded: { exp.isExpanded($0) })
        var responses = Set<String>()
        var seenResponse = Set<Int>()
        for r in rows {
            if case .assistant = r.kind, !seenResponse.contains(r.turn) {
                seenResponse.insert(r.turn); responses.insert(r.id)
            }
        }
        firstResponseIDs = responses
        // The row the reader is anchored on can fold away — a fourth routine call arriving turns
        // three call rows into one run row. Anchor on the row that now shows that call, or the
        // list loses its place and lurches.
        if let top = tracker.topRowID, top.first == "e", let i = Int(top.dropFirst()),
           !rows.contains(where: { $0.id == top }),
           let holder = rows.first(where: { $0.eventIndices.contains(i) }) {
            tracker.topRowID = holder.id
        }
    }

    private func scrollToTop(_ proxy: ScrollViewProxy) {
        tracker.following = false
        if let first = rows.first?.id { DispatchQueue.main.async { proxy.scrollTo(first, anchor: .top) } }
    }

    // MARK: List

    private func list(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(currentRows) { row in
                    TranscriptRowView(row: row, model: model, actions: actions, expansion: expansion,
                                      isFirstResponse: firstResponseIDs.contains(row.id),
                                      isFiltered: isFiltered, highlight: appliedQuery,
                                      jumpToTool: { jump(toToolID: $0, proxy) },
                                      jumpToEvent: { jump(toEvent: $0, proxy) })
                        .id(row.id)
                }
                if rows.isEmpty { emptyState }
                Color.clear.frame(height: 24)
                    .id(Self.bottomID)
                    .modifier(EndSentinel(tracker: tracker))
            }
            .scrollTargetLayout()
            .padding(.leading, 2).padding(.trailing, Self.listTrailingInset)
        }
        .scrollPosition(id: Binding(get: { tracker.topRowID }, set: { tracker.topRowID = $0 }), anchor: .top)
        .modifier(ScrollIntent(tracker: tracker) { proxy.scrollTo(Self.bottomID, anchor: .bottom) })
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: isFiltered ? "line.3.horizontal.decrease.circle" : "text.bubble")
                .font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(isFiltered ? "Nothing matches" : "No messages yet")
                .font(.callout).foregroundStyle(.secondary)
            if isFiltered {
                Button("Clear filters") { filters = []; query = "" }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// Scroll to a tool call — unfolding its run first when it sits inside one.
    private func jump(toToolID id: String, _ proxy: ScrollViewProxy) {
        guard let idx = model.events.firstIndex(where: { if case .tool(let t) = $0 { return t.id == id } else { return false } })
        else { return }
        jump(toEvent: idx, proxy)
    }

    /// Scroll to the row showing an event. A folded run is unfolded first; a row the filters
    /// hide brings the whole transcript back, since a link the reader followed must land.
    private func jump(toEvent idx: Int, _ proxy: ScrollViewProxy) {
        guard model.events.indices.contains(idx) else { return }
        tracker.following = false
        var rebuilt = false
        if isFiltered, target(for: idx) == nil {
            jumping = true
            filters = []; query = ""; appliedQuery = ""
            rebuilt = true
        }
        if let run = model.runID(containing: idx), !expansion.isExpanded(run), !isFiltered || rebuilt {
            expansion.open(run)
            rebuilt = true
        }
        if rebuilt { recompute() }   // the row must exist before it can be scrolled to
        guard let id = target(for: idx) else { jumping = false; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (rebuilt ? 0.12 : 0)) {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            jumping = false
        }
    }

    /// The row that shows an event: its own row, else the row it is folded or clustered into,
    /// else (a prompt, drawn by its turn's header) the header of the turn it opened.
    private func target(for idx: Int) -> String? {
        if let own = rows.first(where: { $0.id == "e\(idx)" }) { return own.id }
        if let holder = rows.first(where: { $0.eventIndices.contains(idx) }) { return holder.id }
        guard let turn = model.turns.first(where: { $0.eventRange?.contains(idx) == true }),
              turn.promptIndex == idx else { return nil }
        return rows.first { $0.id == turn.id }?.id
    }

    // MARK: Toolbar

    /// The rail, its gap and the list's own trailing inset: where the rows end, short of the
    /// window edge. The toolbar and the floating button align to it, not to the rail.
    static let rowsTrailingInset: CGFloat = TranscriptRail.width + railGap + listTrailingInset
    static let railGap: CGFloat = 6
    static let listTrailingInset: CGFloat = 10

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                searchField
                ExpandModeToggle(expansion: expansion)
            }
            FlowLayout(spacing: 5) {
                ForEach(TranscriptFilter.allCases) { f in
                    let count = model.counts[f] ?? 0
                    if count > 0 || filters.contains(f) {
                        FilterChip(filter: f, count: count, isActive: filters.contains(f), detail: chipDetail(f)) {
                            if filters.contains(f) { filters.remove(f) } else { filters.insert(f) }
                        }
                    }
                }
                if !filters.isEmpty {
                    Button { filters = [] } label: {
                        Text("Clear").font(TranscriptStyle.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.trailing, Self.rowsTrailingInset)
        .padding(.bottom, 8)
    }

    /// What a chip's tooltip adds to its count.
    private func chipDetail(_ f: TranscriptFilter) -> String? {
        switch f {
        case .edits where model.stats.filesChanged > 0:
            return "to " + TranscriptFormat.plural(model.stats.filesChanged, "file")
        case .prompts where model.stats.prompts > 0:
            return TranscriptFormat.plural(model.stats.prompts, "prompt") + " you typed"
        case .errors:
            return "failed calls, hook errors and API errors"
        default:
            return nil
        }
    }

    private var resultSummary: String {
        let items = rows.filter { $0.kind != .turnHeader }.count
        let turns = Set(rows.map(\.turn)).count
        if !filters.isEmpty && items == 0 && turns > 0 {
            return TranscriptFormat.plural(turns, "turn")
        }
        return "\(TranscriptFormat.plural(items, "item")) in \(TranscriptFormat.plural(turns, "turn"))"
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: Icon.search).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Search transcript", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onExitCommand { query = ""; searchFocused = false }
            if isFiltered {
                Text(resultSummary)
                    .font(TranscriptStyle.meta).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
            }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: Icon.clearField).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(searchFocused ? Color.accentColor.opacity(0.6) : .clear))
        .background {
            // ⌘F focuses the search from anywhere in the page.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0).allowsHitTesting(false)
        }
    }

}

/// What starts open: every file edit with its diff and the rest on one line, or everything.
/// Clicking the current choice again folds back the rows opened or closed by hand.
private struct ExpandModeToggle: View {
    @ObservedObject var expansion: TranscriptExpansion

    var body: some View {
        HStack(spacing: 6) {
            Text("Expand").font(TranscriptStyle.caption).foregroundStyle(.tertiary)
            HStack(spacing: 2) {
                segment(.edits, "Edits", icon: "pencil",
                        help: "Open every file edit with its diff; everything else stays on one line")
                segment(.all, "All", icon: "arrow.up.left.and.arrow.down.right",
                        help: "Open every row — calls, context, hooks, thinking and folded tool runs")
            }
            .padding(2)
            .background(.white.opacity(0.06), in: Capsule())
        }
    }

    private func segment(_ mode: TranscriptExpansion.Mode, _ title: String, icon: String, help: String) -> some View {
        let on = expansion.mode == mode
        return Button { expansion.setMode(mode) } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(title)
            }
            .font(.system(size: 11, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Color.primary : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(on ? Color.white.opacity(0.13) : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(on ? help + " (click to undo rows you opened or closed by hand)" : help)
    }
}

/// Where the reader is and whether their hand is on the list, from the scroll view itself
/// (macOS 15+). "At the end" is measured, not inferred. Any move up — a swipe, the wheel, the
/// scroll bar, a key, a link followed — stops a live view from following; content arriving below
/// never does, since it changes the content's size, not the offset.
private struct ScrollIntent: ViewModifier {
    let tracker: TranscriptScrollTracker
    /// Put the end back in view. A jump to the end lands before the lazy rows near it are
    /// measured; when they are, the content grows and a following reader is left short of it.
    let pinEnd: () -> Void

    private struct Position: Equatable {
        var offset: CGFloat
        var atEnd: Bool
        var contentHeight: CGFloat
    }

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .onScrollGeometryChange(for: Position.self) { g in
                    Position(offset: g.contentOffset.y,
                             // A few points of slack for fractional offsets, no more: a reader who
                             // nudged up to reread the last line has left the end.
                             atEnd: g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 12,
                             contentHeight: g.contentSize.height)
                } action: { old, new in
                    if tracker.atBottom != new.atEnd { tracker.atBottom = new.atEnd }
                    // Only the reader's own movement decides. When the content changed size in the
                    // same step it is a relayout — rows arriving, a lazy row measured, a run folding
                    // — and the offset the list reports then can momentarily read "at the end"
                    // (arming a jump) or "moved up" (dropping a reader who is following).
                    guard abs(new.contentHeight - old.contentHeight) < 0.5 else {
                        if new.contentHeight > old.contentHeight, !new.atEnd,
                           tracker.following, !tracker.userScrolling { pinEnd() }
                        return
                    }
                    if new.offset < old.offset - 1 { tracker.following = false }
                    else if new.atEnd, new.offset > old.offset + 0.5 { tracker.following = true }
                }
                .onScrollPhaseChange { _, phase in
                    tracker.userScrolling = [.tracking, .interacting, .decelerating].contains(phase)
                }
        } else {
            content
        }
    }
}

/// macOS 14 has no scroll-geometry API: the end sentinel appearing in the lazy list, or leaving
/// it, stands in for "at the end". Coarser — the list keeps it a little past the screen edge.
private struct EndSentinel: ViewModifier {
    let tracker: TranscriptScrollTracker

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
        } else {
            content
                .onAppear { tracker.atBottom = true; tracker.following = true }
                .onDisappear { tracker.atBottom = false; tracker.following = false }
        }
    }
}

/// One filter: its colour, name and how many items answer to it. Chips combine — selecting
/// Edits and Errors shows either.
private struct FilterChip: View {
    let filter: TranscriptFilter
    let count: Int
    let isActive: Bool
    var detail: String? = nil
    let onTap: () -> Void
    @State private var hover = false

    var body: some View {
        let color = TranscriptStyle.color(for: filter)
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: TranscriptStyle.icon(for: filter))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
                Text(filter.label)
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                Text(count.formatted())
                    .foregroundStyle(isActive ? color : Color.secondary.opacity(0.7))
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: isActive ? .semibold : .regular))
            .padding(.horizontal, 8).padding(.vertical, 3.5)
            .background(isActive ? color.opacity(0.16) : (hover ? Color.white.opacity(0.07) : Color.white.opacity(0.035)),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(isActive ? color.opacity(0.55) : Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help((isActive ? "Stop filtering by \(filter.label)" : "Show only \(filter.label.lowercased()) (combine with other filters)")
              + "\n\(count.formatted())" + (detail.map { " · \($0)" } ?? ""))
    }
}

/// "Jump to latest", when the reader has scrolled up from the end.
private struct JumpToLatest: View {
    @ObservedObject var tracker: TranscriptScrollTracker
    let isLive: Bool
    let action: () -> Void

    var body: some View {
        if !tracker.atBottom {
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold))
                    Text(isLive ? "Latest" : "End")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.9), in: Capsule())
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .help(isLive ? "Scroll to the newest activity and follow it" : "Scroll to the end")
        }
    }
}
