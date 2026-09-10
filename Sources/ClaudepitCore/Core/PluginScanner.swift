import Foundation

public struct PluginContribution {
    public enum Kind: Hashable { case skill, command, agent, mcp, hook }
    public let pluginID: String
    public let kind: Kind
    public let name: String
    public let path: URL
    public let description: String?

    public init(pluginID: String, kind: Kind, name: String, path: URL, description: String? = nil) {
        self.pluginID = pluginID
        self.kind = kind
        self.name = name
        self.path = path
        self.description = description
    }
}

public struct PluginInstall: Sendable {
    public let scope: Scope
    public let projectPath: String?
    public let installPath: URL
    public let version: String

    public init(scope: Scope, projectPath: String?, installPath: URL, version: String) {
        self.scope = scope
        self.projectPath = projectPath
        self.installPath = installPath
        self.version = version
    }

    public var projectName: String? {
        projectPath.map { URL(filePath: $0).lastPathComponent }
    }
}

public struct PluginScanner {
    public let pluginsRoot: URL
    public let enabledPlugins: [String: Bool]

    public init(pluginsRoot: URL, enabledPlugins: [String: Bool]) {
        self.pluginsRoot = pluginsRoot
        self.enabledPlugins = enabledPlugins
    }

    public func scan() -> (plugins: [Plugin], contributions: [PluginContribution]) {
        let installedURL = pluginsRoot.appending(path: "installed_plugins.json")
        guard let root = try? JSONFile.readObject(installedURL),
              let plugins = root["plugins"] as? [String: Any] else {
            return ([], [])
        }

        // Build marketplace source map: marketplaceName → base repo URL
        var marketplaceSource: [String: String] = [:]
        if let mkts = try? JSONFile.readObject(pluginsRoot.appending(path: "known_marketplaces.json")) {
            for (mktName, val) in mkts {
                guard let info = val as? [String: Any],
                      let src = info["source"] as? [String: Any] else { continue }
                let kind = src["source"] as? String ?? ""
                if kind == "github", let repo = src["repo"] as? String {
                    marketplaceSource[mktName] = "https://github.com/\(repo)"
                } else if kind == "git", let url = src["url"] as? String {
                    marketplaceSource[mktName] = url.hasSuffix(".git") ? String(url.dropLast(4)) : url
                } else if kind == "directory", let path = src["path"] as? String {
                    marketplaceSource[mktName] = path
                }
            }
        }

        // Build per-plugin source paths from catalog cache (public marketplaces)
        var pluginSourcePath: [String: String] = [:]  // fullID → subdir path like "plugins/gopls-lsp"
        if let catalog = try? JSONFile.readObject(pluginsRoot.appending(path: "plugin-catalog-cache.json")),
           let catalogData = catalog["catalog"] as? [String: Any],
           let catalogPlugins = catalogData["plugins"] as? [String: Any] {
            for (fullID, val) in catalogPlugins {
                guard let entry = val as? [String: Any],
                      let mktEntry = entry["marketplace_entry"] as? [String: Any],
                      let src = mktEntry["source"] as? String else { continue }
                pluginSourcePath[fullID] = src.hasPrefix("./") ? String(src.dropFirst(2)) : src
            }
        }
        // Also read per-marketplace marketplace.json for private marketplaces
        if let mkts = try? JSONFile.readObject(pluginsRoot.appending(path: "known_marketplaces.json")) {
            for (mktName, val) in mkts {
                guard let info = val as? [String: Any],
                      let installLoc = info["installLocation"] as? String else { continue }
                let mktManifest = URL(filePath: installLoc).appending(path: ".claude-plugin/marketplace.json")
                guard let mktData = try? JSONFile.readObject(mktManifest),
                      let pluginsList = mktData["plugins"] as? [[String: Any]] else { continue }
                for entry in pluginsList {
                    guard let pName = entry["name"] as? String,
                          let src = entry["source"] as? String else { continue }
                    let fullID = "\(pName)@\(mktName)"
                    if pluginSourcePath[fullID] == nil {
                        pluginSourcePath[fullID] = src.hasPrefix("./") ? String(src.dropFirst(2)) : src
                    }
                }
            }
        }
        var out: [Plugin] = []
        var contribs: [PluginContribution] = []

        for (fullID, value) in plugins {
            guard let installs = value as? [[String: Any]], !installs.isEmpty else { continue }

            let parts = fullID.split(separator: "@", maxSplits: 1).map(String.init)
            let name = parts.first ?? fullID
            let market = parts.count > 1 ? parts[1] : "unknown"

            // Build all install entries
            let allInstalls: [PluginInstall] = installs.compactMap { entry in
                guard let pathStr = entry["installPath"] as? String else { return nil }
                let installPath = URL(filePath: pathStr)
                let scopeStr = entry["scope"] as? String ?? "user"
                let scope: Scope = scopeStr == "project" ? .project : scopeStr == "local" ? .local : .global
                let ver = entry["version"] as? String ?? "unknown"
                return PluginInstall(scope: scope, projectPath: entry["projectPath"] as? String,
                                     installPath: installPath, version: ver)
            }
            guard let first = allInstalls.first else { continue }

            // Use first install for manifest/contributions
            let manifest = first.installPath.appending(path: ".claude-plugin/plugin.json")
            let manifestObj = try? JSONFile.readObject(manifest)
            let version = first.version != "unknown" ? first.version
                : (manifestObj?["version"] as? String) ?? "unknown"

            let description = manifestObj?["description"] as? String
            let marketplaceURL = (manifestObj?["homepage"] as? String) ?? (manifestObj?["url"] as? String)

            // Build direct source link: plugin subdir if available, else marketplace root
            let mktBase = marketplaceSource[market]
            let pluginSource: String?
            if let base = mktBase {
                if base.hasPrefix("http"), let subPath = pluginSourcePath[fullID] {
                    pluginSource = "\(base)/tree/main/\(subPath)"
                } else {
                    pluginSource = base
                }
            } else {
                pluginSource = nil
            }
            let cacheDir = first.installPath.deletingLastPathComponent()
            let latestCached = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path))?
                .filter { !$0.hasPrefix(".") }
                .sorted { versionGreaterThan($0, $1) }
                .first

