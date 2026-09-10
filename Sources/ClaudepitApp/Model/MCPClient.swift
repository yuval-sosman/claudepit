import Foundation
import ClaudepitCore

// MARK: - Data model

public struct MCPTool: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let title: String?
    public let description: String
    public let readOnly: Bool
    public let destructive: Bool
    public let parameters: [MCPToolParam]

    init(name: String, title: String?, description: String, readOnly: Bool, destructive: Bool,
         parameters: [MCPToolParam]) {
        self.id = name
        self.name = name
        self.title = title
        self.description = description
        self.readOnly = readOnly
        self.destructive = destructive
        self.parameters = parameters
    }
}

public struct MCPToolParam: Sendable {
    public let name: String
    public let type: String
    public let required: Bool
    public let description: String?
}

public enum MCPServerResult: Sendable {
    case idle
    case loading
    case connected([MCPTool])
    case needsAuth       // 401 — requires OAuth via Claude Code
    case failed(String)
}

// MARK: - Client

enum MCPClient {
    static func listTools(for server: MCPServer) async -> MCPServerResult {
        let isHTTP = server.transport == "http" || server.transport == "sse"
        do {
            let tools = isHTTP
                ? try await fetchHTTP(server)
                : try await fetchStdio(server)
            return .connected(tools)
        } catch MCPError.needsAuth {
            return .needsAuth
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Stdio

    private static func fetchStdio(_ server: MCPServer) async throws -> [MCPTool] {
        let cmd = server.command
        let args = server.args
        return try await Task.detached(priority: .userInitiated) {
            try runStdio(command: cmd, args: args)
        }.value
    }

    private static func runStdio(command: String, args: [String]) throws -> [MCPTool] {
        guard !command.isEmpty else { throw MCPError.noCommand }

        let proc = Process()
        proc.executableURL = URL(filePath: command)
        proc.arguments = args

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        // Augment PATH so the binary can find its own dependencies
        var env = ProcessInfo.processInfo.environment
        let extra = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? ""]).joined(separator: ":")
        proc.environment = env

        try proc.run()

        let stdin = stdinPipe.fileHandleForWriting
        let stdout = stdoutPipe.fileHandleForReading

        func send(_ obj: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: obj)
            stdin.write(data)
            stdin.write(Data([0x0A])) // newline
        }

        func readLine() throws -> [String: Any] {
            // Read byte-by-byte until newline (stdout may be chunked)
            var buf = Data()
            while true {
                let byte = stdout.availableData
                if byte.isEmpty {
                    // Small wait and retry — server may still be writing
                    Thread.sleep(forTimeInterval: 0.02)
                    let more = stdout.availableData
                    if more.isEmpty { throw MCPError.noResponse }
                    buf.append(more)
                } else {
                    buf.append(byte)
                }
                if buf.last == 0x0A { break }
                if buf.count > 1_000_000 { throw MCPError.responseTooLarge }
            }
            guard let obj = try? JSONSerialization.jsonObject(with: buf) as? [String: Any] else {
                throw MCPError.badJSON
            }
            return obj
        }

        defer { proc.terminate() }

        // 1. initialize
        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "Claudepit", "version": "1.0"]
        ]])
        _ = try readLine() // consume initialize response

        // 2. initialized notification (fire-and-forget)
        try send(["jsonrpc": "2.0", "method": "notifications/initialized", "params": [:]])

        // 3. tools/list
        try send(["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]])
        let resp = try readLine()

        return parseToolsResponse(resp)
    }

    // MARK: HTTP

    private static func fetchHTTP(_ server: MCPServer) async throws -> [MCPTool] {
        guard let url = URL(string: server.command) else { throw MCPError.noCommand }
        // initialize — captures mcp-session-id from response headers
        let (_, initResp) = try await postRPCRaw(url: url, headers: server.headers,
                              method: "initialize",
                              params: ["protocolVersion": "2024-11-05", "capabilities": [:],
                                       "clientInfo": ["name": "Claudepit", "version": "1.0"]], id: 1)
        var sessionHeaders = server.headers
        if let sessionID = (initResp as? HTTPURLResponse)?.value(forHTTPHeaderField: "mcp-session-id") {
            sessionHeaders["Mcp-Session-Id"] = sessionID
        }
        let (toolsData, _) = try await postRPCRaw(url: url, headers: sessionHeaders,
                                                   method: "tools/list", params: [:], id: 2)
        return parseToolsResponse(toolsData)
    }

    private static func postRPCRaw(url: URL, headers: [String: String],
                                    method: String, params: Any, id: Int) async throws -> ([String: Any], URLResponse) {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { throw MCPError.needsAuth }
            throw MCPError.httpError(code)
        }
        // Try plain JSON first
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (obj, resp)
        }
        // SSE: find first data: line containing a JSON object
        if let text = String(data: data, encoding: .utf8) {
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("data:") {
                    let jsonStr = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if let d = jsonStr.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        return (obj, resp)
                    }
                }
            }
        }
        throw MCPError.badJSON
    }

    // MARK: Parse

    private static func parseToolsResponse(_ resp: [String: Any]) -> [MCPTool] {
        guard let result = resp["result"] as? [String: Any],
              let toolsArr = result["tools"] as? [[String: Any]] else { return [] }
        return toolsArr.compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            let ann = t["annotations"] as? [String: Any] ?? [:]
            let schema = t["inputSchema"] as? [String: Any] ?? [:]
            let props = schema["properties"] as? [String: Any] ?? [:]
            let required = schema["required"] as? [String] ?? []
            let params: [MCPToolParam] = props.map { (k, v) in
                let info = v as? [String: Any] ?? [:]
                return MCPToolParam(name: k,
                        type: info["type"] as? String ?? "any",
                        required: required.contains(k),
                        description: info["description"] as? String)
            }.sorted { $0.name < $1.name }
            return MCPTool(
                name: name,
                title: ann["title"] as? String,
                description: t["description"] as? String ?? "",
                readOnly: ann["readOnlyHint"] as? Bool ?? false,
                destructive: ann["destructiveHint"] as? Bool ?? false,
                parameters: params
            )
        }
    }
}

// MARK: - Errors

private enum MCPError: LocalizedError {
    case noCommand
    case noResponse
    case responseTooLarge
    case badJSON
    case needsAuth
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .noCommand:         return "No command or URL configured"
        case .noResponse:        return "Server did not respond"
        case .responseTooLarge:  return "Response too large"
        case .badJSON:           return "Invalid response format"
        case .needsAuth:         return "Authentication required"
        case .httpError(let c):  return "HTTP \(c)"
        }
    }
}
