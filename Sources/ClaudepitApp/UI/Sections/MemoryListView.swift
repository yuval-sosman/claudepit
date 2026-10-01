import SwiftUI
import AppKit
import ClaudepitCore

/// What the Memory page's right card shows.
enum MemorySelection: Hashable {
    case graph
    case file(String)   // MemoryNode.id
}

enum MemorySort: String, CaseIterable {
    case name, modified

    var label: String { self == .name ? "Name" : "Last Changed" }
}

/// What the Memory page remembers between visits.
struct MemoryPageMemory {
    var selection: MemorySelection = .graph
    var query = ""
}

/// Everything the Memory list shows, as plain data — so the DEBUG `--snapshot-pages` tool can
/// render it without an `AppState`.
struct MemoryListContext {
    var nodes: [MemoryNode] = []
    var edgeCount = 0
    var log: [MemoryLogEntry] = []
    /// The Claudepit memory strategy (rules file + end-of-session hook) is installed here.
    var memoryEnabled = true
    /// The strategy as it is installed, for the ⓘ popover.
    var strategyText = HookScripts.memorySystemPrompt
    var herdrAvailable = false
    var now = Date()

    var oversized: [MemoryNode] { nodes.filter(\.exceedsReadLimit) }
}

struct MemoryListActions {
    var setEnabled: (Bool) -> Void = { _ in }
    var openFolder: (() -> Void)? = nil
    var trash: (MemoryNode) -> Void = { _ in }
    /// Open the herdr agent that splits the oversized files; reports whether it started.
    var launchFix: (@escaping @MainActor (Bool) -> Void) -> Void = { done in Task { @MainActor in done(false) } }
    /// Jump to the strategy's card in App Settings.
    var editStrategy: (() -> Void)? = nil
}

/// The Memory page's left card: the strategy switch, search, every memory file (the graph and
/// the index first, then the topics MEMORY.md links, then any file nothing links), and the
/// activity log under a draggable divider.
struct MemoryListView: View {
    let context: MemoryListContext
    @Binding var selection: MemorySelection
    @Binding var query: String
    /// One-shot from a deep link: scroll this row to the middle of the list, then cleared.
    @Binding var revealRequest: MemorySelection?
    var actions = MemoryListActions()
    /// Open the newest log entries (the snapshot tool).
    var expandLog = false

    @AppStorage("memoryListSort") private var sortRaw = MemorySort.name.rawValue
    @FocusState private var listFocused: Bool
    @State private var hovered: MemorySelection?
    @State private var showStrategy = false
    @State private var searchFocusToken = 0
    @State private var keyScroll: MemorySelection?
    @State private var logFraction: CGFloat = 0.34      // share of the card's lower area the log gets
    @State private var expandedLog: Set<String> = []

    private var sort: MemorySort { MemorySort(rawValue: sortRaw) ?? .name }

    private var root: MemoryNode? { context.nodes.first(where: \.isRoot) }

    private func sorted(_ nodes: [MemoryNode]) -> [MemoryNode] {
        switch sort {
        case .name:
            return nodes.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .modified:
            return nodes.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        }
    }

