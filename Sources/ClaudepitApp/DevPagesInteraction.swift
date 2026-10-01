#if DEBUG
import SwiftUI
import AppKit
import ClaudepitCore

/// Developer tool, DEBUG builds only: drive the Plans, Specs and Memory lists with synthetic clicks and
/// keys in an offscreen key window (the Sessions harness's `Driver`) and check what they do —
/// click, ↑/↓, ↓ from the search box into the results, a click never scrolling the list, deep-link
/// reveals, and log links. Real files, read only; nothing on disk changes.
///
///     .build/debug/ClaudepitApp --snapshot-pages plans|specs|memory --interaction-test [--project p]
/// Claims key status outright. A click into a window that isn't key only makes it key — the
/// content never sees it — and this offscreen window didn't reliably become key (the harness
/// must never activate the app to get there: that would steal the user's focus).
private final class AlwaysKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
}

@MainActor
enum DevPagesInteraction {
    private static var failures = 0

    private static func expect(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL")  \(what)")
        if !ok { failures += 1 }
    }

    private static func makeDriver<V: View>(_ view: V, height: CGFloat = 700) -> (Driver, FrameBox) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let frames = FrameBox()
        let host = NSHostingView(rootView: view
            .environment(\.debugFrameReporter, { id, rect in frames.map[id] = rect })
            .environment(\.colorScheme, .dark))
        host.frame = CGRect(x: 0, y: 0, width: 324, height: height)
        let window = AlwaysKeyWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        window.makeKey()
        let d = Driver(window: window, host: host, frames: frames)
        d.settle(1.0)
        return (d, frames)
    }

    // MARK: Plans and Specs

    final class DocumentsProbe: ObservableObject {
        @Published var selection: URL?
        @Published var query = ""
        @Published var filter: TimeFilter = .all
        @Published var reveal: URL?
    }

    private struct DocumentsHost: View {
        let kind: DocumentKind
        let docs: [MarkdownDoc]
        @ObservedObject var probe: DocumentsProbe
        var body: some View {
            GlassCard {
                DocumentListView(kind: kind, docs: docs, now: Date(), selection: $probe.selection,
                                 query: $probe.query, timeFilter: $probe.filter, revealRequest: $probe.reveal,
                                 onTrash: kind == .plan ? { _ in } : nil, onOpenFolder: {})
            }
            .frame(width: 300, height: 676)
            .padding(12)
            .background(Color(red: 0.11, green: 0.115, blue: 0.13))
        }
    }

    /// The Plans and Specs lists are one view; this drives whichever `kind` it is given. Specs are
    /// fewer (one per task), so the checks that need a long list are skipped below six.
    static func runDocuments(_ kind: DocumentKind, _ docs: [MarkdownDoc]) -> Bool {
        guard docs.count >= 3 else { print("need at least 3 \(kind.noun)s, found \(docs.count)"); return false }
        let probe = DocumentsProbe()
        let (d, _) = makeDriver(DocumentsHost(kind: kind, docs: docs, probe: probe))
        // List order is newest first — the order the date sections draw.
        let o = docs.sorted { $0.modifiedAt > $1.modifiedAt }
        func row(_ doc: MarkdownDoc) -> String { "\(kind.noun)-row-\(doc.tag)" }

        d.click(row(o[1]))
        expect(probe.selection == o[1].id, "click selects a \(kind.noun)")
        d.key(.down)
        expect(probe.selection == o[2].id, "↓ moves to the next \(kind.noun)")
        d.key(.up); d.key(.up)
        expect(probe.selection == o[0].id, "↑↑ moves back two")
        d.key(.up)
        expect(probe.selection == o[0].id, "↑ at the top stays on the first \(kind.noun)")

        let before = d.scrollOffset()
        d.click(row(o[2]))
        expect(abs(d.scrollOffset() - before) < 1 && probe.selection == o[2].id, "a click selects without scrolling")

        // ⌥⌘F, not a click: a click on the field starts AppKit's text-tracking loop, which waits
        // for a mouse-up from the real event queue that a synthetic event never reaches.
        let target = o[o.count - 1]
        let word = target.title.split(separator: " ").map(String.init).first { $0.count >= 5 } ?? target.tag
        let matches = o.filter { $0.matches(word) }
        d.key(.char("f"), [.command, .option])
        d.type(word)
        expect(probe.query == word, "⌥⌘F focuses search and typing filters (“\(word)”)")
        d.key(.down)
        expect(probe.selection == matches.first?.id, "↓ from the search box selects the first match")
        if matches.count > 1 {
            d.key(.down)
            expect(probe.selection == matches[1].id, "…and ↓ then moves through the matches")
        }
        probe.query = ""
        d.settle(0.4)

        // A deep link scrolls a far document into view — only meaningful when the list overflows.
        if docs.count >= 6 {
            let far = o[o.count - 1]
            probe.selection = far.id
            probe.reveal = far.id
            d.settle(0.8)
            expect(probe.reveal == nil && d.scrollOffset() > 1, "a reveal request scrolls the linked \(kind.noun) into view")
        } else {
            print("SKIP  reveal scroll — \(docs.count) \(kind.noun)s fit without scrolling")
        }
        return failures == 0
    }

    // MARK: Memory

    final class MemoryProbe: ObservableObject {
        @Published var selection: MemorySelection = .graph
        @Published var query = ""
        @Published var reveal: MemorySelection?
    }

    private struct MemoryHost: View {
        let context: MemoryListContext
        @ObservedObject var probe: MemoryProbe
        var body: some View {
            GlassCard {
                MemoryListView(context: context, selection: $probe.selection, query: $probe.query,
                               revealRequest: $probe.reveal, actions: MemoryListActions(openFolder: {}),
                               expandLog: true)
            }
            .frame(width: 300, height: 1076)
            .padding(12)
            .background(Color(red: 0.11, green: 0.115, blue: 0.13))
        }
    }

    static func runMemory(_ graph: MemoryGraph, log: [MemoryLogEntry]) -> Bool {
        // The list's order follows the stored sort preference — read it, never write it: this
        // process shares the app's defaults.
        let sort = MemorySort(rawValue: UserDefaults.standard.string(forKey: "memoryListSort") ?? "") ?? .name
        let topics = graph.nodes.filter { !$0.isRoot && !$0.isOrphan }.sorted { a, b in
            sort == .name ? a.title.localizedStandardCompare(b.title) == .orderedAscending
                          : (a.modifiedAt ?? .distantPast) > (b.modifiedAt ?? .distantPast)
        }
        guard topics.count >= 3, graph.nodes.contains(where: \.isRoot) else {
            print("need MEMORY.md and at least 3 linked topics"); return false
        }
        let probe = MemoryProbe()
        let context = MemoryListContext(nodes: graph.nodes, edgeCount: graph.edges.count, log: log)
        let (d, frames) = makeDriver(MemoryHost(context: context, probe: probe), height: 1100)

        expect(probe.selection == .graph, "the graph is selected on arrival")
        d.click(MemoryListView.frameID(.file("MEMORY.md")))
        expect(probe.selection == .file("MEMORY.md"), "click selects the index")
        d.key(.down)
        expect(probe.selection == .file(topics[0].id), "↓ moves to the first topic")
        d.key(.up); d.key(.up)
        expect(probe.selection == .graph, "↑↑ climbs back to the graph")

        let before = d.scrollOffset()
        d.click(MemoryListView.frameID(.file(topics[1].id)))
        expect(abs(d.scrollOffset() - before) < 1 && probe.selection == .file(topics[1].id),
               "a click selects without scrolling")

        // Search reads bodies: pick a word from a topic's body that its title doesn't contain.
        let target = topics[2]
        let word = target.body.split(whereSeparator: { !$0.isLetter }).map(String.init)
            .first { $0.count >= 7 && !target.title.localizedCaseInsensitiveContains($0) } ?? target.title
        let ordered = graph.nodes.filter { $0.matches(word) }
        d.key(.char("f"), [.command, .option])
        d.type(word)
        expect(probe.query == word && !ordered.isEmpty, "typing searches every line (“\(word)”, \(ordered.count) files)")
        d.key(.down)
        if case .file(let id) = probe.selection {
            expect(graph.nodes.first { $0.id == id }?.matches(word) == true, "↓ from the search box selects a match")
        } else {
            expect(false, "↓ from the search box selects a match")
        }
        probe.query = ""
        d.settle(0.4)

        // A log entry's file link opens that file and scrolls it into view.
        // The newest entries are open; take a link that exists as a file and is on screen.
        let logged = log.prefix(2).flatMap(\.displayChanges).map(\.file)
            .filter { f in graph.nodes.contains { $0.id == f || ($0.id as NSString).lastPathComponent == (f as NSString).lastPathComponent } }
            .first { f in frames.map["log-file-\(f)"].map { $0.maxY < d.host.bounds.height - 8 && $0.height > 0 } ?? false }
        if let logged {
            d.click("log-file-\(logged)")
            if case .file(let id) = probe.selection {
                expect((id as NSString).lastPathComponent == (logged as NSString).lastPathComponent,
                       "a log entry's file link opens that file (\(logged))")
            } else {
                expect(false, "a log entry's file link opens that file (\(logged))")
            }
        } else {
            print("SKIP  no visible file link in the two newest log entries")
        }

        // A deep link to the last topic scrolls it into view.
        let last = topics[topics.count - 1]
        d.click(MemoryListView.frameID(.graph))
        let top = d.scrollOffset()
        probe.selection = .file(last.id)
        probe.reveal = .file(last.id)
        d.settle(0.8)
        expect(probe.reveal == nil && d.scrollOffset() > top, "a reveal request scrolls the linked file into view")
        return failures == 0
    }
}
#endif
