import Foundation

// MARK: - Config (Claude Desktop-compatible)

struct MCPConfig: Codable {
    var mcpServers: [String: ServerSpec]
    struct ServerSpec: Codable {
        var command: String
        var args: [String]?
        var env: [String: String]?
    }
}

enum MCPConfigStore {
    static var mllamaPath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Mllama/mcp.json")
    }

    static var claudeDesktopPath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Claude/claude_desktop_config.json")
    }

    /// Load Mllama config; if missing, fall back to importing Claude Desktop's config
    /// so users with existing MCP setups Just Work.
    static func load() -> MCPConfig {
        let fm = FileManager.default
        if fm.fileExists(atPath: mllamaPath.path),
           let data = try? Data(contentsOf: mllamaPath),
           let cfg = try? JSONDecoder().decode(MCPConfig.self, from: data) {
            return cfg
        }
        if fm.fileExists(atPath: claudeDesktopPath.path),
           let data = try? Data(contentsOf: claudeDesktopPath),
           let cfg = try? JSONDecoder().decode(MCPConfig.self, from: data) {
            return cfg
        }
        return MCPConfig(mcpServers: [:])
    }

    static func ensureScaffold() {
        let fm = FileManager.default
        try? fm.createDirectory(at: mllamaPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: mllamaPath.path) {
            let example = """
            {
              "mcpServers": {
                "// example": "Edit this file to add MCP servers. Same format as Claude Desktop.",
                "// example_filesystem": {
                  "command": "npx",
                  "args": ["-y", "@modelcontextprotocol/server-filesystem", "~/Documents"]
                }
              }
            }
            """
            try? example.write(to: mllamaPath, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - JSON-RPC framing

private struct JSONRPCRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: JSONValue?
}

private struct JSONRPCNotification: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: JSONValue?
}

// MARK: - MCP client per server

actor MCPServer {
    let name: String
    let spec: MCPConfig.ServerSpec

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?

    private var nextId: Int = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private(set) var tools: [MCPToolInfo] = []
    private(set) var lastError: String?
    private var readBuffer = Data()
    private var isReadingStarted = false

    struct MCPToolInfo {
        var name: String
        var description: String
        var inputSchema: JSONValue
    }

    init(name: String, spec: MCPConfig.ServerSpec) {
        self.name = name
        self.spec = spec
    }

    func start() async throws {
        try launchProcess()
        startReader()
        _ = try await send(method: "initialize", params: .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities":    .object(["tools": .object([:])]),
            "clientInfo":      .object([
                "name":    .string("Mllama"),
                "version": .string("2.0.0"),
            ]),
        ]))
        sendNotification(method: "notifications/initialized", params: nil)
        try await refreshTools()
    }

    func stop() {
        process?.terminate()
        process = nil
        stdin = nil
        stdout = nil
        stderr = nil
        for (_, cont) in pending {
            cont.resume(throwing: NSError(domain: "MCP", code: -1, userInfo: [NSLocalizedDescriptionKey: "server stopped"]))
        }
        pending.removeAll()
    }

    func refreshTools() async throws {
        let result = try await send(method: "tools/list", params: nil)
        var out: [MCPToolInfo] = []
        if let arr = result["tools"] as? [[String: Any]] {
            for t in arr {
                guard let name = t["name"] as? String else { continue }
                let desc = (t["description"] as? String) ?? ""
                let schema = JSONValue.from(t["inputSchema"] as Any)
                out.append(.init(name: name, description: desc, inputSchema: schema))
            }
        }
        tools = out
    }

    func callTool(name toolName: String, arguments: [String: Any]) async throws -> String {
        let result = try await send(method: "tools/call", params: .object([
            "name":      .string(toolName),
            "arguments": JSONValue.from(arguments),
        ]))
        if let content = result["content"] as? [[String: Any]] {
            var parts: [String] = []
            for item in content {
                if let type = item["type"] as? String {
                    switch type {
                    case "text":
                        if let t = item["text"] as? String { parts.append(t) }
                    case "image":
                        parts.append("[image]")
                    case "resource":
                        if let res = item["resource"] as? [String: Any], let uri = res["uri"] as? String {
                            parts.append("[resource: \(uri)]")
                        }
                    default:
                        parts.append("[\(type)]")
                    }
                }
            }
            let joined = parts.joined(separator: "\n")
            if let isErr = result["isError"] as? Bool, isErr {
                throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: joined])
            }
            return joined
        }
        return ""
    }

    // MARK: - Wire send / read

    private func launchProcess() throws {
        let p = Process()
        // `command` may be a bare program name (e.g. "npx") that lives on PATH;
        // resolve via /usr/bin/env so the user's shell-installed binaries are found.
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var argv = [spec.command]
        argv.append(contentsOf: spec.args ?? [])
        p.arguments = argv
        var env = ProcessInfo.processInfo.environment
        // Make sure common Node install dirs are on PATH for GUI-launched apps.
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.nvm/versions/node"]
        let existing = env["PATH"] ?? ""
        env["PATH"] = (extraPaths + existing.split(separator: ":").map(String.init))
            .joined(separator: ":")
        for (k, v) in spec.env ?? [:] { env[k] = v }
        p.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        try p.run()
        self.process = p
        self.stdin = inPipe.fileHandleForWriting
        self.stdout = outPipe.fileHandleForReading
        self.stderr = errPipe.fileHandleForReading

        // Drain stderr → keep last error for diagnostics.
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let text = String(data: d, encoding: .utf8) else { return }
            Task { await self?.setLastError(text) }
        }
    }

    private func setLastError(_ s: String) {
        lastError = (lastError ?? "") + s
        if (lastError?.count ?? 0) > 4096 {
            lastError = String(lastError!.suffix(2048))
        }
    }

    private func startReader() {
        guard !isReadingStarted, let out = stdout else { return }
        isReadingStarted = true
        out.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { return }
            Task { await self?.ingest(d) }
        }
    }

    private func ingest(_ chunk: Data) {
        readBuffer.append(chunk)
        // MCP uses newline-delimited JSON over stdio (LSP-style "Content-Length"
        // framing is for HTTP/websocket; stdio servers use NDJSON in practice).
        while let nl = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer.subdata(in: 0..<nl)
            readBuffer.removeSubrange(0...nl)
            guard !lineData.isEmpty else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            handleMessage(obj)
        }
    }

    private func handleMessage(_ obj: [String: Any]) {
        if let id = obj["id"] as? Int, let cont = pending.removeValue(forKey: id) {
            if let err = obj["error"] as? [String: Any] {
                let msg = (err["message"] as? String) ?? "MCP error"
                cont.resume(throwing: NSError(domain: "MCP", code: (err["code"] as? Int) ?? -1,
                                              userInfo: [NSLocalizedDescriptionKey: msg]))
                return
            }
            if let result = obj["result"] as? [String: Any] {
                cont.resume(returning: result)
            } else {
                cont.resume(returning: [:])
            }
        }
        // Notifications and server-initiated requests: ignored for now.
    }

    private func send(method: String, params: JSONValue?) async throws -> [String: Any] {
        let id = nextId; nextId += 1
        let req = JSONRPCRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(req)
        var line = data
        line.append(0x0A) // newline-delimited
        guard let stdin = stdin else {
            throw NSError(domain: "MCP", code: -2, userInfo: [NSLocalizedDescriptionKey: "server not running"])
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            pending[id] = cont
            do { try stdin.write(contentsOf: line) }
            catch {
                pending.removeValue(forKey: id)
                cont.resume(throwing: error)
            }
        }
    }

    private func sendNotification(method: String, params: JSONValue?) {
        let notif = JSONRPCNotification(method: method, params: params)
        guard let data = try? JSONEncoder().encode(notif), let stdin = stdin else { return }
        var line = data
        line.append(0x0A)
        try? stdin.write(contentsOf: line)
    }
}

