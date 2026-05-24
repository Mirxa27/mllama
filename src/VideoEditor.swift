import Foundation
import AVFoundation
import AppKit

// MARK: - Operations

/// Thread-safe mutable box for sharing a value between background threads.
/// Used to bridge code that holds a mutable variable into Sendable closures.
final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ initial: T) { value = initial }
    func read() -> T {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func mutate(_ body: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&value)
    }
}

struct VideoEditError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
    var localizedDescription: String { message }
}

enum VideoEditOp: Hashable {
    case trim(start: Double, end: Double)             // seconds
    case crop(x: Int, y: Int, width: Int, height: Int)
    case scale(width: Int, height: Int)               // -2 for either dimension keeps aspect
    case speed(factor: Double)                        // 0.5 = slow-mo, 2 = fast
    case rotate(degrees: Int)                         // 90, 180, 270
    case flipHorizontal
    case flipVertical
    case grayscale
    case colorAdjust(brightness: Double, contrast: Double, saturation: Double)
    case lut(URL)
    case burnSubtitles(URL, fontSize: Int)
    case fps(Int)
    case mute
    case replaceAudio(URL)
    case extractFrames(fps: Int, outputDir: URL)
    case framesToVideo(pattern: String, fps: Int)     // %04d.png
    case toGIF(fps: Int, width: Int)
    case interpolate(targetFps: Int)
}

// MARK: - Editor

/// ffmpeg-based subprocess wrapper. Stays small: each op produces a fresh
/// output file rather than composing graphs. For complex pipelines, chain ops.
@MainActor
final class VideoEditor: ObservableObject {
    @Published var isProcessing: Bool = false
    @Published var lastError: String?
    @Published var progress: Double = 0
    @Published var statusMessage: String = ""

    var ffmpegURL: URL? {
        InstallPaths.locate("ffmpeg")
    }

    /// Apply an op to `input`, producing `output`. Async; reports progress
    /// roughly via ffmpeg's time= output parsing.
    func apply(_ op: VideoEditOp, to input: URL, output: URL) async -> Result<URL, VideoEditError> {
        guard let ff = ffmpegURL else {
            return .failure(VideoEditError("ffmpeg not found. Install via `brew install ffmpeg`."))
        }
        isProcessing = true
        progress = 0
        statusMessage = "Running \(opLabel(op))…"
        defer {
            Task { @MainActor in
                self.isProcessing = false
                self.progress = 1
                self.statusMessage = "Done"
            }
        }

        let args = arguments(for: op, input: input, output: output)
        let totalDuration = await Self.duration(of: input)

        return await withCheckedContinuation { (cont: CheckedContinuation<Result<URL, VideoEditError>, Never>) in
            let p = Process()
            p.executableURL = ff
            p.arguments = args + ["-y", "-progress", "pipe:1"]
            let outPipe = Pipe(); let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe

            // Progress comes on stdout when -progress pipe:1 is set.
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                guard let self else { return }
                let d = h.availableData
                guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
                for line in s.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("out_time_ms="),
                       let micro = Double(trimmed.dropFirst("out_time_ms=".count)) {
                        let seconds = micro / 1_000_000.0
                        let frac = totalDuration > 0 ? min(1, seconds / totalDuration) : 0
                        Task { @MainActor in self.progress = frac }
                    }
                }
            }

