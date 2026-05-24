import Foundation
import SwiftUI

// MARK: - Unified model record

enum ModelOrigin: String, Hashable {
    case localDisk          // user's home / ~/models
    case lmStudio
    case ollama
    case downloaded         // pulled from HF into ~/.mllama/hf
    case curated            // catalog entry, not yet downloaded

    var label: String {
        switch self {
        case .localDisk:  return "Local"
        case .lmStudio:   return "LM Studio"
        case .ollama:     return "Ollama"
        case .downloaded: return "Downloaded"
        case .curated:    return "Catalog"
        }
    }
    var sfSymbol: String {
        switch self {
        case .localDisk:  return "folder"
        case .lmStudio:   return "macwindow"
        case .ollama:     return "shippingbox"
        case .downloaded: return "arrow.down.circle.fill"
        case .curated:    return "sparkles"
        }
    }
}

enum ModelCompatibility: Hashable {
    case unknown            // can't tell from filename alone
    case fits               // comfortably runs on this Mac
    case tight              // technically possible but slow / will swap
    case tooBig             // won't fit
    case downloading        // download in progress

    var color: Color {
        switch self {
        case .fits:        return Theme.mint
        case .tight:       return Theme.amber
        case .tooBig:      return Theme.coral
        case .downloading: return Theme.cyan
        case .unknown:     return Theme.textFaint
        }
    }
    var label: String {
        switch self {
        case .fits:        return "Fits"
        case .tight:       return "Tight"
        case .tooBig:      return "Won't fit"
        case .downloading: return "Downloading"
        case .unknown:     return "—"
        }
    }
}

struct UnifiedModel: Identifiable, Hashable {
    let id: String                  // stable id for diffing
    let displayName: String
    let kind: RecommendKind
    let origin: ModelOrigin
    let sizeBytes: Int64
    let path: String?               // local file path, nil if not downloaded
    let repoId: String?
    let filename: String?           // file path inside repo
    let quantization: String?
    let runtimeRamGB: Double?
    let tags: [String]
    let isActive: Bool              // currently loaded in its engine
    let isVisionCapable: Bool
    /// Companion file alongside the main model (e.g. mmproj for LLM vision).
    let companionPath: String?

    var humanSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
    var humanRAM: String {
        guard let r = runtimeRamGB else { return "" }
        return String(format: "~%.0f GB RAM", r)
    }

    /// Hosting repo author (if available) for display.
    var displayAuthor: String? {
        repoId?.split(separator: "/").first.map(String.init)
    }
}

// MARK: - Catalog

@MainActor
final class UnifiedModelCatalog: ObservableObject {
    @Published private(set) var models: [UnifiedModel] = []
    @Published private(set) var lastRebuiltAt: Date?
    @Published var lastError: String?

    private unowned let library: ModelLibrary
    private unowned let downloads: HFDownloadManager
    private unowned let server: ServerController
    private unowned let sdServer: SDServerController
    private unowned let monitor: ResourceMonitor
    /// Closure that returns `true` if the image generator is currently mid-flight.
    /// Set by `App.bootstrap()` so the auto-restart-on-companion-arrival path
    /// can defer the restart instead of yanking sd-server out from under a
    /// running request. Defaults to `{ false }` so unit tests / preview don't
    /// have to wire it.
    var isImageGeneratorBusy: () -> Bool = { false }
    /// True when we noticed companions changed mid-generation and held off
    /// the restart. Next opportunity (e.g., next rebuild while idle) we
    /// apply it.
    private var pendingSdRestart: Bool = false

    init(library: ModelLibrary, downloads: HFDownloadManager,
         server: ServerController, sdServer: SDServerController,
         monitor: ResourceMonitor) {
        self.library = library
        self.downloads = downloads
        self.server = server
        self.sdServer = sdServer
        self.monitor = monitor
    }

    // MARK: Aggregation