    var body: some View {
        let matching = context.nodes.filter { $0.matches(query) }
        let topics = sorted(matching.filter { !$0.isRoot && !$0.isOrphan })
        let orphans = sorted(matching.filter(\.isOrphan))
        let showRoot = root.map { $0.matches(query) } ?? false
        let order: [MemorySelection] = (query.isEmpty && !context.nodes.isEmpty ? [.graph] : [])
            + (showRoot ? [.file("MEMORY.md")] : []) + (topics + orphans).map { .file($0.id) }

        VStack(spacing: 0) {
            header
            strategyRow
            searchRow(order)
            if !context.oversized.isEmpty { oversizeBanner }
            GeometryReader { geo in
                VStack(spacing: 0) {
                    Group {
                        if context.nodes.isEmpty {
                            PageListEmptyState(icon: "brain",
                                               title: "No memory yet",
                                               detail: context.memoryEnabled
                                                   ? "Claude saves what it learns about this project here as you work."
                                                   : "Turn the memory strategy on, and Claude will save what it learns here as you work.")
                        } else if order.isEmpty {
                            PageListEmptyState(icon: Icon.search, title: "No memory files match “\(query)”",
                                               detail: "Search reads titles, descriptions and every line of each file.") {
                                Button("Clear Search") { query = "" }.buttonStyle(.bordered).controlSize(.small)
                            }
                        } else {
                            list(topics: topics, orphans: orphans, showRoot: showRoot, order: order)
                        }
                    }
                    .frame(height: max(80, geo.size.height * (1 - logFraction)))

                    logDivider(totalHeight: geo.size.height)

                    MemoryLogPanel(entries: context.log, now: context.now, expanded: $expandedLog,
                                   onSelectFile: selectLogFile)
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            if expandLog { expandedLog = Set(context.log.prefix(2).map(\.id)) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Memory").font(.headline)
            Text("\(context.nodes.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            Spacer()
            if let openFolder = actions.openFolder {
                Button(action: openFolder) {
                    Image(systemName: Icon.revealInFinder).font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the memory folder in Finder")
            }
        }
        .padding(.leading, 16).padding(.trailing, 10)
        .padding(.top, 12).padding(.bottom, 8)
    }

    /// The switch for Claudepit's memory strategy in this project, with what it installs.
    private var strategyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain")
                .font(.system(size: 12))
                .foregroundStyle(context.memoryEnabled ? Color.accentColor : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("Memory strategy").font(.system(size: 12, weight: .medium))
                    Button { showStrategy.toggle() } label: {
                        Image(systemName: Icon.info).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("What the strategy tells Claude, and what the end-of-session hook says")
                    .popover(isPresented: $showStrategy, arrowEdge: .trailing) {
                        MemoryInspectorPopover(strategyText: context.strategyText, onEdit: actions.editStrategy.map { edit in
                            { showStrategy = false; edit() }
                        })
                    }
                }
                Text(context.memoryEnabled ? "On — saved by feature" : "Off in this project")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            PillToggle(isOn: context.memoryEnabled) { actions.setEnabled($0) }
                .help(context.memoryEnabled
                      ? "On: Claudepit's memory rules file and end-of-session hook are installed in this project"
                      : "Off: turn on to install Claudepit's memory rules file and end-of-session hook in this project")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func searchRow(_ order: [MemorySelection]) -> some View {
        HStack(spacing: 6) {
            PageListSearchField(text: $query, placeholder: "Search memory",
                                help: "Searches titles, descriptions and every line of each file (⌥⌘F)",
                                focusToken: searchFocusToken,
                                onArrowDown: {
                                    listFocused = true
                                    if let first = order.first(where: { $0 != .graph }) ?? order.first {
                                        selection = first
                                        keyScroll = first
                                    }
                                },
                                onLeave: { listFocused = true })
            sortMenu
        }
        .debugFrame("memory-search")
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .background {
            Button("") { searchFocusToken += 1 }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .opacity(0).frame(width: 0, height: 0)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $sortRaw) {
                ForEach(MemorySort.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 7)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .help("Sort topics by \(sort == .name ? "name" : "last change") — click to change")
    }

    /// Shown while any file runs past what Claude reads: how many, and the one-click fix.
    private var oversizeBanner: some View {
        let count = context.oversized.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "scissors")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("\(count) \(count == 1 ? "file runs" : "files run") past what Claude reads "
                     + "(\(MemoryReadLimit.maxLines) lines or \(MemoryReadLimit.maxBytes / 1000) KB)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            MemoryFixButton(herdrAvailable: context.herdrAvailable, hasWork: count > 0, launch: actions.launchFix)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.orange.opacity(0.18)))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    // MARK: List

    private func list(topics: [MemoryNode], orphans: [MemoryNode], showRoot: Bool,
                      order: [MemorySelection]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    if query.isEmpty { graphRow.id(MemorySelection.graph) }
                    if showRoot, let root { fileRow(root).id(MemorySelection.file(root.id)) }
                    if !topics.isEmpty {
                        SwiftUI.Section {
                            ForEach(topics) { fileRow($0).id(MemorySelection.file($0.id)) }
                        } header: {
                            PageListSectionHeader(title: "Topics", count: topics.count,
                                                  help: "Files MEMORY.md links to, directly or through another topic")
                        }
                    }
                    if !orphans.isEmpty {
                        SwiftUI.Section {
                            ForEach(orphans) { fileRow($0).id(MemorySelection.file($0.id)) }
                        } header: {
                            PageListSectionHeader(title: "Not in MEMORY.md", count: orphans.count,
                                                  help: "Claude finds topic files through MEMORY.md, so it may never read these. Link them from the index, or merge them into a topic.")
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in
                let delta: Int
                switch press.key {
                case .upArrow: delta = -1
                case .downArrow: delta = 1
                default: return .ignored
                }
                if let next = PageListKeys.step(selection, by: delta, in: order) {
                    selection = next
                    keyScroll = next
                }
                return .handled
            }
            .onChange(of: keyScroll) { _, target in
                guard let target else { return }
                proxy.scrollTo(target)
                keyScroll = nil
            }
            .onAppear { reveal(proxy) }
            .onChange(of: revealRequest) { reveal(proxy) }
        }
    }

    /// Clicking a row never scrolls the list; only deep links and log clicks do, centred.
    private func reveal(_ proxy: ScrollViewProxy) {
        guard let target = revealRequest else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) }
            revealRequest = nil
        }
    }

    private var graphRow: some View {
        let unlinked = context.nodes.filter(\.isOrphan).count
        let meta = "\(context.nodes.count) file\(context.nodes.count == 1 ? "" : "s") · "
            + "\(context.edgeCount) link\(context.edgeCount == 1 ? "" : "s")"
            + (unlinked > 0 ? " · \(unlinked) unlinked" : "")
        return selectable(.graph) { isSelected, isHovered in
            PageListRow(title: "Knowledge Graph", meta: Text(meta),
                        isSelected: isSelected, isFocused: listFocused, isHovered: isHovered,
                        help: "Every memory file and the links between them", onTap: { select(.graph) }) {
                rowGlyph("point.3.filled.connected.trianglepath.dotted", tint: .accentColor)
            } markers: { EmptyView() } menuItems: {
                if let openFolder = actions.openFolder {
                    Button(action: openFolder) { Label("Open Memory Folder", systemImage: Icon.revealInFinder) }
                }
            }
        }
    }

    private func fileRow(_ node: MemoryNode) -> some View {
        let snippet = query.isEmpty ? nil
            : SearchText.snippet(in: node.body, query: query, visible: [node.title, node.id, node.description ?? ""])
        var meta = Text(node.modifiedAt.map { SessionTimeLabel.text(for: $0, now: context.now, inDateSection: false) } ?? "")
        if node.isRoot {
            meta = Text("Index") + Text(" · ") + meta
        } else if node.title != URL(fileURLWithPath: node.id).deletingPathExtension().lastPathComponent {
            meta = meta + Text(" · ") + Text(node.id)
        }
        return selectable(.file(node.id)) { isSelected, isHovered in
            PageListRow(title: node.displayTitle,
                        subtitle: snippet ?? (node.isRoot ? "What Claude reads first — one line per topic" : node.description),
                        subtitleIsExcerpt: snippet != nil,
                        subtitleLines: snippet != nil ? 2 : 1,
                        meta: meta,
                        isSelected: isSelected, isFocused: listFocused, isHovered: isHovered,
                        help: tooltip(node), onTap: { select(.file(node.id)) }) {
                rowGlyph(node.isRoot ? "list.bullet.rectangle" : node.isOrphan ? "doc.badge.ellipsis" : "doc.text",
                         tint: node.isOrphan ? .orange : .secondary)
            } markers: {
                if node.exceedsReadLimit {
                    Image(systemName: "scissors")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            } menuItems: {
                fileContextMenu(url: node.url)
                Divider()
                Button(role: .destructive) { actions.trash(node) } label: {
                    Label("Move to Trash", systemImage: Icon.delete)
                }
            }
        }
    }

    static func frameID(_ item: MemorySelection) -> String {
        switch item {
        case .graph: return "memory-row-graph"
        case .file(let id): return "memory-row-\(id)"
        }
    }

    private func select(_ item: MemorySelection) {
        selection = item
        listFocused = true
    }

    private func rowGlyph(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 11))
            .foregroundStyle(tint)
            .frame(width: 16)
    }

    private func selectable<Row: View>(_ item: MemorySelection,
                                       @ViewBuilder row: (Bool, Bool) -> Row) -> some View {
        row(selection == item, hovered == item)
            .debugFrame(Self.frameID(item))
            .onHover { inside in
                if inside { hovered = item } else if hovered == item { hovered = nil }
            }
    }

    private func tooltip(_ node: MemoryNode) -> String {
        var lines = [node.displayTitle]
        if let d = node.description, !node.isRoot { lines.append(d) }
        var facts = [node.id]
        if let s = node.size { facts.append(s.label) }
        if let m = node.modifiedAt { facts.append("changed " + m.formatted(date: .abbreviated, time: .shortened)) }
        lines.append(facts.joined(separator: " · "))
        if node.exceedsReadLimit {
            lines.append("Claude stops reading partway — limit \(MemoryReadLimit.maxLines) lines or \(MemoryReadLimit.maxBytes / 1000) KB")
        }
        if node.isOrphan { lines.append("Not linked from MEMORY.md — Claude may never read it") }
        return lines.joined(separator: "\n")
    }

    // MARK: Log

    /// Drags the file-list / log split. Clamped to 0.15…0.7.
    private func logDivider(totalHeight: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            Capsule().fill(Color.white.opacity(0.18)).frame(width: 28, height: 4)
        }
        .frame(height: 12)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture()
                .onChanged { v in
                    guard totalHeight > 0 else { return }
                    let f = logFraction - v.translation.height / totalHeight
                    logFraction = min(0.7, max(0.15, f))
                }
        )
        .help("Drag to resize the activity log")
    }

    /// Deep-link from a log entry's filename to that memory file (if it still exists).
    private func selectLogFile(_ file: String) {
        let trimmed = file.hasPrefix("./") ? String(file.dropFirst(2)) : file
        let name = (trimmed as NSString).lastPathComponent
        guard let node = context.nodes.first(where: { $0.id == trimmed })
                ?? context.nodes.first(where: { ($0.id as NSString).lastPathComponent == name || $0.title == name })
        else { return }
        if !node.matches(query) { query = "" }
        selection = .file(node.id)
        revealRequest = .file(node.id)
    }
}

// MARK: - MemoryLogPanel

/// UI mapping for change actions — color/label/order live here (SwiftUI) rather
/// than Core. Letter (`A`/`M`/`D`) is on the Core type. Colors match ReviewChangesSheet.
extension MemoryLogEntry.Change.Action {
    static let allCasesOrdered: [Self] = [.create, .update, .delete]
    var color: Color { switch self { case .create: .green; case .update: .orange; case .delete: .red } }
    var groupLabel: String { switch self { case .create: "ADDED"; case .update: "MODIFIED"; case .delete: "DELETED" } }
}

/// The memory activity log: one row per memory pass or dream, expandable to its summary and
/// the files it added, modified and deleted. Reads `AppState.memoryLog`.
struct MemoryLogPanel: View {
    let entries: [MemoryLogEntry]
    var now = Date()
    @Binding var expanded: Set<String>
    let onSelectFile: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("Activity").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if !entries.isEmpty {
                    Text("\(entries.count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .help("Every memory pass and consolidation, newest first, from memory/log.json")

            if entries.isEmpty {
                Text("No memory activity yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(entries) { entry in
                            MemoryLogRow(
                                entry: entry,
                                isOpen: expanded.contains(entry.id),
                                dateText: SessionTimeLabel.text(for: entry.date, now: now, inDateSection: false),
                                onToggle: { toggle(entry.id) },
                                onSelectFile: onSelectFile
                            )
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }
}

/// One log entry. Split out from the panel so the type-checker doesn't choke
/// on a single giant expression.
private struct MemoryLogRow: View {
    let entry: MemoryLogEntry
    let isOpen: Bool
    let dateText: String
    let onToggle: () -> Void
    let onSelectFile: (String) -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onToggle) { header }
                .buttonStyle(.plain)
            if isOpen { detail }
        }
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 8).fill(isOpen ? Color.white.opacity(0.04)
                                                          : hover ? Color.white.opacity(0.03) : .clear))
        .padding(.horizontal, 6)
        .onHover { hover = $0 }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.type == .dream ? "moon.stars.fill" : "square.and.pencil")
                .font(.system(size: 10.5))
                .foregroundStyle(entry.type == .dream ? Color.purple : .secondary)
                .frame(width: 14)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayTitle)
                    .font(.system(size: 12))
                    .lineLimit(isOpen ? nil : 1)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Text(dateText)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    ForEach(badges, id: \.letter) { b in
                        Pill("\(b.letter)\(b.count)", color: b.color, hPadding: 6, vPadding: 2)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: Icon.chevronCollapsed)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .padding(.top, 3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(entry.date.formatted(date: .abbreviated, time: .shortened)
              + (entry.sessionId.map { " · session \($0.prefix(8))" } ?? ""))
    }

    @ViewBuilder private var detail: some View {
        if let summary = entry.displaySummary {
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 32).padding(.trailing, 10)
                .padding(.bottom, 4)
        }
        ForEach(groups, id: \.action) { g in
            VStack(alignment: .leading, spacing: 2) {
                Text(g.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(g.color)
                ForEach(g.files, id: \.self) { file in
                    Button { onSelectFile(file) } label: {
                        Text((file as NSString).lastPathComponent)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(file)")
                    .debugFrame("log-file-\(file)")
                }
            }
            .padding(.leading, 32).padding(.trailing, 10)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var badges: [(letter: String, count: Int, color: Color)] {
        MemoryLogEntry.Change.Action.allCasesOrdered.compactMap { action in
            let n = entry.displayChanges.filter { $0.action == action }.count
            return n == 0 ? nil : (action.letter, n, action.color)
        }
    }

    private var groups: [(action: String, label: String, color: Color, files: [String])] {
        MemoryLogEntry.Change.Action.allCasesOrdered.compactMap { action in
            let files = entry.displayChanges.filter { $0.action == action }.map(\.file)
            return files.isEmpty ? nil : (action.rawValue, action.groupLabel, action.color, files)
        }
    }
}
