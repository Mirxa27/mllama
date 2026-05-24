import Foundation
import Darwin

// MARK: - Defaults keys

enum SDKeys {
    static let binaryOverride       = "sd.binaryOverride"   // path to sd-server (override bundled)
    static let cliOverride          = "sd.cliOverride"      // path to sd-cli for video gen
    static let imageModelPath       = "sd.imageModelPath"
    static let vaePath              = "sd.vaePath"
    static let clipLPath            = "sd.clipLPath"
    static let clipGPath            = "sd.clipGPath"
    static let t5Path               = "sd.t5Path"
    static let upscalerPath         = "sd.upscalerPath"
    static let controlNetPath       = "sd.controlNetPath"
    static let loraDir              = "sd.loraDir"
    static let host                 = "sd.host"
    static let port                 = "sd.port"
    static let vaeOnCpu             = "sd.vaeOnCpu"
    static let clipOnCpu            = "sd.clipOnCpu"
    static let flashAttn            = "sd.flashAttn"
    static let vaeTiling            = "sd.vaeTiling"
    static let threads              = "sd.threads"
    static let outputRoot           = "sd.outputRoot"

    // Video-specific
    static let videoModelPath       = "sd.videoModelPath"
    static let videoVaePath         = "sd.videoVaePath"
    static let videoT5Path          = "sd.videoT5Path"
}

// MARK: - Controller

/// Manages the `sd-server` subprocess (HTTP API for image generation).
/// Mirrors the lifecycle of ServerController used for llama-server.
@MainActor
final class SDServerController: ObservableObject {
    enum Status: Equatable {
        case stopped, starting, running, failed(String), notConfigured
    }

    @Published var status: Status = .stopped
    @Published var log: String = ""
    @Published var runtimePort: Int = 1235
    /// True once we've confirmed the running server speaks /sdcpp/v1/*
    /// (the native endpoint family with proper distilled-guidance support).
    /// Set during `waitUntilReady()` via a capabilities probe.
    @Published private(set) var supportsSdcpp: Bool = false

    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?

    var host: String { UserDefaults.standard.string(forKey: SDKeys.host) ?? "127.0.0.1" }
    var port: Int { UserDefaults.standard.integer(forKey: SDKeys.port).nonZeroOr(1235) }

    var serverURL: URL? { URL(string: "http://\(host):\(runtimePort)/") }

    /// Path to sd-server. Search order: user override → ~/.mllama/bin → bundle → Homebrew.
    var binaryURL: URL? {
        InstallPaths.locate("sd-server", userOverrideKey: SDKeys.binaryOverride)
    }

    var modelPath: String? {
        let p = UserDefaults.standard.string(forKey: SDKeys.imageModelPath) ?? ""
        return p.isEmpty ? nil : p
    }

