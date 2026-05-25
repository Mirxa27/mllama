import Foundation
import SwiftUI

/// Holds the conversation and runs the agent loop. Published state drives the UI.
@MainActor
final class Agent: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isStreaming: Bool = false
    @Published var lastError: String?
    @Published var isCompacting: Bool = false

    // Approval state surfaced to the UI.
    @Published var pendingApproval: PendingApproval?
    @Published var autoApproveInSession: Bool = false

    var systemPrompt: String {
        UserDefaults.standard.string(forKey: Keys.systemPrompt) ?? defaultSystemPrompt
    }
    var modelLabel: String {
        server.modelName.isEmpty ? "local" : server.modelName
    }
    var toolsEnabled: Bool = true

    private unowned let server: ServerController
    private let chatClient: ChatClient
    private let registry: ToolRegistry
    private let maxIterations: Int = 12
    private var streamTask: Task<Void, Never>?

    struct PendingApproval: Identifiable {
        let id = UUID()
        let toolName: String
        let humanName: String
        let arguments: String
        var onResolve: (Bool) -> Void
    }

    init(server: ServerController, registry: ToolRegistry) {
        self.server = server
        let baseURL = server.serverURL ?? URL(string: "http://127.0.0.1:8080")!
        self.chatClient = ChatClient(serverURL: baseURL)
        self.registry = registry
    }

    func reset() {
        cancel()
        messages.removeAll()
        lastError = nil
        pendingApproval = nil
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        for i in messages.indices where messages[i].streaming {
            messages[i].streaming = false
        }
        SpeechSynthesizer.shared.stop()
    }

    func send(_ userText: String) {
        guard !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        SpeechSynthesizer.shared.stop()
        messages.append(ChatMessage(role: .user, content: userText))
        run()
    }

    private func run() {
        cancel()
        isStreaming = true
        lastError = nil
        let task = Task { [weak self] in
            guard let self else { return }
            // Auto-compact before sending if we're crowding the context window.
            if UserDefaults.standard.bool(forKey: Keys.autoCompact),
               await self.shouldAutoCompact() {
                await self.compactNow()
            }
            await self.loop()
        }
        streamTask = task
    }

    private func loop() async {
        defer { isStreaming = false }
        // Sync chat client base URL in case the port changed between sends.
        if let url = server.serverURL { await chatClient.updateBase(url) }

        var iter = 0
        // Tracks whether we've already auto-compacted this run after hitting
        // an `exceed_context_size_error`. Without this guard, a hostile
        // sequence of tool results that immediately re-fills the context
        // would put us into an infinite compact/retry loop.
        var didEmergencyCompact = false
        while iter < maxIterations {
            iter += 1
            if Task.isCancelled { return }
            do {
                let req = await buildRequest()
                let stream = await chatClient.stream(req)
                let assistantIndex = appendStreamingAssistant()
                var pendingArgs: [Int: String] = [:]
                var pendingNames: [Int: String] = [:]
                var pendingIds: [Int: String] = [:]
                var finishReason: String?
                var streamErrorMessage: String?

                for try await event in stream {
                    if Task.isCancelled { return }
                    switch event {
                    case .contentDelta(let s):
                        messages[assistantIndex].content += s
                    case .toolCallStarted(let index, let id, let name):
                        pendingIds[index] = id
                        pendingNames[index] = name
                    case .toolCallArgsDelta(let index, let delta):
                        pendingArgs[index, default: ""] += delta
                    case .finish(let reason):
                        finishReason = reason
                    case .error(let msg):
                        streamErrorMessage = msg
                    }
                }

                // Detect the llama-server context-overflow error and
                // auto-recover by compacting the conversation once.
                if let err = streamErrorMessage,
                   Self.isContextOverflowError(err),
                   !didEmergencyCompact {
                    Log.agent.notice("Context overflow — auto-compacting and retrying.")
                    // Drop the in-flight (empty) assistant message we just appended.
                    if messages.indices.contains(assistantIndex) {
                        messages.remove(at: assistantIndex)
                    }
                    await compactNow()
                    didEmergencyCompact = true
                    continue
                }
                if let err = streamErrorMessage {
                    lastError = err
                }

                messages[assistantIndex].streaming = false

                let calls: [ToolCallRequest] = pendingIds.keys.sorted().compactMap { idx in
                    guard let name = pendingNames[idx] else { return nil }
                    return ToolCallRequest(
                        id: pendingIds[idx] ?? "call_\(idx)",
                        name: name,
                        arguments: pendingArgs[idx] ?? "{}"
                    )
                }
                messages[assistantIndex].toolCalls = calls
                for c in calls { messages[assistantIndex].toolApprovals[c.id] = .pending }

                if calls.isEmpty {
                    autoSpeakIfEnabled(messages[assistantIndex].content)
                    return
                }
                if finishReason == "stop" && calls.isEmpty {
                    autoSpeakIfEnabled(messages[assistantIndex].content)
                    return
                }

                for call in calls {
                    if Task.isCancelled { return }
                    let result = await executeToolCall(call, assistantIndex: assistantIndex)
                    messages.append(ChatMessage(
                        role: .tool,
                        content: result.content,
                        toolCallId: call.id,
                        toolName: call.name
                    ))
                }
            } catch {
                let msg = error.localizedDescription
                // Same recovery on a thrown error path — some llama-server
                // builds surface context overflow via HTTP 400 body rather
                // than a stream `error` event.
                if Self.isContextOverflowError(msg), !didEmergencyCompact {
                    Log.agent.notice("Context overflow (thrown) — auto-compacting and retrying.")
                    await compactNow()
                    didEmergencyCompact = true
                    continue
                }
                lastError = msg
                return
            }
        }
        lastError = "Reached max agent iterations (\(maxIterations))."
    }

    /// Detect llama-server's context-overflow response so we can compact +
    /// retry instead of dumping a wall of JSON onto the user. Matches the
    /// canonical `exceed_context_size_error` plus the more permissive
    /// "exceeds the available context size" substring that older builds
    /// produce.
    static func isContextOverflowError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("exceed_context_size_error")
            || lower.contains("exceeds the available context size")
            || lower.contains("context size")
    }

    private func executeToolCall(_ call: ToolCallRequest, assistantIndex: Int) async -> ToolCallResult {
        let startedAt = Date()

        guard let tool = await registry.tool(named: call.name) else {
            messages[assistantIndex].toolApprovals[call.id] = .errored
            let r = ToolCallResult(toolCallId: call.id, content: "no such tool: \(call.name)", isError: true)
            messages[assistantIndex].toolResults[call.id] = r
            // Record the unknown-tool case too — the agent can use this signal
            // via `reflect` to stop calling a tool name that doesn't exist.
            await ReflectionStore.shared.record(
                toolName: call.name, args: call.arguments,
                result: r,
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1000)
            )
            return r
        }

        if tool.requiresApproval && !autoApproveInSession {
            let approved = await requestApproval(toolName: tool.name, humanName: tool.humanName, args: call.arguments)
            if !approved {
                messages[assistantIndex].toolApprovals[call.id] = .denied
                let r = ToolCallResult(toolCallId: call.id, content: "user denied this tool call", isError: true)
                messages[assistantIndex].toolResults[call.id] = r
                // Record denied calls so the agent learns to stop trying the
                // same tool with the same shape over and over.
                await ReflectionStore.shared.record(
                    toolName: call.name, args: call.arguments,
                    result: r,
                    durationMs: Int(Date().timeIntervalSince(startedAt) * 1000)
                )
                return r
            }
        }

        messages[assistantIndex].toolApprovals[call.id] = .running
        var result = await tool.run(arguments: call.arguments)
        result = ToolCallResult(toolCallId: call.id, content: result.content, isError: result.isError)
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        messages[assistantIndex].toolApprovals[call.id] = result.isError ? .errored : .done
        messages[assistantIndex].toolResults[call.id] = result
        // Reflection log: every executed tool call (success or failure) goes
        // into the ring so `reflect` can surface patterns.
        await ReflectionStore.shared.record(
            toolName: call.name,
            args: call.arguments,
            result: result,
            durationMs: durationMs
        )
        return result
    }

    private func requestApproval(toolName: String, humanName: String, args: String) async -> Bool {
        await withCheckedContinuation { cont in
            pendingApproval = PendingApproval(
                toolName: toolName,
                humanName: humanName,
                arguments: args,
                onResolve: { [weak self] ok in
                    Task { @MainActor in
                        self?.pendingApproval = nil
                        cont.resume(returning: ok)
                    }
                }
            )
        }
    }

    private func appendStreamingAssistant() -> Int {
        messages.append(ChatMessage(role: .assistant, content: "", streaming: true))
        return messages.count - 1
    }

    private func buildRequest() async -> ChatCompletionRequest {
        var wire: [ChatCompletionRequest.WireMessage] = [
            .init(role: "system", content: systemPrompt)
        ]
        for m in messages {
            switch m.role {
            case .system:
                if !m.content.isEmpty { wire.append(.init(role: "system", content: m.content)) }
            case .user:
                wire.append(.init(role: "user", content: m.content))
            case .assistant:
                let calls = m.toolCalls.map {
                    ChatCompletionRequest.WireToolCall(
                        id: $0.id,
                        function: .init(name: $0.name, arguments: $0.arguments)
                    )
                }
                wire.append(.init(
                    role: "assistant",
                    content: m.content.isEmpty ? nil : m.content,
                    tool_calls: calls.isEmpty ? nil : calls
                ))
            case .tool:
                wire.append(.init(role: "tool", content: m.content, tool_call_id: m.toolCallId))
            }
        }
        let toolsList: [ChatCompletionRequest.WireTool]? = toolsEnabled
            ? (await registry.all()).map { $0.wireDefinition() }
            : nil
        return ChatCompletionRequest(
            model: modelLabel,
            messages: wire,
            stream: true,
            temperature: 0.6,
            top_p: 0.95,
            tools: (toolsList?.isEmpty ?? true) ? nil : toolsList,
            tool_choice: toolsList == nil ? nil : "auto"
        )
    }

    // MARK: - Token estimation + compaction

    /// Rough token estimate. chars/3.5 is a tighter (more conservative)
    /// approximation of BPE token density on the kinds of prose + JSON
    /// tool args we send through; chars/4 systematically under-counts and
    /// let context overflow sneak past the auto-compact guard. The figure
    /// is still cheap to compute and stable enough to drive the usage bar.
    var estimatedTokens: Int {
        var chars = systemPrompt.count
        for m in messages {
            chars += m.content.count
            for c in m.toolCalls { chars += c.name.count + c.arguments.count }
            for (_, r) in m.toolResults { chars += r.content.count }
        }
        // Multiply then divide to avoid losing fractional accuracy.
        return (chars * 2) / 7
    }

    var contextWindow: Int {
        // Trust the server's reported n_ctx when known; otherwise assume 8192.
        server.nCtx > 0 ? server.nCtx : 8192
    }

    var contextUsageFraction: Double {
        guard contextWindow > 0 else { return 0 }
        return min(Double(estimatedTokens) / Double(contextWindow), 1.0)
    }

    private func shouldAutoCompact() async -> Bool {
        guard contextWindow > 0 else { return false }
        // Trigger earlier (65% instead of 75%) and drop the message-count
        // floor — a single huge tool result can blow the context on its own.
        return contextUsageFraction >= 0.65 && messages.count >= 4
    }

    func manualCompact() async {
        await compactNow()
    }

    /// Summarize all but the most recent few turns and replace with a system
    /// note so the conversation can continue without blowing the context.
    private func compactNow() async {
        guard messages.count >= 4 else { return }
        isCompacting = true
        defer { isCompacting = false }

        let keepTail = 4
        let head = Array(messages.prefix(max(0, messages.count - keepTail)))
        let tail = Array(messages.suffix(keepTail))
        if head.isEmpty { return }

        let summaryReq = ChatCompletionRequest(
            model: modelLabel,
            messages: [
                .init(role: "system", content: "You compress conversation history. Output a TIGHT bullet list of: user goals, decisions made, facts established, file paths / IDs / commands mentioned, and unresolved threads. No fluff. Max 25 bullets."),
                .init(role: "user", content: serializeForSummary(head))
            ],
            stream: false,
            temperature: 0.2,
            top_p: 0.9,
            tools: nil,
            tool_choice: nil
        )
        do {
            if let url = server.serverURL { await chatClient.updateBase(url) }
            let summary = try await chatClient.complete(summaryReq)
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let note = ChatMessage(
                role: .system,
                content: "[Earlier conversation, compacted]\n\(trimmed)"
            )
            messages = [note] + tail
        } catch {
            lastError = "Compaction failed: \(error.localizedDescription)"
        }
    }

    private func autoSpeakIfEnabled(_ text: String) {
        guard UserDefaults.standard.bool(forKey: VoiceKeys.autoSpeak) else { return }
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        SpeechSynthesizer.shared.speak(text)
    }

    private func serializeForSummary(_ msgs: [ChatMessage]) -> String {
        var out = ""
        for m in msgs {
            switch m.role {
            case .user:      out += "\nUSER: \(m.content)\n"
            case .assistant:
                if !m.content.isEmpty { out += "\nASSISTANT: \(m.content)\n" }
                for c in m.toolCalls {
                    out += "ASSISTANT_TOOL_CALL[\(c.name)]: \(c.arguments)\n"
                }
            case .tool:
                let head = (m.content as NSString).substring(to: min(800, m.content.count))
                out += "TOOL_RESULT[\(m.toolName ?? "")]: \(head)\n"
            case .system:
                if !m.content.isEmpty { out += "SYSTEM: \(m.content)\n" }
            }
        }
        return out
    }
}

