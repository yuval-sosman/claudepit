#if DEBUG
import SwiftUI
import AppKit
import ClaudepitCore

/// Developer tool, DEBUG builds only: render a session transcript offscreen to PNG, so the
/// transcript view can be checked against real transcripts without launching the app — no
/// window, no Dock icon, no `AppState` (whose pollers would drive the user's tasks).
///
///     .build/debug/ClaudepitApp --snapshot-transcript <file.jsonl> --out <dir> [options]
///
///   --width N          content width in points (default 980)
///   --height N         page height for the page image (default 1100)
///   --rows A-B         also render visible rows A…B as one tall image (non-lazy)
///   --only id,id       …or just these rows (ids from --list), as only.png
///   --list             print the visible rows (index, id, kind, turn) and exit
///   --markdown         print the conversation as Markdown (the header menu's copy) and exit
///   --shrink-test      live-view regression: publish a model from the file cut to a quarter
///                      (a rewritten transcript) under a rendered one; must not trap
///   --follow-test      live-follow regression: grow a live transcript at the end (must follow)
///                      and after scrolling up (must stay put — "it scrolls by itself")
///   --expand-all       the toolbar's "All" (default is "Edits": file edits open, the rest folded)
///   --open id,id       open these rows (toggle from their default)
///   --filter a,b       select filters (prompts, tools, errors, …)
///   --query text       search
///   --scroll-to id     bring this row to the top of the page image
///   --hover-row id     show the timeline rail's hover card for this row's mark
///   --rail-key         also render the timeline's colour key (a popover in the app) as key.png
///   --reveal id        after --scroll-to, bring this panel into view as an Ask click does
///                      (open it too: --open <row>/qa)
@MainActor
enum DevSnapshot {
    /// Links render only when an action exists for them; these stand in for the app's, so plan
    /// and subagent links draw as they would in a window.
    static let actions = TranscriptActions(openPlan: { print("openPlan \($0)") })

    static func runIfRequested() -> Bool {
        if DevSessionsSnapshot.runIfRequested() { return true }
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot-transcript"), i + 1 < args.count else { return false }
        func value(_ flag: String) -> String? {
            guard let j = args.firstIndex(of: flag), j + 1 < args.count else { return nil }
            return args[j + 1]
        }
        let url = URL(fileURLWithPath: args[i + 1])
        let outDir = URL(fileURLWithPath: value("--out") ?? FileManager.default.currentDirectoryPath)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let width = CGFloat(Double(value("--width") ?? "") ?? 980)
        let height = CGFloat(Double(value("--height") ?? "") ?? 1100)
        let filters = Set((value("--filter") ?? "").split(separator: ",").compactMap { TranscriptFilter(rawValue: String($0)) })
        let query = value("--query") ?? ""

        NSApplication.shared.setActivationPolicy(.prohibited)

        let t0 = Date()
        var parser = SessionTranscript()
        let events = parser.parse(data: (try? Data(contentsOf: url)) ?? Data())
        let model = TranscriptModel(events: events, metadata: parser.metadata)
        print("parsed \(events.count) events → \(model.rows.count) rows, \(model.turns.count) turns in \(Int(Date().timeIntervalSince(t0) * 1000))ms")

        let expansion = TranscriptExpansion()
        if args.contains("--expand-all") { expansion.setMode(.all) }
        for id in (value("--open") ?? "").split(separator: ",").map(String.init) {
            if id.hasSuffix("/qa") { expansion.togglePanel(id) } else { expansion.toggle(id) }
        }

        let rows = model.visibleRows(filters: filters, query: query, runExpanded: { expansion.isExpanded($0) })
        if args.contains("--markdown") { print(model.markdown()); exit(0) }
        if args.contains("--shrink-test") { shrinkTest(url); exit(0) }
        if args.contains("--follow-test") {
            let ok = [560.0, 900.0].map { followTest(url, height: $0) }.allSatisfy { $0 }
            exit(ok ? 0 : 1)
        }
        if args.contains("--list") {
            for (n, r) in rows.enumerated() { print(String(format: "%4d  %-8@ turn %-3d %@", n, r.id as NSString, r.turn, describe(r, model) as NSString)) }
            exit(0)
        }

        // The page: header + toolbar + transcript, as the detail card shows it.
        let page = SnapshotPage(model: model, title: model.metadata.aiTitle ?? url.deletingPathExtension().lastPathComponent,
                                expansion: expansion, filters: filters, query: query, scrollTo: value("--scroll-to"),
                                railHover: value("--hover-row"), reveal: value("--reveal"))
            .frame(width: width, height: height)
        write(page, size: CGSize(width: width, height: height), to: outDir.appending(path: "page.png"))

        if args.contains("--rail-key") {
            write(RailKey().background(SnapshotBackground()), size: nil, width: 330, to: outDir.appending(path: "key.png"))
        }

        let only = Set((value("--only") ?? "").split(separator: ",").map(String.init))
        if !only.isEmpty || value("--rows") != nil {
            var slice: [TranscriptRow]
            var name: String
            if !only.isEmpty {
                slice = rows.filter { only.contains($0.id) }
                name = "only"
            } else if let range = value("--rows"), let (a, b) = parseRange(range, count: rows.count) {
                slice = Array(rows[a...b]); name = "rows-\(a)-\(b)"
            } else { exit(1) }
            var firstResponse = Set<String>(), seen = Set<Int>()
            for r in rows { if case .assistant = r.kind, !seen.contains(r.turn) { seen.insert(r.turn); firstResponse.insert(r.id) } }
            let column = VStack(alignment: .leading, spacing: 2) {
                ForEach(slice) { row in
                    TranscriptRowView(row: row, model: model, actions: actions, expansion: expansion,
                                      isFirstResponse: firstResponse.contains(row.id),
                                      isFiltered: !filters.isEmpty || !query.isEmpty, highlight: query)
                }
            }
            .padding(16)
            .frame(width: width, alignment: .topLeading)
            .background(SnapshotBackground())
            write(column, size: nil, width: width, to: outDir.appending(path: "\(name).png"))
        }
        exit(0)
    }

