import Foundation
import AVFoundation
import SwiftUI

// MARK: - Storyboard model

/// One scene in a long-video storyboard. Each scene becomes a single sd-cli run,
/// optionally chained to the previous scene by reusing its last frame as the
/// init image — this gives temporal coherence across cuts.
struct StoryScene: Identifiable, Hashable, Codable {
    var id = UUID()
    var prompt: String
    var negativePrompt: String = ""
    var seconds: Double = 2.0
    var width: Int = 832
    var height: Int = 480
    var fps: Int = 24
    var steps: Int = 25
    var cfgScale: Double = 6.0
    var seed: Int64 = -1
    var chainFromPrevious: Bool = true   // start where last scene ended

    var frames: Int { max(8, Int(seconds * Double(fps))) }
}

enum StorySceneStatus: Equatable {
    case pending
    case extractingTransition       // extracting last frame of prev scene
    case generating(step: Int, total: Int)
    case stitching                  // pipeline-level (only for the overall step)
    case done(URL)                  // produced this scene's clip
    case failed(String)

    var label: String {
        switch self {
        case .pending:                       return "Pending"
        case .extractingTransition:          return "Linking to previous scene…"
        case .generating(let s, let t):      return "Generating · step \(s)/\(t)"
        case .stitching:                     return "Stitching final video…"
        case .done:                          return "Done"
        case .failed(let m):                 return "Failed: \(m)"
        }
    }

    var fraction: Double {
        switch self {
        case .pending:                       return 0
        case .extractingTransition:          return 0.05
        case .generating(let s, let t):      return 0.05 + 0.85 * Double(s)/Double(max(1,t))
        case .stitching:                     return 0.95
        case .done:                          return 1
        case .failed:                        return 0
        }
    }

    var isTerminal: Bool {
        if case .done = self { return true }
        if case .failed = self { return true }
        return false
    }
}

struct Storyboard: Codable, Hashable {
    var title: String = "Untitled story"
    var scenes: [StoryScene] = []
    /// Smooth final video by interpolating to a higher fps with ffmpeg
    var interpolateTo: Int = 0          // 0 = no interpolation, else target fps
    /// Optional audio track to mux into the final output
    var audioTrackPath: String? = nil
}

// MARK: - Pipeline

/// Per-scene status — published as the pipeline progresses.
@MainActor
final class VideoPipeline: ObservableObject {
    @Published private(set) var storyboard: Storyboard = Storyboard()
    @Published private(set) var sceneStatuses: [UUID: StorySceneStatus] = [:]
    @Published private(set) var currentSceneIndex: Int = -1
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published var lastError: String?
    @Published private(set) var finalVideoURL: URL?
    @Published private(set) var elapsed: TimeInterval = 0

    private let server: SDServerController
    private var pipelineTask: Task<Void, Never>?
    private var pauseGate: CheckedContinuation<Void, Never>?
    private var startTime: Date?
    private var clockTimer: Task<Void, Never>?

    init(server: SDServerController) {
        self.server = server
    }

    // MARK: - Storyboard editing

    func load(_ story: Storyboard) {
        storyboard = story
        sceneStatuses = Dictionary(uniqueKeysWithValues: story.scenes.map { ($0.id, .pending) })
        finalVideoURL = nil
        currentSceneIndex = -1
        elapsed = 0
    }

    func appendScene(prompt: String = "", chainFromPrevious: Bool = true) {
        var s = StoryScene(prompt: prompt, chainFromPrevious: chainFromPrevious)
        // Inherit dimensions/seconds from the previous scene for consistency
        if let prev = storyboard.scenes.last {
            s.width = prev.width; s.height = prev.height
            s.fps = prev.fps; s.seconds = prev.seconds; s.steps = prev.steps
            s.cfgScale = prev.cfgScale
        }
        storyboard.scenes.append(s)
        sceneStatuses[s.id] = .pending
    }

    func removeScene(at index: Int) {
        guard storyboard.scenes.indices.contains(index) else { return }
        let id = storyboard.scenes[index].id
        sceneStatuses.removeValue(forKey: id)
        storyboard.scenes.remove(at: index)
    }

