import Foundation
import OSLog

/// Centralised `os.Logger` categories. Replaces `NSLog` and `print` across
/// the app so a single subsystem (`org.mllama.app`) shows up consistently
/// in Console.app and `log stream` filters.
///
/// Sensitivity tagging:
/// - User prompts, file paths under $HOME, model filenames → `.private`
/// - HTTP status codes, exit codes, port numbers, timing → `.public`
/// - HF tokens, API keys → never logged
///
/// Usage:
///     Log.app.info("bootstrap complete")
///     Log.sd.error("sd-server exited \(code, privacy: .public)")
///     Log.agent.debug("tool call \(toolName, privacy: .public) args=\(args, privacy: .private)")
enum Log {
    private static let subsystem = "org.mllama.app"

    static let app     = Logger(subsystem: subsystem, category: "app")
    static let llama   = Logger(subsystem: subsystem, category: "llama-server")
    static let sd      = Logger(subsystem: subsystem, category: "sd-server")
    static let sdcli   = Logger(subsystem: subsystem, category: "sd-cli")
    static let agent   = Logger(subsystem: subsystem, category: "agent")
    static let tools   = Logger(subsystem: subsystem, category: "tools")
    static let hf      = Logger(subsystem: subsystem, category: "huggingface")
    static let mcp     = Logger(subsystem: subsystem, category: "mcp")
    static let media   = Logger(subsystem: subsystem, category: "media")
    static let net     = Logger(subsystem: subsystem, category: "network")
    static let voice   = Logger(subsystem: subsystem, category: "voice")
    static let evolve  = Logger(subsystem: subsystem, category: "self-improvement")
    static let perm    = Logger(subsystem: subsystem, category: "permissions")
    static let update  = Logger(subsystem: subsystem, category: "update-check")

    /// Mirror a message to the on-disk diag.log so the user can post-mortem
    /// without having to invoke `log show`. Kept for backwards compatibility
    /// with the existing `MllamaApp.diagLog` entrypoint.
    static func diag(_ msg: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mllama/diag.log")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
        Log.app.info("\(msg, privacy: .public)")
    }
}
