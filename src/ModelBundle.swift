import Foundation

// MARK: - Model family

/// Diffusion-model families we recognise from filename. The family decides
/// which companion files (text encoders, VAE) the model needs at runtime
/// because none of these are bundled into the diffusion GGUF.
enum DiffusionFamily: String {
    case flux           // FLUX.1 dev / schnell / Kontext / Fill
    case sd35           // Stable Diffusion 3.5 Large/Medium
    case sdxl           // SDXL (incl. Turbo)
    case sd15           // SD 1.x / 2.x
    case wan21          // Wan 2.1 T2V / I2V
    case ltx            // LTX Video
    case unknown

    static func detect(path: String) -> DiffusionFamily {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.contains("flux") || name.contains("kontext") { return .flux }
        if name.contains("sd3.5") || name.contains("sd_3.5") || name.contains("sd35") { return .sd35 }
        if name.contains("sdxl") || name.contains("sd_xl") || name.contains("xl_turbo") || name.contains("sd-xl") { return .sdxl }
        if name.contains("wan2") || name.contains("wan_2") { return .wan21 }
        if name.contains("ltx") { return .ltx }
        if name.contains("v1-5") || name.contains("v2-1") || name.contains("stable-diffusion-v1")
            || name.contains("sd_1") || name.contains("sd_2") {
            return .sd15
        }
        // Filename didn't help — try to peek inside.
        if let sniffed = sniffFamilyFromFile(path: path) {
            return sniffed
        }
        return .unknown
    }

    /// Last-resort detection: peek at the file's header bytes / safetensors
    /// metadata to guess the family. Bounded read (≤ 4 KB) so it's cheap
    /// enough to call from filename-based detection paths.
    private static func sniffFamilyFromFile(path: String) -> DiffusionFamily? {
        let expanded = (path as NSString).expandingTildeInPath
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: expanded)) else {
            return nil
        }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), head.count > 8 else { return nil }
        // GGUF: bytes 0..4 == "GGUF". Following bytes encode the architecture
        // string somewhere in the key/value table; do a cheap substring scan
        // for known arch names in the first 4 KB. Safetensors: first 8 bytes
        // are little-endian uint64 header length, then JSON — also a cheap
        // ASCII scan works.
        if let text = String(data: head, encoding: .ascii)?.lowercased() {
            if text.contains("flux") || text.contains("kontext") { return .flux }
            if text.contains("sd3.5") || text.contains("sd35") || text.contains("stable_diffusion_3") { return .sd35 }
            if text.contains("sdxl") || text.contains("sd_xl") { return .sdxl }
            if text.contains("wan2") || text.contains("wan_2") { return .wan21 }
            if text.contains("ltx-video") || text.contains("ltxv") { return .ltx }
        }
        return nil
    }

    var label: String {
        switch self {
        case .flux:    return "FLUX"
        case .sd35:    return "SD 3.5"
        case .sdxl:    return "SDXL"
        case .sd15:    return "SD 1.x / 2.x"
        case .wan21:   return "Wan 2.1"
        case .ltx:     return "LTX Video"
        case .unknown: return "Unknown"
        }
    }

    /// Suggested generation defaults for this family (only the ones that
    /// commonly trip users up — leaving sampler/scheduler at user choice when
    /// not strongly opinionated).
    struct Defaults: Equatable {
        let cfgScale: Double
        let guidance: Double          // distilled guidance (for FLUX/SD3)
        let steps: Int
        let sampler: SDSampler
        let scheduler: SDScheduler
    }

    var defaults: Defaults {
        switch self {
        case .flux:
            // FLUX is distilled: CFG should be ~1, distilled guidance ~3.5,
            // 4 steps for schnell / 20-28 for dev. Euler is the canonical sampler.
            return Defaults(cfgScale: 1.0, guidance: 3.5, steps: 20,
                            sampler: .euler, scheduler: .simple)
        case .sd35:
            // SD 3.5 wants moderate CFG, Euler, ~28 steps.
            return Defaults(cfgScale: 4.5, guidance: 3.5, steps: 28,
                            sampler: .euler, scheduler: .simple)
        case .sdxl:
            return Defaults(cfgScale: 7.0, guidance: 3.5, steps: 24,
                            sampler: .dpmpp2m, scheduler: .karras)
        case .sd15:
            return Defaults(cfgScale: 7.5, guidance: 3.5, steps: 30,
                            sampler: .dpmpp2m, scheduler: .karras)
        case .wan21, .ltx:
            return Defaults(cfgScale: 6.0, guidance: 5.0, steps: 25,
                            sampler: .euler, scheduler: .simple)
        case .unknown:
            return Defaults(cfgScale: 7.0, guidance: 3.5, steps: 24,
                            sampler: .dpmpp2m, scheduler: .karras)
        }
    }

    /// Whether this family uses distilled guidance (separate from CFG) — i.e.
    /// whether the generator should use the /sdcpp/v1/img_gen endpoint so
    /// `guidance` is actually applied at the server.
    var usesDistilledGuidance: Bool {
        switch self {
        case .flux, .sd35: return true
        default:           return false
        }
    }
}

