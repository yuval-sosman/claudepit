import SwiftUI
import AppKit
import ClaudepitCore

/// The two pages built from these views. Everything a plan list and a spec list don't share is
/// said here; the rest is one implementation.
enum DocumentKind {
    case plan, spec

    var noun: String { self == .plan ? "plan" : "spec" }
    var pageTitle: String { self == .plan ? "Plans" : "Specs" }
    var emptyIcon: String { self == .plan ? "list.bullet.clipboard" : "doc.text.magnifyingglass" }
    var emptyTitle: String { "No \(noun)s yet" }
    var emptyDetail: String {
        self == .plan ? "When Claude plans in plan mode, the plan is saved to ~/.claude/plans and listed here."
                      : "A task's Spec phase writes its spec here. Run it from a task on the Tasks page."
    }
    var searchHelp: String {
        self == .plan ? "Searches every word of each plan — titles, file names and text (⌥⌘F)"
                      : "Searches every word of each spec — task names, task ids and text (⌥⌘F)"
    }
    var folderHelp: String {
        self == .plan ? "Open ~/.claude/plans in Finder" : "Open this project's task folders in Finder"
    }
    /// How a row names the file in its meta line: a plan's slug, a spec's task.
    func tagLabel(_ doc: MarkdownDoc) -> String { self == .plan ? doc.tag : "task \(doc.tag)" }
    /// The file, as the header's fact strip and the row tooltip name it.
    func fileLabel(_ doc: MarkdownDoc) -> String {
        self == .plan ? "\(doc.tag).md" : "\(doc.tag)/spec.md"
    }
}

/// What the Plans and Specs pages remember between visits: leaving and coming back keeps the
/// document you were reading, your search and your date filter.
struct DocumentPageMemory {
    var selection: URL?
    var query = ""
    var timeFilter: TimeFilter = .all
}

/// The Plans and Specs pages' left card: every document under the same date headers as the
/// Sessions list, titled by name rather than by file (plan files are random slugs, specs all
/// `spec.md`), searchable by any word in it. Takes plain data and closures, never `AppState`, so
/// the DEBUG `--snapshot-pages` tool can render it offscreen.
struct DocumentListView: View {
    let kind: DocumentKind
    let docs: [MarkdownDoc]
    let now: Date
    @Binding var selection: URL?
    @Binding var query: String
    @Binding var timeFilter: TimeFilter
    /// One-shot from a deep link: scroll this document to the middle of the list, then cleared.
    @Binding var revealRequest: URL?
    /// nil: no Move to Trash (a spec belongs to its task).
    var onTrash: ((MarkdownDoc) -> Void)? = nil
    var onOpenFolder: (() -> Void)? = nil
    /// Brainstorm a document in a new herdr pane (see `DocumentDetailView.brainstorm`). nil: no herdr.
    var onBrainstorm: ((MarkdownDoc) -> Void)? = nil

    @FocusState private var listFocused: Bool
    @State private var hoveredID: URL?
    @State private var showCustomRange = false
    @State private var searchFocusToken = 0
    /// A keyboard move: scroll just far enough to show the row.
    @State private var keyScroll: URL?

    private var visible: [MarkdownDoc] {
        docs.filter { timeFilter.includes($0.modifiedAt) && $0.matches(query) }
    }

    var body: some View {
        let shown = visible
        VStack(spacing: 0) {
            header
            searchRow(shown)
            chips
            if docs.isEmpty {
                PageListEmptyState(icon: kind.emptyIcon, title: kind.emptyTitle, detail: kind.emptyDetail)
            } else if shown.isEmpty {
                noMatches
            } else {
                list(shown)
            }
        }
    }

    // MARK: Header and search

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(kind.pageTitle).font(.headline)
            Text("\(docs.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            Spacer()
            if let onOpenFolder {
                Button(action: onOpenFolder) {
                    Image(systemName: Icon.revealInFinder).font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(kind.folderHelp)
            }
        }
        .padding(.leading, 16).padding(.trailing, 10)
        .padding(.top, 12).padding(.bottom, 8)
    }

    private func searchRow(_ shown: [MarkdownDoc]) -> some View {
        HStack(spacing: 6) {
            PageListSearchField(text: $query, placeholder: "Search \(kind.noun)s",
                                help: kind.searchHelp,
                                focusToken: searchFocusToken,
                                onArrowDown: {
                                    listFocused = true
                                    if let first = shown.first { selection = first.id; keyScroll = first.id }
                                },
                                onLeave: { listFocused = true })
            dateMenu
        }
        .debugFrame("\(kind.noun)-search")
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .background {
            Button("") { searchFocusToken += 1 }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .opacity(0).frame(width: 0, height: 0)
        }
    }