    func moveScene(from src: Int, to dst: Int) {
        guard storyboard.scenes.indices.contains(src) else { return }
        let dstClamped = max(0, min(dst, storyboard.scenes.count))
        let s = storyboard.scenes.remove(at: src)
        storyboard.scenes.insert(s, at: dstClamped > src ? dstClamped - 1 : dstClamped)
    }

    func updateScene(_ id: UUID, _ mutate: (inout StoryScene) -> Void) {
        guard let idx = storyboard.scenes.firstIndex(where: { $0.id == id }) else { return }
        mutate(&storyboard.scenes[idx])
    }

    // MARK: - Run

    func cancel() {
        pipelineTask?.cancel()
        pipelineTask = nil
        clockTimer?.cancel()
        clockTimer = nil
        isRunning = false
        isPaused = false
        if let gate = pauseGate { pauseGate = nil; gate.resume() }
    }

    func pause() { isPaused = true }
    func resume() {
        isPaused = false
        if let gate = pauseGate { pauseGate = nil; gate.resume() }
    }

    /// Reset every scene's status back to pending without touching the storyboard
    /// contents. Use this before re-running after a partial run.
    func resetStatuses() {
        for id in sceneStatuses.keys { sceneStatuses[id] = .pending }
        finalVideoURL = nil
        elapsed = 0
        currentSceneIndex = -1
    }

    /// Execute the storyboard end-to-end.
    func run() {
        guard !isRunning, !storyboard.scenes.isEmpty else { return }
        let validPrompts = storyboard.scenes.allSatisfy { !$0.prompt.trimmingCharacters(in: .whitespaces).isEmpty }
        guard validPrompts else {
            lastError = "All scenes need a prompt."
            return
        }
        cancel()
        resetStatuses()
        isRunning = true
        lastError = nil
        startTime = Date()
        startClockTimer()
        pipelineTask = Task { [weak self] in
            await self?.execute()
        }
    }

