import SwiftUI
import WebKit
import ClaudepitCore

// MARK: - MemorySection

struct MemorySection: View {
    @ObservedObject var app: AppState
    @State private var selectedNode: MemoryNode?
    @State private var fileContent: String = ""
    @State private var truncatedRemainder: String = ""
    @State private var fileTruncated = false
    @State private var frontmatter: MemoryFrontmatter? = nil
    @State private var showQA: Bool = false
    @State private var showGraphQA: Bool = false
    @State private var graphHighlights: Set<String> = []
    @State private var showMemoryInspector = false
    @State private var logFraction: CGFloat = 0.4          // share of sidebar height the LOG panel gets
    @State private var expandedLog: Set<String> = []

    var graph: MemoryGraph { app.memoryGraph }
    var sortedNodes: [MemoryNode] {
        graph.nodes.sorted { a, b in
            if a.isRoot { return true }
            if b.isRoot { return false }
            return a.title < b.title
        }
    }

    // MARK: - Sidebar sub-views

    private var fileList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sortedNodes) { node in
                    HStack(spacing: 0) {
                        Button {
                            selectedNode = node
                            loadContent(node)
                            showGraphQA = false
                            graphHighlights = []
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: node.isRoot ? "list.bullet.rectangle" : "doc.text")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                Text(node.isRoot ? "MEMORY.md" : node.title)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Menu {
                            fileContextMenu(url: node.url)
                            Divider()
                            Button(role: .destructive) {
                                if selectedNode?.id == node.id { selectedNode = nil }
                                try? FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
                                // memoryGraph reloads via FileWatcher automatically
                            } label: {
                                Label("Move to Trash", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .padding(.trailing, 6)
                    }
                    .background(
                        selectedNode?.id == node.id
                            ? Color.white.opacity(0.08)
                            : Color.clear
                    )
                }
            }
        }
    }

    /// Thin grip that drags the file-list / LOG split. Clamped to 0.15…0.7.
    private func logDragHandle(totalHeight: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            Image(systemName: "ellipsis")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .frame(height: 10)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { v in
                    guard totalHeight > 0 else { return }
                    let f = logFraction - v.translation.height / totalHeight
                    logFraction = min(0.7, max(0.15, f))
                }
        )
    }

    /// Deep-link from a LOG entry's filename to that memory file (if it still exists).
    private func selectLogFile(_ file: String) {
        let name = (file as NSString).lastPathComponent
        guard let node = graph.nodes.first(where: { $0.id == name || $0.title == name }) else { return }
        selectedNode = node
        loadContent(node)
        showGraphQA = false
        graphHighlights = []
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left sidebar — always visible
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("MEMORY FILES")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let base = app.activePath {
                        Button {
                            NSWorkspace.shared.open(Paths.memoryDir(projectSlug: Paths.slug(for: base)))
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Open memory folder in Finder")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                HStack {
                    Image(systemName: "brain")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Memory Instructions")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if app.memoryEnabled {
                        Button { showMemoryInspector.toggle() } label: {
                            Image(systemName: Icon.info)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showMemoryInspector, arrowEdge: .trailing) {
                            MemoryInspectorPopover()
                        }
                    }
                    Spacer()
                    PillToggle(isOn: app.memoryEnabled) { enabled in
                        app.memoryEnabled = enabled
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                Divider().opacity(0.2)

                if graph.nodes.isEmpty {
                    Text("No memory files yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12)
                }

                GeometryReader { geo in
                    VStack(spacing: 0) {
                        fileList
                            .frame(height: max(60, geo.size.height * (1 - logFraction)))

                        // Draggable handle — resizes the file-list / LOG split.
                        logDragHandle(totalHeight: geo.size.height)

                        MemoryLogPanel(
                            entries: app.memoryLog,
                            expanded: $expandedLog,
                            onSelectFile: selectLogFile
                        )
                        .frame(maxHeight: .infinity)
                    }
                }
            }
            .frame(width: 240)
            .background(.ultraThinMaterial)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            }

            // Right panel — graph or file detail
            if let node = selectedNode {
                detailPanel(node: node)
            } else {
                graphPanel
            }
        }
        .onChange(of: selectedNode) { _, node in app.selectedMemoryTitle = node?.title }
        .onChange(of: app.focusMemoryFileID) { _, id in
            guard let id, let node = graph.nodes.first(where: { $0.id == id }) else { return }
            selectedNode = node
            loadContent(node)
            showGraphQA = false
            graphHighlights = []
            app.focusMemoryFileID = nil
        }
        .onChange(of: app.memoryGraph) { _, _ in
            if let node = selectedNode,
               let fresh = app.memoryGraph.nodes.first(where: { $0.id == node.id }) {
                loadContent(fresh)
            }
        }
        .onChange(of: app.selected) { _, section in
            if section != .memory { graphHighlights = [] }
        }
    }

    private func highlightsFromAnswer(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        return Set(graph.nodes.filter { lower.contains($0.title.lowercased()) }.map(\.id))
    }

    private var allMemoryContent: String {        sortedNodes.compactMap { node -> String? in
            guard let raw = try? String(contentsOf: node.url, encoding: .utf8) else { return nil }
            let title = node.isRoot ? "MEMORY.md" : node.title
            return "### \(title)\n\(raw)"
        }.joined(separator: "\n\n---\n\n")
    }

    private var graphPanel: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .foregroundStyle(.secondary)
                    Text("Knowledge Graph")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showGraphQA.toggle()
                        if !showGraphQA { graphHighlights = [] }
                    } label: {
                        Image(systemName: showGraphQA
                              ? "bubble.left.and.text.bubble.right.fill"
                              : "bubble.left.and.text.bubble.right")
                            .font(.system(size: 13))
                            .foregroundStyle(showGraphQA ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(graph.nodes.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().opacity(0.2)

                if showGraphQA {
                    PlanQAPanel(
                        planContent: allMemoryContent,
                        title: "Ask about all memory files",
                        showImprovement: false,
                        onAnswer: { answer in
                            graphHighlights = highlightsFromAnswer(answer)
                        }
                    )
                    .frame(height: geo.size.height * 0.4)
                    Divider().opacity(0.25)
                }

                if graph.nodes.isEmpty {
                    emptyState
                } else {
                    D3GraphView(graph: graph, highlightedIDs: graphHighlights) { nodeID in
                        if let node = graph.nodes.first(where: { $0.id == nodeID }) {
                            selectedNode = node
                            loadContent(node)
                            showGraphQA = false
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No memory files yet")
                .font(.headline).foregroundStyle(.secondary)
            Text("Claude will build a knowledge graph here as you work in this project.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Detail panel (replaces graph in right area)

    private func detailPanel(node: MemoryNode) -> some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        selectedNode = nil
                        fileContent = ""
                        truncatedRemainder = ""
                        fileTruncated = false
                        showQA = false
                    } label: {
                        Label("Knowledge Graph", systemImage: "chevron.left")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        showQA.toggle()
                    } label: {
                        Image(systemName: showQA
                              ? "bubble.left.and.text.bubble.right.fill"
                              : "bubble.left.and.text.bubble.right")
                            .font(.system(size: 13))
                            .foregroundStyle(showQA ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)

                    CopyPathButton(url: node.url)

                    Button {
                        NSWorkspace.shared.open(node.url)
                    } label: {
                        Image(systemName: Icon.openFile)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open in default text editor")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().opacity(0.2)

                if showQA {
                    PlanQAPanel(
                        planContent: fileContent,
                        title: "Ask about this memory file",
                        showImprovement: false
                    )
                    .frame(height: geo.size.height * 0.4)
                    Divider().opacity(0.25)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !node.isRoot {
                            Text(node.title)
                                .font(.title2).bold()
                        }

                        if let fm = frontmatter {
                            MemoryFrontmatterCard(frontmatter: fm, app: app)
                        }

                        if fileContent.isEmpty {
                            ProgressView()
                        } else {
                            MarkdownText(fileContent)
                            if fileTruncated {
                                VStack(spacing: 6) {
                                    HStack {
                                        Rectangle().fill(Color.orange.opacity(0.5)).frame(height: 1)
                                        Image(systemName: "scissors")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.orange)
                                        Rectangle().fill(Color.orange.opacity(0.5)).frame(height: 1)
                                    }
                                    Text("Claude stops reading here — file exceeds 200 lines or 25 KB")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.orange.opacity(0.8))
                                }
                                .padding(.top, 8)

                                MarkdownText(truncatedRemainder)
                                    .opacity(0.3)
                                    .padding(.top, 4)
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .environment(\.focusMemoryFileID, $app.focusMemoryFileID)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadContent(_ node: MemoryNode) {
        showQA = false
        let raw = (try? String(contentsOf: node.url, encoding: .utf8)) ?? "_Could not read file._"
        let (fm, body) = MemoryFrontmatter.parse(from: raw)
        frontmatter = node.isRoot ? nil : fm
        let maxBytes = 25_000
        let maxLines = 200
        let lines = body.components(separatedBy: "\n")
        if body.utf8.count <= maxBytes && lines.count <= maxLines {
            fileContent = body
            truncatedRemainder = ""
            fileTruncated = false
        } else {
            var byteCount = 0
            var keptCount = 0
            for (i, line) in lines.enumerated() {
                let lineBytes = (line + "\n").utf8.count
                if i >= maxLines || byteCount + lineBytes > maxBytes {
                    break
                }
                keptCount = i + 1
                byteCount += lineBytes
            }
            fileContent = lines.prefix(keptCount).joined(separator: "\n")
            truncatedRemainder = lines.dropFirst(keptCount).joined(separator: "\n")
            fileTruncated = true
        }
    }
}

// MARK: - MemoryFrontmatterCard

private struct MemoryFrontmatterCard: View {
    let frontmatter: MemoryFrontmatter
    let app: AppState

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Description + date on same line
            if let desc = frontmatter.description, !desc.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text(desc)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let modified = frontmatter.modified {
                        Text(Self.dateFormatter.string(from: modified))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            } else if let modified = frontmatter.modified {
                HStack {
                    Spacer()
                    Text(Self.dateFormatter.string(from: modified))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            // Session pills
            if !frontmatter.sessions.isEmpty {
                HStack(spacing: 6) {
                    Text("Sessions")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    ForEach(frontmatter.sessions, id: \.self) { sid in
                        sessionPill(id: sid, isOrigin: sid == frontmatter.originSessionId)
                    }
                }
            } else if let origin = frontmatter.originSessionId {
                HStack(spacing: 6) {
                    Text("Session")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    sessionPill(id: origin, isOrigin: true)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.12)))
    }

    private func sessionPill(id: String, isOrigin: Bool) -> some View {
        Button {
            app.focusSessionID = id
            app.selected = .sessions
        } label: {
            HStack(spacing: 3) {
                if isOrigin {
                    Image(systemName: "star.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(Color.accentColor)
                }
                Text(String(id.prefix(8)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isOrigin ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(
                isOrigin ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 5)
            )
        }
        .buttonStyle(.plain)
        .help(id)
    }
}

// MARK: - MemoryInspectorPopover

private struct MemoryInspectorPopover: View {
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "brain")
                    .foregroundStyle(.secondary)
                Text("Memory Instructions")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Picker("", selection: $tab) {
                Text("System Prompt").tag(0)
                Text("Stop Hook").tag(1)
                Text("Stop Hook (Dream)").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider().opacity(0.2)

            ScrollView {
                if tab == 0 {
                    MarkdownText(HookScripts.memorySystemPrompt)
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    let content = tab == 1 ? HookScripts.memoryHookReminder : HookScripts.memoryHookDreaming
                    MarkdownText(content)
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: 700, height: 650)
    }
}

// MARK: - D3GraphView

struct D3GraphView: NSViewRepresentable {
    let graph: MemoryGraph
    let highlightedIDs: Set<String>
    let onNodeTap: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onNodeTap: onNodeTap) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "nodeSelected")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = wv
        if let url = Bundle.module.url(forResource: "d3.min", withExtension: "js"),
           let d3 = try? String(contentsOf: url, encoding: .utf8) {
            wv.loadHTMLString(graphHTML(d3: d3), baseURL: nil)
        }
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        context.coordinator.pendingGraph = graphJSON()
        context.coordinator.pendingHighlights = highlightedIDs
        context.coordinator.flushIfReady()
    }

    // MARK: JSON

    private func graphJSON() -> String {
        let nodes = graph.nodes.map { n in
            """
            {"id":\(jsonStr(n.id)),"label":\(jsonStr(n.isRoot ? "MEMORY.md" : n.title)),"isRoot":\(n.isRoot)}
            """
        }.joined(separator: ",")
        let links = graph.edges.map { e in
            """
            {"source":\(jsonStr(e.from)),"target":\(jsonStr(e.to))}
            """
        }.joined(separator: ",")
        return "{\"nodes\":[\(nodes)],\"links\":[\(links)]}"
    }

    private func jsonStr(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    // MARK: HTML

    private func graphHTML(d3: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          * { margin: 0; padding: 0; box-sizing: border-box; }
          html, body { width: 100%; height: 100%; overflow: hidden; background: transparent; }
          svg { width: 100%; height: 100%; }
          .link { stroke: rgba(255,255,255,0.18); stroke-width: 1.2; }
          .node circle {
            cursor: pointer;
            transition: r 0.15s, opacity 0.15s;
          }
          .node text {
            fill: rgba(255,255,255,0.7);
            font-family: -apple-system, sans-serif;
            font-size: 11px;
            pointer-events: none;
            text-anchor: middle;
          }
          .node:hover circle { opacity: 1 !important; }
          .node:hover text { fill: white; }
        </style>
        </head>
        <body>
        <svg id="svg"></svg>
        <script>
        \(d3)
        </script>
        <script>
        var simulation, nodeG, linkG, svg, g;
        var currentData = null;

        function init(data) {
          currentData = data;
          var el = document.getElementById('svg');
          var W = el.clientWidth || window.innerWidth;
          var H = el.clientHeight || window.innerHeight;

          d3.select('#svg').selectAll('*').remove();

          svg = d3.select('#svg');
          g = svg.append('g');

          // Zoom + pan
          svg.call(d3.zoom()
            .scaleExtent([0.2, 4])
            .on('zoom', function(event) { g.attr('transform', event.transform); })
          );

          simulation = d3.forceSimulation(data.nodes)
            .force('link', d3.forceLink(data.links).id(function(d) { return d.id; }).distance(120))
            .force('charge', d3.forceManyBody().strength(-400))
            .force('center', d3.forceCenter(W / 2, H / 2))
            .force('collision', d3.forceCollide(40));

          linkG = g.append('g').selectAll('line')
            .data(data.links).enter().append('line')
            .attr('class', 'link');

          nodeG = g.append('g').selectAll('.node')
            .data(data.nodes).enter().append('g')
            .attr('class', 'node')
            .call(d3.drag()
              .on('start', dragStart)
              .on('drag', dragged)
              .on('end', dragEnd)
            )
            .on('click', function(event, d) {
              window.webkit.messageHandlers.nodeSelected.postMessage(d.id);
            });

          nodeG.append('circle')
            .attr('r', function(d) { return d.isRoot ? 18 : 10; })
            .attr('fill', function(d) {
              return d.isRoot ? 'rgba(120,100,240,0.85)' : 'rgba(120,120,140,0.6)';
            })
            .attr('stroke', function(d) {
              return d.isRoot ? 'rgba(160,140,255,0.9)' : 'rgba(180,180,200,0.4)';
            })
            .attr('stroke-width', function(d) { return d.isRoot ? 2 : 1; });

          nodeG.append('text')
            .attr('dy', function(d) { return (d.isRoot ? 18 : 10) + 14; })
            .text(function(d) { return d.label; });

          simulation.on('tick', function() {
            linkG
              .attr('x1', function(d) { return d.source.x; })
              .attr('y1', function(d) { return d.source.y; })
              .attr('x2', function(d) { return d.target.x; })
              .attr('y2', function(d) { return d.target.y; });
            nodeG.attr('transform', function(d) {
              return 'translate(' + d.x + ',' + d.y + ')';
            });
          });
        }

        function highlight(ids) {
          if (!nodeG) return;
          nodeG.selectAll('circle')
            .attr('stroke-width', function(d) {
              return ids.indexOf(d.id) >= 0 ? 3 : (d.isRoot ? 2 : 1);
            })
            .attr('stroke', function(d) {
              if (ids.indexOf(d.id) >= 0) return 'rgba(255,220,100,0.9)';
              return d.isRoot ? 'rgba(160,140,255,0.9)' : 'rgba(180,180,200,0.4)';
            })
            .attr('r', function(d) {
              return ids.indexOf(d.id) >= 0 ? (d.isRoot ? 22 : 14) : (d.isRoot ? 18 : 10);
            });
        }

        function dragStart(event, d) {
          if (!event.active) simulation.alphaTarget(0.3).restart();
          d.fx = d.x; d.fy = d.y;
        }
        function dragged(event, d) { d.fx = event.x; d.fy = event.y; }
        function dragEnd(event, d) {
          if (!event.active) simulation.alphaTarget(0);
          d.fx = null; d.fy = null;
        }

        window.loadGraph = function(json) {
          var data = JSON.parse(json);
          init(data);
        };
        window.highlightNode = function(ids) { highlight(ids); };
        </script>
        </body>
        </html>
        """
    }

    // MARK: Coordinator

    class Coordinator: NSObject, WKScriptMessageHandler {
        let onNodeTap: (String) -> Void
        weak var webView: WKWebView?
        var isReady = false
        var pendingGraph: String?
        var pendingHighlights: Set<String>?

        init(onNodeTap: @escaping (String) -> Void) { self.onNodeTap = onNodeTap }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "nodeSelected", let id = message.body as? String {
                DispatchQueue.main.async { self.onNodeTap(id) }
            }
        }

        func flushIfReady() {
            guard let wv = webView else { return }
            if !isReady {
                // Poll readiness via JS
                wv.evaluateJavaScript("typeof window.loadGraph") { [weak self] result, _ in
                    if (result as? String) == "function" {
                        self?.isReady = true
                        self?.flushIfReady()
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self?.flushIfReady()
                        }
                    }
                }
                return
            }
            if let json = pendingGraph {
                pendingGraph = nil
                let escaped = json
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                wv.evaluateJavaScript("window.loadGraph('\(escaped)')") { _, _ in }
            }
            if let hids = pendingHighlights {
                pendingHighlights = nil
                let arr = hids.map { "\"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ",")
                wv.evaluateJavaScript("window.highlightNode([\(arr)])") { _, _ in }
            }
        }
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

/// Bottom-of-sidebar activity log: one card per memory pass / dream, expandable
/// to reveal the summary and per-action file groups. Reads `AppState.memoryLog`.
struct MemoryLogPanel: View {
    let entries: [MemoryLogEntry]
    @Binding var expanded: Set<String>
    let onSelectFile: (String) -> Void

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy h:mm a"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("LOG")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            if entries.isEmpty {
                Text("No memory activity yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            MemoryLogRow(
                                entry: entry,
                                isOpen: expanded.contains(entry.id),
                                dateText: Self.dateFmt.string(from: entry.date),
                                onToggle: { toggle(entry.id) },
                                onSelectFile: onSelectFile
                            )
                            Divider().opacity(0.15)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

/// One LOG entry. Split out from the panel so the type-checker doesn't choke
/// on a single giant expression.
private struct MemoryLogRow: View {
    let entry: MemoryLogEntry
    let isOpen: Bool
    let dateText: String
    let onToggle: () -> Void
    let onSelectFile: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onToggle) { header }
                .buttonStyle(.plain)
            if isOpen { detail }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.type == .dream ? "moon.stars.fill" : "bubble.left")
                .font(.system(size: 11))
                .foregroundStyle(entry.type == .dream ? Color.purple : .secondary)
                .frame(width: 14)
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var detail: some View {
        if let summary = entry.displaySummary {
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
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
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
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