    private var dateMenu: some View {
        Menu {
            Picker(selection: datePresetBinding) {
                Text("Any Time").tag("all")
                ForEach(TimePreset.allCases, id: \.self) { p in Text(p.menuTitle).tag(p.rawValue) }
                if case .custom = timeFilter { Text("Custom Range").tag("custom") }
            } label: { Text("Modified") }
            .pickerStyle(.inline)
            Button("Custom Range…") { showCustomRange = true }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12, weight: timeFilter.isActive ? .bold : .regular))
                .foregroundStyle(timeFilter.isActive ? Color.accentColor : .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 6)
        .background(timeFilter.isActive ? Color.accentColor.opacity(0.16) : .white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 7))
        .help("Filter by date modified")
        .popover(isPresented: $showCustomRange, arrowEdge: .bottom) {
            TimeFilterPopover(filter: $timeFilter)
        }
    }

    private var datePresetBinding: Binding<String> {
        Binding(
            get: {
                switch timeFilter {
                case .all: return "all"
                case .preset(let p): return p.rawValue
                case .custom: return "custom"
                }
            },
            set: { tag in
                if tag == "all" { timeFilter = .all }
                else if let p = TimePreset(rawValue: tag) { timeFilter = .preset(p) }
            })
    }

    @ViewBuilder private var chips: some View {
        if timeFilter.isActive {
            HStack {
                PageListChip(text: "Modified: \(timeFilter.menuLabel)") { timeFilter = .all }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    private var noMatches: some View {
        PageListEmptyState(icon: Icon.search,
                           title: query.isEmpty ? "No \(kind.noun)s in this date range" : "No \(kind.noun)s match “\(query)”",
                           detail: query.isEmpty ? "Try a wider range." : "Search reads every word of each \(kind.noun).") {
            Button("Clear Search and Filters") { query = ""; timeFilter = .all }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    // MARK: List

    private func list(_ shown: [MarkdownDoc]) -> some View {
        let sections = DateSections.group(shown, date: \.modifiedAt, now: now)
        let order = sections.flatMap { $0.items.map(\.id) }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        SwiftUI.Section {
                            ForEach(section.items) { doc in row(doc) }
                        } header: {
                            PageListSectionHeader(title: section.title)
                        }
                    }
                }
                .padding(.bottom, 10)
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
            .onAppear { reveal(proxy) }
            .onChange(of: revealRequest) { reveal(proxy) }
            .onChange(of: keyScroll) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
                keyScroll = nil
            }
        }
    }

    private func row(_ doc: MarkdownDoc) -> some View {
        let snippet = query.isEmpty ? nil
            : SearchText.snippet(in: doc.text, query: query, visible: [doc.title, doc.summary ?? ""])
        let time = SessionTimeLabel.text(for: doc.modifiedAt, now: now, inDateSection: true)
        return PageListRow(
            title: doc.title,
            titleLines: 2,
            subtitle: snippet ?? doc.summary,
            subtitleIsExcerpt: snippet != nil,
            subtitleLines: snippet != nil ? 2 : 1,
            meta: Text(time) + Text(" · ") + Text(kind.tagLabel(doc)),
            isSelected: selection == doc.id,
            isFocused: listFocused,
            isHovered: hoveredID == doc.id,
            help: "\(doc.title)\n\(kind.fileLabel(doc)) · \(doc.words.formatted()) words · "
                + doc.modifiedAt.formatted(date: .abbreviated, time: .shortened),
            onTap: {
                selection = doc.id
                listFocused = true
            }
        ) {
            EmptyView()
        } markers: {
            EmptyView()
        } menuItems: {
            if let onBrainstorm {
                Button { onBrainstorm(doc) } label: { Label("Brainstorm in herdr", systemImage: "terminal") }
                Divider()
            }
            fileContextMenu(url: doc.url)
            if let onTrash {
                Divider()
                Button(role: .destructive) { onTrash(doc) } label: {
                    Label("Move to Trash", systemImage: Icon.delete)
                }
            }
        }
        .id(doc.id)
        .debugFrame("\(kind.noun)-row-\(doc.tag)")
        .onHover { inside in
            if inside { hoveredID = doc.id } else if hoveredID == doc.id { hoveredID = nil }
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let id = revealRequest else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            revealRequest = nil
        }
    }
}
