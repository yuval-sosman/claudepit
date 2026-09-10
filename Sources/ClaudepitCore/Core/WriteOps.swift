import Foundation

public enum WriteOps {
    public static func setModel(_ model: String, in settingsURL: URL, epoch: Int) throws {
        try mutate(settingsURL, epoch: epoch) { $0["model"] = model }
    }

    public static func setPluginEnabled(_ id: String, _ enabled: Bool, in settingsURL: URL, epoch: Int) throws {
        try mutate(settingsURL, epoch: epoch) { obj in
            var plugins = obj["enabledPlugins"] as? [String: Any] ?? [:]
            plugins[id] = enabled
            obj["enabledPlugins"] = plugins
        }
    }

    /// Remove a plugin's entry from enabledPlugins. If the dict becomes empty, removes the key entirely.
    public static func removePluginEnabled(_ id: String, in settingsURL: URL, epoch: Int) throws {
        try mutate(settingsURL, epoch: epoch) { obj in
            guard var plugins = obj["enabledPlugins"] as? [String: Any] else { return }
            plugins.removeValue(forKey: id)
            if plugins.isEmpty { obj.removeValue(forKey: "enabledPlugins") }
            else { obj["enabledPlugins"] = plugins }
        }
    }

    /// Remove an MCP server entry by name. Removes `mcpServers` key entirely if it becomes empty.
    public static func removeMCPServer(_ name: String, in settingsURL: URL, epoch: Int) throws {
        try mutate(settingsURL, epoch: epoch) { obj in
            guard var servers = obj["mcpServers"] as? [String: Any] else { return }
            servers.removeValue(forKey: name)
            if servers.isEmpty { obj.removeValue(forKey: "mcpServers") }
            else { obj["mcpServers"] = servers }
        }
    }

    /// Remove a hook entry matching `command` under `event`. Cleans up empty groups
    /// and removes the event key (and `hooks` key) if they become empty.
    public static func removeHook(event: String, command: String, in settingsURL: URL, epoch: Int) throws {
        try mutate(settingsURL, epoch: epoch) { obj in
            guard var allHooks = obj["hooks"] as? [String: Any],
                  var groups = allHooks[event] as? [[String: Any]] else { return }
            for i in groups.indices {
                guard var inner = groups[i]["hooks"] as? [[String: Any]] else { continue }
                inner.removeAll { ($0["command"] as? String) == command }
                groups[i]["hooks"] = inner
            }
            groups.removeAll { (($0["hooks"] as? [[String: Any]])?.isEmpty ?? true) }
            if groups.isEmpty { allHooks.removeValue(forKey: event) }
            else { allHooks[event] = groups }
            if allHooks.isEmpty { obj.removeValue(forKey: "hooks") }
            else { obj["hooks"] = allHooks }
        }
    }

    public static func setMCPEnabled(_ name: String, _ enabled: Bool, in settingsURL: URL, epoch: Int) throws {
        try mutate(settingsURL, epoch: epoch) { obj in
            guard var servers = obj["mcpServers"] as? [String: Any],
                  var server = servers[name] as? [String: Any] else { return }
            server["disabled"] = !enabled       // absent/false == enabled
            servers[name] = server
            obj["mcpServers"] = servers
        }
    }

    /// Toggle a skill's `skillOverrides` entry. On (=default) removes the key entirely
    /// and drops the `skillOverrides` object if it becomes empty; off sets
    /// "user-invocable-only" (Claude can't auto-invoke; user still can via `/`).
    public static func setSkillOverride(_ name: String, enabled: Bool, in settingsURL: URL, epoch: Int) throws {
        try mutate(settingsURL, epoch: epoch) { obj in
            var overrides = obj["skillOverrides"] as? [String: String] ?? [:]
            if enabled { overrides.removeValue(forKey: name) }
            else       { overrides[name] = "user-invocable-only" }
            if overrides.isEmpty { obj.removeValue(forKey: "skillOverrides") }
            else                 { obj["skillOverrides"] = overrides }
        }
    }

    /// Set or delete a value at an arbitrary key path in a settings JSON.
    /// Pass `value: nil` to delete the key. Intermediate dicts are created as needed.
    public static func setValueAtKeyPath(_ keyPath: [String], value: Any?, in settingsURL: URL, epoch: Int) throws {
        guard !keyPath.isEmpty else { return }
        try mutate(settingsURL, epoch: epoch) { obj in
            if keyPath.count == 1 {
                if let v = value { obj[keyPath[0]] = v } else { obj.removeValue(forKey: keyPath[0]) }
                return
            }
            var nested = obj[keyPath[0]] as? [String: Any] ?? [:]
            setNested(&nested, keys: Array(keyPath.dropFirst()), value: value)
            obj[keyPath[0]] = nested
        }
    }

    private static func setNested(_ dict: inout [String: Any], keys: [String], value: Any?) {
        if keys.count == 1 {
            if let v = value { dict[keys[0]] = v } else { dict.removeValue(forKey: keys[0]) }
            return
        }
        var nested = dict[keys[0]] as? [String: Any] ?? [:]
        setNested(&nested, keys: Array(keys.dropFirst()), value: value)
        dict[keys[0]] = nested
    }

    /// Read+mutate+write a settings JSON. Tolerates a missing file: starts from an
    /// empty object, creates the parent directory, and skips the backup step.
    private static func mutate(_ url: URL, epoch: Int, _ change: (inout [String: Any]) -> Void) throws {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        var obj = exists ? try JSONFile.readObject(url) : [:]
        if exists {
            _ = try JSONFile.backup(url, epoch: epoch)
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        change(&obj)
        try JSONFile.writeObject(obj, to: url)
    }

    public enum RekeyError: Error, LocalizedError {
        case notFound
        case alreadyExists
        public var errorDescription: String? {
            switch self {
            case .notFound: return "Plugin not found in installed_plugins.json"
            case .alreadyExists: return "Already installed from that marketplace"
            }
        }
    }

    public static func rekeyPlugin(id: String, newMarketplace: String, in url: URL) throws {
        let parts = id.split(separator: "@", maxSplits: 1).map(String.init)
        let name = parts.first ?? id
        let newKey = "\(name)@\(newMarketplace)"
        guard id != newKey else { return }
        var obj = try JSONFile.readObject(url)
        guard var plugins = obj["plugins"] as? [String: Any] else { throw RekeyError.notFound }
        guard plugins[id] != nil else { throw RekeyError.notFound }
        guard plugins[newKey] == nil else { throw RekeyError.alreadyExists }
        plugins[newKey] = plugins.removeValue(forKey: id)
        obj["plugins"] = plugins
        _ = try JSONFile.backup(url, epoch: Int(Date().timeIntervalSince1970))
        try JSONFile.writeObject(obj, to: url)
    }
}
