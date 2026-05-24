import Foundation

// MARK: - Recommendation domain

enum RecommendKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case llm, image, video
    var id: String { rawValue }
    var label: String {
        switch self {
        case .llm:   return "LLM"
        case .image: return "Image"
        case .video: return "Video"
        }
    }
    var sfSymbol: String {
        switch self {
        case .llm:   return "text.bubble.fill"
        case .image: return "photo.artframe"
        case .video: return "film.stack"
        }
    }
}

/// One curated, downloadable model with size + tier metadata so we can pick
/// per the user's Mac.
struct ModelRec: Identifiable, Hashable {
    let id: String                 // unique slug
    let repoId: String             // HuggingFace repo id
    let filename: String           // canonical file to grab (smallest "good" quant)
    let label: String
    let blurb: String
    let kind: RecommendKind
    let approxDownloadGB: Double   // file size on disk
    let runtimeRamGB: Double       // memory the loaded model will consume
    let tier: RamTier              // minimum tier where it runs comfortably
    let tags: [String]

    var humanDownload: String { String(format: "%.1f GB download", approxDownloadGB) }
    var humanRam:      String { String(format: "~%.1f GB RAM",     runtimeRamGB) }
}

// MARK: - Catalog (hand-curated, verified popular repos)

enum ModelRecommender {

