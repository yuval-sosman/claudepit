import SwiftUI
import ClaudepitCore

struct PluginsSection: View {
    @ObservedObject var app: AppState
    @State private var expanded: Set<String> = []
    @State private var reloading = false
    @State private var updating: Set<String> = []
    @State private var updateMessages: [String: String] = [:]
    @State private var installing: Set<String> = []
    @State private var installError: String? = nil
    @State private var installLog: String? = nil            // full CLI output of last install
    @State private var helpPopover: String? = nil           // which section header's info popover is open
    @State private var search: String = ""                  // filters the current tab's list
    @State private var uninstalling: Set<String> = []        // "pluginID::scope" keys
    @State private var uninstallConfirm: String? = nil       // "pluginID::scope" pending confirm
    @State private var uninstallError: [String: String] = [:]
    @State private var rekeyingPluginID: String? = nil
    @State private var rekeySelected: String = ""
    @State private var rekeyAddMode: Bool = false
    @State private var rekeyNewSource: String = ""
    @State private var rekeyError: String? = nil
    @State private var rekeyLoading: Bool = false

    enum Tab { case plugins, marketplaces }
    @State private var tab: Tab = .plugins
    @State private var expandedMarketplaces: Set<String> = []
    @State private var refreshingMarketplaces: Set<String> = []
    @State private var removingMarketplace: String? = nil
    @State private var marketplaceError: [String: String] = [:]
    @State private var mktAddMode: Bool = false
    @State private var mktNewSource: String = ""
    @State private var mktAdding: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                tabBar
                Spacer()
            }
            .padding(.bottom, 4)

            switch tab {
            case .plugins:
                pluginsTab
            case .marketplaces:
                marketplacesTab
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: Binding(get: { installLog.map { LogItem(text: $0) } },
                             set: { if $0 == nil { installLog = nil } })) { item in
            installLogSheet(item.text)
        }
        .onAppear { applyFocusPlugin(app.focusPluginID) }
        .onChange(of: app.focusPluginID) { _, id in applyFocusPlugin(id) }
    }

    /// When another page navigates here targeting a specific plugin, switch to the
    /// Plugins tab, filter to it, and expand its card. Consumes the focus request.
    private func applyFocusPlugin(_ id: String?) {
        guard let id else { return }
        tab = .plugins
        expanded.insert(id)
        if let p = app.store.plugins.first(where: { $0.id == id }) { search = p.name }
        app.focusPluginID = nil
    }

    private struct LogItem: Identifiable { let id = UUID(); let text: String }

    @ViewBuilder
    private func installLogSheet(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install Log").font(.headline)
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200, maxHeight: 400)
            .padding(8)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Close") { installLog = nil }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder
    private func tabButton(_ label: String, _ value: Tab) -> some View {
        let active = tab == value
        VStack(spacing: 4) {
            Text(label)
                .font(.headline)
                .foregroundStyle(active ? .primary : .secondary)
            Rectangle()
                .fill(active ? Color.accentColor : .clear)
                .frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { tab = value; search = "" }
    }

    private var tabBar: some View {
        HStack(spacing: 18) {
            tabButton("Plugins", .plugins)
            tabButton("Marketplaces", .marketplaces)
        }
    }

    private var searchBox: some View {
        HStack(spacing: 6) {
            Image(systemName: Icon.search).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Filter…", text: $search)
                .textFieldStyle(.plain)
                .font(.caption)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: Icon.clearField).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }

    private func matches(_ p: Plugin) -> Bool {
        guard !search.isEmpty else { return true }
        return p.name.localizedCaseInsensitiveContains(search)
            || p.marketplace.localizedCaseInsensitiveContains(search)
            || (p.description?.localizedCaseInsensitiveContains(search) ?? false)
    }

    @ViewBuilder
    private var pluginsTab: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(app.store.plugins.count) installed").font(.caption).foregroundStyle(.secondary)
                Spacer()
                reloadPluginsButton
            }
            searchBox
            pluginsList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var reloadPluginsButton: some View {
        Button {
            reloading = true
            Task.detached {
                shell("claude", "-p", "/reload-plugins")
                await MainActor.run {
                    reloading = false
                    app.store.reload(activePath: app.activePath)
                }
            }
        } label: {
            HStack(spacing: 4) {
                if reloading {
                    ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                } else {
                    Image(systemName: Icon.refresh).font(.system(size: 10, weight: .medium))
                }
                Text("Reload Plugins").font(.caption).fontWeight(.medium)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
        .disabled(reloading)
    }

    @ViewBuilder
    private var pluginsList: some View {
        if let activePath = app.activePath {
            let filtered = app.store.plugins.filter(matches)
            let active = filtered.filter { isActive($0, for: activePath) }
            let available = filtered.filter { !isActive($0, for: activePath) }
            GeometryReader { geo in
                VStack(spacing: 12) {
                    pluginSection(title: "Active for \(activePath.lastPathComponent)", plugins: active,
                                  help: "Installed in a scope that applies to \(activePath.lastPathComponent): user (global), or project/local set to this folder.")
                        .frame(height: (geo.size.height - 12) / 2)
                    pluginSection(title: "Installed elsewhere", plugins: available, isAvailable: true,
                                  help: "Installed on this machine but scoped to a different project, so not active for \(activePath.lastPathComponent).")
                        .frame(height: (geo.size.height - 12) / 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ForEach(app.store.plugins.filter(matches)) { p in pluginRow(p) }
        }
    }

    @ViewBuilder
    private var marketplacesTab: some View {
        let markets = Marketplaces.load(Paths.knownMarketplaces)
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.sourceValue.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name < $1.name }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(markets.count) configured").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    mktAddMode.toggle()
                    mktNewSource = ""
                    marketplaceError.removeValue(forKey: "__add__")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: Icon.add).font(.system(size: 10, weight: .medium))
                        Text("Add marketplace…").font(.caption).fontWeight(.medium)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
            searchBox
            if mktAddMode { addMarketplaceForm }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(markets) { marketplaceRow($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.10), lineWidth: 1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var addMarketplaceForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GitHub repo (owner/repo), URL, or local path").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("e.g. obra/superpowers", text: $mktNewSource)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    mktAdding = true
                    marketplaceError.removeValue(forKey: "__add__")
                    let source = mktNewSource
                    Task.detached {
                        let out = shell("claude", "plugin", "marketplace", "add", source)
                        let failed = out.lowercased().contains("error") || out.lowercased().contains("failed")
                        await MainActor.run {
                            mktAdding = false
                            if failed {
                                marketplaceError["__add__"] = out.components(separatedBy: .newlines).first { !$0.isEmpty } ?? "Failed"
                            } else {
                                mktAddMode = false
                                mktNewSource = ""
                                app.store.reload(activePath: app.activePath)
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(mktNewSource.isEmpty || mktAdding)
            }
            if let err = marketplaceError["__add__"] {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func relativeDate(_ iso: String?) -> String? {
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private func marketplaceRow(_ m: Marketplace) -> some View {
        let isExpanded = expandedMarketplaces.contains(m.name)
        let isRefreshing = refreshingMarketplaces.contains(m.name)
        let isConfirming = removingMarketplace == m.name
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isExpanded ? Color.accentColor : .secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(m.name).font(.body).bold()
                        Pill(m.sourceLabel, color: .purple, hPadding: 7, vPadding: 2)
                    }
                    Text(m.sourceValue)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if let updated = relativeDate(m.lastUpdated) {
                        Text(updated).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isConfirming {
                    HStack(spacing: 6) {
                        Text("Remove \(m.name)?").font(.caption).foregroundStyle(.secondary)
                        Button("Cancel") { removingMarketplace = nil }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        Button("Remove") {
                            removingMarketplace = nil
                            let name = m.name
                            marketplaceError.removeValue(forKey: name)
                            Task.detached {
                                let out = shell("claude", "plugin", "marketplace", "remove", name)
                                let failed = out.lowercased().contains("error") || out.lowercased().contains("failed") || out.contains("✘")
                                await MainActor.run {
                                    if failed {
                                        marketplaceError[name] = out.components(separatedBy: .newlines).first { !$0.isEmpty } ?? "Remove failed"
                                    } else {
                                        app.store.reload(activePath: app.activePath)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.red)
                    }
                } else {
                    Button {
                        refreshingMarketplaces.insert(m.name)
                        let name = m.name
                        marketplaceError.removeValue(forKey: name)
                        Task.detached {
                            let out = shell("claude", "plugin", "marketplace", "update", name)
                            let failed = out.lowercased().contains("error") || out.lowercased().contains("failed") || out.contains("✘")
                            await MainActor.run {
                                refreshingMarketplaces.remove(name)
                                if failed {
                                    marketplaceError[name] = out.components(separatedBy: .newlines).first { !$0.isEmpty } ?? "Refresh failed"
                                } else {
                                    app.store.reload(activePath: app.activePath)
                                }
                            }
                        }
                    } label: {
                        if isRefreshing {
                            ProgressView().scaleEffect(0.6).frame(width: 24, height: 24)
                        } else {
                            Image(systemName: Icon.refresh)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary).frame(width: 24, height: 24)
                        }
                    }
                    .buttonStyle(.plain).disabled(isRefreshing)
                    Button { removingMarketplace = m.name } label: {
                        Image(systemName: Icon.delete)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary).frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded { expandedMarketplaces.remove(m.name) } else { expandedMarketplaces.insert(m.name) }
                }
            }
            if let err = marketplaceError[m.name] {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal, 12).padding(.bottom, 6)
            }
            if isExpanded {
                marketplaceCatalog(m)
                    .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 12).padding(.leading, 22)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(.white.opacity(isExpanded ? 0.06 : 0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func marketplaceCatalog(_ m: Marketplace) -> some View {
        let plugins = Marketplaces.catalog(installLocation: m.installLocation).sorted { $0.name < $1.name }
        let installed = Marketplaces.installedKeys(Paths.installedPlugins)
        VStack(alignment: .leading, spacing: 6) {
            if plugins.isEmpty {
                Text("No plugins in catalog.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(plugins) { p in
                    let key = "\(p.name)@\(m.name)"
                    let isInstalled = installed.contains(key)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.subheadline).fontWeight(.semibold)
                            if let d = p.description {
                                Text(d).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if isInstalled {
                            Pill("installed", color: .green, hPadding: 7, vPadding: 2)
                        } else {
                            let isInstalling = installing.contains(key)
                            Menu {
                                Button("Install for User") { runInstall(key, scope: "user") }
                                if let activePath = app.activePath {
                                    Button("Install for \(activePath.lastPathComponent)") {
                                        runInstall(key, scope: "project", projectPath: activePath.path)
                                    }
                                }
                                Button("Install for Local") { runInstall(key, scope: "local") }
                            } label: {
                                HStack(spacing: 4) {
                                    if isInstalling {
                                        ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                                    } else {
                                        Image(systemName: Icon.addCircle).font(.system(size: 11, weight: .medium))
                                    }
                                    Text(isInstalling ? "Installing..." : "Install").font(.caption).fontWeight(.medium)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                                .foregroundStyle(.blue)
                            }
                            .menuStyle(.borderlessButton).fixedSize().disabled(isInstalling)
                        }
                    }
                    .padding(.vertical, 6).padding(.horizontal, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    @ViewBuilder
    private func pluginSection(title: String, plugins: [Plugin], isAvailable: Bool = false, help: String = "") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline).foregroundStyle(.secondary)
                if !help.isEmpty {
                    Button { helpPopover = (helpPopover == title) ? nil : title } label: {
                        Image(systemName: Icon.info)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(help)   // hover tooltip when the window is key
                    .popover(isPresented: Binding(
                        get: { helpPopover == title },
                        set: { if !$0 { helpPopover = nil } })) {
                        Text(help)
                            .font(.callout)
                            .padding(12)
                            .frame(width: 260)
                    }
                }
                Spacer()
                Text("\(plugins.count)").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if isAvailable, let errMsg = installError {
                        HStack(spacing: 8) {
                            Text(errMsg)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                installError = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(.orange.opacity(0.20), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.orange.opacity(0.35), lineWidth: 1))
                    }
                    if plugins.isEmpty {
                        Text("—").font(.caption).foregroundStyle(.tertiary)
                    } else {
                        ForEach(plugins) { pluginRow($0, isAvailable: isAvailable) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.10), lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func isActive(_ p: Plugin, for activePath: URL) -> Bool {
        ConfigStore.pluginActive(p, for: activePath.path)
    }

    @ViewBuilder
    private func scopeBadge(_ scope: Scope, count: Int = 1) -> some View {
        let label: String = switch scope {
        case .global:  "user"
        case .project: "project"
        case .local:   "local"
        default:       "plugin"
        }
        let text = count > 1 ? "\(label) ×\(count)" : label
        Pill(text, color: .scopeColor(scope), hPadding: 7, vPadding: 2)
    }

    // Collapsed row: show unique scopes with counts
    @ViewBuilder
    private func installBadges(_ installs: [PluginInstall]) -> some View {
        let grouped = Dictionary(grouping: installs, by: \.scope)
        let order: [Scope] = [.global, .project, .local]
        HStack(spacing: 4) {
            ForEach(order, id: \.self) { scope in
                if let entries = grouped[scope] {
                    scopeBadge(scope, count: entries.count)
                }
            }
        }
    }

    @ViewBuilder
    private func pluginRow(_ p: Plugin, isAvailable: Bool = false) -> some View {
        let isUpdating = updating.contains(p.id)
        let cliScope = p.scope == .global ? "user" : p.scope.rawValue
        let expandedBinding = Binding<Bool>(
            get: { expanded.contains(p.id) },
            set: { newVal in if newVal { expanded.insert(p.id) } else { expanded.remove(p.id) } }
        )
        ExpandableCard(expanded: expandedBinding) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(p.name).font(.body).bold()
                        installBadges(p.allInstalls.isEmpty ? [PluginInstall(scope: p.scope, projectPath: p.projectPath, installPath: p.installPath, version: p.version)] : p.allInstalls)
                        Text("\(p.skillCount) skills, \(p.commandCount) cmds, \(p.agentCount) agents, \(p.mcpCount) mcp")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Marketplace")
                                .font(.caption2).fontWeight(.bold)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase).tracking(0.6)
                            Button {
                                tab = .marketplaces
                                search = p.marketplace
                            } label: {
                                Text(p.marketplace)
                                    .font(.caption).foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                        if p.updateAvailable, let latest = p.latestCachedVersion {
                            Text("· v\(p.version) → v\(latest)")
                                .font(.caption).fontWeight(.medium)
                                .foregroundStyle(.orange)
                        }
                    }
                    if let msg = updateMessages[p.id] {
                        Text(msg).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if p.updateAvailable || isUpdating {
                    Button {
                        let pluginID = p.id
                        updating.insert(pluginID)
                        Task.detached {
                            let output = shell("claude", "plugins", "update", pluginID, "--scope", cliScope)
                            let lines = output.components(separatedBy: .newlines)
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                            let msg: String
                            if let line = lines.first(where: { $0.contains("updated from") || $0.contains("refreshed from") }) {
                                msg = line.replacingOccurrences(of: "✔ ", with: "")
                                await MainActor.run { app.store.reload(activePath: app.activePath) }
                            } else if lines.contains(where: { $0.contains("latest version") || $0.contains("already at") }) {
                                msg = "Already at latest version"
                            } else if let err = lines.first(where: { $0.contains("✘") || $0.contains("Failed") }) {
                                msg = err.replacingOccurrences(of: "✘ ", with: "")
                            } else {
                                msg = lines.last ?? "Done"
                            }
                            await MainActor.run {
                                updating.remove(pluginID)
                                updateMessages[pluginID] = msg
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isUpdating {
                                ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "arrow.up.circle")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            Text(isUpdating ? "Updating..." : "Update")
                                .font(.caption).fontWeight(.medium)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .disabled(isUpdating)
                }

                if isAvailable {
                    let isInstalling = installing.contains(p.id)
                    Menu {
                        Button("Install for User") {
                            runInstall(p.id, scope: "user")
                        }
                        if let activePath = app.activePath {
                            Button("Install for \(activePath.lastPathComponent)") {
                                runInstall(p.id, scope: "project", projectPath: activePath.path)
                            }
                        }
                        Button("Install for Local") {
                            runInstall(p.id, scope: "local")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isInstalling {
                                ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                            } else {
                                Image(systemName: Icon.addCircle)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            Text(isInstalling ? "Installing..." : "Install")
                                .font(.caption).fontWeight(.medium)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(.blue)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(isInstalling)
                }

                if !isAvailable {
                    let installs = p.allInstalls.isEmpty
                        ? [PluginInstall(scope: p.scope, projectPath: p.projectPath, installPath: p.installPath, version: p.version)]
                        : p.allInstalls
                    pluginEnableToggles(p)
                    // Single scope: inline-confirm trash. Multi-scope: pick which to remove.
                    if installs.count == 1 {
                        trashButton(p, install: installs[0])
                    } else {
                        multiScopeTrash(p, installs: installs)
                    }
                }
            }
        } detail: {
            VStack(alignment: .leading, spacing: 10) {
                pluginDetail(p)
                if !p.contributions.isEmpty {
                    contributionsList(p.contributions)
                }
            }
        }
    }

    @ViewBuilder
    private func pluginEnableToggles(_ p: Plugin) -> some View {
        let installs = p.allInstalls.isEmpty
            ? [PluginInstall(scope: p.scope, projectPath: p.projectPath, installPath: p.installPath, version: p.version)]
            : p.allInstalls
        let hasGlobalInstall = installs.contains { $0.scope == .global }
        let hasProjectInstall = installs.contains { $0.scope == .project || $0.scope == .local }
        HStack(spacing: 10) {
            // Effective (read-only)
            HStack(spacing: 4) {
                Text("effective").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                PillToggle(isOn: p.enabled) { _ in }
                    .disabled(true)
                    .opacity(0.55)
                    .help(p.enabled ? "Enabled (effective)" : "Disabled (effective)")
            }
            // User (global) — only editable if installed globally
            HStack(spacing: 4) {
                Text("user").font(.caption2)
                    .foregroundStyle(hasGlobalInstall ? .blue.opacity(0.8) : .secondary.opacity(0.4))
                    .lineLimit(1)
                scopeSegment(value: p.globalEnabled, settingsURL: Paths.globalSettings,
                             pluginID: p.id, enabled: hasGlobalInstall)
            }
            .help(hasGlobalInstall ? "" : "Not installed in user scope")
            // Project — only editable if installed in project/local scope
            HStack(spacing: 4) {
                Text("project").font(.caption2)
                    .foregroundStyle(hasProjectInstall ? .green.opacity(0.8) : .secondary.opacity(0.4))
                    .lineLimit(1)
                if let base = app.activePath {
                    scopeSegment(value: p.projectEnabled, settingsURL: Paths.projectSettings(base),
                                 pluginID: p.id, enabled: hasProjectInstall)
                } else {
                    ThreeStateSegment(value: nil as Bool?, enabled: false) { _ in }
                        .help("No project open")
                }
            }
            .help(hasProjectInstall ? "" : "Not installed in project scope")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func scopeSegment(value: Bool?, settingsURL: URL, pluginID: String, enabled: Bool = true) -> some View {
        ThreeStateSegment(value: value, enabled: enabled) { newState in
            switch newState {
            case .on:
                try? WriteOps.setPluginEnabled(pluginID, true, in: settingsURL,
                                               epoch: Int(Date().timeIntervalSince1970))
            case .off:
                try? WriteOps.setPluginEnabled(pluginID, false, in: settingsURL,
                                               epoch: Int(Date().timeIntervalSince1970))
            case .unset:
                try? WriteOps.removePluginEnabled(pluginID, in: settingsURL,
                                                  epoch: Int(Date().timeIntervalSince1970))
            }
            app.store.reload(activePath: app.activePath)
        }
    }

    @ViewBuilder
    private func pluginDetail(_ p: Plugin) -> some View {
        let installs = p.allInstalls.isEmpty
            ? [PluginInstall(scope: p.scope, projectPath: p.projectPath, installPath: p.installPath, version: p.version)]
            : p.allInstalls
        VStack(alignment: .leading, spacing: 10) {
            if let desc = p.description {
                Text(desc).font(.subheadline).foregroundStyle(.primary.opacity(0.75))
            }

            // Installed in section
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "location").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Text("Installed in").font(.caption).fontWeight(.bold).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.6)
                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                }
                ForEach(Array(installs.enumerated()), id: \.offset) { _, install in
                    uninstallRow(p, install: install)
                }
                if installs.count > 1 {
                    let allKey = "\(p.id)::all"
                    let isUninstallingAll = uninstalling.contains(allKey)
                    HStack {
                        Spacer()
                        if isUninstallingAll {
                            ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                        } else {
                            Button("Remove all") {
                                uninstalling.insert(allKey)
                                let pluginID = p.id
                                let installsCopy = installs
                                Task.detached {
                                    for install in installsCopy {
                                        let scopeStr: String = switch install.scope {
                                        case .global: "user"
                                        case .project: "project"
                                        case .local: "local"
                                        default: "user"
                                        }
                                        let args = ["claude", "plugin", "uninstall", pluginID, "--scope", scopeStr, "-y"]
                                        shellArgs(args, cwd: scopeStr == "project" ? install.projectPath : nil)
                                    }
                                    await MainActor.run {
                                        uninstalling.remove(allKey)
                                        app.store.reload(activePath: app.activePath)
                                    }
                                }
                            }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.red.opacity(0.8))
                        }
                    }
                }
            }

            // Source link
            if let src = p.marketplaceSource {
                if src.hasPrefix("http"), let url = URL(string: src) {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Image(systemName: Icon.externalLink).font(.system(size: 11))
                            Text(src).lineLimit(1).truncationMode(.middle)
                        }
                        .font(.caption)
                    }
                } else {
                    Button { NSWorkspace.shared.open(URL(filePath: src)) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: Icon.revealInFinder).font(.system(size: 11))
                            Text(src).lineLimit(1).truncationMode(.middle)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else if let urlStr = p.marketplaceURL, let url = URL(string: urlStr) {
                Link(urlStr, destination: url).font(.caption).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private func contributionsList(_ contribs: [PluginContribution]) -> some View {
        let order: [PluginContribution.Kind] = [.skill, .command, .agent, .mcp, .hook]
        let meta: [PluginContribution.Kind: (label: String, icon: String)] = [
            .skill:   ("Skills",      "wand.and.stars"),
            .command: ("Commands",    "terminal"),
            .agent:   ("Agents",      "person.2"),
            .mcp:     ("MCP Servers", "server.rack"),
            .hook:    ("Hooks",       "link"),
        ]
        VStack(alignment: .leading, spacing: 12) {
            ForEach(order, id: \.self) { kind in
                let group = contribs.filter { $0.kind == kind }
                if !group.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: meta[kind]?.icon ?? "square")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(meta[kind]?.label ?? "")
                                .font(.caption).fontWeight(.bold)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .tracking(0.6)
                            Rectangle()
                                .fill(.white.opacity(0.08))
                                .frame(height: 1)
                        }
                        ForEach(group, id: \.name) { c in
                            contributionRow(c)
                        }
                    }
                }
            }
        }
    }

    private func runInstall(_ pluginID: String, scope: String, projectPath: String? = nil) {
        installing.insert(pluginID)
        installError = nil
        Task.detached {
            let args = ["claude", "plugin", "install", pluginID, "--scope", scope]
            // project scope keys off the CLI's cwd, not a flag
            let output = shellArgs(args, cwd: scope == "project" ? projectPath : nil)
            let lines = output.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let failed = lines.contains { $0.hasPrefix("✘") || $0.lowercased().contains("error") || $0.lowercased().contains("failed") }
            await MainActor.run {
                installing.remove(pluginID)
                let cwdNote = (scope == "project" && projectPath != nil) ? "  (in \(projectPath!))" : ""
                installLog = "$ claude plugin install \(pluginID) --scope \(scope)\(cwdNote)\n\n" + (output.isEmpty ? "(no output)" : output)
                if failed {
                    installError = lines.first { $0.hasPrefix("✘") || $0.lowercased().contains("error") || $0.lowercased().contains("failed") }
                        ?? lines.last ?? "Installation failed"
                } else {
                    installError = nil
                    app.store.reload(activePath: app.activePath)
                }
            }
        }
    }

    @ViewBuilder
    private func rekeyPopover(for pluginID: String) -> some View {
        let names = knownMarketplaceNames()
        VStack(alignment: .leading, spacing: 10) {
            Text("Change Marketplace").font(.headline)
            if rekeyAddMode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("GitHub repo, URL, or local path").font(.caption).foregroundStyle(.secondary)
                    TextField("e.g. obra/superpowers", text: $rekeyNewSource)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                    HStack {
                        Button("Cancel") { rekeyAddMode = false; rekeyNewSource = "" }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        Spacer()
                        Button("Add & Select") {
                            rekeyLoading = true
                            rekeyError = nil
                            let source = rekeyNewSource
                            Task.detached {
                                let out = shell("claude", "plugin", "marketplace", "add", source)
                                let failed = out.lowercased().contains("error") || out.lowercased().contains("failed")
                                await MainActor.run {
                                    rekeyLoading = false
                                    if failed {
                                        rekeyError = out.components(separatedBy: .newlines).first { !$0.isEmpty } ?? "Failed"
                                    } else {
                                        // derive marketplace name: last path component of source
                                        let derived = source.split(separator: "/").last.map(String.init) ?? source
                                        rekeySelected = derived
                                        rekeyAddMode = false
                                        rekeyNewSource = ""
                                    }
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(rekeyNewSource.isEmpty || rekeyLoading)
                    }
                }
            } else {
                Picker("Marketplace", selection: $rekeySelected) {
                    ForEach(names, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 260)
                Button("Add new marketplace…") { rekeyAddMode = true }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
            }
            if let err = rekeyError {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") {
                    rekeyingPluginID = nil
                    rekeyError = nil
                    rekeyAddMode = false
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button("Save") {
                    rekeyLoading = true
                    rekeyError = nil
                    let id = pluginID
                    let marketplace = rekeySelected
                    Task.detached {
                        do {
                            try WriteOps.rekeyPlugin(id: id, newMarketplace: marketplace,
                                                     in: Paths.installedPlugins)
                            await MainActor.run {
                                rekeyingPluginID = nil
                                rekeyLoading = false
                                app.store.reload(activePath: app.activePath)
                            }
                        } catch {
                            await MainActor.run {
                                rekeyError = error.localizedDescription
                                rekeyLoading = false
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(rekeySelected.isEmpty || rekeyLoading || rekeyAddMode)
            }
        }
        .padding(16)
        .frame(minWidth: 300)
    }

    @ViewBuilder
    private func contributionRow(_ c: PluginContribution) -> some View {
        let pathLabel = c.kind == .mcp
            ? ".mcp.json → mcpServers.\(c.name)"
            : c.path.lastPathComponent
        let sectionRaw: String = switch c.kind {
            case .skill: "skills"
            case .command: "commands"
            case .agent: "agents"
            case .mcp: "mcp"
            case .hook: "hooks"
        }
        Button { app.navigate(to: sectionRaw, itemID: c.name) } label: {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(c.name).font(.subheadline).fontWeight(.semibold).foregroundStyle(Color.accentColor)
                        Text(pathLabel)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if let desc = c.description {
                        Text(desc).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6).padding(.horizontal, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    // Multi-scope plugin: trash opens a menu to pick which scope to remove.
    @ViewBuilder
    private func multiScopeTrash(_ p: Plugin, installs: [PluginInstall]) -> some View {
        let busy = installs.contains { uninstalling.contains("\(p.id)::\(scopeString($0.scope))") }
        Menu {
            ForEach(Array(installs.enumerated()), id: \.offset) { _, install in
                let scopeStr = scopeString(install.scope)
                Button("Remove from \(scopeStr)", role: .destructive) {
                    performUninstall(p, install: install, scopeStr: scopeStr, key: "\(p.id)::\(scopeStr)")
                }
            }
        } label: {
            if busy {
                ProgressView().scaleEffect(0.7).frame(width: 22, height: 22)
            } else {
                Image(systemName: Icon.delete)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(width: 22, height: 22)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Uninstall plugin — installed in multiple scopes, choose which to remove")
    }

    private func scopeString(_ scope: Scope) -> String {
        switch scope {
        case .global:  "user"
        case .project: "project"
        case .local:   "local"
        default:       "user"
        }
    }

    @ViewBuilder
    // Shared trash button + inline confirm, used both next to the toggle
    // (single-scope) and in each per-scope "Installed in" row.
    private func trashButton(_ p: Plugin, install: PluginInstall) -> some View {
        let scopeStr = scopeString(install.scope)
        let key = "\(p.id)::\(scopeStr)"
        let isUninstalling = uninstalling.contains(key)
        let isConfirming = uninstallConfirm == key

        if isUninstalling {
            ProgressView().scaleEffect(0.7).frame(width: 18, height: 18)
        } else if isConfirming {
            HStack(spacing: 6) {
                Text("Remove?").font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { uninstallConfirm = nil }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                Button("Remove") { performUninstall(p, install: install, scopeStr: scopeStr, key: key) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.red)
            }
        } else {
            Button { uninstallConfirm = key } label: {
                Image(systemName: Icon.delete)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(p.allInstalls.count <= 1
                ? "Uninstall plugin — removes all files from the \(scopeStr) scope and deletes the local installation"
                : "Remove \(scopeStr) install — uninstalls from \(scopeStr) scope only; other installs remain")
        }
    }

    private func performUninstall(_ p: Plugin, install: PluginInstall, scopeStr: String, key: String) {
        uninstallConfirm = nil
        uninstalling.insert(key)
        uninstallError.removeValue(forKey: key)
        let pluginID = p.id
        let projectPath = install.projectPath
        Task.detached {
            let args = ["claude", "plugin", "uninstall", pluginID, "--scope", scopeStr, "-y"]
            let out = shellArgs(args, cwd: scopeStr == "project" ? projectPath : nil)
            let failed = out.lowercased().contains("error") || out.lowercased().contains("failed") || out.contains("✘")
            await MainActor.run {
                uninstalling.remove(key)
                if failed {
                    uninstallError[key] = out.components(separatedBy: .newlines)
                        .first { !$0.isEmpty } ?? "Uninstall failed"
                } else {
                    app.store.reload(activePath: app.activePath)
                }
            }
        }
    }

    private func uninstallRow(_ p: Plugin, install: PluginInstall) -> some View {
        let scopeStr: String = switch install.scope {
        case .global:  "user"
        case .project: "project"
        case .local:   "local"
        default:       "user"
        }
        let key = "\(p.id)::\(scopeStr)"

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let proj = install.projectPath {
                    Button { NSWorkspace.shared.open(URL(filePath: proj)) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "folder").font(.system(size: 10))
                            Text(URL(filePath: proj).lastPathComponent).font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text("v\(install.version)").font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(install.installPath.path)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            if let err = uninstallError[key] {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func knownMarketplaceNames() -> [String] {
        guard let obj = try? JSONFile.readObject(Paths.knownMarketplaces) else { return [] }
        return obj.keys.sorted()
    }
}

// ponytail: a GUI-launched app has a minimal PATH, so `env claude` fails to
// find the CLI. Resolve real paths and augment PATH with the usual install dirs.
private let shellPATH: String = {
    let extra = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    let current = ProcessInfo.processInfo.environment["PATH"] ?? ""
    return (extra + [current]).joined(separator: ":")
}()

@discardableResult
private func runProcess(_ args: [String], cwd: String? = nil) -> String {
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/env")
    p.arguments = args
    // Project scope is determined by the CLI's working directory (there is no
    // --project-path flag), so run in the active project dir when given one.
    if let cwd { p.currentDirectoryURL = URL(filePath: cwd) }
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = shellPATH
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    // ponytail: without this the child inherits the GUI app's stdin, which never
    // delivers EOF, so `claude plugin install` blocks forever waiting on it.
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch {
        return "Failed to launch: \(error.localizedDescription)"
    }
    // Read before waitUntilExit so a full pipe buffer can't deadlock the child.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

@discardableResult
func shell(_ args: String..., cwd: String? = nil) -> String {
    runProcess(args, cwd: cwd)
}

@discardableResult
private func shellArgs(_ args: [String], cwd: String? = nil) -> String {
    runProcess(args, cwd: cwd)
}