// MARK: - MCP-bridged tool (lets the agent call MCP tools through ToolRegistry)

struct MCPTool: AgentTool {
    let serverName: String
    let toolName: String
    let toolDescription: String
    let toolSchema: JSONValue
    let server: MCPServer

    var name: String { "mcp__\(sanitize(serverName))__\(sanitize(toolName))" }
    var humanName: String { "\(serverName) → \(toolName)" }
    var description: String { toolDescription.isEmpty ? "MCP tool from \(serverName)" : toolDescription }
    var requiresApproval: Bool { false } // could be made conservative; left lenient for now
    var parameters: JSONValue { toolSchema }

    func run(arguments: String) async -> ToolCallResult {
        let args = parseArgs(arguments)
        do {
            let text = try await server.callTool(name: toolName, arguments: args)
            return .init(toolCallId: "", content: text.isEmpty ? "(empty)" : text, isError: false)
        } catch {
            return .init(toolCallId: "", content: "MCP error: \(error.localizedDescription)", isError: true)
        }
    }
}

private func sanitize(_ s: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
    return String(s.map { allowed.contains($0) ? $0 : "_" })
}

// MARK: - Manager (spawns all configured servers, syncs tools into registry)

@MainActor
final class MCPManager: ObservableObject {
    @Published private(set) var servers: [(name: String, tools: [String], error: String?)] = []
    private var live: [String: MCPServer] = [:]
    private let registry: ToolRegistry

    init(registry: ToolRegistry) {
        self.registry = registry
    }

    func bootstrap() async {
        let cfg = MCPConfigStore.load()
        for (name, spec) in cfg.mcpServers where !name.hasPrefix("//") {
            await launch(name: name, spec: spec)
        }
        await publishState()
    }

    func reload() async {
        for (name, srv) in live {
            await srv.stop()
            await registry.unregister(prefix: "mcp__\(sanitize(name))__")
        }
        live.removeAll()
        await bootstrap()
    }

    private func launch(name: String, spec: MCPConfig.ServerSpec) async {
        let server = MCPServer(name: name, spec: spec)
        do {
            try await server.start()
            live[name] = server
            for t in await server.tools {
                let bridged = MCPTool(
                    serverName: name,
                    toolName: t.name,
                    toolDescription: t.description,
                    toolSchema: t.inputSchema,
                    server: server
                )
                await registry.register(bridged)
            }
        } catch {
            // Surface error in UI; don't crash the app.
            await server.stop()
        }
    }

    private func publishState() async {
        var rows: [(String, [String], String?)] = []
        for (name, srv) in live {
            let toolNames = await srv.tools.map(\.name)
            let err = await srv.lastError
            rows.append((name, toolNames, err))
        }
        self.servers = rows.sorted { $0.0 < $1.0 }
    }
}
