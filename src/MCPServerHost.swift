import Foundation
import Network
import SwiftUI

// MARK: - Defaults

enum MCPHostKeys {
    static let enabled = "mcp.host.enabled"
    static let port    = "mcp.host.port"
    static let host    = "mcp.host.host"     // bind interface; default 127.0.0.1
}

// MARK: - Host

/// HTTP+JSON-RPC server that lets *other* AI agents (Claude Desktop, Cursor,
/// etc.) call Mllama's image/video generation through the standard Model
/// Context Protocol. Bound to localhost by default. One endpoint: POST /mcp.
@MainActor
final class MCPServerHost: ObservableObject {
    enum Status: Equatable {
        case stopped
        case running(port: UInt16)
        case failed(String)
    }

    @Published var status: Status = .stopped
    @Published var requestCount: Int = 0
    @Published var lastError: String?
    @Published var recentRequests: [LoggedRequest] = []

    struct LoggedRequest: Identifiable, Hashable {
        let id = UUID()
        let at: Date
        let method: String
        let toolName: String?
        let okOrErrCode: String
    }

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let registry: MCPHostToolRegistry
    private let dispatchQueue = DispatchQueue(label: "Mllama.MCPServerHost")

    /// Server self-description sent back in `initialize`.
    let serverName = "Mllama"
    let serverVersion = "2.4.0"

    init(registry: MCPHostToolRegistry) {
        self.registry = registry
    }

    var configuredPort: UInt16 {
        let p = UserDefaults.standard.integer(forKey: MCPHostKeys.port)
        return p > 0 ? UInt16(p) : 3737
    }

    var configuredHost: String {
        UserDefaults.standard.string(forKey: MCPHostKeys.host) ?? "127.0.0.1"
    }

    // MARK: Lifecycle

