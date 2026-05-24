import Foundation
import SwiftUI

// MARK: - Persistence root

/// Everything self-improvement persists lives under `~/.mllama/agent/`.
enum SelfImprovementPaths {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mllama/agent")
    }
    static var promptHistoryURL: URL { root.appendingPathComponent("prompt_history.json") }
    static var dynamicToolsURL:  URL { root.appendingPathComponent("dynamic_tools.json") }
    static var reflectionURL:    URL { root.appendingPathComponent("reflection.jsonl") }

    static func ensureRoot() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}

// MARK: - Reflection: what just happened?

/// One recorded tool invocation. We capture enough to spot recurring failures
/// without storing arbitrarily large tool outputs.
struct ReflectionRecord: Codable, Hashable, Identifiable {
    var id = UUID()
    var timestamp: Date
    var toolName: String
    /// First 600 chars of the JSON arguments — enough for pattern matching.
    var argsHead: String
    var isError: Bool
    /// First 600 chars of the result.
    var resultHead: String
    var durationMs: Int
}

/// Actor-isolated log of recent tool outcomes. Bounded ring (last 200 in
/// memory) plus an append-only JSONL on disk so we can survive restarts.
actor ReflectionStore {
    static let shared = ReflectionStore()

    private var ring: [ReflectionRecord] = []
    private let maxInMemory = 200
    private let onDiskURL: URL = SelfImprovementPaths.reflectionURL

    init() {
        // Load the tail of the on-disk log lazily — only the last N lines.
        if let data = try? Data(contentsOf: onDiskURL),
           let text = String(data: data, encoding: .utf8) {
            let lines = text.split(separator: "\n").suffix(maxInMemory)
            for line in lines {
                if let line_data = line.data(using: .utf8),
                   let rec = try? JSONDecoder.iso.decode(ReflectionRecord.self, from: line_data) {
                    ring.append(rec)
                }
            }
        }
    }

    func record(toolName: String, args: String, result: ToolCallResult, durationMs: Int) {
        let rec = ReflectionRecord(
            timestamp: Date(),
            toolName: toolName,
            argsHead: String(args.prefix(600)),
            isError: result.isError,
            resultHead: String(result.content.prefix(600)),
            durationMs: durationMs
        )
        ring.append(rec)
        if ring.count > maxInMemory { ring.removeFirst(ring.count - maxInMemory) }
        appendToDisk(rec)
    }

    /// Recent records, newest first.
    func recent(limit: Int = 50) -> [ReflectionRecord] {
        Array(ring.suffix(limit).reversed())
    }

    /// Just the failures, newest first.
    func recentFailures(limit: Int = 20) -> [ReflectionRecord] {
        Array(ring.filter { $0.isError }.suffix(limit).reversed())
    }

    /// Cheap pattern detection: which tool names have repeatedly errored
    /// in the last `windowMinutes`. Useful for the `reflect` tool.
    func failurePatterns(windowMinutes: Int = 30) -> [(toolName: String, count: Int)] {
        let cutoff = Date().addingTimeInterval(-Double(windowMinutes) * 60)
        var counts: [String: Int] = [:]
        for r in ring where r.isError && r.timestamp >= cutoff {
            counts[r.toolName, default: 0] += 1
        }
        return counts
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .map { (toolName: $0.key, count: $0.value) }
    }

    func clear() {
        ring.removeAll()
        try? FileManager.default.removeItem(at: onDiskURL)
    }

    private func appendToDisk(_ rec: ReflectionRecord) {
        SelfImprovementPaths.ensureRoot()
        guard let line = (try? JSONEncoder.iso.encode(rec))
                .flatMap({ String(data: $0, encoding: .utf8) }) else { return }
        let payload = line + "\n"
        guard let data = payload.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: onDiskURL.path),
           let h = try? FileHandle(forWritingTo: onDiskURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: onDiskURL)
        }
    }
}

// MARK: - Prompt evolution

/// One snapshot of the system prompt — the agent has overwritten its own
/// instructions and we keep the history so the user can roll back.
struct PromptVersion: Codable, Hashable, Identifiable {
    var id = UUID()
    var timestamp: Date
    var prompt: String
    /// Why the change was made (model-supplied or "manual edit" / "rollback").
    var reason: String
    /// Monotonic version number (0 = baseline default).
    var version: Int
}

