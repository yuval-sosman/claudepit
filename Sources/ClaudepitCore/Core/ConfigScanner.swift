import Foundation

public struct LayerResult {
    public var skills: [Skill] = []
    public var commands: [Command] = []
    public var agents: [Agent] = []
    public var rules: [Rule] = []
    public var mcpServers: [MCPServer] = []
    public var hooks: [Hook] = []
    public var envVars: [EnvVar] = []
    public var settings: [String: Any] = [:]
    public var settingsSourcePath: URL? = nil

    public init() {}
}

public struct ConfigScanner {
    public let claudeDir: URL
    public let scope: Scope

    public init(claudeDir: URL, scope: Scope) {
        self.claudeDir = claudeDir
        self.scope = scope
    }

    private var settingsFileName: String { scope == .local ? "settings.local.json" : "settings.json" }

    public func scan() -> LayerResult {
        var r = LayerResult()
        let settingsURL = claudeDir.appending(path: settingsFileName)
        if let obj = try? JSONFile.readObject(settingsURL) {
            r.settings = obj
            r.settingsSourcePath = settingsURL
            r.mcpServers = Self.parseMCP(obj, scope: scope, source: settingsURL)
            r.hooks = Self.parseHooks(obj, scope: scope, source: settingsURL)
            r.envVars = Self.parseEnv(obj, scope: scope, source: settingsURL)
        }
        // The .local scope reads only settings.local.json — it has no skills/commands/agents
        // directories of its own. Those live under global (~/.claude) and project (<path>/.claude).
        guard scope != .local else { return r }
        r.skills = scanSkills()
        r.commands = scanMarkdownDir("commands").map {
            Command(id: $0.name, description: $0.desc, scope: scope, sourcePath: $0.url, origin: .user,
                    meta: $0.meta, bodyPreview: $0.body)
        }
        r.agents = scanMarkdownDir("agents").map {
            Agent(id: $0.name, description: $0.desc, scope: scope, sourcePath: $0.url, origin: .user,
                  meta: $0.meta, bodyPreview: $0.body)
        }
        r.rules = scanMarkdownDir("rules").map {
            let paths = ($0.meta["paths"] ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            return Rule(id: $0.name, scope: scope, sourcePath: $0.url, origin: .user,
                        meta: $0.meta, bodyPreview: $0.body, paths: paths)
        }
        return r
    }

    // MARK: settings sub-parsers
    public static func parseMCP(_ o: [String: Any], scope: Scope, source: URL) -> [MCPServer] {
        guard let servers = o["mcpServers"] as? [String: Any] else { return [] }
        return servers.compactMap { (name, v) in
            guard let d = v as? [String: Any] else { return nil }
            let transport = d["type"] as? String ?? d["transport"] as? String
            // HTTP/SSE servers have a url field instead of command+args
            let command = d["command"] as? String ?? d["url"] as? String ?? ""
            let headers = d["headers"] as? [String: String] ?? [:]
            return MCPServer(id: name,
                command: command,
                args: d["args"] as? [String] ?? [],
                transport: transport,
                headers: headers,
                enabled: (d["disabled"] as? Bool).map { !$0 } ?? true,
                scope: scope, sourcePath: source, origin: .user)
        }.sorted { $0.id < $1.id }
    }

    /// Read MCP servers declared in a standalone `.mcp.json` file (project root).
    /// Returns [] if the file is absent or has no mcpServers.
    public static func parseMcpJsonFile(_ url: URL, scope: Scope) -> [MCPServer] {
        guard let obj = try? JSONFile.readObject(url) else { return [] }
        return parseMCP(obj, scope: scope, source: url)
    }

    public static func parseHooks(_ o: [String: Any], scope: Scope, source: URL) -> [Hook] {
        guard let hooks = o["hooks"] as? [String: Any] else { return [] }
        var out: [Hook] = []
        for (event, v) in hooks {
            guard let groups = v as? [[String: Any]] else { continue }
            var idx = 0
            for g in groups {
                let matcher = g["matcher"] as? String
                let inner = g["hooks"] as? [[String: Any]] ?? []
                for h in inner {
                    out.append(Hook(id: "\(event):\(idx)", event: event, matcher: matcher,
                                    command: h["command"] as? String ?? "",
                                    scope: scope, sourcePath: source, origin: .user))
                    idx += 1
                }
            }
        }
        return out.sorted { $0.id < $1.id }
    }

    public static func parseEnv(_ o: [String: Any], scope: Scope, source: URL) -> [EnvVar] {
        guard let env = o["env"] as? [String: Any] else { return [] }
        return env.map { EnvVar(id: $0.key, rawValue: "\($0.value)", scope: scope, sourcePath: source) }
            .sorted { $0.id < $1.id }
    }

    // MARK: markdown dirs
    private func scanSkills() -> [Skill] {
        let fm = FileManager.default
        let dir = claudeDir.appending(path: "skills")
        guard let subs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [Skill] = []
        for s in subs where (try? s.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let md = s.appending(path: "SKILL.md")
            guard fm.fileExists(atPath: md.path) else { continue }
            let parsed = Frontmatter.parseWithBody(md)
            out.append(Skill(id: parsed.fields["name"] ?? s.lastPathComponent,
                             description: parsed.fields["description"] ?? "",
                             scope: scope, sourcePath: md, origin: .user,
                             meta: parsed.fields, bodyPreview: parsed.body))
        }
        return out.sorted { $0.id < $1.id }
    }

    private func scanMarkdownDir(_ name: String) -> [(name: String, desc: String, meta: [String: String], body: String, url: URL)] {
        let fm = FileManager.default
        let dir = claudeDir.appending(path: name)
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "md" }.map {
            let p = Frontmatter.parseWithBody($0)
            return ($0.deletingPathExtension().lastPathComponent, p.fields["description"] ?? "", p.fields, p.body, $0)
        }.sorted { $0.name < $1.name }
    }
}

