import Foundation

// MARK: - Protocol

/// Each tool advertises a JSON schema for its arguments and supplies an async
/// runner. The agent serializes the catalog into the `tools` field of the chat
/// completion request; results come back as `role: tool` messages.
protocol AgentTool: Sendable {
    var name: String { get }
    var humanName: String { get }
    var description: String { get }
    var parameters: JSONValue { get }
    /// True if the tool needs explicit user approval before each invocation.
    var requiresApproval: Bool { get }
    func run(arguments: String) async -> ToolCallResult
}

extension AgentTool {
    func wireDefinition() -> ChatCompletionRequest.WireTool {
        .init(function: .init(name: name, description: description, parameters: parameters))
    }
}

/// Helper to build a JSON-schema parameters object: `{type:"object", properties:{...}, required:[...]}`.
func paramsObject(properties: [String: JSONValue], required: [String] = []) -> JSONValue {
    .object([
        "type": .string("object"),
        "properties": .object(properties),
        "required": .array(required.map { .string($0) }),
        "additionalProperties": .bool(false),
    ])
}

func strSchema(_ desc: String) -> JSONValue {
    .object(["type": .string("string"), "description": .string(desc)])
}

func intSchema(_ desc: String, default def: Int? = nil) -> JSONValue {
    var d: [String: JSONValue] = ["type": .string("integer"), "description": .string(desc)]
    if let v = def { d["default"] = .int(v) }
    return .object(d)
}

func boolSchema(_ desc: String, default def: Bool? = nil) -> JSONValue {
    var d: [String: JSONValue] = ["type": .string("boolean"), "description": .string(desc)]
    if let v = def { d["default"] = .bool(v) }
    return .object(d)
}

// MARK: - Registry

actor ToolRegistry {
    private var tools: [String: AgentTool] = [:]

    func register(_ tool: AgentTool) {
        tools[tool.name] = tool
    }

    func unregister(_ name: String) {
        tools.removeValue(forKey: name)
    }

    func unregister(prefix: String) {
        for name in tools.keys where name.hasPrefix(prefix) {
            tools.removeValue(forKey: name)
        }
    }

    func all() -> [AgentTool] { Array(tools.values) }

    func tool(named name: String) -> AgentTool? { tools[name] }

    func count() -> Int { tools.count }
}

// MARK: - Built-in: shell

struct ShellTool: AgentTool {
    let name = "shell"
    let humanName = "Run shell command"
    let description = """
        Execute a shell command on the user's Mac (via /bin/zsh -lc). Returns
        combined stdout + stderr (truncated to ~64 KB) and the exit status.
        Use for short, focused commands — not long-lived processes. The user
        must approve each run.
        """
    let requiresApproval = true
    var parameters: JSONValue {
        paramsObject(
            properties: [
                "command": strSchema("The shell command to run, e.g. 'ls -la ~/Downloads'."),
                "cwd": strSchema("Optional working directory (absolute path). Defaults to user home."),
                "timeout_seconds": intSchema("Hard kill after N seconds. Default 30, max 300.", default: 30),
            ],
            required: ["command"]
        )
    }

    func run(arguments: String) async -> ToolCallResult {
        let args = parseArgs(arguments)
        let cmd = (args["command"] as? String) ?? ""
        let cwd = (args["cwd"] as? String) ?? NSHomeDirectory()
        let timeout = min(max((args["timeout_seconds"] as? Int) ?? 30, 1), 300)
        if cmd.trimmingCharacters(in: .whitespaces).isEmpty {
            return .init(toolCallId: "", content: "error: 'command' is required", isError: true)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        // Inherit a minimal but useful environment.
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        p.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        do {
            try p.run()
        } catch {
            return .init(toolCallId: "", content: "failed to launch: \(error.localizedDescription)", isError: true)
        }

        // Race process completion against a timeout.
        let timedOut: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resumed = false
            let lock = NSLock()
            func resume(_ v: Bool) {
                lock.lock(); defer { lock.unlock() }
                if resumed { return }
                resumed = true
                cont.resume(returning: v)
            }
            p.terminationHandler = { _ in resume(false) }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) {
                if p.isRunning {
                    p.terminate()
                    resume(true)
                }
            }
        }

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let status = p.terminationStatus

        var combined = ""
        if !stdout.isEmpty { combined += stdout }
        if !stderr.isEmpty {
            if !combined.isEmpty && !combined.hasSuffix("\n") { combined += "\n" }
            combined += "[stderr]\n" + stderr
        }
        if combined.count > 64_000 {
            combined = String(combined.prefix(64_000)) + "\n…[truncated]"
        }
        if combined.isEmpty { combined = "(no output)" }
        let header = timedOut
            ? "exit: killed after \(timeout)s timeout\n"
            : "exit: \(status)\n"
        return .init(toolCallId: "", content: header + combined, isError: status != 0 || timedOut)
    }
}

// MARK: - Built-in: read_file