    func rebuild() {
        var out: [UnifiedModel] = []
        let fm = FileManager.default

        let activeLLM   = server.modelPath
        let activeImage = UserDefaults.standard.string(forKey: SDKeys.imageModelPath)
        let activeVideo = UserDefaults.standard.string(forKey: SDKeys.videoModelPath)

        // 1. LLMs discovered from LM Studio / Ollama / local dirs
        for m in library.models {
            out.append(UnifiedModel(
                id: "local:llm:\(m.path)",
                displayName: m.displayName,
                kind: .llm,
                origin: originFromSource(m.source),
                sizeBytes: m.sizeBytes,
                path: m.path,
                repoId: nil,
                filename: nil,
                quantization: m.quantization,
                runtimeRamGB: nil,
                tags: m.isVision ? ["vision"] : [],
                isActive: m.path == activeLLM,
                isVisionCapable: m.isVision,
                companionPath: m.mmprojPath
            ))
        }

        // 2. Anything downloaded to the HF cache that isn't already shown.
        let cacheRoot = downloads.rootDirectory
        if fm.fileExists(atPath: cacheRoot.path),
           let enumerator = fm.enumerator(at: cacheRoot,
                                          includingPropertiesForKeys: [.fileSizeKey],
                                          options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let path = url.path
                let ext = url.pathExtension.lowercased()
                guard ext == "gguf" || ext == "safetensors" else { continue }
                // Don't double-count if ModelLibrary already saw it.
                if out.contains(where: { $0.path == path }) { continue }
                let kind = Self.guessKind(path: path)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
                let active = (kind == .llm && path == activeLLM)
                          || (kind == .image && path == activeImage)
                          || (kind == .video && path == activeVideo)
                let (repo, fileInRepo) = Self.repoMetadata(from: url, under: cacheRoot)
                out.append(UnifiedModel(
                    id: "downloaded:\(path)",
                    displayName: Self.prettyName(from: url),
                    kind: kind,
                    origin: .downloaded,
                    sizeBytes: size,
                    path: path,
                    repoId: repo,
                    filename: fileInRepo,
                    quantization: Self.extractQuant(url.lastPathComponent),
                    runtimeRamGB: catalogRamFor(repo: repo, file: fileInRepo),
                    tags: tagsFromFilename(url.lastPathComponent),
                    isActive: active,
                    isVisionCapable: false,
                    companionPath: nil
                ))
            }
        }

        // 3. Catalog entries that aren't downloaded yet.
        for rec in ModelRecommender.catalog {
            let dest = downloads.destination(repoId: rec.repoId, file: rec.filename)
            if fm.fileExists(atPath: dest.path) { continue }
            out.append(UnifiedModel(
                id: "curated:\(rec.id)",
                displayName: rec.label,
                kind: rec.kind,
                origin: .curated,
                sizeBytes: Int64(rec.approxDownloadGB * 1_073_741_824),
                path: nil,
                repoId: rec.repoId,
                filename: rec.filename,
                quantization: nil,
                runtimeRamGB: rec.runtimeRamGB,
                tags: rec.tags,
                isActive: false,
                isVisionCapable: false,
                companionPath: nil
            ))
        }

        // Sort: active first, then downloaded, then curated. Within each,
        // by kind then size.
        out.sort { a, b in
            if a.isActive != b.isActive { return a.isActive }
            let aHasFile = a.path != nil
            let bHasFile = b.path != nil
            if aHasFile != bHasFile { return aHasFile }
            if a.kind != b.kind {
                return a.kind.rawValue < b.kind.rawValue
            }
            return a.sizeBytes < b.sizeBytes
        }

        self.models = out
        self.lastRebuiltAt = Date()