/// Minimal YAML-ish frontmatter reader: first --- block, `key: value` lines.
/// Handles block scalars (`key: >` folded, `key: |` literal) and quoted values —
/// enough for the `description:`-heavy frontmatter of skills/commands. Not a full YAML parser.
public enum Frontmatter {
    public static func parse(_ url: URL) -> [String: String] {
        parseWithBody(url).fields
    }

    /// Parse frontmatter fields AND return a capped preview of the markdown body
    /// (everything after the closing `---`). Body capped to ~15 non-empty lines / 800 chars.
    public static func parseWithBody(_ url: URL) -> (fields: [String: String], body: String) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ([:], "") }
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            // No frontmatter: whole file is body.
            return ([:], cappedBody(lines[...]))
        }
        var fields: [String: String] = [:]
        var closeIdx: Int? = nil
        var i = 1
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces) == "---" { closeIdx = i; break }
            guard let colon = line.firstIndex(of: ":") else { i += 1; continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { i += 1; continue }
            let rawVal = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            if rawVal == ">" || rawVal == "|" || rawVal == ">-" || rawVal == "|-" {
                // Block scalar: consume following lines indented deeper than the key.
                let folded = rawVal.hasPrefix(">")
                let keyIndent = indent(line)
                var block: [String] = []
                var j = i + 1
                while j < lines.count {
                    let l = lines[j]
                    if l.trimmingCharacters(in: .whitespaces) == "---" { break }
                    // blank line stays part of the block; non-blank must be more indented than key
                    if !l.trimmingCharacters(in: .whitespaces).isEmpty && indent(l) <= keyIndent { break }
                    block.append(l.trimmingCharacters(in: .whitespaces))
                    j += 1
                }
                let joined = folded
                    ? block.joined(separator: " ").replacingOccurrences(of: "  ", with: " ")
                    : block.joined(separator: "\n")
                fields[key] = joined.trimmingCharacters(in: .whitespacesAndNewlines)
                i = j
            } else if rawVal.isEmpty {
                // YAML sequence: consume "  - item" lines (e.g. paths: list)
                var items: [String] = []
                var j = i + 1
                while j < lines.count {
                    let l = lines[j].trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("- ") { items.append(unquote(String(l.dropFirst(2)))); j += 1 }
                    else { break }
                }
                if !items.isEmpty { fields[key] = items.joined(separator: "\n"); i = j; continue }
                i += 1
            } else {
                fields[key] = unquote(rawVal)
                i += 1
            }
        }
        let body = closeIdx.map { cappedBody(lines[($0 + 1)...]) } ?? ""
        return (fields, body)
    }

    private static func indent(_ s: String) -> Int { s.prefix { $0 == " " }.count }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    private static func cappedBody(_ lines: ArraySlice<String>) -> String {
        var kept: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty && kept.isEmpty { continue }
            kept.append(line)
            if kept.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count >= 15 { break }
        }
        let text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 800 ? String(text.prefix(800)) + "…" : text
    }
}
