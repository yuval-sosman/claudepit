import SwiftUI
import ClaudepitCore

struct MCPServerCard: View {
    let server: MCPServer
    @ObservedObject var app: AppState
    @State private var expanded = false
    @State private var result: MCPServerResult = .idle
    @State private var toolsExpanded: Set<String> = []

    private var pluginID: String? { server.origin.pluginID }

    private var canToggle: Bool {
        server.origin == .user && server.scope != .plugin
            && server.sourcePath.lastPathComponent != ".claude.json"
    }

    var body: some View {
        ExpandableCard(expanded: $expanded) { header } detail: { detail }
        .onChange(of: expanded) { _, isExpanded in
            if isExpanded, case .idle = result { fetchTools() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.displayName)
                        .font(.body).bold()
                        .strikethrough(server.isOverridden)
                        .foregroundStyle(server.isOverridden ? .secondary : .primary)
                    statusDot
                    if let pid = pluginID {
                        Button { jumpToPlugin(pid) } label: {
                            Pill(pid.components(separatedBy: "@").first ?? pid, color: .purple)
                        }
                        .buttonStyle(.plain)
                        .help("Show \(pid) on the Plugins page")
                    } else {
                        ProvenanceBadge(scope: server.scope, origin: server.origin)
                    }
                    if let transport = server.transport {
                        Pill(transport, color: .teal, hPadding: 7, vPadding: 2)
                    }
                }
                if !expanded {
                    Text(server.command)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if canToggle {
                Toggle("", isOn: Binding(
                    get: { server.enabled },
                    set: { newVal in
                        try? WriteOps.setMCPEnabled(server.id, newVal, in: server.sourcePath,
                                                    epoch: Int(Date().timeIntervalSince1970))
                        app.store.reload(activePath: app.activePath)
                    }
                )).labelsHidden()
            }
            OpenInEditorButton(url: server.sourcePath, onDelete: server.origin.pluginID == nil ? {
                try? WriteOps.removeMCPServer(server.id, in: server.sourcePath,
                                              epoch: Int(Date().timeIntervalSince1970))
                app.store.reload(activePath: app.activePath)
            } : nil)
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch result {
        case .idle:
            EmptyView()
        case .loading:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 10, height: 10)
        case .connected(let tools):
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("\(tools.count) tools")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        case .needsAuth:
            HStack(spacing: 4) {
                Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.orange)
                Text("needs auth").font(.caption2).foregroundStyle(.orange)
            }
        case .failed:
            Circle().fill(.red).frame(width: 7, height: 7)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Command/URL section
            SectionHeaderLabel("Command", icon: "terminal")
            Text(([server.command] + server.args).joined(separator: " "))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6).padding(.horizontal, 9)
                .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))

            // Tools section
            toolsSection

            sourceRow

            if let pid = pluginID {
                Button { jumpToPlugin(pid) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "puzzlepiece.extension").font(.system(size: 11))
                        Text("Provided by \(pid)").font(.caption)
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var toolsSection: some View {
        switch result {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6)
                Text("Connecting…").font(.caption).foregroundStyle(.secondary)
            }
        case .needsAuth:
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").foregroundStyle(.orange).font(.system(size: 11))
                Text("Requires authentication — run \"/mcp\" in Claude Code to authenticate.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let reason):
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.system(size: 11))
                Text(reason).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") { fetchTools() }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
        case .connected(let tools):
            if !tools.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeaderLabel("Tools (\(tools.count))", icon: "wrench.and.screwdriver")
                    ForEach(tools) { toolRow($0) }
                }
            }
        }
    }

    @ViewBuilder
    private func toolRow(_ tool: MCPTool) -> some View {
        let isOpen = toolsExpanded.contains(tool.name)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isOpen ? Color.accentColor : .secondary)
                    .frame(width: 10)
                Text(tool.title ?? tool.name)
                    .font(.caption).fontWeight(.semibold)
                if tool.readOnly {
                    annotationBadge("read-only", color: .teal)
                }
                if tool.destructive {
                    annotationBadge("destructive", color: .orange)
                }
                Spacer()
                Text(tool.name).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isOpen { toolsExpanded.remove(tool.name) }
                    else { toolsExpanded.insert(tool.name) }
                }
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 4) {
                    if !tool.description.isEmpty {
                        Text(tool.description)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !tool.parameters.isEmpty {
                        ForEach(tool.parameters, id: \.name) { p in
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(p.name)
                                    .font(.caption2.monospaced()).fontWeight(.semibold)
                                    .foregroundStyle(p.required ? .primary : .secondary)
                                Text(p.type)
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                if let desc = p.description {
                                    Text("— \(desc)").font(.caption2).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 14).padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
    }

    private func annotationBadge(_ label: String, color: Color) -> some View {
        Pill(label, color: color, hPadding: 6, vPadding: 2)
    }

    private var sourceRow: some View {
        FilePathLabel(url: server.sourcePath)
    }

    private func jumpToPlugin(_ pid: String) {
        app.focusPluginID = pid
        app.selected = .plugins
    }

    private func fetchTools() {
        result = .loading
        let server = self.server
        Task {
            let r = await MCPClient.listTools(for: server)
            await MainActor.run { result = r }
        }
    }
}