struct ReadFileTool: AgentTool {
    let name = "read_file"
    let humanName = "Read file"
    let description = "Read a UTF-8 text file from disk. Optionally limit line range. Max 256 KB."
    let requiresApproval = false
    var parameters: JSONValue {
        paramsObject(
            properties: [
                "path": strSchema("Absolute path to the file."),
                "max_bytes": intSchema("Max bytes to read (default 65536, hard cap 262144).", default: 65536),
            ],
            required: ["path"]
        )
    }
    func run(arguments: String) async -> ToolCallResult {
        let args = parseArgs(arguments)
        guard let path = args["path"] as? String, !path.isEmpty else {
            return .init(toolCallId: "", content: "error: 'path' is required", isError: true)
        }
        let cap = min(max((args["max_bytes"] as? Int) ?? 65536, 1), 262_144)
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return .init(toolCallId: "", content: "error: no such file: \(expanded)", isError: true)
        }
        guard let fh = FileHandle(forReadingAtPath: expanded) else {
            return .init(toolCallId: "", content: "error: cannot open: \(expanded)", isError: true)
        }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: cap)) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? "<binary or non-UTF8 content; \(data.count) bytes>"
        let suffix = data.count == cap ? "\n…[truncated at \(cap) bytes]" : ""
        return .init(toolCallId: "", content: text + suffix, isError: false)
    }
}

// MARK: - Built-in: write_file

struct WriteFileTool: AgentTool {
    let name = "write_file"
    let humanName = "Write file"
    let description = "Overwrite a file with the given UTF-8 content. Creates parent directories. Requires user approval."
    let requiresApproval = true
    var parameters: JSONValue {
        paramsObject(
            properties: [
                "path":    strSchema("Absolute path to the file."),
                "content": strSchema("The full content to write."),
            ],
            required: ["path", "content"]
        )
    }
    func run(arguments: String) async -> ToolCallResult {
        let args = parseArgs(arguments)
        guard let path = args["path"] as? String, let content = args["content"] as? String else {
            return .init(toolCallId: "", content: "error: 'path' and 'content' are required", isError: true)
        }
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return .init(toolCallId: "", content: "wrote \(content.utf8.count) bytes to \(expanded)", isError: false)
        } catch {
            return .init(toolCallId: "", content: "error: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - Built-in: list_directory

struct ListDirectoryTool: AgentTool {
    let name = "list_directory"
    let humanName = "List directory"
    let description = "List files and directories at a path (non-recursive). Returns one entry per line with size + type."
    let requiresApproval = false
    var parameters: JSONValue {
        paramsObject(properties: ["path": strSchema("Absolute path of the directory.")], required: ["path"])
    }
    func run(arguments: String) async -> ToolCallResult {
        let args = parseArgs(arguments)
        guard let path = args["path"] as? String, !path.isEmpty else {
            return .init(toolCallId: "", content: "error: 'path' is required", isError: true)
        }
        let expanded = (path as NSString).expandingTildeInPath
        do {
            let entries = try FileManager.default.contentsOfDirectory(atPath: expanded).sorted()
            var lines: [String] = []
            for name in entries {
                let full = (expanded as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
                if isDir.boolValue {
                    lines.append("d  -          \(name)/")
                } else {
                    let size = (try? FileManager.default.attributesOfItem(atPath: full)[.size] as? Int) ?? 0
                    lines.append("f  \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))  \(name)")
                }
            }
            return .init(toolCallId: "", content: lines.joined(separator: "\n"), isError: false)
        } catch {
            return .init(toolCallId: "", content: "error: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - Built-in: fetch_url

struct FetchURLTool: AgentTool {
    let name = "fetch_url"
    let humanName = "Fetch URL"
    let description = "HTTP GET a URL and return the body (text, truncated to ~64 KB). Follows redirects."
    let requiresApproval = false
    var parameters: JSONValue {
        paramsObject(properties: [
            "url": strSchema("Absolute http(s):// URL."),
        ], required: ["url"])
    }
    func run(arguments: String) async -> ToolCallResult {
        let args = parseArgs(arguments)
        guard let raw = args["url"] as? String, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else {
            return .init(toolCallId: "", content: "error: provide a http(s) URL", isError: true)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Mllama/1.0 (+https://github.com)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes binary>"
            let body = text.count > 64_000 ? String(text.prefix(64_000)) + "\n…[truncated]" : text
            return .init(toolCallId: "", content: "status: \(status)\n\n\(body)", isError: !(200..<400).contains(status))
        } catch {
            return .init(toolCallId: "", content: "error: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - Built-in: get_datetime

struct GetDateTimeTool: AgentTool {
    let name = "get_datetime"
    let humanName = "Get current date/time"
    let description = "Return current date and time (ISO 8601 + human readable) in the user's timezone."
    let requiresApproval = false
    var parameters: JSONValue {
        paramsObject(properties: [:])
    }
    func run(arguments: String) async -> ToolCallResult {
        let now = Date()
        let iso = ISO8601DateFormatter()
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .long
        return .init(
            toolCallId: "",
            content: "\(iso.string(from: now))\n\(f.string(from: now))\nTZ: \(TimeZone.current.identifier)",
            isError: false
        )
    }
}

// MARK: - Arg parsing helper

/// Decodes a JSON string-form arguments blob to a [String: Any] dict.
/// Models sometimes emit slightly-broken JSON; we make a couple of recovery attempts.
func parseArgs(_ s: String) -> [String: Any] {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [:] }
    if let data = trimmed.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return obj
    }
    // Some models close-quote JSON inside an outer JSON string.
    if let data = trimmed.data(using: .utf8),
       let inner = try? JSONSerialization.jsonObject(with: data) as? String,
       let innerData = inner.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any] {
        return obj
    }
    return [:]
}
