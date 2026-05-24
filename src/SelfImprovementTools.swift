import Foundation

// MARK: - reflect

/// `reflect` exposes the agent's own recent tool-call outcomes so it can
/// notice patterns ("dock_status fails 3 turns in a row → my approach is
/// wrong") and propose a fix. Auto-approved because read-only.
struct ReflectTool: AgentTool {
    let name = "reflect"
    let humanName = "Self-reflect"
    let description = """
        Inspect your own recent tool-call history to identify where you've been struggling.
        Returns: the last N failures, repeated-failure patterns over the last
        30 minutes, and a count of total invocations. Call this whenever you
        feel stuck, repeat the same action twice without progress, or are
        asked to introspect. After reading the result, decide if you should
        update_instructions or create_tool.
        """
    let requiresApproval = false

    var parameters: JSONValue {
        paramsObject(
            properties: [
                "limit": intSchema("Max number of failure records to return (default 20).", default: 20),
                "include_successes": boolSchema("Also include the last successful calls. Default false.")
            ]
        )
    }

    func run(arguments: String) async -> ToolCallResult {
        let args = parseArgs(arguments)
        let limit = (args["limit"] as? Int) ?? 20
        let includeOK = (args["include_successes"] as? Bool) ?? false

        let recent = await ReflectionStore.shared.recent(limit: 200)
        let failures = await ReflectionStore.shared.recentFailures(limit: limit)
        let patterns = await ReflectionStore.shared.failurePatterns()

        var lines: [String] = []
        lines.append("== reflection ==")
        lines.append("total_recorded: \(recent.count)")
        lines.append("failure_count: \(recent.filter { $0.isError }.count)")

        if patterns.isEmpty {
            lines.append("recurring_failures: (none in last 30 min)")
        } else {
            lines.append("recurring_failures:")
            for p in patterns {
                lines.append("  - \(p.toolName): \(p.count) errors in last 30 min")
            }
        }

        lines.append("")
        lines.append("== recent failures (newest first) ==")
        if failures.isEmpty {
            lines.append("(none)")
        } else {
            for f in failures.prefix(limit) {
                lines.append("[\(stamp(f.timestamp))] \(f.toolName) (\(f.durationMs) ms)")
                lines.append("  args: \(f.argsHead.prefix(200))")
                lines.append("  err:  \(f.resultHead.prefix(300))")
            }
        }

        if includeOK {
            lines.append("")
            lines.append("== recent successes ==")
            let oks = recent.filter { !$0.isError }.prefix(10)
            for o in oks {
                lines.append("[\(stamp(o.timestamp))] \(o.toolName) (\(o.durationMs) ms)")
            }
        }

        return ToolCallResult(toolCallId: "", content: lines.joined(separator: "\n"), isError: false)
    }

    private func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}

// MARK: - update_instructions

/// `update_instructions` lets the agent rewrite its own system prompt. The
/// new prompt takes effect on the very next turn (the existing
/// Agent.systemPrompt accessor reads UserDefaults at request-build time).
struct UpdateInstructionsTool: AgentTool {
    let name = "update_instructions"
    let humanName = "Rewrite system prompt"
    let description = """
        Replace your own system prompt with an improved version. Use sparingly
        — only when a pattern in reflect output suggests your current
        approach is fundamentally wrong, or the user explicitly asks you to
        remember a new rule. The previous prompt is preserved so it can be
        rolled back from Settings → Evolution. Provide a one-sentence
        `reason` so the user can audit changes.
        """
    let requiresApproval = true

    var parameters: JSONValue {
        paramsObject(
            properties: [
                "prompt": strSchema("The complete new system prompt. Do NOT diff — supply the whole replacement."),
                "reason": strSchema("One sentence on why you're updating, e.g. 'After 3 failed shell calls, prefer ReadFile when scanning text.'")
            ],
            required: ["prompt", "reason"]
        )
    }

    func run(arguments: String) async -> ToolCallResult {
        let args = parseArgs(arguments)
        guard let prompt = args["prompt"] as? String, !prompt.isEmpty else {
            return ToolCallResult(toolCallId: "", content: "error: 'prompt' is required", isError: true)
        }
        let reason = (args["reason"] as? String) ?? "agent self-update"
        let v = await PromptEvolution.shared.append(prompt: prompt, reason: reason)
        // Hydrate UserDefaults so Agent.systemPrompt picks it up next turn.
        UserDefaults.standard.set(prompt, forKey: Keys.systemPrompt)

        let result = """
            ok
            new_version: v\(v.version)
            reason: \(reason)
            takes_effect: next turn
            """
        return ToolCallResult(toolCallId: "", content: result, isError: false)
    }
}

// MARK: - create_tool

/// `create_tool` adds a new ScriptedTool to the live registry. The agent can
/// invoke it on the very next turn — the catalog is rebuilt per request.
struct CreateToolTool: AgentTool {
    /// The registry is unowned because App keeps it alive for the lifetime
    /// of the process.
    private let registryRef: @Sendable () -> ToolRegistry
    /// Coordinator handle so we can refresh published UI state after add.
    private let onChanged: @Sendable () async -> Void

    let name = "create_tool"
    let humanName = "Create new tool"
    let description = """
        Author a new tool for yourself by providing a shell command template
        with `{{paramName}}` placeholders. The tool is registered immediately
        — you can call it on your next turn.

        Example: a 'wordcount' tool you'll then call with {path:"/some.txt"}:
          name: "wordcount"
          description: "Count words in a file."
          parameters_json: '{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}'
          command_template: "wc -w {{path}}"

        Parameters are shell-escaped before substitution, so user-controlled
        strings can't inject extra commands. Avoid creating tools that
        duplicate existing built-ins (shell, read_file, etc.).
        """
    let requiresApproval = true