        // Opportunistic re-link: when companion downloads complete, the
        // catalog rebuild fires and we can auto-fill any companion paths
        // that weren't set yet.
        relinkActiveCompanionsIfNeeded()
    }

    /// If the active image / video model still has unsatisfied companions,
    /// scan the cache off-actor and fill in any paths that exist now. The
    /// filesystem walk in `CompanionResolver.scanCache` can be slow on a
    /// large HF cache, so we never run it on the main actor.
    private func relinkActiveCompanionsIfNeeded() {
        let defaults = UserDefaults.standard
        let img = defaults.string(forKey: SDKeys.imageModelPath) ?? ""
        let vid = defaults.string(forKey: SDKeys.videoModelPath) ?? ""
        guard !img.isEmpty || !vid.isEmpty else { return }
        let root = downloads.rootDirectory
        Task.detached(priority: .utility) { [weak self] in
            let imgFound = img.isEmpty
                ? []
                : CompanionResolver.scanOffActor(forDiffusion: img, downloadsRoot: root)
            let vidFound = vid.isEmpty
                ? []
                : CompanionResolver.scanOffActor(forDiffusion: vid, downloadsRoot: root)
            // Hop back to the main actor to apply. Capture `self` weakly
            // again so we don't extend its lifetime if the user closes the
            // app while the scan is in flight.
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applyRelink(found: imgFound, isVideo: false)
                self.applyRelink(found: vidFound, isVideo: true)
            }
        }
    }

    private func applyRelink(found: [CompanionStatus], isVideo: Bool) {
        var changedImageCompanion = false
        for s in found {
            guard let path = s.localPath else { continue }
            let key: String
            switch s.role {
            case .t5:    key = isVideo ? SDKeys.videoT5Path : SDKeys.t5Path
            case .clipL: key = SDKeys.clipLPath
            case .clipG: key = SDKeys.clipGPath
            case .vae:   key = isVideo ? SDKeys.videoVaePath : SDKeys.vaePath
            }
            let current = UserDefaults.standard.string(forKey: key) ?? ""
            if current != path {
                UserDefaults.standard.set(path, forKey: key)
                if !isVideo { changedImageCompanion = true }
            }
        }
        // sd-server only reads companion paths at startup. If we just
        // discovered new image-side companion files while it's running with
        // stale paths, restart so they actually load. Otherwise FLUX/SD3
        // generations would still fail with "missing encoder" errors.
        if changedImageCompanion && sdServer.status == .running {
            if isImageGeneratorBusy() {
                // Don't yank the server out from under an in-flight request.
                // Apply on the next idle rebuild tick.
                pendingSdRestart = true
            } else {
                sdServer.restart()
            }
        } else if pendingSdRestart && !isImageGeneratorBusy() && sdServer.status == .running {
            // Catch-up: previous tick set a pending restart while busy.
            pendingSdRestart = false
            sdServer.restart()
        }
    }

    // MARK: Compatibility per-system

    func compatibility(of model: UnifiedModel) -> ModelCompatibility {
        if let path = model.path,
           downloads.jobs.contains(where: {
               $0.destination.path == path && $0.state == .running
           }) {
            return .downloading
        }
        guard let needed = model.runtimeRamGB else { return .unknown }
        let totalRam = monitor.hardware.totalRamGB
        if needed > totalRam - 2  { return .tooBig }
        if needed > totalRam * 0.7 { return .tight }
        return .fits
    }

    // MARK: Filtering

    func filtered(query: String, kind: RecommendKind?) -> [UnifiedModel] {
        var out = models
        if let k = kind { out = out.filter { $0.kind == k } }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return out }
        // Tokenize the query — every token must match somewhere.
        let tokens = q.split(separator: " ").map(String.init)
        return out.filter { m in
            let haystack = [
                m.displayName,
                m.repoId ?? "",
                m.filename ?? "",
                m.path ?? "",
                m.quantization ?? "",
                m.origin.label,
                m.kind.label,
                m.tags.joined(separator: " ")
            ].joined(separator: " ").lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    // MARK: Activation

    /// Activate the given model on its engine. For curated (not-downloaded)
    /// models, queues a download. For diffusion families that require
    /// separate text encoders / VAE (FLUX, SD 3.5, Wan 2.1, LTX), any
    /// already-cached companion files are auto-linked into the SD defaults,
    /// and missing companions are surfaced via `pendingCompanionsForActive`
    /// so the UI can offer "Get missing files" without a separate action.
    @discardableResult
    func activate(_ model: UnifiedModel) -> String {
        switch model.origin {
        case .curated:
            guard let repo = model.repoId, let file = model.filename else {
                lastError = "Curated model is missing repo info"
                return "Could not start download — missing repo info."
            }
            downloads.enqueue(repoId: repo, file: file)
            // If this is a diffusion model that needs companions, queue them
            // up front so the user doesn't end up with a half-installed model.
            let queuedCompanions = enqueueMissingCompanions(diffusionPath: nil,
                                                            family: DiffusionFamily.detect(path: file))
            if queuedCompanions > 0 {
                return "Download queued: \(model.displayName) + \(queuedCompanions) required companion file\(queuedCompanions == 1 ? "" : "s")."
            }
            return "Download queued. Open Models tab to monitor progress."
        case .localDisk, .lmStudio, .ollama, .downloaded:
            guard let path = model.path else {
                return "Model has no local file."
            }
            switch model.kind {
            case .llm:
                server.activate(modelPath: path, mmprojPath: model.companionPath)
                return "Switching LLM to \(model.displayName) — restarting llama-server…"
            case .image:
                UserDefaults.standard.set(path, forKey: SDKeys.imageModelPath)
                let res = autoLinkCompanions(for: path, isVideo: false)
                sdServer.restart()
                return res.summary(modelName: model.displayName, engine: "sd-server")
            case .video:
                UserDefaults.standard.set(path, forKey: SDKeys.videoModelPath)
                let res = autoLinkCompanions(for: path, isVideo: true)
                return res.summary(modelName: model.displayName, engine: "video gen")
            }
        }
    }

    // MARK: Companion handling

    /// Result of trying to wire up companion files for a diffusion model.
    struct CompanionLinkResult {
        let family: DiffusionFamily
        let linked: [CompanionRole]      // companions we set from cache
        let missing: [CompanionRequirement]
        let queuedDownloads: Int          // companions we kicked off for download

        func summary(modelName: String, engine: String) -> String {
            switch family {
            case .unknown, .sdxl, .sd15:
                return "Activated \(modelName) — \(engine) ready."
            default: break
            }
            var bits: [String] = ["Activated \(modelName) (\(family.label))"]
            if !linked.isEmpty {
                bits.append("auto-linked \(linked.count) companion file\(linked.count == 1 ? "" : "s")")
            }
            if queuedDownloads > 0 {
                bits.append("queued \(queuedDownloads) missing companion download\(queuedDownloads == 1 ? "" : "s")")
            }
            if !missing.isEmpty && queuedDownloads == 0 {
                let names = missing.map { $0.label }.joined(separator: ", ")
                bits.append("needs: \(names)")
            }
            return bits.joined(separator: " — ") + "."
        }
    }

    /// Look up companions on disk and write paths into the corresponding
    /// UserDefaults keys. Returns which roles were satisfied and which are
    /// still missing.
    @discardableResult
    func autoLinkCompanions(for diffusionPath: String, isVideo: Bool) -> CompanionLinkResult {
        let family = DiffusionFamily.detect(path: diffusionPath)
        let reqs = ModelBundle.requiredCompanions(for: family)
        guard !reqs.isEmpty else {
            return CompanionLinkResult(family: family, linked: [], missing: [], queuedDownloads: 0)
        }
        let statuses = CompanionResolver.status(forDiffusion: diffusionPath,
                                                 downloadsRoot: downloads.rootDirectory)
        var linked: [CompanionRole] = []
        var missing: [CompanionRequirement] = []
        for status in statuses {
            // For video families, write to videoT5/videoVae; for image
            // families write to the image-side keys.
            if let path = status.localPath {
                writeCompanionPath(role: status.role, path: path, isVideo: isVideo)
                linked.append(status.role)
            } else {
                let req = reqs.first { $0.role == status.role }!
                missing.append(req)
            }
        }
        let queued = enqueueMissingCompanions(diffusionPath: diffusionPath, family: family)
        return CompanionLinkResult(family: family, linked: linked, missing: missing, queuedDownloads: queued)
    }

    /// Enqueue downloads for any companion files that aren't already on disk.
    /// Returns the number of new download jobs started.
    @discardableResult
    func enqueueMissingCompanions(diffusionPath: String?, family: DiffusionFamily) -> Int {
        let reqs = ModelBundle.requiredCompanions(for: family)
        guard !reqs.isEmpty else { return 0 }
        let fm = FileManager.default
        var queued = 0
        for req in reqs {
            guard let rec = ModelBundle.catalogEntry(for: req) else { continue }
            let dest = downloads.destination(repoId: rec.repoId, file: rec.filename)
            if fm.fileExists(atPath: dest.path) { continue }
            // If the path is already a known user setting, skip too.
            if let diffusionPath {
                let statuses = CompanionResolver.status(forDiffusion: diffusionPath,
                                                         downloadsRoot: downloads.rootDirectory)
                if statuses.first(where: { $0.role == req.role })?.localPath != nil { continue }
            }
            // Avoid duplicating an in-flight job.
            let alreadyQueued = downloads.jobs.contains {
                $0.repoId == rec.repoId && $0.file == rec.filename && !$0.state.isTerminal
            }
            if alreadyQueued { continue }
            downloads.enqueue(repoId: rec.repoId, file: rec.filename)
            queued += 1
        }
        return queued
    }

    private func writeCompanionPath(role: CompanionRole, path: String, isVideo: Bool) {
        let key: String
        switch role {
        case .t5:    key = isVideo ? SDKeys.videoT5Path : SDKeys.t5Path
        case .clipL: key = SDKeys.clipLPath
        case .clipG: key = SDKeys.clipGPath
        case .vae:   key = isVideo ? SDKeys.videoVaePath : SDKeys.vaePath
        }
        UserDefaults.standard.set(path, forKey: key)
    }

    /// Public view of companion state for the currently active image or video model.
    func companionStatus(for kind: RecommendKind) -> [CompanionStatus] {
        let key: String
        switch kind {
        case .image: key = SDKeys.imageModelPath
        case .video: key = SDKeys.videoModelPath
        case .llm:   return []
        }
        guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty else { return [] }
        return CompanionResolver.status(forDiffusion: path,
                                         downloadsRoot: downloads.rootDirectory)
    }

    // MARK: Helpers

    static func guessKind(path: String) -> RecommendKind {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.contains("wan2") || name.contains("ltx") || name.contains("svd")
           || name.contains("mochi") || name.contains("hunyuan-video")
           || name.contains("animatediff") {
            return .video
        }
        if name.contains("flux") || name.contains("sdxl") || name.contains("sd3")
           || name.contains("stable-diffusion") || name.contains("sd_xl_turbo")
           || name.contains("controlnet") || name.contains("pixart")
           || name.contains("chroma") || name.contains("qwen-image")
           || name.contains("hidream") {
            return .image
        }
        return .llm
    }

    static func prettyName(from url: URL) -> String {
        // e.g. ~/.mllama/hf/city96/FLUX.1-dev-gguf/flux1-dev-Q4_K_S.gguf
        //   → "FLUX.1-dev-gguf · flux1-dev-Q4_K_S"
        let base = url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent().lastPathComponent
        if !parent.isEmpty && parent != "." {
            return "\(parent) · \(base)"
        }
        return base
    }

    /// For files under the HF cache root, recover "<author>/<repo>" and the
    /// relative file path within the repo.
    static func repoMetadata(from url: URL, under root: URL) -> (repoId: String?, filename: String?) {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let p = url.path
        guard p.hasPrefix(rootPath) else { return (nil, nil) }
        let rel = String(p.dropFirst(rootPath.count))
        let parts = rel.split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return (nil, nil) }
        let repo = "\(parts[0])/\(parts[1])"
        let file = parts.dropFirst(2).joined(separator: "/")
        return (repo, file)
    }

    static func extractQuant(_ name: String) -> String? {
        let upper = name.uppercased()
        let patterns = [
            #"\b(IQ\d[A-Z_]*)\b"#,
            #"\b(Q\d+(?:_[KMSL0-9]+)*)\b"#,
            #"\b(F16|BF16|F32|FP16|FP32)\b"#,
        ]
        for p in patterns {
            if let r = upper.range(of: p, options: .regularExpression) {
                return String(upper[r])
            }
        }
        return nil
    }

    private func tagsFromFilename(_ name: String) -> [String] {
        let n = name.lowercased()
        var out: [String] = []
        if n.contains("instruct") { out.append("instruct") }
        if n.contains("chat")     { out.append("chat") }
        if n.contains("turbo") || n.contains("schnell") { out.append("fast") }
        if n.contains("inpaint") || n.contains("fill")  { out.append("inpaint") }
        if n.contains("kontext") || n.contains("edit")  { out.append("edit") }
        return out
    }

    private func catalogRamFor(repo: String?, file: String?) -> Double? {
        guard let repo, let file else { return nil }
        return ModelRecommender.catalog.first(where: {
            $0.repoId == repo && $0.filename == file
        })?.runtimeRamGB
    }

    private func originFromSource(_ s: ModelSource) -> ModelOrigin {
        switch s {
        case .lmStudio: return .lmStudio
        case .ollama:   return .ollama
        case .local:    return .localDisk
        case .custom:   return .localDisk
        }
    }
}