    private func startClockTimer() {
        clockTimer?.cancel()
        clockTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self else { return }
                if let s = await self.startTime { await MainActor.run { self.elapsed = Date().timeIntervalSince(s) } }
            }
        }
    }

    // MARK: - Execution

    private func execute() async {
        defer {
            Task { @MainActor in
                self.isRunning = false
                self.clockTimer?.cancel()
                self.clockTimer = nil
            }
        }

        var generatedClips: [URL] = []
        var lastFrameForChain: URL? = nil

        for (idx, scene) in storyboard.scenes.enumerated() {
            await waitIfPausedOrCancelled()
            if Task.isCancelled { return }
            await MainActor.run { self.currentSceneIndex = idx }

            // 1. If chaining, extract last frame of the previous clip
            var initImage: String? = nil
            if scene.chainFromPrevious, let prevClip = generatedClips.last {
                await MainActor.run { self.sceneStatuses[scene.id] = .extractingTransition }
                if let frame = await Self.extractLastFrame(of: prevClip) {
                    initImage = frame.path
                    lastFrameForChain = frame
                }
            }

            // 2. Generate the clip
            let clipURL: URL
            do {
                clipURL = try await generateClip(
                    scene: scene,
                    initImage: initImage,
                    sceneIndex: idx
                )
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    self.sceneStatuses[scene.id] = .failed(error.localizedDescription)
                    self.lastError = "Scene \(idx + 1) failed: \(error.localizedDescription)"
                }
                return
            }
            await MainActor.run { self.sceneStatuses[scene.id] = .done(clipURL) }
            generatedClips.append(clipURL)
            _ = lastFrameForChain  // silence unused warning when not chaining onward
        }

        // 3. Stitch all clips together
        if Task.isCancelled { return }
        await MainActor.run {
            if let firstId = storyboard.scenes.first?.id { _ = firstId }  // anchor for UI
        }
        let final: URL?
        do {
            final = try await stitchClips(generatedClips,
                                          interpolateFps: storyboard.interpolateTo,
                                          audioTrackPath: storyboard.audioTrackPath)
        } catch {
            await MainActor.run { self.lastError = "Stitching failed: \(error.localizedDescription)" }
            return
        }

        if let final = final {
            await MainActor.run { self.finalVideoURL = final }
            // Record in media library so it shows up in Gallery.
            let result = VideoGenResult(
                url: final,
                params: VideoGenParams(
                    prompt: storyboard.scenes.map { $0.prompt }.joined(separator: " → "),
                    negativePrompt: "",
                    width: storyboard.scenes.first?.width ?? 832,
                    height: storyboard.scenes.first?.height ?? 480,
                    frames: storyboard.scenes.reduce(0) { $0 + $1.frames },
                    fps: storyboard.scenes.first?.fps ?? 24,
                    steps: storyboard.scenes.first?.steps ?? 25,
                    cfgScale: storyboard.scenes.first?.cfgScale ?? 6.0,
                    seed: -1
                ),
                createdAt: Date(),
                elapsedSeconds: elapsed,
                modelName: "storyboard",
                thumbnailURL: await VideoThumbnailer.makeThumbnail(for: final)
            )
            await MainActor.run { MediaLibrary.shared.record(video: result) }
        }
    }

    private func waitIfPausedOrCancelled() async {
        if Task.isCancelled { return }
        if !isPaused { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.pauseGate = cont
        }
    }

    // MARK: - Per-clip generation

    private func generateClip(scene: StoryScene, initImage: String?, sceneIndex: Int) async throws -> URL {
        guard let bin = await MainActor.run(body: { Self.cliURL() }) else {
            throw PipelineError("sd-cli binary not found. Build stable-diffusion.cpp with -DSD_BUILD_SERVER=ON.")
        }
        let d = UserDefaults.standard
        guard let model = d.string(forKey: SDKeys.videoModelPath),
              !model.isEmpty, FileManager.default.fileExists(atPath: model) else {
            throw PipelineError("No video model configured. Settings → Video Gen.")
        }

        let outRoot = await MainActor.run { server.outputRoot.appendingPathComponent("storyboard") }
        try FileManager.default.createDirectory(at: outRoot, withIntermediateDirectories: true)
        let stamp = DateFormatter.compactStamp.string(from: Date())
        let outURL = outRoot.appendingPathComponent("scene\(sceneIndex + 1)_\(stamp).webp")

        var args: [String] = [
            "-M", "vid_gen",
            "--diffusion-model", model,
            "-p", scene.prompt,
            "-W", String(scene.width), "-H", String(scene.height),
            "--video-frames", String(scene.frames),
            "--fps", String(scene.fps),
            "--steps", String(scene.steps),
            "--cfg-scale", String(scene.cfgScale),
            "--guidance", "5.0",
            "-s", String(scene.seed),
            "-o", outURL.path,
            "--mmap", "--fa", "--diffusion-fa",
        ]
        if !scene.negativePrompt.isEmpty {
            args.append(contentsOf: ["-n", scene.negativePrompt])
        }
        if let vae = d.string(forKey: SDKeys.videoVaePath), !vae.isEmpty, FileManager.default.fileExists(atPath: vae) {
            args.append(contentsOf: ["--vae", vae])
        }
        if let t5 = d.string(forKey: SDKeys.videoT5Path), !t5.isEmpty, FileManager.default.fileExists(atPath: t5) {
            args.append(contentsOf: ["--t5xxl", t5])
        }
        if let init_ = initImage, FileManager.default.fileExists(atPath: init_) {
            args.append(contentsOf: ["-i", init_])
            // Note: real i2v also needs --clip_vision; expose later when needed
        }

        let totalSteps = scene.steps
        let sceneId = scene.id

        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = bin
            p.arguments = args
            let outPipe = Pipe(); let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe

            // Parse `sampling step N/M` from stderr so the UI can show progress
            // per scene. Same regex as VideoGenerator.
            let regex = try? NSRegularExpression(pattern: #"sampling step (\d+)/(\d+)"#)
            let handler: @Sendable (FileHandle) -> Void = { [weak self] h in
                let d = h.availableData
                guard !d.isEmpty,
                      let s = String(data: d, encoding: .utf8),
                      let rx = regex else { return }
                for line in s.components(separatedBy: "\n") {
                    let r = NSRange(line.startIndex..., in: line)
                    guard let m = rx.firstMatch(in: line, range: r) else { continue }
                    let stepStr = (line as NSString).substring(with: m.range(at: 1))
                    let totalStr = (line as NSString).substring(with: m.range(at: 2))
                    let step = Int(stepStr) ?? 0
                    let total = Int(totalStr) ?? totalSteps
                    Task { @MainActor in
                        self?.sceneStatuses[sceneId] = .generating(step: step, total: total)
                    }
                }
            }
            outPipe.fileHandleForReading.readabilityHandler = handler
            errPipe.fileHandleForReading.readabilityHandler = handler

            p.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0, FileManager.default.fileExists(atPath: outURL.path) {
                    cont.resume(returning: outURL)
                } else {
                    cont.resume(throwing: PipelineError("sd-cli exit \(proc.terminationStatus)"))
                }
            }
            do { try p.run() }
            catch { cont.resume(throwing: error) }
        }
    }

    // MARK: - Stitching with ffmpeg

    private func stitchClips(_ clips: [URL], interpolateFps: Int, audioTrackPath: String?) async throws -> URL {
        guard let ff = Self.ffmpegURL() else {
            throw PipelineError("ffmpeg not found. Install via `brew install ffmpeg`.")
        }
        // Mark every scene's status conceptually as "stitching" while it runs
        await MainActor.run {
            // No per-scene status to change here; use lastError to communicate
        }

        let outRoot = await MainActor.run { server.outputRoot }
        try FileManager.default.createDirectory(at: outRoot, withIntermediateDirectories: true)
        let stamp = DateFormatter.compactStamp.string(from: Date())

        // sd-cli outputs animated WEBP. We re-encode each clip to a uniform
        // intermediate mp4 first (so concat works regardless of codec). Then
        // we concat all intermediates.

        // Step 1: convert each WEBP → mp4
        var intermediates: [URL] = []
        for (i, clip) in clips.enumerated() {
            let mp4URL = outRoot.appendingPathComponent("stitch_\(stamp)_\(i).mp4")
            try await Self.runFFmpeg(ff, args: [
                "-y", "-i", clip.path,
                "-c:v", "libx264", "-pix_fmt", "yuv420p",
                "-movflags", "+faststart", "-an",
                mp4URL.path
            ])
            intermediates.append(mp4URL)
        }

        // Step 2: build a concat list and run the concat demuxer
        let listURL = outRoot.appendingPathComponent("stitch_\(stamp).txt")
        let listContent = intermediates
            .map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")
        try listContent.write(to: listURL, atomically: true, encoding: .utf8)

        let concatURL = outRoot.appendingPathComponent("story_\(stamp).mp4")
        try await Self.runFFmpeg(ff, args: [
            "-y", "-f", "concat", "-safe", "0",
            "-i", listURL.path,
            "-c", "copy",
            concatURL.path
        ])

        var current = concatURL

        // Step 3 (optional): interpolate to a higher fps
        if interpolateFps > 0 {
            let interpURL = outRoot.appendingPathComponent("story_\(stamp)_interp\(interpolateFps).mp4")
            try await Self.runFFmpeg(ff, args: [
                "-y", "-i", current.path,
                "-vf", "minterpolate=fps=\(interpolateFps):mi_mode=mci:mc_mode=aobmc:vsbmf=1",
                "-c:a", "copy",
                interpURL.path
            ])
            current = interpURL
        }

        // Step 4 (optional): add audio track
        if let audio = audioTrackPath, FileManager.default.fileExists(atPath: audio) {
            let withAudio = outRoot.appendingPathComponent("story_\(stamp)_final.mp4")
            try await Self.runFFmpeg(ff, args: [
                "-y", "-i", current.path, "-i", audio,
                "-c:v", "copy", "-c:a", "aac",
                "-map", "0:v:0", "-map", "1:a:0", "-shortest",
                withAudio.path
            ])
            current = withAudio
        }

        // Cleanup intermediates (best-effort)
        for u in intermediates { try? FileManager.default.removeItem(at: u) }
        try? FileManager.default.removeItem(at: listURL)
        if current != concatURL { try? FileManager.default.removeItem(at: concatURL) }

        return current
    }

    private static func runFFmpeg(_ bin: URL, args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = bin
            p.arguments = args
            let errPipe = Pipe()
            p.standardError = errPipe
            let outPipe = Pipe()
            p.standardOutput = outPipe
            outPipe.fileHandleForReading.readabilityHandler = { _ in }
            let errBox = LockedBox<Data>(Data())
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { errBox.mutate { $0.append(d) } }
            }
            p.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let stderr = String(data: errBox.read(), encoding: .utf8) ?? ""
                    cont.resume(throwing: PipelineError("ffmpeg exit \(proc.terminationStatus): \(stderr.suffix(500))"))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// Extract the last frame of a video as a PNG. Used to chain scenes together
    /// — the next scene starts from where the previous one left off.
    static func extractLastFrame(of clip: URL) async -> URL? {
        guard let ff = ffmpegURL() else { return nil }
        let out = clip.deletingPathExtension().appendingPathExtension("lastframe.png")
        do {
            // -sseof -0.1 = seek to 100ms before end; grab a single frame.
            try await runFFmpeg(ff, args: [
                "-y", "-sseof", "-0.5", "-i", clip.path,
                "-vframes", "1", "-q:v", "2",
                out.path
            ])
            return FileManager.default.fileExists(atPath: out.path) ? out : nil
        } catch {
            return nil
        }
    }

    // MARK: - Tool discovery

    @MainActor
    static func cliURL() -> URL? {
        InstallPaths.locate("sd-cli", userOverrideKey: SDKeys.cliOverride)
    }

    static func ffmpegURL() -> URL? {
        InstallPaths.locate("ffmpeg")
    }
}

