import SwiftUI
import WebKit
import ClaudepitCore

/// The memory knowledge graph: a d3 force layout in a web view. MEMORY.md is the large accent
/// node; a topic's size follows its length; a file Claude stops reading partway has an orange
/// ring, and a file no link reaches is drawn dashed and apart. Hover a node to light up its
/// links; click it to open the file.
///
/// The page re-renders on every `AppState` change, so the graph is only re-sent to the page when
/// its JSON actually changed — re-sending it re-ran the whole layout, and the graph jumped
/// whenever anything else in the app moved. A real change keeps every surviving node where it was.
struct D3GraphView: NSViewRepresentable {
    let graph: MemoryGraph
    let highlightedIDs: Set<String>
    /// Bump to zoom the whole graph back into view.
    var fitToken: Int = 0
    let onNodeTap: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onNodeTap: onNodeTap) }

    func makeNSView(context: Context) -> WKWebView {
        let wv = Self.makeWebView(handler: context.coordinator)
        context.coordinator.webView = wv
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        let c = context.coordinator
        c.onNodeTap = onNodeTap
        let json = Self.graphJSON(graph)
        if json != c.sentGraph { c.pendingGraph = json }
        if highlightedIDs != c.sentHighlights { c.pendingHighlights = highlightedIDs }
        if fitToken != c.sentFitToken { c.pendingFit = true; c.sentFitToken = fitToken }
        c.flushIfReady()
    }

    static func makeWebView(handler: WKScriptMessageHandler) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(handler, name: "nodeSelected")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        if let url = Bundle.module.url(forResource: "d3.min", withExtension: "js"),
           let d3 = try? String(contentsOf: url, encoding: .utf8) {
            wv.loadHTMLString(graphHTML(d3: d3), baseURL: nil)
        }
        return wv
    }

    // MARK: JSON

    /// Nodes in a stable order, so an unchanged graph always serialises to the same string.
    static func graphJSON(_ graph: MemoryGraph) -> String {
        let nodes: [[String: Any]] = graph.nodes.sorted { $0.id < $1.id }.map { n in
            var tip = [n.displayTitle]
            if let d = n.description, !d.isEmpty { tip.append(d) }
            if let s = n.size { tip.append(s.label + (n.exceedsReadLimit ? " — Claude stops reading partway" : "")) }
            if n.isOrphan { tip.append("Not linked from MEMORY.md") }
            return ["id": n.id, "label": n.displayTitle, "isRoot": n.isRoot, "lines": n.size?.lines ?? 0,
                    "oversize": n.exceedsReadLimit, "orphan": n.isOrphan, "tip": tip.joined(separator: "\n")]
        }
        let links: [[String: String]] = graph.edges.map { ["source": $0.from, "target": $0.to] }
        let data = (try? JSONSerialization.data(withJSONObject: ["nodes": nodes, "links": links],
                                                options: [.sortedKeys])) ?? Data("{\"nodes\":[],\"links\":[]}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: HTML

    static func graphHTML(d3: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          :root {
            --link: rgba(255,255,255,0.16); --link-on: rgba(255,255,255,0.55);
            --label: rgba(255,255,255,0.72); --label-on: #fff;
            --node: rgba(140,140,160,0.55); --node-stroke: rgba(190,190,210,0.45);
            --root: rgba(120,100,240,0.88); --root-stroke: rgba(170,150,255,0.95);
            --warn: rgba(255,159,10,0.95); --hl: rgba(255,214,10,0.95);
          }
          @media (prefers-color-scheme: light) {
            :root {
              --link: rgba(0,0,0,0.14); --link-on: rgba(0,0,0,0.5);
              --label: rgba(0,0,0,0.7); --label-on: #000;
              --node: rgba(120,120,140,0.45); --node-stroke: rgba(80,80,100,0.45);
            }
          }
          * { margin: 0; padding: 0; box-sizing: border-box; }
          html, body { width: 100%; height: 100%; overflow: hidden; background: transparent; }
          svg { width: 100%; height: 100%; cursor: grab; }
          svg:active { cursor: grabbing; }
          .link { stroke: var(--link); stroke-width: 1.2; transition: opacity 0.15s, stroke 0.15s; }
          .link.index { stroke-opacity: 0.45; stroke-width: 1; }
          .link.on { stroke: var(--link-on); }
          .node { cursor: pointer; transition: opacity 0.15s; }
          .node circle { fill: var(--node); stroke: var(--node-stroke); stroke-width: 1; }
          .node.root circle { fill: var(--root); stroke: var(--root-stroke); stroke-width: 2; }
          .node.orphan circle { fill-opacity: 0.45; stroke-dasharray: 3 2; stroke-width: 1.4; }
          .node.oversize circle { stroke: var(--warn); stroke-width: 2.4; }
          .node.hl circle { stroke: var(--hl); stroke-width: 3; }
          .node text {
            fill: var(--label); font: 11px -apple-system, sans-serif;
            pointer-events: none; text-anchor: middle;
            paint-order: stroke; stroke: rgba(0,0,0,0.35); stroke-width: 3px;
          }
          @media (prefers-color-scheme: light) { .node text { stroke: rgba(255,255,255,0.6); } }
          .node:hover text, .node.on text { fill: var(--label-on); }
          .dim { opacity: 0.18; }
        </style>
        </head>
        <body>
        <svg id="svg"></svg>
        <script>
        \(d3)
        </script>
        <script>
        var simulation, nodeG, linkG, svg, g, zoom;
        var current = null, highlighted = [], userZoomed = false, W = 0, H = 0;

        function measure() {
          W = document.documentElement.clientWidth || window.innerWidth;
          H = document.documentElement.clientHeight || window.innerHeight;
        }
        function radius(d) { return d.isRoot ? 18 : 6 + Math.min(8, Math.sqrt(d.lines || 1) * 0.5); }
        function short(s) { return s.length > 28 ? s.slice(0, 26) + '…' : s; }
        // Labels are wide and sit under the node, so nodes keep a label's half-width apart.
        function room(d) { return Math.max(radius(d) + 16, Math.min(84, short(d.label).length * 3.3)); }

        function init(data) {
          measure();
          // Keep every surviving node where it was, so an edit doesn't reshuffle the graph.
          var prev = {};
          if (current) current.nodes.forEach(function(n) { prev[n.id] = n; });
          var kept = 0;
          data.nodes.forEach(function(n) {
            var p = prev[n.id];
            if (p && p.x !== undefined) { n.x = p.x; n.y = p.y; kept++; }
          });
          var fresh = kept < data.nodes.length / 2;
          current = data;

          d3.select('#svg').selectAll('*').remove();
          svg = d3.select('#svg');
          g = svg.append('g');
          zoom = d3.zoom().scaleExtent([0.2, 4]).on('zoom', function(event) {
            if (event.sourceEvent) userZoomed = true;
            g.attr('transform', event.transform);
          });
          svg.call(zoom).on('dblclick.zoom', null);

          var reachable = data.nodes.filter(function(n) { return !n.orphan; }).length;
          // A handful of files shouldn't fly to the corners: forces grow with the graph.
          var n = data.nodes.length, spread = Math.min(1, 0.45 + n / 40);
          simulation = d3.forceSimulation(data.nodes)
            .force('link', d3.forceLink(data.links).id(function(d) { return d.id; })
              .distance(function(l) { return (l.source.isRoot ? 150 : 120) * spread; })
              .strength(function(l) { return l.source.isRoot ? 0.25 : 0.12; }))
            .force('charge', d3.forceManyBody().strength(-520 * spread))
            .force('center', d3.forceCenter(W / 2, H / 2))
            .force('collision', d3.forceCollide(room).iterations(2))
            // Unlinked files gather below the graph instead of drifting off-screen.
            .force('orphanY', d3.forceY(function(d) { return d.orphan && reachable ? H * 0.78 : H / 2; })
              .strength(function(d) { return d.orphan ? 0.06 : 0.03; }))
            .force('x', d3.forceX(W / 2).strength(0.03));

          linkG = g.append('g').selectAll('line')
            .data(data.links).enter().append('line')
            // MEMORY.md links every topic; its spokes recede so links between topics stand out.
            .attr('class', function(l) { return 'link' + (l.source.isRoot ? ' index' : ''); });

          nodeG = g.append('g').selectAll('.node')
            .data(data.nodes).enter().append('g')
            .attr('class', function(d) {
              return 'node' + (d.isRoot ? ' root' : '') + (d.orphan ? ' orphan' : '') + (d.oversize ? ' oversize' : '');
            })
            .call(d3.drag().on('start', dragStart).on('drag', dragged).on('end', dragEnd))
            .on('click', function(event, d) { window.webkit.messageHandlers.nodeSelected.postMessage(d.id); })
            .on('mouseenter', function(event, d) { focusNode(d); })
            .on('mouseleave', function() { focusNode(null); });

          nodeG.append('circle').attr('r', radius);
          nodeG.append('title').text(function(d) { return d.tip; });
          nodeG.append('text')
            .attr('dy', function(d) { return radius(d) + 14; })
            .text(function(d) { return short(d.label); });

          simulation.on('tick', draw);
          if (fresh) {
            // Lay out before showing, so the graph appears settled and in view, not exploding.
            simulation.stop();
            for (var i = 0; i < 320; i++) simulation.tick();
            draw();
            userZoomed = false;
            fit(false);
            simulation.alpha(0.02).restart();
          } else {
            draw();
            simulation.alpha(0.3).restart();
          }
          highlight(highlighted);
        }

        function draw() {
          linkG
            .attr('x1', function(d) { return d.source.x; }).attr('y1', function(d) { return d.source.y; })
            .attr('x2', function(d) { return d.target.x; }).attr('y2', function(d) { return d.target.y; });
          nodeG.attr('transform', function(d) { return 'translate(' + d.x + ',' + d.y + ')'; });
        }

        function fit(animate) {
          if (!current || !current.nodes.length) return;
          var x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
          current.nodes.forEach(function(n) {
            var r = radius(n);
            x0 = Math.min(x0, n.x - r - 60); x1 = Math.max(x1, n.x + r + 60);
            y0 = Math.min(y0, n.y - r - 10); y1 = Math.max(y1, n.y + r + 24);
          });
          // The legend floats over the bottom edge: fit above it.
          var legend = 44, h = Math.max(1, H - legend);
          var k = Math.min(1.6, 0.92 * Math.min(W / (x1 - x0), h / (y1 - y0)));
          var t = d3.zoomIdentity.translate(W / 2, h / 2).scale(k).translate(-(x0 + x1) / 2, -(y0 + y1) / 2);
          (animate ? svg.transition().duration(350) : svg).call(zoom.transform, t);
        }

        function focusNode(d) {
          if (!d) {
            nodeG.classed('dim', false).classed('on', false);
            linkG.classed('dim', false).classed('on', false);
            return;
          }
          var near = {}; near[d.id] = true;
          current.links.forEach(function(l) {
            if (l.source.id === d.id) near[l.target.id] = true;
            if (l.target.id === d.id) near[l.source.id] = true;
          });
          nodeG.classed('dim', function(n) { return !near[n.id]; }).classed('on', function(n) { return n.id === d.id; });
          linkG.classed('dim', function(l) { return l.source.id !== d.id && l.target.id !== d.id; })
               .classed('on', function(l) { return l.source.id === d.id || l.target.id === d.id; });
        }

        function highlight(ids) {
          highlighted = ids;
          if (!nodeG) return;
          nodeG.classed('hl', function(d) { return ids.indexOf(d.id) >= 0; });
          nodeG.select('circle').attr('r', function(d) { return radius(d) + (ids.indexOf(d.id) >= 0 ? 4 : 0); });
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

        window.addEventListener('resize', function() {
          if (!simulation) return;
          measure();
          simulation.force('center', d3.forceCenter(W / 2, H / 2));
          if (!userZoomed) fit(false);
        });

        window.loadGraph = function(data) { init(data); };
        window.highlightNode = function(ids) { highlight(ids); };
        window.fitGraph = function() { userZoomed = false; fit(true); };
        </script>
        </body>
        </html>
        """
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onNodeTap: (String) -> Void
        weak var webView: WKWebView?
        var isReady = false
        var pendingGraph: String?
        var pendingHighlights: Set<String>?
        var pendingFit = false
        /// What the page already has — the next update sends only what differs.
        var sentGraph: String?
        var sentHighlights: Set<String> = []
        var sentFitToken = 0

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
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self?.flushIfReady() }
                    }
                }
                return
            }
            // JSON is a JavaScript expression, so it goes in as an object literal — no string
            // escaping to get wrong.
            if let json = pendingGraph {
                pendingGraph = nil
                sentGraph = json
                wv.evaluateJavaScript("window.loadGraph(\(json))") { _, _ in }
            }
            if let ids = pendingHighlights {
                pendingHighlights = nil
                sentHighlights = ids
                let arr = (try? JSONSerialization.data(withJSONObject: Array(ids))).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
                wv.evaluateJavaScript("window.highlightNode(\(arr))") { _, _ in }
            }
            if pendingFit {
                pendingFit = false
                wv.evaluateJavaScript("window.fitGraph()") { _, _ in }
            }
        }
    }
}