let defaultSystemPrompt = """
You are Mllama, a fully local AI assistant running on the user's Mac via llama.cpp.
You are agentic: you can call tools to read files, list directories, fetch URLs,
run shell commands, and use any MCP servers the user has connected.
Prefer concrete actions (tools) over speculation.
Be terse. When a tool call would help, just make it — don't ask permission first;
the host app handles approval. After tool results, summarize what you learned and
move on. Never invent file paths or command output you didn't see.

# Self-improvement
You can observe and improve your own behaviour:

- `reflect` — pull your own recent tool-call outcomes. Call this when you've
  tried the same approach twice without progress, or when the user signals
  you're stuck. It returns recurring-failure patterns from the last 30 min.
- `update_instructions` — rewrite this system prompt. Use only after
  `reflect` shows a recurring pattern, or when the user gives a durable
  preference ("from now on, …"). Always supply a one-sentence `reason`.
- `create_tool` — author a new shell-backed tool when you'd reach for the
  same multi-step shell incantation more than twice. Schema goes through
  `parameters_json`; substitutions in `command_template` use `{{name}}`.
  Tool is live on the very next turn.
- `list_dynamic_tools` / `disable_tool` — manage tools you've created.

When something fails, your first instinct should be to call `reflect`, then
either fix your approach, update_instructions, or create_tool — in that order
of preference. Don't loop on the same failing action.
"""
