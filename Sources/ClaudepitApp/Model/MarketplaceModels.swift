import Foundation
import ClaudepitCore

public struct Marketplace: Identifiable {
    public var id: String { name }
    public let name: String
    public let sourceLabel: String  // "github", "git", "directory"
    public let sourceValue: String  // the actual repo/url/path
    public let installLocation: String
    public let lastUpdated: String?
}

public struct MarketplacePlugin: Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String?
}

public enum Marketplaces {
    public static func load(_ url: URL) -> [Marketplace] {
        guard let obj = try? JSONFile.readObject(url) else { return [] }
        return obj.compactMap { name, val -> Marketplace? in
            guard let dict = val as? [String: Any],
                  let src = dict["source"] as? [String: Any],
                  let loc = dict["installLocation"] as? String else { return nil }
            let srcType = src["source"] as? String ?? "unknown"
            let srcVal: String
            switch srcType {
            case "github": srcVal = (src["repo"] as? String) ?? ""
            case "git":    srcVal = (src["url"] as? String) ?? ""
            case "directory": srcVal = (src["path"] as? String) ?? ""
            default: srcVal = ""
            }
            return Marketplace(
                name: name,
                sourceLabel: srcType,
                sourceValue: srcVal,
                installLocation: loc,
                lastUpdated: dict["lastUpdated"] as? String
            )
        }
    }

    public static func catalog(installLocation: String) -> [MarketplacePlugin] {
        // Marketplace catalog lives in <installLocation>/.claude-plugin/marketplace.json
        // as a `plugins` array (same source the CLI reads).
        let file = URL(filePath: installLocation)
            .appending(path: ".claude-plugin").appending(path: "marketplace.json")
        guard let obj = try? JSONFile.readObject(file),
              let plugins = obj["plugins"] as? [[String: Any]] else { return [] }
        return plugins.compactMap { p in
            guard let name = p["name"] as? String else { return nil }
            return MarketplacePlugin(name: name, description: p["description"] as? String)
        }
    }

    public static func installedKeys(_ url: URL) -> Set<String> {
        guard let obj = try? JSONFile.readObject(url),
              let plugins = obj["plugins"] as? [String: Any] else { return [] }
        return Set(plugins.keys)
    }
}