// MARK: - Required companions

enum CompanionRole: String, Hashable {
    case t5         // T5-XXL text encoder
    case clipL      // CLIP-L text encoder
    case clipG      // CLIP-G text encoder
    case vae        // VAE
}

struct CompanionRequirement: Hashable {
    let role: CompanionRole
    /// The catalog id that satisfies this role for this family. nil means
    /// "any catalog entry with the matching role tag will do".
    let preferredCatalogId: String?

    var label: String {
        switch role {
        case .t5:    return "T5-XXL encoder"
        case .clipL: return "CLIP-L encoder"
        case .clipG: return "CLIP-G encoder"
        case .vae:   return "VAE"
        }
    }
}

// MARK: - Bundle resolver

enum ModelBundle {

    /// What companion files this family REQUIRES on disk for generation
    /// to actually work. Order matters — first match wins for picking the
    /// curated download.
    static func requiredCompanions(for family: DiffusionFamily) -> [CompanionRequirement] {
        switch family {
        case .flux:
            return [
                CompanionRequirement(role: .t5,    preferredCatalogId: "enc.t5xxl-q5"),
                CompanionRequirement(role: .clipL, preferredCatalogId: "enc.clip-l"),
                CompanionRequirement(role: .vae,   preferredCatalogId: "vae.flux-ae"),
            ]
        case .sd35:
            return [
                CompanionRequirement(role: .t5,    preferredCatalogId: "enc.t5xxl-q5"),
                CompanionRequirement(role: .clipL, preferredCatalogId: "enc.clip-l"),
                CompanionRequirement(role: .clipG, preferredCatalogId: "enc.clip-g"),
                CompanionRequirement(role: .vae,   preferredCatalogId: "vae.sd35"),
            ]
        case .sdxl, .sd15:
            // SDXL / SD 1.5 GGUFs typically have the VAE baked in; no
            // separate encoder file is needed.
            return []
        case .wan21:
            return [
                CompanionRequirement(role: .t5,  preferredCatalogId: "enc.umt5-wan"),
                CompanionRequirement(role: .vae, preferredCatalogId: "vae.wan"),
            ]
        case .ltx:
            return [
                CompanionRequirement(role: .t5,  preferredCatalogId: "enc.t5-ltx"),
            ]
        case .unknown:
            return []
        }
    }

    /// Locate a catalog entry that satisfies the role for this family.
    static func catalogEntry(for req: CompanionRequirement) -> ModelRec? {
        if let id = req.preferredCatalogId,
           let rec = ModelRecommender.catalog.first(where: { $0.id == id }) {
            return rec
        }
        // Fallback: any companion entry tagged with the role.
        let tag: String = {
            switch req.role {
            case .t5: return "t5"
            case .clipL: return "clip-l"
            case .clipG: return "clip-g"
            case .vae: return "vae"
            }
        }()
        return ModelRecommender.catalog.first { $0.tags.contains("companion") && $0.tags.contains(tag) }
    }

    /// Total approx download size (GB) for missing companions.
    static func missingDownloadGB(missing: [(CompanionRequirement, ModelRec)]) -> Double {
        missing.reduce(0) { $0 + $1.1.approxDownloadGB }
    }
}

// MARK: - Companion file lookup on disk

/// Resolved state of each companion role for the active diffusion model.
struct CompanionStatus: Hashable {
    let role: CompanionRole
    let label: String
    let localPath: String?      // nil if missing
    let curated: ModelRec?      // suggested catalog entry if missing
    var isMissing: Bool { localPath == nil }
}

/// Given the chosen diffusion model path, surface companion file state by
/// looking under the HF cache root for the catalog files. This is what
/// drives the UI hints and the "Download missing files" button.
///
/// `status(forDiffusion:downloadsRoot:)` is `@MainActor` because it reads
/// `UserDefaults.standard`. `scanOffActor(...)` is the off-actor variant
/// callers should use when on a `Task.detached` to avoid blocking the UI
/// during a deep filesystem walk.
@MainActor
enum CompanionResolver {

