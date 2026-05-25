import Foundation
import SwiftUI

// MARK: - Keys

enum HFKeys {
    static let token         = "hf.token"            // stored in UserDefaults; for real use prefer Keychain
    static let downloadsRoot = "hf.downloadsRoot"
    static let lastFilters   = "hf.lastFilters"
}

// MARK: - Domain

enum HFTask: String, CaseIterable, Identifiable, Codable {
    case any              = "any"
    case textToImage      = "text-to-image"
    case imageToImage     = "image-to-image"
    case imageToVideo     = "image-to-video"
    case textToVideo      = "text-to-video"
    case textToSpeech     = "text-to-speech"
    case automaticSpeechRecognition = "automatic-speech-recognition"
    case textGeneration   = "text-generation"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .any:                       return "Any"
        case .textToImage:               return "Text → Image"
        case .imageToImage:              return "Image → Image (edit/inpaint)"
        case .imageToVideo:              return "Image → Video"
        case .textToVideo:               return "Text → Video"
        case .textToSpeech:              return "Text → Speech"
        case .automaticSpeechRecognition:return "Speech → Text"
        case .textGeneration:            return "Text Generation (LLM)"
        }
    }

    var sfSymbol: String {
        switch self {
        case .any:                       return "square.grid.2x2"
        case .textToImage:               return "photo.on.rectangle.angled"
        case .imageToImage:              return "wand.and.rays"
        case .imageToVideo:              return "play.rectangle.fill"
        case .textToVideo:               return "film"
        case .textToSpeech:              return "speaker.wave.2.fill"
        case .automaticSpeechRecognition:return "waveform"
        case .textGeneration:            return "text.bubble"
        }
    }
}

enum HFFormat: String, CaseIterable, Identifiable, Codable {
    case any         = "any"
    case gguf        = "gguf"
    case safetensors = "safetensors"
    case diffusers   = "diffusers"
    case ggml        = "ggml"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .any:         return "Any format"
        case .gguf:        return "GGUF"
        case .safetensors: return "Safetensors"
        case .diffusers:   return "Diffusers"
        case .ggml:        return "GGML"
        }
    }
}

enum HFSort: String, CaseIterable, Identifiable, Codable {
    case trending     = "trendingScore"
    case downloads    = "downloads"
    case likes        = "likes"
    case recent       = "lastModified"
    case created      = "createdAt"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .trending:  return "Trending"
        case .downloads: return "Most Downloaded"
        case .likes:     return "Most Liked"
        case .recent:    return "Recently Updated"
        case .created:   return "Recently Created"
        }
    }
}

struct HFFilters: Codable, Hashable {
    var query: String = ""
    var task: HFTask = .textToImage
    var format: HFFormat = .gguf
    var sort: HFSort = .trending
    var author: String = ""
}

/// A model card returned from the search/list endpoints.
struct HFModel: Identifiable, Hashable, Codable {
    let id: String                   // == modelId, e.g. "city96/FLUX.1-dev-gguf"
    let author: String
    let pipelineTag: String?
    let libraryName: String?
    let downloads: Int
    let likes: Int
    let lastModified: String?
    let tags: [String]
    let gated: Bool
    let isPrivate: Bool

    var displayAuthor: String { author }
    var displayName: String {
        let p = id.split(separator: "/").map(String.init)
        return p.last ?? id
    }
    var urlOnHub: URL {
        // `id` is server-controlled; percent-encode and fall back to the homepage
        // if it ever contains something we can't render in a URL.
        let allowed = CharacterSet.urlPathAllowed
        let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
        return URL(string: "https://huggingface.co/\(encoded)")
            ?? URL(string: "https://huggingface.co/")!
    }
}

/// A single file inside a repo's tree.
struct HFFile: Identifiable, Hashable, Codable {
    let path: String
    let size: Int64
    let oid: String?
    let lfsSize: Int64?

    var id: String { path }
    var displayName: String { (path as NSString).lastPathComponent }
    var ext: String { ((path as NSString).pathExtension).lowercased() }
    var humanSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    var isGGUF: Bool { ext == "gguf" }
    var isMmproj: Bool { displayName.lowercased().hasPrefix("mmproj") }
}