            let c = scanContributions(pluginID: fullID, dir: first.installPath)
            contribs += c

            out.append(Plugin(
                id: fullID, name: name, marketplace: market, version: version,
                enabled: enabledPlugins[fullID] ?? enabledPlugins.isEmpty,
                installPath: first.installPath, scope: first.scope,
                sourcePath: manifest, origin: .plugin(id: fullID),
                skillCount: c.filter { $0.kind == .skill }.count,
                commandCount: c.filter { $0.kind == .command }.count,
                agentCount: c.filter { $0.kind == .agent }.count,
                mcpCount: c.filter { $0.kind == .mcp }.count,
                hookCount: c.filter { $0.kind == .hook }.count,
                description: description,
                marketplaceURL: marketplaceURL,
                contributions: c,
                latestCachedVersion: latestCached,
                marketplaceSource: pluginSource,
                projectPath: first.projectPath,
                allInstalls: allInstalls))
        }
        return (out.sorted { $0.name < $1.name }, contribs)
    }

    private func scanContributions(pluginID: String, dir: URL) -> [PluginContribution] {
        let fm = FileManager.default
        var out: [PluginContribution] = []
        let skillsDir = dir.appending(path: "skills")
        if let subs = try? fm.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: nil) {
            for s in subs where (try? s.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let md = s.appending(path: "SKILL.md")
                if fm.fileExists(atPath: md.path) {
                    out.append(.init(pluginID: pluginID, kind: .skill, name: s.lastPathComponent,
                                     path: md, description: extractDescription(from: md)))
                }
            }
        }
        for (sub, kind) in [("commands", PluginContribution.Kind.command), ("agents", .agent)] {
            let d = dir.appending(path: sub)
            if let files = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) {
                for f in files where f.pathExtension == "md" {
                    out.append(.init(pluginID: pluginID, kind: kind,
                                     name: f.deletingPathExtension().lastPathComponent,
                                     path: f, description: extractDescription(from: f)))
                }
            }
        }
        let mcp = dir.appending(path: ".mcp.json")
        if let obj = try? JSONFile.readObject(mcp),
           let servers = obj["mcpServers"] as? [String: Any] {
            for name in servers.keys {
                out.append(.init(pluginID: pluginID, kind: .mcp, name: name, path: mcp))
            }
        }
        return out
    }

    private func extractDescription(from url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var inFrontmatter = false
        var frontmatterSeen = false
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if !frontmatterSeen { inFrontmatter = true; frontmatterSeen = true; continue }
                else if inFrontmatter { inFrontmatter = false; continue }
            }
            if inFrontmatter { continue }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            return String(trimmed.prefix(120))
        }
        return nil
    }

    private func versionGreaterThan(_ a: String, _ b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let va = i < pa.count ? pa[i] : 0
            let vb = i < pb.count ? pb[i] : 0
            if va != vb { return va > vb }
        }
        return false
    }
}