    init(registry: @autoclosure @escaping @Sendable () -> ToolRegistry,
         onChanged: @escaping @Sendable () async -> Void) {
        self.registryRef = registry
        self.onChanged = onChanged
    }

    var parameters: JSONValue {
        paramsObject(
            properties: [
                "name": strSchema("Tool name (snake_case, no spaces). Must be unique."),
                "human_name": strSchema("Short display name for UI."),
                "description": strSchema("What the tool does and when to use it."),
                "parameters_json": strSchema("JSON-schema object as a string describing the parameters."),
                "command_template": strSchema("Shell command with {{name}} placeholders matching the parameter names."),
                "requires_approval": boolSchema("Whether each invocation needs user approval. Defaults true.")
            ],
            required: ["name", "description", "parameters_json", "command_template"]
        )
    }

    func run(arguments: String) async -> ToolCallResult {
        let args = parseArgs(arguments)
        guard let name = args["name"] as? String, !name.isEmpty,
              let desc = args["description"] as? String, !desc.isEmpty,
              let schema = args["parameters_json"] as? String, !schema.isEmpty,
              let cmd = args["command_template"] as? String, !cmd.isEmpty else {
            return ToolCallResult(
                toolCallId: "",
                content: "error: required: name, description, parameters_json, command_template",
                isError: true
            )
        }
        // Sanity: refuse to overwrite built-ins.
        let reserved: Set<String> = [
            "shell", "read_file", "write_file", "list_directory", "fetch_url",
            "get_date_time", "generate_image", "edit_image", "generate_video",
            "edit_video", "search_huggingface", "download_hf_model", "list_media",
            "reflect", "update_instructions", "create_tool", "list_dynamic_tools",
            "disable_tool",
        ]
        if reserved.contains(name) {
            return ToolCallResult(
                toolCallId: "",
                content: "error: '\(name)' shadows a built-in tool. Pick another name.",
                isError: true
            )
        }
        // Validate the JSON schema parses.
        guard let schemaData = schema.data(using: .utf8),
              let _ = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any] else {
            return ToolCallResult(
                toolCallId: "",
                content: "error: parameters_json isn't a JSON object",
                isError: true
            )
        }
        let humanName = (args["human_name"] as? String) ?? name.replacingOccurrences(of: "_", with: " ")
        let approval = (args["requires_approval"] as? Bool) ?? true
        let spec = ScriptedToolSpec(
            name: name,
            humanName: humanName,
            description: desc,
            parametersJSON: schema,
            commandTemplate: cmd,
            requiresApproval: approval,
            createdAt: Date(),
            version: 1
        )
        let saved = await DynamicToolStore.shared.upsert(spec)
        let registry = registryRef()
        await registry.register(ScriptedTool(spec: saved))
        await onChanged()

        return ToolCallResult(
            toolCallId: "",
            content: "ok\nregistered: \(saved.name) v\(saved.version)\ntakes_effect: immediately (next turn sees this tool in the catalog)",
            isError: false
        )
    }
}

// MARK: - list_dynamic_tools

struct ListDynamicToolsTool: AgentTool {
    let name = "list_dynamic_tools"
    let humanName = "List dynamic tools"
    let description = "List every tool you've authored at runtime, with version and command template."
    let requiresApproval = false

    var parameters: JSONValue { paramsObject(properties: [:]) }

    func run(arguments: String) async -> ToolCallResult {
        let specs = await DynamicToolStore.shared.all()
        if specs.isEmpty {
            return ToolCallResult(toolCallId: "", content: "(no dynamic tools yet)", isError: false)
        }
        var out: [String] = []
        for s in specs {
            out.append("- \(s.name) (v\(s.version)) — \(s.description.prefix(120))")
            out.append("    cmd: \(s.commandTemplate)")
        }
        return ToolCallResult(toolCallId: "", content: out.joined(separator: "\n"), isError: false)
    }
}

// MARK: - disable_tool

struct DisableToolTool: AgentTool {
    private let registryRef: @Sendable () -> ToolRegistry
    private let onChanged: @Sendable () async -> Void

    let name = "disable_tool"
    let humanName = "Disable dynamic tool"
    let description = """
        Remove a tool you previously created with create_tool. Built-in tools
        cannot be disabled. The change is immediate — next turn won't see
        the removed tool.
        """
    let requiresApproval = false

    init(registry: @autoclosure @escaping @Sendable () -> ToolRegistry,
         onChanged: @escaping @Sendable () async -> Void) {
        self.registryRef = registry
        self.onChanged = onChanged
    }

    var parameters: JSONValue {
        paramsObject(
            properties: ["name": strSchema("Name of the dynamic tool to remove.")],
            required: ["name"]
        )
    }

    func run(arguments: String) async -> ToolCallResult {
        let args = parseArgs(arguments)
        guard let name = args["name"] as? String, !name.isEmpty else {
            return ToolCallResult(toolCallId: "", content: "error: 'name' required", isError: true)
        }
        guard let removed = await DynamicToolStore.shared.remove(name: name) else {
            return ToolCallResult(toolCallId: "", content: "no dynamic tool named '\(name)'", isError: true)
        }
        let registry = registryRef()
        await registry.unregister(removed.name)
        await onChanged()
        return ToolCallResult(toolCallId: "", content: "ok — removed \(removed.name)", isError: false)
    }
}