    static let catalog: [ModelRec] = [

        // ============ LLMs ============
        ModelRec(id: "llm.llama32-1b",
                 repoId: "unsloth/Llama-3.2-1B-Instruct-GGUF",
                 filename: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
                 label: "Llama 3.2 1B",
                 blurb: "Tiny, fast Meta instruction model. Great on any Mac.",
                 kind: .llm,
                 approxDownloadGB: 0.8, runtimeRamGB: 1.5,
                 tier: .small, tags: ["fast", "tool-use"]),
        ModelRec(id: "llm.llama32-3b",
                 repoId: "unsloth/Llama-3.2-3B-Instruct-GGUF",
                 filename: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
                 label: "Llama 3.2 3B",
                 blurb: "Small, capable. Best balance for 8 GB Macs.",
                 kind: .llm,
                 approxDownloadGB: 2.0, runtimeRamGB: 3.0,
                 tier: .small, tags: ["tool-use", "recommended"]),
        ModelRec(id: "llm.qwen25-7b",
                 repoId: "bartowski/Qwen2.5-7B-Instruct-GGUF",
                 filename: "Qwen2.5-7B-Instruct-Q4_K_M.gguf",
                 label: "Qwen 2.5 7B",
                 blurb: "Strong general-purpose model. Multilingual, code, math.",
                 kind: .llm,
                 approxDownloadGB: 4.7, runtimeRamGB: 6.0,
                 tier: .mid, tags: ["multilingual", "code"]),
        ModelRec(id: "llm.llama31-8b",
                 repoId: "MaziyarPanahi/Meta-Llama-3.1-8B-Instruct-GGUF",
                 filename: "Meta-Llama-3.1-8B-Instruct.Q4_K_M.gguf",
                 label: "Llama 3.1 8B",
                 blurb: "Meta's solid mid-size workhorse. Great for chat + tools.",
                 kind: .llm,
                 approxDownloadGB: 4.9, runtimeRamGB: 6.0,
                 tier: .mid, tags: ["tool-use", "recommended"]),
        ModelRec(id: "llm.qwen25-14b",
                 repoId: "bartowski/Qwen2.5-14B-Instruct-GGUF",
                 filename: "Qwen2.5-14B-Instruct-Q4_K_M.gguf",
                 label: "Qwen 2.5 14B",
                 blurb: "Step up in quality. Needs 16 GB Mac.",
                 kind: .llm,
                 approxDownloadGB: 9.0, runtimeRamGB: 11.0,
                 tier: .mid, tags: ["quality"]),
        ModelRec(id: "llm.llama33-70b",
                 repoId: "bartowski/Llama-3.3-70B-Instruct-GGUF",
                 filename: "Llama-3.3-70B-Instruct-Q4_K_M.gguf",
                 label: "Llama 3.3 70B",
                 blurb: "Frontier quality. Needs 32 GB+ and patience.",
                 kind: .llm,
                 approxDownloadGB: 42.0, runtimeRamGB: 46.0,
                 tier: .large, tags: ["frontier", "slow"]),
        ModelRec(id: "llm.qwen25-72b",
                 repoId: "bartowski/Qwen2.5-72B-Instruct-GGUF",
                 filename: "Qwen2.5-72B-Instruct-Q4_K_M.gguf",
                 label: "Qwen 2.5 72B",
                 blurb: "Top open-weights model. 64 GB+ recommended.",
                 kind: .llm,
                 approxDownloadGB: 43.5, runtimeRamGB: 50.0,
                 tier: .xl, tags: ["frontier"]),

        // ============ Image generators ============
        // All filenames verified against the live HuggingFace API (2026-05).
        ModelRec(id: "img.sdxl-turbo",
                 repoId: "OlegSkutte/sdxl-turbo-GGUF",
                 filename: "sd_xl_turbo_1.0.q8_0.gguf",
                 label: "SDXL Turbo",
                 blurb: "1-step distillation of SDXL. Lightning fast.",
                 kind: .image,
                 approxDownloadGB: 3.9, runtimeRamGB: 6.0,
                 tier: .small, tags: ["fast"]),
        ModelRec(id: "img.flux-schnell",
                 repoId: "city96/FLUX.1-schnell-gguf",
                 filename: "flux1-schnell-Q4_K_S.gguf",
                 label: "FLUX.1 schnell",
                 blurb: "4-step Flux distill. Best speed/quality on 16 GB.",
                 kind: .image,
                 approxDownloadGB: 6.8, runtimeRamGB: 10.0,
                 tier: .mid, tags: ["fast", "recommended"]),
        ModelRec(id: "img.flux-dev",
                 repoId: "city96/FLUX.1-dev-gguf",
                 filename: "flux1-dev-Q4_K_S.gguf",
                 label: "FLUX.1 dev",
                 blurb: "Black Forest Labs' top open image model.",
                 kind: .image,
                 approxDownloadGB: 6.8, runtimeRamGB: 12.0,
                 tier: .mid, tags: ["quality", "recommended"]),
        ModelRec(id: "img.sd35-large-q4",
                 repoId: "city96/stable-diffusion-3.5-large-gguf",
                 filename: "sd3.5_large-Q4_0.gguf",
                 label: "SD 3.5 Large (Q4)",
                 blurb: "Stability's flagship SD3.5 in compact Q4 GGUF.",
                 kind: .image,
                 approxDownloadGB: 4.5, runtimeRamGB: 8.0,
                 tier: .mid, tags: ["quality"]),
        ModelRec(id: "img.flux-dev-q8",
                 repoId: "city96/FLUX.1-dev-gguf",
                 filename: "flux1-dev-Q8_0.gguf",
                 label: "FLUX.1 dev (Q8)",
                 blurb: "Higher-fidelity Flux quant. 32 GB recommended.",
                 kind: .image,
                 approxDownloadGB: 12.7, runtimeRamGB: 18.0,
                 tier: .large, tags: ["quality"]),
        ModelRec(id: "img.sd35-large-q8",
                 repoId: "city96/stable-diffusion-3.5-large-gguf",
                 filename: "sd3.5_large-Q8_0.gguf",
                 label: "SD 3.5 Large (Q8)",
                 blurb: "Stability's flagship at higher fidelity.",
                 kind: .image,
                 approxDownloadGB: 8.4, runtimeRamGB: 14.0,
                 tier: .large, tags: ["quality"]),
        ModelRec(id: "img.flux-kontext",
                 repoId: "QuantStack/FLUX.1-Kontext-dev-GGUF",
                 filename: "flux1-kontext-dev-Q4_K_S.gguf",
                 label: "FLUX Kontext",
                 blurb: "Instruction-based image editing (\"make it night\").",
                 kind: .image,
                 approxDownloadGB: 7.0, runtimeRamGB: 12.0,
                 tier: .mid, tags: ["editing"]),
        ModelRec(id: "img.flux-fill",
                 repoId: "YarvixPA/FLUX.1-Fill-dev-GGUF",
                 filename: "flux1-fill-dev-Q4_K_S.gguf",
                 label: "FLUX Fill (inpaint)",
                 blurb: "Inpainting / outpainting variant of FLUX.",
                 kind: .image,
                 approxDownloadGB: 7.0, runtimeRamGB: 12.0,
                 tier: .mid, tags: ["inpaint"]),

        // ============ Video generators ============
        // No Wan 1.3B GGUF exists; the smallest verified Wan is 14B Q3_K_S.
        ModelRec(id: "vid.ltx-096-q4",
                 repoId: "calcuis/ltxv0.9.6-gguf",
                 filename: "ltxv-2b-0.9.6-dev-q4_k_s.gguf",
                 label: "LTX Video 0.9.6 (Q4)",
                 blurb: "Tiny Lightricks video model. Runs on 16 GB Macs.",
                 kind: .video,
                 approxDownloadGB: 1.2, runtimeRamGB: 6.0,
                 tier: .mid, tags: ["fast", "recommended"]),
        ModelRec(id: "vid.ltx-096-q8",
                 repoId: "calcuis/ltxv0.9.6-gguf",
                 filename: "ltxv-2b-0.9.6-dev-f16.gguf",
                 label: "LTX Video 0.9.6 (F16)",
                 blurb: "Full-precision LTX 2B. Best quality.",
                 kind: .video,
                 approxDownloadGB: 3.8, runtimeRamGB: 10.0,
                 tier: .large, tags: ["quality"]),
        ModelRec(id: "vid.wan21-14b-q3",
                 repoId: "city96/Wan2.1-T2V-14B-gguf",
                 filename: "wan2.1-t2v-14b-Q3_K_S.gguf",
                 label: "Wan 2.1 T2V 14B (Q3)",
                 blurb: "High-quality Wan 14B. Needs 32 GB+ RAM.",
                 kind: .video,
                 approxDownloadGB: 6.7, runtimeRamGB: 20.0,
                 tier: .large, tags: ["quality"]),
        ModelRec(id: "vid.wan21-14b-q4",
                 repoId: "city96/Wan2.1-T2V-14B-gguf",
                 filename: "wan2.1-t2v-14b-Q4_0.gguf",
                 label: "Wan 2.1 T2V 14B (Q4)",
                 blurb: "Higher fidelity Wan. 64 GB recommended.",
                 kind: .video,
                 approxDownloadGB: 8.6, runtimeRamGB: 28.0,
                 tier: .xl, tags: ["quality"]),

        // ============ Companion files (encoders / VAE) ============
        // These are required by FLUX, SD3.5, and Wan video models — they are
        // NOT bundled into the diffusion GGUF and must be loaded separately.
        ModelRec(id: "enc.t5xxl-q5",
                 repoId: "city96/t5-v1_1-xxl-encoder-gguf",
                 filename: "t5-v1_1-xxl-encoder-Q5_K_M.gguf",
                 label: "T5-XXL encoder (Q5)",
                 blurb: "Text encoder used by FLUX, SD3, Wan. Pair with diffusion model.",
                 kind: .image,
                 approxDownloadGB: 3.5, runtimeRamGB: 4.0,
                 tier: .mid, tags: ["companion", "t5"]),
        ModelRec(id: "enc.t5xxl-q8",
                 repoId: "city96/t5-v1_1-xxl-encoder-gguf",
                 filename: "t5-v1_1-xxl-encoder-Q8_0.gguf",
                 label: "T5-XXL encoder (Q8)",
                 blurb: "Higher-fidelity T5 text encoder for FLUX / SD3 / Wan.",
                 kind: .image,
                 approxDownloadGB: 5.0, runtimeRamGB: 6.0,
                 tier: .large, tags: ["companion", "t5"]),
        ModelRec(id: "enc.clip-l",
                 repoId: "comfyanonymous/flux_text_encoders",
                 filename: "clip_l.safetensors",
                 label: "CLIP-L encoder",
                 blurb: "OpenAI CLIP-L text encoder. Required by FLUX, SDXL, SD3.",
                 kind: .image,
                 approxDownloadGB: 0.25, runtimeRamGB: 0.6,
                 tier: .small, tags: ["companion", "clip-l"]),
        ModelRec(id: "enc.clip-g",
                 repoId: "Comfy-Org/stable-diffusion-3.5-fp8",
                 filename: "text_encoders/clip_g.safetensors",
                 label: "CLIP-G encoder (SD 3.5)",
                 blurb: "Bigger CLIP encoder used by SDXL and SD 3.5.",
                 kind: .image,
                 approxDownloadGB: 1.4, runtimeRamGB: 1.6,
                 tier: .mid, tags: ["companion", "clip-g"]),
        // FLUX VAE — Kijai's redistribution is publicly downloadable (the
        // canonical black-forest-labs/FLUX.1-schnell repo became gated and
        // requires HF login + accepted ToS).
        ModelRec(id: "vae.flux-ae",
                 repoId: "Kijai/flux-fp8",
                 filename: "flux-vae-bf16.safetensors",
                 label: "FLUX VAE (bf16)",
                 blurb: "Required VAE for FLUX dev / schnell / Kontext / Fill. Public mirror.",
                 kind: .image,
                 approxDownloadGB: 0.17, runtimeRamGB: 0.5,
                 tier: .small, tags: ["companion", "vae"]),
        ModelRec(id: "vae.sd35",
                 repoId: "huaweilin/stable-diffusion-3.5-large-vae",
                 filename: "vae/diffusion_pytorch_model.safetensors",
                 label: "SD 3.5 VAE",
                 blurb: "VAE for Stable Diffusion 3.5 GGUF models (split out from the full checkpoint).",
                 kind: .image,
                 approxDownloadGB: 0.17, runtimeRamGB: 0.4,
                 tier: .small, tags: ["companion", "vae"]),
        ModelRec(id: "vae.wan",
                 repoId: "Comfy-Org/Wan_2.1_ComfyUI_repackaged",
                 filename: "split_files/vae/wan_2.1_vae.safetensors",
                 label: "Wan 2.1 VAE",
                 blurb: "Required VAE for Wan 2.1 T2V/I2V video models.",
                 kind: .video,
                 approxDownloadGB: 0.5, runtimeRamGB: 0.8,
                 tier: .mid, tags: ["companion", "vae"]),
        ModelRec(id: "enc.umt5-wan",
                 repoId: "Comfy-Org/Wan_2.1_ComfyUI_repackaged",
                 filename: "split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors",
                 label: "UMT5 encoder (Wan)",
                 blurb: "UMT5-XXL text encoder used by Wan 2.1 video models.",
                 kind: .video,
                 approxDownloadGB: 6.7, runtimeRamGB: 7.0,
                 tier: .large, tags: ["companion", "t5"]),
        // LTX uses the same T5-XXL as SD 3.5 — Comfy-Org's text_encoders
        // bundle exposes it as a single safetensors file (the canonical
        // Lightricks repo only ships it as a sharded diffusers checkpoint).
        ModelRec(id: "enc.t5-ltx",
                 repoId: "Comfy-Org/stable-diffusion-3.5-fp8",
                 filename: "text_encoders/t5xxl_fp16.safetensors",
                 label: "T5-XXL fp16 (LTX / SD3.5)",
                 blurb: "T5 text encoder for LTX Video and SD 3.5 fp16 setups.",
                 kind: .video,
                 approxDownloadGB: 9.5, runtimeRamGB: 10.0,
                 tier: .large, tags: ["companion", "t5"]),
    ]

