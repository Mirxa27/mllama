import Foundation
import SwiftUI

// MARK: - Params

struct VideoGenParams: Hashable, Codable {
    var prompt: String = ""
    var negativePrompt: String = ""
    var width: Int = 832
    var height: Int = 480
    var frames: Int = 33                // ~1s at 24fps
    var fps: Int = 24
    var steps: Int = 25
    var cfgScale: Double = 6.0
    var guidance: Double = 5.0          // distilled guidance for Wan / LTX
    var seed: Int64 = -1
    var sampler: SDSampler = .euler

    // Image→video (first frame)
    var initImagePath: String? = nil
    var endImagePath: String? = nil     // first-last-frame mode
    var clipVisionPath: String? = nil   // I2V usually needs this
}

struct VideoGenResult: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let params: VideoGenParams
    let createdAt: Date
    let elapsedSeconds: Double
    let modelName: String
    let thumbnailURL: URL?
}

struct VideoGenProgress: Equatable {
    var step: Int
    var totalSteps: Int
    var fraction: Double
    var message: String
}

// MARK: - Generator

@MainActor
final class VideoGenerator: ObservableObject {
    @Published var isGenerating: Bool = false
    @Published var lastError: String?
    @Published var progress: VideoGenProgress?
    @Published var results: [VideoGenResult] = []

    private let server: SDServerController       // reuse for output paths/binaries
    private var process: Process?
    private var monitor: Task<Void, Never>?

    init(server: SDServerController) {
        self.server = server
    }

    /// Path to sd-cli (different from sd-server). Falls back to PATH lookup.
    var cliURL: URL? {
        InstallPaths.locate("sd-cli", userOverrideKey: SDKeys.cliOverride)
    }

    func cancel() {
        process?.terminate()
        process = nil
        monitor?.cancel()
        monitor = nil
        isGenerating = false
        progress = nil
    }

    func generate(_ params: VideoGenParams) {
        guard let bin = cliURL else {
            lastError = "sd-cli binary not found. Install stable-diffusion.cpp or set Settings → Video Gen → CLI path."
            return
        }
        let d = UserDefaults.standard
        guard let model = d.string(forKey: SDKeys.videoModelPath),
              !model.isEmpty, FileManager.default.fileExists(atPath: model) else {
            lastError = "No video model selected. Pick a Wan2.x or LTX-2 model in Settings → Video Gen."
            return
        }

        cancel()
        isGenerating = true
        lastError = nil
        progress = VideoGenProgress(step: 0, totalSteps: params.steps, fraction: 0, message: "Starting…")

        let outRoot = server.outputRoot
        try? FileManager.default.createDirectory(at: outRoot, withIntermediateDirectories: true)
        let ts = DateFormatter.compactStamp.string(from: Date())
        // sd-cli vid_gen writes animated webp / webm / avi only. We always
        // ask for .webp (smallest, most reliable) and then transcode to mp4
        // post-hoc so AVPlayer / AVKit can play it back natively.
        let outURL = outRoot.appendingPathComponent("vid_\(ts).webp")

        var args: [String] = ["-M", "vid_gen",
                              "--diffusion-model", model,
                              "-p", params.prompt,
                              "-W", String(params.width),
                              "-H", String(params.height),
                              "--video-frames", String(params.frames),
                              "--fps", String(params.fps),
                              "--steps", String(params.steps),
                              "--cfg-scale", String(params.cfgScale),
                              "--guidance", String(params.guidance),
                              "-s", String(params.seed),
                              "--sampling-method", params.sampler.rawValue,
                              "-o", outURL.path,
                              "--mmap", "--fa", "--diffusion-fa"]
        if !params.negativePrompt.isEmpty {
            args.append(contentsOf: ["-n", params.negativePrompt])
        }
        if let vae = d.string(forKey: SDKeys.videoVaePath), !vae.isEmpty, FileManager.default.fileExists(atPath: vae) {
            args.append(contentsOf: ["--vae", vae])
        }
        if let t5 = d.string(forKey: SDKeys.videoT5Path), !t5.isEmpty, FileManager.default.fileExists(atPath: t5) {
            args.append(contentsOf: ["--t5xxl", t5])
        }
        if let init_ = params.initImagePath, FileManager.default.fileExists(atPath: init_) {
            args.append(contentsOf: ["-i", init_])
            if let cv = params.clipVisionPath, FileManager.default.fileExists(atPath: cv) {
                args.append(contentsOf: ["--clip-vision", cv])
            }
        }
        if let end = params.endImagePath, FileManager.default.fileExists(atPath: end) {
            args.append(contentsOf: ["--end-img", end])
        }

        let start = Date()
        let p = Process()
        p.executableURL = bin
        p.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        // Parse "step X/Y" lines from stderr for progress.
        let regex = try? NSRegularExpression(pattern: #"sampling step (\d+)/(\d+)"#)
        let totalSteps = params.steps
        let handler: @Sendable (FileHandle) -> Void = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8), let rx = regex else { return }
            for line in s.components(separatedBy: "\n") {
                let r = NSRange(line.startIndex..., in: line)
                guard let m = rx.firstMatch(in: line, range: r) else { continue }
                let stepStr = (line as NSString).substring(with: m.range(at: 1))
                let totalStr = (line as NSString).substring(with: m.range(at: 2))
                let step = Int(stepStr) ?? 0
                let total = Int(totalStr) ?? totalSteps
                Task { @MainActor in
                    self?.progress = VideoGenProgress(
                        step: step, totalSteps: total,
                        fraction: Double(step) / Double(max(1, total)),
                        message: "Step \(step)/\(total)"
                    )
                }
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = handler
        errPipe.fileHandleForReading.readabilityHandler = handler

        p.terminationHandler = { [weak self] proc in
            let elapsed = Date().timeIntervalSince(start)
            Task { @MainActor in
                guard let self else { return }
                self.isGenerating = false
                self.progress = nil
                if proc.terminationStatus != 0 {
                    self.lastError = "sd-cli exited with status \(proc.terminationStatus)."
                    return
                }
                guard FileManager.default.fileExists(atPath: outURL.path) else {
                    self.lastError = "Video file was not produced."
                    return
                }
                // sd-cli vid_gen outputs animated WEBP. AVPlayer can't decode
                // those — transcode to H.264 mp4 so the in-app player works.
                self.progress = VideoGenProgress(step: params.steps, totalSteps: params.steps,
                                                 fraction: 1.0, message: "Transcoding to mp4…")
                let finalURL = await VideoTranscoder.toMP4(from: outURL) ?? outURL
                let thumb = await VideoThumbnailer.makeThumbnail(for: finalURL)
                let result = VideoGenResult(
                    url: finalURL, params: params, createdAt: Date(),
                    elapsedSeconds: elapsed,
                    modelName: (model as NSString).lastPathComponent,
                    thumbnailURL: thumb
                )
                self.results.insert(result, at: 0)
                MediaLibrary.shared.record(video: result)
                self.progress = nil
            }
        }

        do {
            try p.run()
            process = p
        } catch {
            lastError = "Failed to launch sd-cli: \(error.localizedDescription)"
            isGenerating = false
            progress = nil
        }
    }
}