    func start() {
        stop()
        Log.mcp.info("start() called, port=\(self.configuredPort, privacy: .public)")
        do {
            let port = configuredPort
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                Log.mcp.error("invalid port \(port, privacy: .public)")
                self.status = .failed("Invalid port: \(port)")
                return
            }
            // NWListener binds to all interfaces. We filter incoming
            // connections to loopback-only in handleNewConnection to keep
            // generation off the LAN. (NWParameters.requiredLocalEndpoint is
            // for outgoing connections, not the listener.)
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: nwPort)
            l.stateUpdateHandler = { [weak self] state in
                Log.mcp.info("listener state: \(String(describing: state), privacy: .public)")
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.status = .running(port: port)
                    case .failed(let err):
                        self.status = .failed(err.localizedDescription)
                        self.lastError = err.localizedDescription
                    case .cancelled:
                        if case .stopped = self.status { break }
                        self.status = .stopped
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.handleNewConnection(conn) }
            }
            l.start(queue: dispatchQueue)
            self.listener = l
        } catch {
            self.status = .failed(error.localizedDescription)
            self.lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for (_, c) in connections { c.cancel() }
        connections.removeAll()
        status = .stopped
    }

    // MARK: Connection handling

    private func handleNewConnection(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        Task { @MainActor in self.connections[key] = conn }
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.connections.removeValue(forKey: key) }
            default: break
            }
        }
        conn.start(queue: dispatchQueue)
        readRequest(on: conn)
    }

    /// Read the HTTP request, parse it, dispatch JSON-RPC, send response.
    private func readRequest(on conn: NWConnection) {
        // Read up to 16 MB (covers chunked images in base64 input).
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.sendHTTPResponse(on: conn, status: 500, body: "{\"error\":\"\(error.localizedDescription)\"}")
                return
            }
            guard let data, !data.isEmpty else {
                if isComplete { conn.cancel() }
                return
            }
            self.processHTTP(data: data, on: conn)
        }
    }

    /// Parse an HTTP request from raw bytes. Supports CONNECT-style minimal
    /// HTTP/1.1 with Content-Length-bounded bodies. Streaming/chunked not
    /// supported (clients we target send Content-Length).
    private func processHTTP(data: Data, on conn: NWConnection) {
        // Find header/body boundary.
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            sendHTTPResponse(on: conn, status: 400, body: "{\"error\":\"malformed request\"}")
            return
        }
        let headerBytes = data.subdata(in: 0..<headerEnd.lowerBound)
        let body = data.subdata(in: headerEnd.upperBound..<data.count)
        guard let headerString = String(data: headerBytes, encoding: .utf8) else {
            sendHTTPResponse(on: conn, status: 400, body: "{\"error\":\"bad headers\"}")
            return
        }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendHTTPResponse(on: conn, status: 400, body: "{\"error\":\"no request line\"}")
            return
        }
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else {
            sendHTTPResponse(on: conn, status: 400, body: "{\"error\":\"bad request line\"}")
            return
        }
        let method = parts[0].uppercased()
        let path = parts[1]

        // Headers map
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<colon]).lowercased()
            let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }

        // Health endpoint (handy for "is it up?")
        if method == "GET" && (path == "/" || path == "/health" || path == "/healthz") {
            sendHTTPResponse(on: conn, status: 200,
                             body: "{\"server\":\"\(serverName)\",\"version\":\"\(serverVersion)\",\"ok\":true}")
            return
        }

        // OPTIONS preflight
        if method == "OPTIONS" {
            sendHTTPResponse(on: conn, status: 204, body: "",
                             extraHeaders: [
                                "Access-Control-Allow-Origin": "*",
                                "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
                                "Access-Control-Allow-Headers": "Content-Type, Authorization, Mcp-Session-Id"
                             ])
            return
        }

        // MCP endpoint
        guard method == "POST" else {
            sendHTTPResponse(on: conn, status: 405, body: "{\"error\":\"method not allowed\"}")
            return
        }
        guard path == "/mcp" || path == "/" else {
            sendHTTPResponse(on: conn, status: 404, body: "{\"error\":\"unknown path\"}")
            return
        }

        // If body wasn't fully received, drain until Content-Length is met.
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        if body.count < contentLength {
            drainBody(on: conn, alreadyRead: body, expected: contentLength) { [weak self] full in
                self?.dispatchJSONRPC(body: full, on: conn)
            }
        } else {
            dispatchJSONRPC(body: body, on: conn)
        }
    }

    private func drainBody(on conn: NWConnection, alreadyRead: Data, expected: Int,
                           done: @escaping (Data) -> Void) {
        var buffer = alreadyRead
        func loop() {
            let remaining = expected - buffer.count
            if remaining <= 0 { done(buffer); return }
            conn.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, _, _ in
                if let d = data { buffer.append(d) }
                loop()
            }
        }
        loop()
    }

    // MARK: JSON-RPC dispatch

    private func dispatchJSONRPC(body: Data, on conn: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            sendJSONRPCError(on: conn, id: NSNull(), code: -32700, message: "Parse error")
            return
        }
        // Accept either a single request or a notification.
        let method = (json["method"] as? String) ?? ""
        let id = json["id"] ?? NSNull()
        let params = json["params"] as? [String: Any] ?? [:]

        Task { @MainActor in
            self.requestCount += 1
        }

        switch method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": "2024-11-05",
                "capabilities": [
                    "tools": [:]
                ],
                "serverInfo": [
                    "name": serverName,
                    "version": serverVersion
                ]
            ]
            sendJSONRPCResult(on: conn, id: id, result: result)
            logRequest(method: method, tool: nil, status: "ok")

        case "tools/list":
            Task { @MainActor in
                let tools = await self.registry.descriptors()
                let result: [String: Any] = ["tools": tools]
                self.sendJSONRPCResult(on: conn, id: id, result: result)
                self.logRequest(method: method, tool: nil, status: "ok")
            }

        case "tools/call":
            guard let toolName = params["name"] as? String else {
                sendJSONRPCError(on: conn, id: id, code: -32602, message: "Missing tool name")
                logRequest(method: method, tool: nil, status: "err:no_name")
                return
            }
            let arguments = (params["arguments"] as? [String: Any]) ?? [:]
            Task { @MainActor in
                let result = await self.registry.invoke(name: toolName, arguments: arguments)
                self.sendJSONRPCResult(on: conn, id: id, result: result)
                self.logRequest(method: method, tool: toolName,
                                status: (result["isError"] as? Bool == true) ? "err" : "ok")
            }

        case "notifications/initialized", "":
            // Notifications get no response.
            sendHTTPResponse(on: conn, status: 204, body: "")
            logRequest(method: method.isEmpty ? "notification" : method, tool: nil, status: "ack")

        case "ping":
            sendJSONRPCResult(on: conn, id: id, result: [:])

        default:
            sendJSONRPCError(on: conn, id: id, code: -32601, message: "Method not found: \(method)")
            logRequest(method: method, tool: nil, status: "err:unknown_method")
        }
    }

    private func logRequest(method: String, tool: String?, status: String) {
        Task { @MainActor in
            let entry = LoggedRequest(at: Date(), method: method, toolName: tool, okOrErrCode: status)
            self.recentRequests.insert(entry, at: 0)
            if self.recentRequests.count > 50 {
                self.recentRequests.removeLast(self.recentRequests.count - 50)
            }
        }
    }

    // MARK: HTTP / JSON-RPC writers

    private func sendJSONRPCResult(on conn: NWConnection, id: Any, result: [String: Any]) {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ]
        sendJSONResponse(on: conn, payload: payload)
    }

    private func sendJSONRPCError(on conn: NWConnection, id: Any, code: Int, message: String) {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message]
        ]
        sendJSONResponse(on: conn, payload: payload)
    }

    private func sendJSONResponse(on conn: NWConnection, payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            sendHTTPResponse(on: conn, status: 500, body: "{\"error\":\"could not encode\"}")
            return
        }
        sendHTTPResponse(on: conn, status: 200, body: data, contentType: "application/json")
    }

    private func sendHTTPResponse(on conn: NWConnection,
                                  status: Int,
                                  body: String,
                                  contentType: String = "application/json",
                                  extraHeaders: [String: String] = [:]) {
        sendHTTPResponse(on: conn, status: status, body: Data(body.utf8),
                         contentType: contentType, extraHeaders: extraHeaders)
    }

    private func sendHTTPResponse(on conn: NWConnection,
                                  status: Int,
                                  body: Data,
                                  contentType: String = "application/json",
                                  extraHeaders: [String: String] = [:]) {
        let statusText = httpStatusText(status)
        var headerLines: [String] = [
            "HTTP/1.1 \(status) \(statusText)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "Access-Control-Allow-Origin: *",
        ]
        for (k, v) in extraHeaders { headerLines.append("\(k): \(v)") }
        let header = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func httpStatusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default:  return "Status"
        }
    }
}