    // MARK: Selection

    /// Models a system can comfortably run.
    static func canRun(on hw: HardwareInfo, kind: RecommendKind? = nil) -> [ModelRec] {
        let tierRank: [RamTier: Int] = [.small: 0, .mid: 1, .large: 2, .xl: 3]
        let userTier = tierRank[hw.ramTier] ?? 0
        return catalog
            .filter { model in
                (tierRank[model.tier] ?? 0) <= userTier
                && (kind == nil || model.kind == kind)
            }
            .sorted {
                // Prefer recommended-tagged models first, then larger (more capable) within tier
                let aRec = $0.tags.contains("recommended")
                let bRec = $1.tags.contains("recommended")
                if aRec != bRec { return aRec && !bRec }
                return $0.approxDownloadGB > $1.approxDownloadGB
            }
    }

    /// A short "best for you" list — one LLM, one image, one video (if hardware supports).
    static func starterPack(for hw: HardwareInfo) -> [ModelRec] {
        var out: [ModelRec] = []
        if let llm = canRun(on: hw, kind: .llm).first {
            out.append(llm)
        }
        if let img = canRun(on: hw, kind: .image).first {
            out.append(img)
        }
        if let vid = canRun(on: hw, kind: .video).first {
            out.append(vid)
        }
        return out
    }

    /// Models the system probably *cannot* run well — for the "if you upgrade…" view.
    static func cannotRun(on hw: HardwareInfo, kind: RecommendKind? = nil) -> [ModelRec] {
        let tierRank: [RamTier: Int] = [.small: 0, .mid: 1, .large: 2, .xl: 3]
        let userTier = tierRank[hw.ramTier] ?? 0
        return catalog.filter { m in
            (tierRank[m.tier] ?? 0) > userTier
                && (kind == nil || m.kind == kind)
        }
    }

    static func totalBytesFor(_ models: [ModelRec]) -> Double {
        models.reduce(0) { $0 + $1.approxDownloadGB }
    }
}