/// Detailed model record (siblings + cardData).
struct HFModelDetail: Hashable {
    let model: HFModel
    let cardSummary: String?
    let files: [HFFile]
    let totalBytes: Int64
}

// MARK: - Client

/// REST client for the HuggingFace Hub. No third-party SDK, just URLSession.
actor HuggingFaceClient {
    static let shared = HuggingFaceClient()
    private let base = URL(string: "https://huggingface.co")!
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 30
        cfg.timeoutIntervalForResource = 6 * 3600  // big GGUFs may take hours
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: cfg)
    }()

    func token() -> String? {
        // Migrated from UserDefaults to Keychain in 3.0.3. KeychainStore
        // does the one-shot legacy migration the first time it's read.
        KeychainStore.huggingFaceToken()
    }

    private func authorize(_ req: inout URLRequest) {
        if let t = token() {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("Mllama/2.3 (+https://mllama.local)", forHTTPHeaderField: "User-Agent")
    }

    // MARK: Search

    /// Search the Hub. Returns up to `limit` models matching the filters.
    /// We pull `full=true` so we get tags + siblings without a follow-up call.
    func search(filters f: HFFilters, limit: Int = 60) async throws -> [HFModel] {
        var comps = URLComponents(url: base.appendingPathComponent("api/models"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "limit", value: String(limit)),
            .init(name: "sort",  value: f.sort.rawValue),
            .init(name: "full",  value: "true"),
        ]
        if !f.query.isEmpty   { items.append(.init(name: "search", value: f.query)) }
        if !f.author.isEmpty  { items.append(.init(name: "author", value: f.author)) }
        if f.task   != .any   { items.append(.init(name: "pipeline_tag", value: f.task.rawValue)) }
        if f.format != .any   { items.append(.init(name: "filter", value: f.format.rawValue)) }
        comps.queryItems = items

        var req = URLRequest(url: comps.url!)
        authorize(&req)

        let (data, response) = try await session.data(for: req)
        try Self.throwIfNonOK(response, body: data)
        let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return raw.map(Self.mapModel)
    }

    /// Fetch full model card + sibling file list with sizes (via tree API).
    func detail(repoId: String) async throws -> HFModelDetail {
        async let modelTask: HFModel = fetchModelMeta(repoId: repoId)
        async let filesTask: [HFFile] = listTree(repoId: repoId)
        let (model, files) = try await (modelTask, filesTask)
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        return HFModelDetail(model: model, cardSummary: nil, files: files, totalBytes: total)
    }

    private func fetchModelMeta(repoId: String) async throws -> HFModel {
        let url = base.appendingPathComponent("api/models/\(repoId)")
        var req = URLRequest(url: url)
        authorize(&req)
        let (data, response) = try await session.data(for: req)
        try Self.throwIfNonOK(response, body: data)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return Self.mapModel(obj)
    }

    /// List all files in the default branch using the tree API (gives us sizes).
    func listTree(repoId: String, revision: String = "main") async throws -> [HFFile] {
        var comps = URLComponents(url: base.appendingPathComponent("api/models/\(repoId)/tree/\(revision)"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "recursive", value: "true")]
        var req = URLRequest(url: comps.url!)
        authorize(&req)
        let (data, response) = try await session.data(for: req)
        try Self.throwIfNonOK(response, body: data)
        let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        var out: [HFFile] = []
        for entry in arr {
            guard (entry["type"] as? String) == "file",
                  let path = entry["path"] as? String else { continue }
            let size = (entry["size"] as? Int64) ?? Int64(entry["size"] as? Int ?? 0)
            let oid  = entry["oid"] as? String
            var lfsSize: Int64? = nil
            if let lfs = entry["lfs"] as? [String: Any] {
                lfsSize = (lfs["size"] as? Int64) ?? Int64(lfs["size"] as? Int ?? 0)
            }
            out.append(HFFile(path: path, size: size, oid: oid, lfsSize: lfsSize))
        }
        return out
    }

    /// HEAD a resolver URL to learn final size (after LFS redirect) without downloading.
    func headFileSize(repoId: String, file: String, revision: String = "main") async throws -> Int64 {
        let url = base.appendingPathComponent("\(repoId)/resolve/\(revision)/\(file)")
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        authorize(&req)
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { return -1 }
        if let len = http.value(forHTTPHeaderField: "Content-Length"), let n = Int64(len) { return n }
        return -1
    }

    /// Convenience: build a /resolve URL for a file.
    static func resolveURL(repoId: String, file: String, revision: String = "main") -> URL {
        URL(string: "https://huggingface.co/\(repoId)/resolve/\(revision)/\(file)")!
    }

    // MARK: - Helpers

    private static func throwIfNonOK(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if !(200..<300).contains(http.statusCode) {
            let text = String(data: body, encoding: .utf8)?.prefix(400) ?? "<binary>"
            throw NSError(domain: "HuggingFace", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(text)"])
        }
    }

    private static func mapModel(_ obj: [String: Any]) -> HFModel {
        let id = (obj["modelId"] as? String) ?? (obj["id"] as? String) ?? "unknown"
        let author = (obj["author"] as? String) ?? id.split(separator: "/").first.map(String.init) ?? ""
        let pipe = obj["pipeline_tag"] as? String
        let lib  = obj["library_name"] as? String
        let dl   = (obj["downloads"] as? Int) ?? 0
        let li   = (obj["likes"] as? Int) ?? 0
        let lm   = obj["lastModified"] as? String
        let tags = (obj["tags"] as? [String]) ?? []
        let gated = (obj["gated"] as? Bool) ?? ((obj["gated"] as? String) != nil)
        let priv  = (obj["private"] as? Bool) ?? false
        return HFModel(
            id: id, author: author, pipelineTag: pipe, libraryName: lib,
            downloads: dl, likes: li, lastModified: lm, tags: tags,
            gated: gated, isPrivate: priv
        )
    }
}

// MARK: - Curated picks

/// Hand-picked, known-good GGUF repos for first-time users so the browser
/// doesn't open empty. These are real, popular repos.
enum HFCurated {
    static let imageGen: [(id: String, label: String, blurb: String)] = [
        ("city96/FLUX.1-dev-gguf",         "FLUX.1 dev (GGUF)",   "Black Forest Labs' Flux dev model, GGUF-quantized. Excellent quality."),
        ("city96/FLUX.1-schnell-gguf",     "FLUX.1 schnell",      "4-step distillation. Fast generation."),
        ("QuantStack/FLUX.1-Kontext-dev-GGUF", "FLUX Kontext",    "FLUX for instruction-based image editing."),
        ("YarvixPA/FLUX.1-Fill-dev-GGUF",  "FLUX Fill (inpaint)", "Inpainting / outpainting variant of FLUX."),
        ("second-state/stable-diffusion-3.5-large-GGUF", "SD 3.5 Large", "Stability's SD3.5 in GGUF format."),
        ("gpustack/stable-diffusion-xl-base-1.0-GGUF", "SDXL base 1.0", "Classic SDXL, GGUF-quantized."),
        ("OlegSkutte/sdxl-turbo-GGUF",     "SDXL Turbo",          "1-2 step distillation of SDXL."),
    ]
    static let videoGen: [(id: String, label: String, blurb: String)] = [
        ("stabilityai/stable-video-diffusion-img2vid-xt", "SVD img2vid-xt", "Stable Video Diffusion: animate a still image into a short clip."),
        ("ali-vilab/text-to-video-ms-1.7b",  "ModelScope T2V",  "Open text-to-video. Lower quality, runs broadly."),
        ("genmo/mochi-1-preview",            "Mochi-1 (preview)", "High-quality T2V; large model."),
    ]
    static let llm: [(id: String, label: String, blurb: String)] = [
        ("unsloth/Llama-3.2-3B-Instruct-GGUF", "Llama 3.2 3B",   "Small, fast Llama for tool use."),
        ("bartowski/Qwen2.5-7B-Instruct-GGUF", "Qwen 2.5 7B",    "Strong general-purpose model."),
        ("bartowski/Llama-3.1-8B-Instruct-GGUF", "Llama 3.1 8B", "Solid mid-size workhorse."),
    ]
}