            // Collect stderr for error reporting (ffmpeg uses stderr by default).
            // Lock-protected mutable box so background-thread readabilityHandler
            // and terminationHandler can share without a data race.
            let errBox = LockedBox<Data>(Data())
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { errBox.mutate { $0.append(d) } }
            }

            p.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: output.path) {
                    cont.resume(returning: .success(output))
                } else {
                    let stderr = String(data: errBox.read(), encoding: .utf8) ?? ""
                    let tail = String(stderr.suffix(1200))
                    cont.resume(returning: .failure(VideoEditError("ffmpeg exit \(proc.terminationStatus):\n\(tail)")))
                }
            }
            do { try p.run() }
            catch {
                cont.resume(returning: .failure(VideoEditError("Failed to launch ffmpeg: \(error.localizedDescription)")))
            }
        }
    }

    // MARK: - Argument builder

    private func arguments(for op: VideoEditOp, input: URL, output: URL) -> [String] {
        switch op {
        case .trim(let s, let e):
            return ["-ss", String(s), "-to", String(e), "-i", input.path, "-c", "copy", output.path]
        case .crop(let x, let y, let w, let h):
            return ["-i", input.path, "-vf", "crop=\(w):\(h):\(x):\(y)", "-c:a", "copy", output.path]
        case .scale(let w, let h):
            return ["-i", input.path, "-vf", "scale=\(w):\(h)", "-c:a", "copy", output.path]
        case .speed(let f):
            // Video: setpts; Audio: atempo (only 0.5–2.0, so chain for extremes)
            let vpts = String(format: "%.3f", 1.0 / f)
            let atempo = clampAtempoChain(factor: f)
            return ["-i", input.path,
                    "-filter_complex", "[0:v]setpts=\(vpts)*PTS[v];[0:a]\(atempo)[a]",
                    "-map", "[v]", "-map", "[a]", output.path]
        case .rotate(let deg):
            let f: String
            switch deg % 360 {
            case 90:  f = "transpose=1"
            case 180: f = "transpose=2,transpose=2"
            case 270: f = "transpose=2"
            default:  f = "null"
            }
            return ["-i", input.path, "-vf", f, "-c:a", "copy", output.path]
        case .flipHorizontal:
            return ["-i", input.path, "-vf", "hflip", "-c:a", "copy", output.path]
        case .flipVertical:
            return ["-i", input.path, "-vf", "vflip", "-c:a", "copy", output.path]
        case .grayscale:
            return ["-i", input.path, "-vf", "format=gray", "-c:a", "copy", output.path]
        case .colorAdjust(let b, let c, let s):
            return ["-i", input.path,
                    "-vf", "eq=brightness=\(b):contrast=\(c):saturation=\(s)",
                    "-c:a", "copy", output.path]
        case .lut(let url):
            return ["-i", input.path, "-vf", "lut3d=\(url.path)", "-c:a", "copy", output.path]
        case .burnSubtitles(let url, let size):
            let escaped = url.path.replacingOccurrences(of: ":", with: "\\:")
            return ["-i", input.path,
                    "-vf", "subtitles=\(escaped):force_style='Fontsize=\(size)'",
                    "-c:a", "copy", output.path]
        case .fps(let n):
            return ["-i", input.path, "-r", String(n), "-c:a", "copy", output.path]
        case .mute:
            return ["-i", input.path, "-c:v", "copy", "-an", output.path]
        case .replaceAudio(let audio):
            return ["-i", input.path, "-i", audio.path,
                    "-c:v", "copy", "-c:a", "aac",
                    "-map", "0:v:0", "-map", "1:a:0", "-shortest", output.path]
        case .extractFrames(let fps, let dir):
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pattern = dir.appendingPathComponent("frame_%04d.png").path
            return ["-i", input.path, "-vf", "fps=\(fps)", pattern]
        case .framesToVideo(let pattern, let fps):
            return ["-framerate", String(fps), "-i", pattern,
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", output.path]
        case .toGIF(let fps, let width):
            let filter = "fps=\(fps),scale=\(width):-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse"
            return ["-i", input.path, "-vf", filter, output.path]
        case .interpolate(let targetFps):
            return ["-i", input.path,
                    "-vf", "minterpolate=fps=\(targetFps):mi_mode=mci:mc_mode=aobmc:vsbmf=1",
                    "-c:a", "copy", output.path]
        }
    }

    private func opLabel(_ op: VideoEditOp) -> String {
        switch op {
        case .trim:           return "Trim"
        case .crop:           return "Crop"
        case .scale:          return "Scale"
        case .speed:          return "Speed change"
        case .rotate:         return "Rotate"
        case .flipHorizontal: return "Flip horizontal"
        case .flipVertical:   return "Flip vertical"
        case .grayscale:      return "Grayscale"
        case .colorAdjust:    return "Color adjust"
        case .lut:            return "LUT 3D"
        case .burnSubtitles:  return "Burn subtitles"
        case .fps:            return "Change FPS"
        case .mute:           return "Mute"
        case .replaceAudio:   return "Replace audio"
        case .extractFrames:  return "Extract frames"
        case .framesToVideo:  return "Frames → Video"
        case .toGIF:          return "Export GIF"
        case .interpolate:    return "Interpolate frames"
        }
    }

    /// ffmpeg's `atempo` filter only accepts 0.5–2.0; chain it for wider ranges.
    private func clampAtempoChain(factor: Double) -> String {
        var f = factor
        var pieces: [String] = []
        while f > 2.0 {
            pieces.append("atempo=2.0"); f /= 2.0
        }
        while f < 0.5 {
            pieces.append("atempo=0.5"); f *= 2.0
        }
        pieces.append("atempo=\(f)")
        return pieces.joined(separator: ",")
    }

    /// Probe a media file's duration. Best-effort; returns 0 on failure.
    static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        if #available(macOS 13.0, *) {
            do {
                let d = try await asset.load(.duration)
                return CMTimeGetSeconds(d)
            } catch { return 0 }
        }
        return CMTimeGetSeconds(asset.duration)
    }
}