    var outputRoot: URL {
        if let custom = UserDefaults.standard.string(forKey: SDKeys.outputRoot), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".mllama/media")
    }

    /// Switch to a new model and restart.
    func activate(modelPath: String) {
        UserDefaults.standard.set(modelPath, forKey: SDKeys.imageModelPath)
        restart()
    }

    func start() {
        stop()
        guard let bin = binaryURL else {
            status = .notConfigured
            appendLog("[SDServer] sd-server binary not found. Set Settings → Image Gen → Binary path, or install stable-diffusion.cpp.\n")
            return
        }
        guard let model = modelPath, FileManager.default.fileExists(atPath: model) else {
            status = .notConfigured
            appendLog("[SDServer] No image model selected. Pick a GGUF/safetensors model in Settings → Image Gen.\n")
            return
        }

        let d = UserDefaults.standard
        let configured = port
        guard let chosen = findFreePort(startingAt: configured, host: host) else {
            status = .failed("Could not find a free port near \(configured).")
            return
        }
        runtimePort = chosen
        if chosen != configured {
            appendLog("[SDServer] Port \(configured) busy → using \(chosen).\n")
        }

        // Try to create the output dir up front.
        try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        // Diffusion-only families (FLUX, SD 3.5, Wan, LTX) ship as a split
        // weights file — the VAE and text encoders live in separate files.
        // Pass them via `--diffusion-model`; only complete checkpoints (SDXL,
        // SD 1.x) use `-m`. Mixing these up makes sd-server reject the file.
        let family = DiffusionFamily.detect(path: model)
        let modelFlag: String = {
            switch family {
            case .flux, .sd35, .wan21, .ltx: return "--diffusion-model"
            case .sdxl, .sd15, .unknown:     return "-m"
            }
        }()
        var args: [String] = [
            "--listen-ip", host,
            "--listen-port", String(chosen),
            modelFlag, model,
        ]

        // Optional submodels.
        if let vae = d.string(forKey: SDKeys.vaePath), !vae.isEmpty, FileManager.default.fileExists(atPath: vae) {
            args.append(contentsOf: ["--vae", vae])
        }
        if let cl = d.string(forKey: SDKeys.clipLPath), !cl.isEmpty, FileManager.default.fileExists(atPath: cl) {
            args.append(contentsOf: ["--clip_l", cl])
        }
        if let cg = d.string(forKey: SDKeys.clipGPath), !cg.isEmpty, FileManager.default.fileExists(atPath: cg) {
            args.append(contentsOf: ["--clip_g", cg])
        }
        if let t5 = d.string(forKey: SDKeys.t5Path), !t5.isEmpty, FileManager.default.fileExists(atPath: t5) {
            args.append(contentsOf: ["--t5xxl", t5])
        }
        if let loras = d.string(forKey: SDKeys.loraDir), !loras.isEmpty {
            args.append(contentsOf: ["--lora-model-dir", loras])
        }

        // Apple Silicon hygiene flags.
        args.append("--mmap")
        if (d.object(forKey: SDKeys.flashAttn) as? Bool) ?? true {
            args.append("--fa")
            args.append("--diffusion-fa")
        }
        if (d.object(forKey: SDKeys.vaeTiling) as? Bool) ?? true {
            args.append("--vae-tiling")
        }
        if d.bool(forKey: SDKeys.vaeOnCpu) { args.append("--vae-on-cpu") }
        if d.bool(forKey: SDKeys.clipOnCpu) { args.append("--clip-on-cpu") }
        let t = d.integer(forKey: SDKeys.threads)
        if t > 0 { args.append(contentsOf: ["-t", String(t)]) }

        let p = Process()
        p.executableURL = bin
        p.arguments = args

        let outPipe = Pipe(); let errPipe = Pipe()
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
                    self.status = .failed("sd-server exited with status \(proc.terminationStatus).")
                } else {
                    self.status = .stopped
                }
            }
        }

        do {
            status = .starting
            appendLog("[SDServer] starting: \(args.joined(separator: " "))\n")
            try p.run()
            process = p
            Task { await self.waitUntilReady() }
        } catch {
            status = .failed("Failed to launch sd-server: \(error.localizedDescription)")
        }
    }

    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        stdoutHandle = nil
        stderrHandle = nil
        supportsSdcpp = false
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
        if log.count > 100_000 { log = String(log.suffix(80_000)) }
    }

    private func waitUntilReady() async {
        guard let base = serverURL else { return }
        let probe = base.appendingPathComponent("sdapi/v1/options")
        var req = URLRequest(url: probe); req.timeoutInterval = 2
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if status == .stopped || (process?.isRunning ?? false) == false { return }
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
                    self.status = .running
                    await probeSdcppSupport(base: base)
                    return
                }
            } catch { /* keep polling */ }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        if status != .running {
            status = .failed("sd-server did not become ready in time.")
        }
    }

    /// Probe whether the running sd-server exposes the native /sdcpp/v1/*
    /// endpoints. Older builds only have /sdapi/v1/, in which case FLUX/SD3
    /// distilled guidance can't be passed through — the UI will fall back
    /// to the A1111 path and warn that guidance won't apply.
    private func probeSdcppSupport(base: URL) async {
        let probe = base.appendingPathComponent("sdcpp/v1/capabilities")
        var req = URLRequest(url: probe); req.timeoutInterval = 2
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                self.supportsSdcpp = true
                appendLog("[SDServer] /sdcpp/v1/* available — distilled guidance enabled for FLUX/SD3.\n")
                return
            }
        } catch { /* swallow */ }
        self.supportsSdcpp = false
        appendLog("[SDServer] /sdcpp/v1/* not available — distilled guidance won't apply on this build.\n")
    }
}