// MARK: - Errors

struct PipelineError: Error, CustomStringConvertible {
    let message: String
    init(_ m: String) { self.message = m }
    var description: String { message }
    var localizedDescription: String { message }
}

// MARK: - Storyboard templates (one-click starting points)

enum StoryboardTemplate {
    static let cinematicShort: Storyboard = {
        var s = Storyboard(title: "Cinematic short")
        s.scenes = [
            StoryScene(prompt: "wide cinematic shot of a vast misty mountain at dawn, soft golden light, drone aerial view, anamorphic lens",
                       seconds: 3, width: 832, height: 480, fps: 24, steps: 25, cfgScale: 6.0, chainFromPrevious: false),
            StoryScene(prompt: "slow dolly toward a lone figure standing on a cliff edge, dramatic backlight, wind blowing cloak",
                       seconds: 3, width: 832, height: 480, fps: 24, steps: 25, cfgScale: 6.0, chainFromPrevious: true),
            StoryScene(prompt: "close-up of the figure's eyes opening, reflection of mountains in the iris, color graded teal and orange",
                       seconds: 3, width: 832, height: 480, fps: 24, steps: 25, cfgScale: 6.0, chainFromPrevious: true),
        ]
        s.interpolateTo = 60
        return s
    }()

    static let productReel: Storyboard = {
        var s = Storyboard(title: "Product reel")
        s.scenes = [
            StoryScene(prompt: "minimalist white studio, slow 360° rotation around a sleek matte black smartphone, soft shadows",
                       seconds: 4, width: 960, height: 544, chainFromPrevious: false),
            StoryScene(prompt: "macro shot of the same phone screen lighting up with vibrant UI, depth of field bokeh",
                       seconds: 3, width: 960, height: 544, chainFromPrevious: true),
            StoryScene(prompt: "hand picking up the phone, motion blur, golden hour window light through blinds",
                       seconds: 3, width: 960, height: 544, chainFromPrevious: true),
        ]
        return s
    }()

    static let abstractLoop: Storyboard = {
        var s = Storyboard(title: "Abstract loop")
        s.scenes = [
            StoryScene(prompt: "iridescent liquid mercury flowing in slow motion, cymatic patterns, dark background, holographic",
                       seconds: 3, width: 832, height: 480, chainFromPrevious: false),
            StoryScene(prompt: "the same mercury splitting into geometric crystalline shards, magenta and cyan reflections",
                       seconds: 3, width: 832, height: 480, chainFromPrevious: true),
        ]
        s.interpolateTo = 60
        return s
    }()

    static let all: [Storyboard] = [cinematicShort, productReel, abstractLoop]
}
