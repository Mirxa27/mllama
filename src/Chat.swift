import Foundation

// MARK: - Domain

enum MessageRole: String, Codable, Hashable {
    case system, user, assistant, tool
}

struct ToolCallRequest: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    /// Raw JSON arguments object as the model produced it.
    var arguments: String
}

struct ToolCallResult: Codable, Hashable {
    var toolCallId: String
    var content: String
    var isError: Bool
}

/// Single conversation message. May carry assistant tool_calls (when assistant
/// is requesting tool use) or a single tool result (when role == .tool).
struct ChatMessage: Identifiable, Hashable {
    var id = UUID()
    var role: MessageRole
    var content: String = ""
    var toolCalls: [ToolCallRequest] = []
    var toolCallId: String? = nil       // for role == .tool
    var toolName: String? = nil         // for role == .tool, convenience
    var streaming: Bool = false         // animated cursor in UI
    var createdAt: Date = .init()
    /// Per-call approval state, only relevant for assistant messages with tool_calls.
    var toolApprovals: [String: ToolApprovalState] = [:]
    var toolResults: [String: ToolCallResult] = [:]
}

enum ToolApprovalState: String, Codable, Hashable {
    case pending, approved, denied, running, done, errored
}

// MARK: - Wire types for /v1/chat/completions

struct ChatCompletionRequest: Encodable {
    var model: String
    var messages: [WireMessage]
    var stream: Bool = true
    var temperature: Double? = 0.6
    var top_p: Double? = 0.95
    var tools: [WireTool]?
    var tool_choice: String? = "auto"

    struct WireMessage: Encodable {
        var role: String
        var content: String?
        var name: String?
        var tool_calls: [WireToolCall]?
        var tool_call_id: String?
    }

    struct WireToolCall: Encodable {
        var id: String
        var type: String = "function"
        var function: Function
        struct Function: Encodable {
            var name: String
            var arguments: String
        }
    }

    struct WireTool: Encodable {
        var type: String = "function"
        var function: Function
        struct Function: Encodable {
            var name: String
            var description: String
            var parameters: JSONValue
        }
    }
}

/// Tagged JSON value so we can pass an arbitrary parameters schema through `Encodable`.
indirect enum JSONValue: Encodable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let v):    try c.encode(v)
        case .int(let v):     try c.encode(v)
        case .double(let v):  try c.encode(v)
        case .string(let v):  try c.encode(v)
        case .array(let v):   try c.encode(v)
        case .object(let v):  try c.encode(v)
        }
    }

    static func from(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull: return .null
        case let v as Bool: return .bool(v)
        case let v as Int: return .int(v)
        case let v as Double: return .double(v)
        case let v as String: return .string(v)
        case let v as [Any]: return .array(v.map(from))
        case let v as [String: Any]: return .object(v.mapValues(from))
        default: return .string(String(describing: any))
        }
    }
}

// MARK: - Streaming events

enum StreamEvent {
    case contentDelta(String)
    case toolCallStarted(index: Int, id: String, name: String)
    case toolCallArgsDelta(index: Int, delta: String)
    case finish(reason: String?)
    case error(String)
}

// MARK: - Client

actor ChatClient {
    private var urlBase: URL

    init(serverURL: URL) {
        self.urlBase = serverURL
    }

    func updateBase(_ url: URL) { urlBase = url }

    /// Non-streaming convenience: returns the assistant content as a single string.
    /// Used by the compactor to summarize older turns.
    func complete(_ req: ChatCompletionRequest) async throws -> String {
        var r = req
        r.stream = false
        r.tools = nil
        r.tool_choice = nil
        let endpoint = urlBase.appendingPathComponent("v1/chat/completions")
        var urlReq = URLRequest(url: endpoint)
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.timeoutInterval = 180
        urlReq.httpBody = try JSONEncoder().encode(r)
        let (data, _) = try await URLSession.shared.data(for: urlReq)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else { return "" }
        return content
    }

    /// POSTs a chat completion request and yields decoded SSE events.
    func stream(_ req: ChatCompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let endpoint = urlBase.appendingPathComponent("v1/chat/completions")

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var urlReq = URLRequest(url: endpoint)
                    urlReq.httpMethod = "POST"
                    urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlReq.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlReq.timeoutInterval = 600
                    let body = try JSONEncoder().encode(req)
                    urlReq.httpBody = body

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlReq)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var raw = ""
                        for try await line in bytes.lines { raw += line + "\n"; if raw.count > 4096 { break } }
                        throw NSError(
                            domain: "Mllama.ChatClient", code: http.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(raw)"]
                        )
                    }

                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" {
                            continuation.finish()
                            return
                        }
                        guard let data = payload.data(using: .utf8) else { continue }
                        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        guard let choices = json["choices"] as? [[String: Any]], let choice = choices.first else { continue }

                        if let delta = choice["delta"] as? [String: Any] {
                            if let content = delta["content"] as? String, !content.isEmpty {
                                continuation.yield(.contentDelta(content))
                            }
                            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                                for tc in toolCalls {
                                    let index = (tc["index"] as? Int) ?? 0
                                    let id = (tc["id"] as? String) ?? "call_\(index)"
                                    if let fn = tc["function"] as? [String: Any] {
                                        if let name = fn["name"] as? String, !name.isEmpty {
                                            continuation.yield(.toolCallStarted(index: index, id: id, name: name))
                                        }
                                        if let args = fn["arguments"] as? String, !args.isEmpty {
                                            continuation.yield(.toolCallArgsDelta(index: index, delta: args))
                                        }
                                    }
                                }
                            }
                        }

                        if let finish = choice["finish_reason"] as? String {
                            continuation.yield(.finish(reason: finish))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