actor PromptEvolution {
    static let shared = PromptEvolution()

    private var history: [PromptVersion] = []

    init() {
        if let data = try? Data(contentsOf: SelfImprovementPaths.promptHistoryURL),
           let arr = try? JSONDecoder.iso.decode([PromptVersion].self, from: data) {
            history = arr
        }
    }

    var currentPrompt: String {
        history.last?.prompt ?? defaultSystemPrompt
    }

    var versions: [PromptVersion] { history }

    /// Replace the active prompt. Caller writes the new value to UserDefaults
    /// so the existing Agent.systemPrompt accessor picks it up immediately.
    @discardableResult
    func append(prompt: String, reason: String) -> PromptVersion {
        let nextVersion = (history.last?.version ?? 0) + 1
        let v = PromptVersion(timestamp: Date(),
                              prompt: prompt,
                              reason: reason,
                              version: nextVersion)
        history.append(v)
        persist()
        return v
    }

    /// Roll back to a specific version. Returns the prompt that's now active.
    @discardableResult
    func rollback(toVersion: Int) -> String? {
        guard let target = history.first(where: { $0.version == toVersion }) else { return nil }
        let rolled = PromptVersion(timestamp: Date(),
                                   prompt: target.prompt,
                                   reason: "Rolled back to v\(toVersion)",
                                   version: (history.last?.version ?? 0) + 1)
        history.append(rolled)
        persist()
        return rolled.prompt
    }

    /// Restore the original baseline.
    @discardableResult
    func resetToBaseline() -> String {
        let v = PromptVersion(timestamp: Date(),
                              prompt: defaultSystemPrompt,
                              reason: "Reset to baseline",
                              version: (history.last?.version ?? 0) + 1)
        history.append(v)
        persist()
        return defaultSystemPrompt
    }

    private func persist() {
        SelfImprovementPaths.ensureRoot()
        if let data = try? JSONEncoder.iso.encode(history) {
            try? data.write(to: SelfImprovementPaths.promptHistoryURL)
        }
    }
}

// MARK: - Dynamic tool: shell-template AgentTool

/// Spec for a tool the agent authored at runtime. The actual execution is a
/// `/bin/zsh -c "..."` with parameter substitution: `{{name}}` in
/// `commandTemplate` is replaced with the JSON-encoded argument value.
struct ScriptedToolSpec: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var humanName: String
    var description: String
    /// JSON schema describing the parameters.
    var parametersJSON: String
    /// Shell command with `{{paramName}}` placeholders. Substitutions are
    /// shell-escaped before interpolation.
    var commandTemplate: String
    /// Whether the host should require user approval per call. Defaults true
    /// since shell execution is dangerous.
    var requiresApproval: Bool
    var createdAt: Date
    var version: Int
}

/// AgentTool wrapper that executes a ScriptedToolSpec by shelling out.
struct ScriptedTool: AgentTool {
    let spec: ScriptedToolSpec

    var name: String { spec.name }
    var humanName: String { spec.humanName }
    var description: String { spec.description + "\n\n(dynamic tool, created \(Self.dateString(spec.createdAt)))" }
    var requiresApproval: Bool { spec.requiresApproval }
    var parameters: JSONValue { Self.parseSchema(spec.parametersJSON) }

    func run(arguments: String) async -> ToolCallResult {
        let argDict = parseArgs(arguments)
        let command = Self.applyTemplate(spec.commandTemplate, with: argDict)

        return await withCheckedContinuation { (cont: CheckedContinuation<ToolCallResult, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            let outPipe = Pipe(); let errPipe = Pipe()
            p.standardOutput = outPipe; p.standardError = errPipe
            let box = LockedBox<Data>(Data())
            let handler: @Sendable (FileHandle) -> Void = { h in
                let d = h.availableData
                if !d.isEmpty { box.mutate { $0.append(d) } }
            }
            outPipe.fileHandleForReading.readabilityHandler = handler
            errPipe.fileHandleForReading.readabilityHandler = handler
            p.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let raw = box.read()
                let trimmed = (String(data: raw, encoding: .utf8) ?? "")
                    .prefix(64_000)
                let exit = Int(proc.terminationStatus)
                let isErr = exit != 0
                let header = isErr
                    ? "exit \(exit)\n"
                    : "exit 0\n"
                cont.resume(returning: ToolCallResult(
                    toolCallId: "",
                    content: header + String(trimmed),
                    isError: isErr
                ))
            }
            do { try p.run() }
            catch {
                cont.resume(returning: ToolCallResult(
                    toolCallId: "",
                    content: "failed to launch shell: \(error.localizedDescription)",
                    isError: true
                ))
            }
        }
    }

    // MARK: Helpers

    private static func applyTemplate(_ template: String, with args: [String: Any]) -> String {
        var out = template
        for (k, v) in args {
            let placeholder = "{{\(k)}}"
            let shellEscaped = shellEscape("\(v)")
            out = out.replacingOccurrences(of: placeholder, with: shellEscaped)
        }
        return out
    }

    /// Single-quote-wrap and escape any embedded single quotes — safe for
    /// `/bin/zsh -lc` regardless of the user-supplied string content.
    private static func shellEscape(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func parseSchema(_ json: String) -> JSONValue {
        if let data = json.data(using: .utf8),
           let any = try? JSONSerialization.jsonObject(with: data) {
            return JSONValue.from(any)
        }
        // Fallback: empty object schema so the tool still loads.
        return .object([
            "type": .string("object"),
            "properties": .object([:]),
            "required": .array([])
        ])
    }

    private static func dateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }
}