    /// A live view whose file was rewritten shorter: the loader publishes a smaller model while
    /// the view still holds rows for the larger one. Found by review as an index-out-of-range trap.
    private static func shrinkTest(_ url: URL) {
        let data = (try? Data(contentsOf: url)) ?? Data()
        var full = SessionTranscript()
        var a = TranscriptModel(events: full.parse(data: data), metadata: full.metadata)
        a.generation = 1
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        let keep = Data(lines.prefix(max(1, lines.count / 4)).joined(separator: [0x0A]) + [0x0A])
        var cut = SessionTranscript()
        var b = TranscriptModel(events: cut.parse(data: keep), metadata: cut.metadata)
        b.generation = 2
        print("A: \(a.events.count) events / \(a.turns.count) turns → B: \(b.events.count) events / \(b.turns.count) turns")
        let box = ShrinkBox(a)
        let host = NSHostingView(rootView: ShrinkHost(box: box))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 1000)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        box.model = b
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        print("survived the shrink")
    }

    /// A live session grows under the reader, a little at a time, as a real one does. Parked at
    /// the end, the view must carry them to the new end; scrolled up — by a short or a long way,
    /// by the scroll bar's route (no gesture) — it must not move.
    private static func followTest(_ url: URL, height: CGFloat) -> Bool {
        let data = (try? Data(contentsOf: url)) ?? Data()
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        var generation = 0
        var kept = Int(Double(lines.count) * 0.5)
        func grow(by n: Int) -> TranscriptModel {
            kept = min(lines.count, kept + n)
            let keep = Data(lines.prefix(kept).joined(separator: [0x0A]) + [0x0A])
            var parser = SessionTranscript()
            var m = TranscriptModel(events: parser.parse(data: keep), metadata: parser.metadata)
            generation += 1
            m.generation = generation
            return m
        }
        let box = ShrinkBox(grow(by: 0))
        let host = NSHostingView(rootView: ShrinkHost(box: box, height: height))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        func settle(_ seconds: Double = 0.9) {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        func scrollView(in v: NSView) -> NSScrollView? {
            if let s = v as? NSScrollView, s.documentView != nil { return s }
            for sub in v.subviews { if let s = scrollView(in: sub) { return s } }
            return nil
        }
        settle()
        guard let scroll = scrollView(in: host) else { print("no scroll view found"); return false }
        func offset() -> CGFloat { scroll.contentView.bounds.origin.y }
        func end() -> CGFloat { max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height) }
        func move(to y: CGFloat) { scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y))); scroll.reflectScrolledClipView(scroll.contentView) }

        var ok = true
        for _ in 0..<3 { box.model = grow(by: 6); settle(0.4) }
        let followed = end() - offset() < 60
        ok = ok && followed
        print(String(format: "[h=%.0f] grew 3× while at the end: offset %.0f, end %.0f → %@",
                     height, offset(), end(), followed ? "followed" : "LEFT BEHIND"))
        for distance in [40.0, 120.0, 300.0, 900.0] {
            move(to: end()); settle(0.4)
            move(to: offset() - distance); settle(0.3)
            let parked = offset()
            var worst: CGFloat = 0
            for _ in 0..<4 { box.model = grow(by: 4); settle(0.35); worst = max(worst, abs(offset() - parked)) }
            let stayed = worst < 40
            ok = ok && stayed
            print(String(format: "[h=%.0f] up %.0fpt, then 4 updates: drifted up to %.0fpt → %@",
                         height, distance, worst, stayed ? "stayed put" : "JUMPED"))
        }
        return ok
    }

    private static func parseRange(_ s: String, count: Int) -> (Int, Int)? {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, count > 0 else { return nil }
        let a = max(0, min(parts[0], count - 1)), b = max(a, min(parts[1], count - 1))
        return (a, b)
    }

    private static func describe(_ r: TranscriptRow, _ m: TranscriptModel) -> String {
        switch r.kind {
        case .turnHeader: return "HEADER  " + m.turns[r.turn].label.prefix(70)
        case .turnFooter: return "footer"
        case .tool(let i): if case .tool(let t) = m.events[i] { return "tool    \(t.name) \(t.argSummary.prefix(60))" }
        case .toolRun(let a): return "run     \(a.count) calls"
        case .assistant(let i): if case .assistantText(let t) = m.events[i] { return "claude  " + t.text.prefix(70).replacingOccurrences(of: "\n", with: " ") }
        case .thinking(let a): return "thinking \(a.count)"
        case .context(let a): return "context \(a.count)"
        case .systemPrompt: return "system prompt"
        case .hook(let i): if case .hook(let h) = m.events[i] { return "hook    \(h.hookName)" }
        case .notice(let i): if case .notice(let n) = m.events[i] { return "notice  \(n.title.prefix(60))" }
        case .message(let i): if case .userMessage(let u) = m.events[i] { return "message \(u.kind)" }
        case .attachment: return "attachment"
        }
        return "?"
    }

    /// Lay the view out in an offscreen window and write it as a 2× PNG. With no `size`, the
    /// height is whatever the content needs at `width`.
    private static func write<V: View>(_ view: V, size: CGSize?, width: CGFloat = 0, to url: URL) {
        let root = view.environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        var frame = CGRect(origin: .zero, size: size ?? CGSize(width: width, height: 100))
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        if size == nil {
            host.layoutSubtreeIfNeeded()
            let fit = host.fittingSize
            frame.size = CGSize(width: width, height: min(fit.height, 30_000))
            window.setContentSize(frame.size)
            host.frame = frame
        }
        // Let SwiftUI lay out, load lazy rows and run onAppear.
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path) \(rep.pixelsWide)×\(rep.pixelsHigh)")
        window.orderOut(nil)
    }
}

