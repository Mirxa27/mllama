import Foundation
import Darwin

// MARK: - Defaults keys

enum Keys {
    static let modelPath    = "modelPath"
    static let mmprojPath   = "mmprojPath"
    static let port         = "port"
    static let contextSize  = "contextSize"   // 0 = model max
    static let ngl          = "ngl"
    static let host         = "host"
    static let extraArgs    = "extraArgs"
    static let customDirs   = "customDirs"
    static let flashAttn    = "flashAttn"
    static let mlock        = "mlock"
    static let threads      = "threads"
    static let systemPrompt = "systemPrompt"
    static let autoCompact  = "autoCompact"
}

// MARK: - Port probe

func isPortFree(_ port: Int, host: String) -> Bool {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    if sock < 0 { return false }
    defer { close(sock) }
    var yes: Int32 = 1
    _ = setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port   = in_port_t(UInt16(port).bigEndian)
    if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
    }
    let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return rc == 0
}

func findFreePort(startingAt: Int, host: String, maxTries: Int = 50) -> Int? {
    for i in 0..<maxTries {
        let p = startingAt + i
        if p > 65535 { return nil }
        if isPortFree(p, host: host) { return p }
    }
    return nil
}

// MARK: - Server controller

@MainActor
final class ServerController: ObservableObject {
    enum Status: Equatable {
        case stopped, starting, running, failed(String)
    }

    @Published var status: Status = .stopped
    @Published var log: String = ""
    @Published var runtimePort: Int = 8080
    /// Context window as reported by the server's /props endpoint after model
    /// loads. Zero until known.
    @Published var nCtx: Int = 0
    @Published var modelName: String = ""

    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?

    var port: Int { UserDefaults.standard.integer(forKey: Keys.port).nonZeroOr(8080) }
    var host: String { UserDefaults.standard.string(forKey: Keys.host) ?? "127.0.0.1" }

    var modelPath: String? {
        let p = UserDefaults.standard.string(forKey: Keys.modelPath) ?? ""
        return p.isEmpty ? nil : p
    }
    var mmprojPath: String? {
        let p = UserDefaults.standard.string(forKey: Keys.mmprojPath) ?? ""
        return p.isEmpty ? nil : p
    }

    var serverURL: URL? { URL(string: "http://\(host):\(runtimePort)/") }

    var binaryURL: URL? {
        Bundle.main.url(forResource: "llama-server", withExtension: nil, subdirectory: "bin")
    }

    func activate(modelPath: String, mmprojPath: String?) {
        let d = UserDefaults.standard
        d.set(modelPath, forKey: Keys.modelPath)
        d.set(mmprojPath ?? "", forKey: Keys.mmprojPath)
        restart()
    }

    func start() {
        stop()
        guard let bin = binaryURL else {
            status = .failed("llama-server is missing from the app bundle")
            return
        }
        guard let model = modelPath, FileManager.default.fileExists(atPath: model) else {
            status = .failed("No model selected. Pick one in the sidebar.")
            return
        }

        let d = UserDefaults.standard
        // Context = 0 → llama-server uses the model's max (from GGUF metadata).
        let ctx       = max(d.integer(forKey: Keys.contextSize), 0)
        let ngl       = (d.object(forKey: Keys.ngl) as? Int) ?? 99
        let threads   = d.integer(forKey: Keys.threads).nonZeroOr(8)
        let flashAttn = (d.object(forKey: Keys.flashAttn) as? Bool) ?? true
        let mlock     = (d.object(forKey: Keys.mlock) as? Bool) ?? true
        let extra     = d.string(forKey: Keys.extraArgs) ?? ""

        let configured = port
        guard let chosen = findFreePort(startingAt: configured, host: host) else {
            status = .failed("Could not find a free port near \(configured).")
            return
        }
        runtimePort = chosen
        if chosen != configured {
            appendLog("[Mllama] Port \(configured) busy → using \(chosen).\n")
        }

        var args: [String] = [
            "-m", model,
            "--host", host,
            "--port", String(chosen),
            "-c", String(ctx),
            "-ngl", String(ngl),
            "-t", String(threads),
            "-tb", String(threads),
            "--jinja",
            "--no-warmup",
            "--cont-batching",
        ]
        if flashAttn { args.append(contentsOf: ["--flash-attn", "on"]) }
        if mlock { args.append("--mlock") }
        if let mmproj = mmprojPath, FileManager.default.fileExists(atPath: mmproj) {
            args.append(contentsOf: ["--mmproj", mmproj])
        }
        if !extra.isEmpty {
            args.append(contentsOf: extra.split(separator: " ").map(String.init))
        }

        let p = Process()
        p.executableURL = bin
        p.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        attach(handle: outHandle)
        attach(handle: errHandle)
        stdoutHandle = outHandle
        stderrHandle = errHandle

        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self = self else { return }
                if proc.terminationStatus != 0 && self.status != .stopped {
                    self.status = .failed("llama-server exited with status \(proc.terminationStatus). Check log.")
                } else {
                    self.status = .stopped
                }
            }
        }

        do {
            status = .starting
            log = ""
            appendLog("[Mllama] starting: \(args.joined(separator: " "))\n")
            try p.run()
            process = p
            Task { await self.waitUntilReady() }
        } catch {
            status = .failed("Failed to launch: \(error.localizedDescription)")
        }
    }

    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        stdoutHandle = nil
        stderrHandle = nil
        status = .stopped
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.start()
        }
    }

    private func attach(handle: FileHandle) {
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { return }
            if let s = String(data: data, encoding: .utf8) {
                Task { @MainActor in self?.appendLog(s) }
            }
        }
    }

    private func appendLog(_ chunk: String) {
        log.append(chunk)
        if log.count > 200_000 {
            log = String(log.suffix(150_000))
        }
    }

    private func waitUntilReady() async {
        guard let healthURL = serverURL?.appendingPathComponent("health") else { return }
        let deadline = Date().addingTimeInterval(180)
        var req = URLRequest(url: healthURL)
        req.timeoutInterval = 1.5
        while Date() < deadline {
            if status == .stopped || (process?.isRunning ?? false) == false { return }
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    self.status = .running
                    await self.fetchProps()
                    return
                }
            } catch { /* keep polling */ }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        if status != .running {
            status = .failed("Server did not become ready in time. Check the log.")
        }
    }

    /// Pull n_ctx, model name etc. from the server's /props endpoint so the
    /// agent can size its token budget without having to crack the GGUF.
    func fetchProps() async {
        guard let base = serverURL else { return }
        let url = base.appendingPathComponent("props")
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            // n_ctx may appear at the root, or nested under default_generation_settings.
            if let n = json["n_ctx"] as? Int { self.nCtx = n }
            else if let g = json["default_generation_settings"] as? [String: Any],
                    let n = g["n_ctx"] as? Int { self.nCtx = n }
            if let path = (json["model_path"] as? String) ?? (json["model_alias"] as? String) {
                self.modelName = (path as NSString).lastPathComponent
            } else if let p = modelPath {
                self.modelName = (p as NSString).lastPathComponent
            }
        } catch { /* tolerate */ }
    }
}

extension Int {
    func nonZeroOr(_ fallback: Int) -> Int { self == 0 ? fallback : self }
}