// MARK: - Dynamic tool store

actor DynamicToolStore {
    static let shared = DynamicToolStore()

    private(set) var specs: [ScriptedToolSpec] = []

    init() {
        if let data = try? Data(contentsOf: SelfImprovementPaths.dynamicToolsURL),
           let arr = try? JSONDecoder.iso.decode([ScriptedToolSpec].self, from: data) {
            specs = arr
        }
    }

    /// Add or replace a tool by name. Returns the stored spec.
    @discardableResult
    func upsert(_ spec: ScriptedToolSpec) -> ScriptedToolSpec {
        var s = spec
        s.version = (specs.first(where: { $0.name == spec.name })?.version ?? 0) + 1
        specs.removeAll { $0.name == s.name }
        specs.append(s)
        persist()
        return s
    }

    func remove(name: String) -> ScriptedToolSpec? {
        guard let idx = specs.firstIndex(where: { $0.name == name }) else { return nil }
        let removed = specs.remove(at: idx)
        persist()
        return removed
    }

    func all() -> [ScriptedToolSpec] { specs }

    private func persist() {
        SelfImprovementPaths.ensureRoot()
        if let data = try? JSONEncoder.iso.encode(specs) {
            try? data.write(to: SelfImprovementPaths.dynamicToolsURL)
        }
    }
}

// MARK: - Coordinator (MainActor facade for UI)

/// Publishes the state of the self-improvement system to SwiftUI and routes
/// edits to the right actor. The actual storage lives in the actors above —
/// this is a thin observable wrapper that keeps the UI snappy.
@MainActor
final class SelfImprovementCoordinator: ObservableObject {
    @Published private(set) var promptVersions: [PromptVersion] = []
    @Published private(set) var currentPromptVersion: Int = 0
    @Published private(set) var dynamicTools: [ScriptedToolSpec] = []
    @Published private(set) var reflectionRecent: [ReflectionRecord] = []
    @Published private(set) var failurePatterns: [(toolName: String, count: Int)] = []

    private unowned let registry: ToolRegistry

    init(registry: ToolRegistry) {
        self.registry = registry
        Task { await self.bootstrap() }
    }

    /// Called once at startup: load any persisted dynamic tools into the
    /// running registry so the agent sees them on the very first turn.
    func bootstrap() async {
        let specs = await DynamicToolStore.shared.all()
        for s in specs {
            await registry.register(ScriptedTool(spec: s))
        }
        let prompts = await PromptEvolution.shared.versions
        let recent = await ReflectionStore.shared.recent(limit: 50)
        let patterns = await ReflectionStore.shared.failurePatterns()
        promptVersions = prompts
        currentPromptVersion = prompts.last?.version ?? 0
        dynamicTools = specs
        reflectionRecent = recent
        failurePatterns = patterns

        // If a non-baseline prompt is persisted but UserDefaults is empty,
        // hydrate the UserDefaults key the existing Agent.systemPrompt reads.
        if let latest = prompts.last,
           UserDefaults.standard.string(forKey: Keys.systemPrompt) ?? "" != latest.prompt {
            UserDefaults.standard.set(latest.prompt, forKey: Keys.systemPrompt)
        }
    }

    /// Refresh published state from the actors. Cheap — call after edits.
    func refresh() async {
        let prompts = await PromptEvolution.shared.versions
        let specs = await DynamicToolStore.shared.all()
        let recent = await ReflectionStore.shared.recent(limit: 50)
        let patterns = await ReflectionStore.shared.failurePatterns()
        promptVersions = prompts
        currentPromptVersion = prompts.last?.version ?? 0
        dynamicTools = specs
        reflectionRecent = recent
        failurePatterns = patterns
    }

    // MARK: - Mutations from UI

    /// User-facing manual edit. Tools call PromptEvolution directly.
    func manuallyUpdatePrompt(_ newPrompt: String, reason: String = "manual edit") async {
        _ = await PromptEvolution.shared.append(prompt: newPrompt, reason: reason)
        UserDefaults.standard.set(newPrompt, forKey: Keys.systemPrompt)
        await refresh()
    }

    func rollbackPrompt(to version: Int) async {
        if let restored = await PromptEvolution.shared.rollback(toVersion: version) {
            UserDefaults.standard.set(restored, forKey: Keys.systemPrompt)
            await refresh()
        }
    }

    func resetPromptToBaseline() async {
        let baseline = await PromptEvolution.shared.resetToBaseline()
        UserDefaults.standard.set(baseline, forKey: Keys.systemPrompt)
        await refresh()
    }

    func disableDynamicTool(name: String) async {
        if let _ = await DynamicToolStore.shared.remove(name: name) {
            await registry.unregister(name)
            await refresh()
        }
    }

    func clearReflectionLog() async {
        await ReflectionStore.shared.clear()
        await refresh()
    }
}

// MARK: - Codable JSON helpers

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