@MainActor
private final class ShrinkBox: ObservableObject {
    @Published var model: TranscriptModel
    init(_ m: TranscriptModel) { model = m }
}

private struct ShrinkHost: View {
    @ObservedObject var box: ShrinkBox
    var height: CGFloat = 1000
    var body: some View { TranscriptView(model: box.model, isLive: true).frame(width: 900, height: height) }
}

/// The detail card as the Sessions page frames it, minus the parts that need `AppState`.
private struct SnapshotPage: View {
    let model: TranscriptModel
    let title: String
    @ObservedObject var expansion: TranscriptExpansion
    let filters: Set<TranscriptFilter>
    let query: String
    var scrollTo: String? = nil
    var railHover: String? = nil
    var reveal: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionHeader(title: title, isActive: false, model: model) {
                HStack(spacing: 6) {
                    ForEach(["Summary", "Report", "Context"], id: \.self) { t in
                        Text(t).font(.system(size: 11)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3.5)
                            .background(Color.white.opacity(0.06), in: Capsule())
                    }
                }
            }
            .padding(.bottom, 10)
            TranscriptView(model: model, actions: DevSnapshot.actions, snapshotExpansion: expansion, snapshotFilters: filters,
                           snapshotQuery: query, scrollTo: scrollTo, railHover: railHover, reveal: reveal)
        }
        .padding(16)
        .background(SnapshotBackground())
    }
}

/// The glass card's look on the app's dark window, approximated with flat colour.
private struct SnapshotBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.11, green: 0.115, blue: 0.13)
            RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.03))
        }
    }
}
#endif