// MARK: - Tool registry (exposed to remote clients)

/// MCP tool callable by a *remote* agent. Same shape as our local AgentTool,
/// but the result returns MCP-compatible content blocks (text + base64 images).
protocol MCPHostTool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchema: [String: Any] { get }
    /// Returns MCP `tools/call` result shape:
    ///   { "content": [{type:"text", text:"..."}, {type:"image", data:"...", mimeType:"..."}],
    ///     "isError": Bool }
    func run(arguments: [String: Any]) async -> [String: Any]
}

@MainActor
final class MCPHostToolRegistry: ObservableObject {
    @Published private(set) var tools: [String: MCPHostTool] = [:]

    func register(_ tool: MCPHostTool) {
        tools[tool.name] = tool
    }

    /// JSON-shaped descriptors for `tools/list`.
    func descriptors() async -> [[String: Any]] {
        tools.values.sorted { $0.name < $1.name }.map { t in
            [
                "name": t.name,
                "description": t.description,
                "inputSchema": t.inputSchema
            ]
        }
    }

    func invoke(name: String, arguments: [String: Any]) async -> [String: Any] {
        guard let tool = tools[name] else {
            return [
                "content": [["type": "text", "text": "Unknown tool: \(name)"]],
                "isError": true
            ]
        }
        return await tool.run(arguments: arguments)
    }
}