    /// Off-actor wrapper: scan disk for companion files without reading
    /// UserDefaults. Safe to call from `Task.detached`. Returns whichever
    /// roles were found on disk (under the curated path or anywhere in the
    /// cache); roles that weren't found are simply omitted.
    nonisolated
    static func scanOffActor(forDiffusion path: String, downloadsRoot: URL) -> [CompanionStatus] {
        let family = DiffusionFamily.detect(path: path)
        let reqs = ModelBundle.requiredCompanions(for: family)
        let fm = FileManager.default
        var out: [CompanionStatus] = []
        for req in reqs {
            let rec = ModelBundle.catalogEntry(for: req)
            if let rec {
                let expected = downloadsRoot
                    .appendingPathComponent(rec.repoId)
                    .appendingPathComponent(rec.filename)
                if fm.fileExists(atPath: expected.path) {
                    out.append(CompanionStatus(role: req.role, label: req.label,
                                               localPath: expected.path, curated: rec))
                    continue
                }
            }
            if let found = scanCache(for: req.role, root: downloadsRoot) {
                out.append(CompanionStatus(role: req.role, label: req.label,
                                           localPath: found, curated: rec))
            }
        }
        return out
    }

    /// Check disk for each required companion. Looks at the configured
    /// SD keys first (user override), then the HF cache.
    static func status(forDiffusion path: String,
                       downloadsRoot: URL,
                       userDefaults: UserDefaults = .standard)
        -> [CompanionStatus]
    {
        let family = DiffusionFamily.detect(path: path)
        let reqs = ModelBundle.requiredCompanions(for: family)
        let fm = FileManager.default
        var out: [CompanionStatus] = []
        for req in reqs {
            let rec = ModelBundle.catalogEntry(for: req)

            // 1. Honor explicit user setting first.
            let userKey: String? = {
                switch req.role {
                case .t5:    return SDKeys.t5Path
                case .clipL: return SDKeys.clipLPath
                case .clipG: return SDKeys.clipGPath
                case .vae:   return SDKeys.vaePath
                }
            }()
            if let key = userKey,
               let p = userDefaults.string(forKey: key),
               !p.isEmpty, fm.fileExists(atPath: p) {
                out.append(CompanionStatus(role: req.role, label: req.label,
                                           localPath: p, curated: rec))
                continue
            }
            // 2. Look for the curated file in the HF cache.
            if let rec {
                let expected = downloadsRoot
                    .appendingPathComponent(rec.repoId)
                    .appendingPathComponent(rec.filename)
                if fm.fileExists(atPath: expected.path) {
                    out.append(CompanionStatus(role: req.role, label: req.label,
                                               localPath: expected.path, curated: rec))
                    continue
                }
            }
            // 3. Fallback: scan HF cache for a file matching the role.
            if let found = scanCache(for: req.role, root: downloadsRoot) {
                out.append(CompanionStatus(role: req.role, label: req.label,
                                           localPath: found, curated: rec))
                continue
            }
            out.append(CompanionStatus(role: req.role, label: req.label,
                                       localPath: nil, curated: rec))
        }
        return out
    }

    /// Best-effort scan of HF cache for a file that "looks like" the role.
    /// Avoids walking the entire tree by checking known repo subpaths first.
    nonisolated
    static func scanCache(for role: CompanionRole, root: URL) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return nil }
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles]) else { return nil }
        var bestMatch: String?
        for case let url as URL in enumerator {
            let n = url.lastPathComponent.lowercased()
            switch role {
            case .t5:
                if n.contains("t5xxl") || n.contains("t5_xxl") || n.contains("umt5") || n.contains("t5-v1_1-xxl") {
                    if n.hasSuffix(".gguf") || n.hasSuffix(".safetensors") {
                        return url.path
                    }
                }
            case .clipL:
                if n.contains("clip_l") || n.contains("clip-l") {
                    if n.hasSuffix(".safetensors") || n.hasSuffix(".gguf") {
                        return url.path
                    }
                }
            case .clipG:
                if n.contains("clip_g") || n.contains("clip-g") {
                    if n.hasSuffix(".safetensors") || n.hasSuffix(".gguf") {
                        return url.path
                    }
                }
            case .vae:
                if n == "ae.safetensors" || n == "ae.sft" {
                    return url.path
                }
                if n.contains("vae") && (n.hasSuffix(".safetensors") || n.hasSuffix(".sft") || n.hasSuffix(".gguf")) {
                    // Prefer "vae" matches but keep searching for canonical names.
                    bestMatch = bestMatch ?? url.path
                }
            }
        }
        return bestMatch
    }
}
