import Foundation
import SwiftUI
import AVFoundation
import AppKit

// MARK: - Persistence types

enum MediaKind: String, Codable, Hashable, CaseIterable, Identifiable {
    case image, video
    var id: String { rawValue }
    var label: String {
        switch self {
        case .image: return "Images"
        case .video: return "Videos"
        }
    }
}

struct MediaAsset: Identifiable, Hashable, Codable {
    let id: UUID
    let kind: MediaKind
    let url: URL                  // absolute file URL
    let thumbnailURL: URL?
    let prompt: String
    let negativePrompt: String
    let modelName: String
    let createdAt: Date
    let width: Int
    let height: Int
    let elapsedSeconds: Double
    /// Free-form parameter dictionary (steps, sampler, seed, etc.) for inspection/reuse.
    let parameters: [String: String]

    var displayName: String { url.lastPathComponent }
    var sizeBytes: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
    var humanSize: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
}

// MARK: - Library

/// Persists generated images and videos with metadata. On disk: a single JSON
/// index at ~/.mllama/library.json with absolute file URLs.
@MainActor
final class MediaLibrary: ObservableObject {
    static let shared = MediaLibrary()

    @Published private(set) var assets: [MediaAsset] = []
    @Published var filter: MediaKind? = nil
    @Published var searchQuery: String = ""

    private let indexURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".mllama/library.json")
    }()

    init() {
        load()
    }

    var filtered: [MediaAsset] {
        var out = assets
        if let f = filter { out = out.filter { $0.kind == f } }
        if !searchQuery.isEmpty {
            let q = searchQuery.lowercased()
            out = out.filter {
                $0.prompt.lowercased().contains(q)
                || $0.modelName.lowercased().contains(q)
                || $0.displayName.lowercased().contains(q)
            }
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: Recording

    func record(image r: ImageGenResult) {
        let params: [String: String] = [
            "steps": String(r.params.steps),
            "sampler": r.params.sampler.rawValue,
            "scheduler": r.params.scheduler.rawValue,
            "cfg_scale": String(r.params.cfgScale),
            "guidance": String(r.params.guidance),
            "seed": String(r.params.seed),
            "loras": r.params.loraDirectives,
        ]
        let a = MediaAsset(
            id: r.id, kind: .image, url: r.url, thumbnailURL: nil,
            prompt: r.params.prompt, negativePrompt: r.params.negativePrompt,
            modelName: r.modelName, createdAt: r.createdAt,
            width: r.params.width, height: r.params.height,
            elapsedSeconds: r.elapsedSeconds, parameters: params
        )
        assets.insert(a, at: 0)
        save()
    }

    func record(video r: VideoGenResult) {
        let params: [String: String] = [
            "frames": String(r.params.frames),
            "fps": String(r.params.fps),
            "steps": String(r.params.steps),
            "cfg_scale": String(r.params.cfgScale),
            "sampler": r.params.sampler.rawValue,
            "seed": String(r.params.seed),
        ]
        let a = MediaAsset(
            id: r.id, kind: .video, url: r.url, thumbnailURL: r.thumbnailURL,
            prompt: r.params.prompt, negativePrompt: r.params.negativePrompt,
            modelName: r.modelName, createdAt: r.createdAt,
            width: r.params.width, height: r.params.height,
            elapsedSeconds: r.elapsedSeconds, parameters: params
        )
        assets.insert(a, at: 0)
        save()
    }

    /// Record an imported asset (drag-drop, file→library) without parameters.
    func record(imported url: URL, kind: MediaKind) {
        let a = MediaAsset(
            id: UUID(), kind: kind, url: url, thumbnailURL: nil,
            prompt: "", negativePrompt: "", modelName: "imported",
            createdAt: Date(),
            width: 0, height: 0, elapsedSeconds: 0, parameters: [:]
        )
        assets.insert(a, at: 0)
        save()
    }

    func remove(_ asset: MediaAsset, deleteFiles: Bool = false) {
        assets.removeAll { $0.id == asset.id }
        if deleteFiles {
            try? FileManager.default.removeItem(at: asset.url)
            if let t = asset.thumbnailURL { try? FileManager.default.removeItem(at: t) }
        }
        save()
    }

    func clear() {
        assets.removeAll()
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let arr = try? decoder.decode([MediaAsset].self, from: data) {
            // Drop entries whose files have been deleted out from under us.
            self.assets = arr.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(assets) {
            try? data.write(to: indexURL)
        }
    }
}

// MARK: - Video thumbnailer

enum VideoThumbnailer {
    /// Produce a JPEG thumbnail from the first frame of a video file.
    static func makeThumbnail(for url: URL) async -> URL? {
        await withCheckedContinuation { cont in
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 480, height: 480)
            let time = CMTime(seconds: 0.1, preferredTimescale: 600)
            if #available(macOS 13.0, *) {
                gen.generateCGImageAsynchronously(for: time) { cg, _, _ in
                    if let cg {
                        let out = url.deletingPathExtension().appendingPathExtension("thumb.jpg")
                        let rep = NSBitmapImageRep(cgImage: cg)
                        if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                            try? data.write(to: out)
                            cont.resume(returning: out)
                            return
                        }
                    }
                    cont.resume(returning: nil)
                }
            } else {
                cont.resume(returning: nil)
            }
        }
    }
}

// MARK: - Video transcoder

/// sd-cli vid_gen writes animated WEBP / WEBM only — AVPlayer can't decode
/// those. We pipe the result through ffmpeg to produce an H.264 mp4 so the
/// in-app player works without weird "video is missing" surprises.
enum VideoTranscoder {

    /// Transcode `source` to a sibling .mp4 file. Returns the new URL on
    /// success, or `nil` if ffmpeg is unavailable / the conversion fails.
    /// Does NOT delete the source — callers can keep both formats.
    static func toMP4(from source: URL) async -> URL? {
        let ext = source.pathExtension.lowercased()
        if ext == "mp4" || ext == "mov" || ext == "m4v" {
            return source
        }
        let ff: URL? = await MainActor.run { InstallPaths.locate("ffmpeg") }
        guard let ff else { return nil }
        let outURL = source.deletingPathExtension().appendingPathExtension("mp4")
        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            let p = Process()
            p.executableURL = ff
            // -y overwrite, libx264 + yuv420p for max-compat playback.
            // -movflags +faststart lets AVPlayer start before the whole file
            // is loaded. Audio absent — videos from sd-cli are silent.
            p.arguments = [
                "-y", "-i", source.path,
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                "-crf", "18",
                "-preset", "veryfast",
                "-movflags", "+faststart",
                "-an",
                outURL.path,
            ]
            // Route stdio to /dev/null so ffmpeg can never block on a pipe
            // buffer filling up. No `waitUntilExit`, so we never block a
            // cooperative thread either.
            p.standardOutput = FileHandle.nullDevice
            p.standardError  = FileHandle.nullDevice
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0,
                   FileManager.default.fileExists(atPath: outURL.path) {
                    cont.resume(returning: outURL)
                } else {
                    cont.resume(returning: nil)
                }
            }
            do { try p.run() }
            catch { cont.resume(returning: nil) }
        }
    }
}
