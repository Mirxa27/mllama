import Foundation
import AppKit
import SwiftUI

// MARK: - Generation parameters

enum SDSampler: String, CaseIterable, Identifiable, Codable {
    case euler        = "euler"
    case eulerA       = "euler_a"
    case heun         = "heun"
    case dpm2         = "dpm2"
    case dpmpp2m      = "dpm++2m"
    case dpmpp2mV2    = "dpm++2m_v2"
    case dpmpp2sa     = "dpm++2s_a"
    case lcm          = "lcm"
    case tcd          = "tcd"
    case ddim         = "ddim_trailing"
    case erSde        = "er_sde"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .euler:     return "Euler"
        case .eulerA:    return "Euler Ancestral"
        case .heun:      return "Heun"
        case .dpm2:      return "DPM2"
        case .dpmpp2m:   return "DPM++ 2M"
        case .dpmpp2mV2: return "DPM++ 2M v2"
        case .dpmpp2sa:  return "DPM++ 2S Ancestral"
        case .lcm:       return "LCM (fast)"
        case .tcd:       return "TCD (fast)"
        case .ddim:      return "DDIM"
        case .erSde:     return "ER-SDE"
        }
    }
}

enum SDScheduler: String, CaseIterable, Identifiable, Codable {
    case discrete    = "discrete"
    case karras      = "karras"
    case exponential = "exponential"
    case ays         = "ays"
    case gits        = "gits"
    case sgmUniform  = "sgm_uniform"
    case simple      = "simple"
    case klOptimal   = "kl_optimal"
    case lcm         = "lcm"
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct ImageGenParams: Hashable, Codable {
    var prompt: String = ""
    var negativePrompt: String = ""
    var width: Int = 1024
    var height: Int = 1024
    var steps: Int = 24
    var cfgScale: Double = 7.0
    var guidance: Double = 3.5         // distilled-guidance (Flux/SD3)
    var seed: Int64 = -1                // -1 → random
    var sampler: SDSampler = .dpmpp2m
    var scheduler: SDScheduler = .karras
    var batchCount: Int = 1
    var clipSkip: Int = -1

    // img2img
    var initImagePath: String? = nil
    var strength: Double = 0.7
    var maskImagePath: String? = nil    // inpainting

    // ControlNet
    var controlImagePath: String? = nil
    var controlStrength: Double = 0.9

    // LoRA — string form e.g. "<lora:cinematic:0.7> <lora:detail:0.4>"
    var loraDirectives: String = ""

    // Upscaler at the end of generation
    var hires: Bool = false
    var hiresScale: Double = 1.5
    var hiresSteps: Int = 10
    var hiresDenoisingStrength: Double = 0.5
}

struct ImageGenResult: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let params: ImageGenParams
    let createdAt: Date
    let elapsedSeconds: Double
    let modelName: String
}

// MARK: - Progress

struct ImageGenProgress: Equatable {
    var step: Int
    var totalSteps: Int
    var fraction: Double
    var etaSeconds: Double
    var previewURL: URL?
    var message: String
}

// MARK: - Generator

@MainActor
final class ImageGenerator: ObservableObject {
    @Published var isGenerating: Bool = false
    @Published var lastError: String?
    @Published var progress: ImageGenProgress?
    @Published var results: [ImageGenResult] = []

    private let server: SDServerController
    private var currentTask: Task<Void, Never>?

    init(server: SDServerController) {
        self.server = server
    }

    /// Cancel any in-flight generation. Server-side cancellation is also issued via /sdapi/v1/interrupt.
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        Task { await interruptServer() }
        isGenerating = false
        progress = nil
    }

    private func interruptServer() async {
        guard let base = server.serverURL else { return }
        var req = URLRequest(url: base.appendingPathComponent("sdapi/v1/interrupt"))
        req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Text-to-image (or img2img / inpaint depending on params).
    func generate(_ params: ImageGenParams) {
        guard server.status == .running, let _ = server.serverURL else {
            lastError = "Image server is not running. Pick a model in Settings → Image Gen."
            return
        }
        cancel()
        isGenerating = true
        lastError = nil
        DockBadge.shared.setImage(1)
        progress = ImageGenProgress(step: 0, totalSteps: params.steps, fraction: 0,
                                    etaSeconds: 0, previewURL: nil, message: "Queued…")
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runGenerate(params)
        }
        currentTask = task
    }

    private func runGenerate(_ params: ImageGenParams) async {
        defer { Task { @MainActor in
            self.isGenerating = false
            self.progress = nil
            DockBadge.shared.setImage(0)
        } }
        guard let base = server.serverURL else { return }

        let start = Date()

        // Decide which API to call.
        // - FLUX / SD 3.5 + sd-server that exposes /sdcpp/v1/* → use the
        //   native endpoint so distilled `guidance` actually applies.
        // - Older sd-server builds only have /sdapi/v1/* — fall back and
        //   warn the user that distilled guidance won't be passed through.
        // - Everything else → A1111-compatible /sdapi/v1/{txt2img,img2img}
        let modelPath = server.modelPath ?? ""
        let family = DiffusionFamily.detect(path: modelPath)
        let isImg2Img = (params.initImagePath != nil)
        let wantsDistilled = family.usesDistilledGuidance
        let useDistilledEndpoint = wantsDistilled && server.supportsSdcpp
        let isControlNetRequest = (params.controlImagePath != nil)

        if wantsDistilled && !server.supportsSdcpp {
            await MainActor.run {
                // Non-fatal hint: generation will still run, just with
                // baseline CFG behaviour instead of distilled guidance.
                self.lastError = "This sd-server build doesn't expose /sdcpp/v1/* — distilled guidance won't apply. Rebuild stable-diffusion.cpp to get FLUX/SD3-quality output."
            }
        }

        let endpoint: URL
        let body: [String: Any]
        let resultKey: String   // JSON key holding the image array

        if useDistilledEndpoint {
            endpoint = base.appendingPathComponent("sdcpp/v1/img_gen")
            body = Self.buildSdcppImgGenPayload(params, family: family)
            resultKey = "images"
        } else {
            endpoint = base.appendingPathComponent(isImg2Img ? "sdapi/v1/img2img" : "sdapi/v1/txt2img")
            body = Self.buildSdapiPayload(params, isImg2Img: isImg2Img)
            resultKey = "images"
            if isControlNetRequest {
                // /sdapi/v1/ in stable-diffusion.cpp does NOT honor
                // alwayson_scripts. Warn the user instead of silently dropping.
                await MainActor.run {
                    self.lastError = "ControlNet over the A1111 endpoint isn't supported by sd-server. Use a FLUX/SD3 model (routed via /sdcpp/v1/img_gen) for ControlNet."
                }
            }
        }

        // Live preview poller (polls /sdapi/v1/progress every 0.4s while generating).
        // The progress endpoint is shared across sdapi and sdcpp paths and
        // reports the active sampler step regardless of which submit path
        // was used.
        let pollTask = Task { [weak self] in
            await self?.pollProgress(base: base, totalSteps: params.steps)
        }

        do {
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 3600
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: req)
            pollTask.cancel()
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let text = String(data: data, encoding: .utf8)?.prefix(400) ?? "<binary>"
                await MainActor.run {
                    self.lastError = "HTTP \(http.statusCode) from \(endpoint.lastPathComponent): \(text)"
                }
                return
            }
            let images = Self.extractImages(from: data, key: resultKey)
            guard !images.isEmpty else {
                await MainActor.run {
                    self.lastError = "Server returned no images. Common causes: missing T5/CLIP encoder for FLUX/SD3, mismatched VAE, or the prompt was filtered."
                }
                return
            }
            let savedURLs: [URL] = images.compactMap { Self.saveBase64Image($0, in: server.outputRoot) }
            let elapsed = Date().timeIntervalSince(start)
            let modelName = (server.modelPath as NSString?)?.lastPathComponent ?? "sd-server"
            await MainActor.run {
                // A successful generate clears any stale warning text (e.g. the
                // ControlNet-not-supported hint we may have set earlier).
                self.lastError = nil
                for u in savedURLs {
                    let r = ImageGenResult(
                        url: u,
                        params: params,
                        createdAt: Date(),
                        elapsedSeconds: elapsed,
                        modelName: modelName
                    )
                    self.results.insert(r, at: 0)
                    MediaLibrary.shared.record(image: r)
                }
            }
            // Fire a banner if the user backgrounded the app while we worked.
            if let firstURL = savedURLs.first {
                let title = "Image ready"
                let promptPreview = String(params.prompt.prefix(80))
                let body = "\(modelName) · \(Int(elapsed))s\n\(promptPreview)"
                await MainActor.run {
                    NotificationCenterBridge.post(kind: .imageReady,
                                                   title: title,
                                                   body: body,
                                                   filePath: firstURL.path)
                }
            }
        } catch is CancellationError {
            pollTask.cancel()
        } catch {
            pollTask.cancel()
            await MainActor.run { self.lastError = error.localizedDescription }
        }
    }

    // MARK: - Payload builders

    /// A1111-compatible payload for /sdapi/v1/{txt2img,img2img}. Includes
    /// every field stable-diffusion.cpp's sdapi route actually parses; fields
    /// it ignores (alwayson_scripts, distilled guidance, n_iter) are omitted.
    private static func buildSdapiPayload(_ params: ImageGenParams, isImg2Img: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "prompt": params.loraDirectives.isEmpty
                ? params.prompt
                : params.prompt + " " + params.loraDirectives,
            "negative_prompt": params.negativePrompt,
            "width": params.width,
            "height": params.height,
            "steps": params.steps,
            "cfg_scale": params.cfgScale,
            "seed": params.seed,
            "sampler_name": params.sampler.rawValue,
            "scheduler": params.scheduler.rawValue,
            "batch_size": max(1, params.batchCount),  // n_iter is NOT a valid sdapi field
        ]
        // clip_skip: server interprets -1 as auto; positive ints skip layers.
        if params.clipSkip >= 0 {
            body["clip_skip"] = params.clipSkip
        }
        // Hi-res fix (txt2img only).
        if params.hires && !isImg2Img {
            body["enable_hr"] = true
            body["hr_scale"] = params.hiresScale
            body["hr_steps"] = params.hiresSteps
            body["denoising_strength"] = params.hiresDenoisingStrength
        }
        if isImg2Img {
            if let init_ = params.initImagePath,
               let img = Self.base64FileContents(at: init_) {
                body["init_images"] = [img]
                body["denoising_strength"] = params.strength
            }
            if let mask_ = params.maskImagePath,
               let m = Self.base64FileContents(at: mask_) {
                body["mask"] = m
                body["mask_blur"] = 4
                body["inpainting_fill"] = 1
                body["inpaint_full_res"] = true
            }
        }
        return body
    }

    /// Payload for /sdcpp/v1/img_gen — the native endpoint that actually
    /// applies distilled `guidance` (required for FLUX / SD 3.5).
    private static func buildSdcppImgGenPayload(_ params: ImageGenParams, family: DiffusionFamily) -> [String: Any] {
        var sampleParams: [String: Any] = [
            "sample_method": params.sampler.rawValue,
            "scheduler": params.scheduler.rawValue,
            "sample_steps": params.steps,
            "guidance": [
                "txt_cfg": params.cfgScale,
                "distilled_guidance": params.guidance,
            ],
        ]
        // FLUX schnell variants want a small flow shift; default ok otherwise.
        if family == .flux {
            sampleParams["flow_shift"] = 1.0
        }

        var body: [String: Any] = [
            "prompt": params.loraDirectives.isEmpty
                ? params.prompt
                : params.prompt + " " + params.loraDirectives,
            "negative_prompt": params.negativePrompt,
            "width": params.width,
            "height": params.height,
            "seed": params.seed,
            "batch_count": max(1, params.batchCount),
            "sample_params": sampleParams,
            "output_format": "png",
        ]
        if params.clipSkip >= 0 {
            body["clip_skip"] = params.clipSkip
        }
        if let init_ = params.initImagePath, let img = Self.base64FileContents(at: init_) {
            body["init_image"] = img
            body["strength"] = params.strength
        }
        if let mask_ = params.maskImagePath, let m = Self.base64FileContents(at: mask_) {
            body["mask_image"] = m
        }
        if let ctrl = params.controlImagePath, let img = Self.base64FileContents(at: ctrl) {
            body["control_image"] = img
            body["control_strength"] = params.controlStrength
        }
        if params.hires {
            body["hires"] = [
                "scale": params.hiresScale,
                "steps": params.hiresSteps,
                "denoising_strength": params.hiresDenoisingStrength,
            ]
        }
        return body
    }

    /// Both endpoints reply with `images: [base64]` but historically the sdapi
    /// route returns the array under "images" while sdcpp also exposes "files".
    /// Decode defensively.
    private static func extractImages(from data: Data, key: String) -> [String] {
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let dict = any as? [String: Any] {
            if let imgs = dict[key] as? [String], !imgs.isEmpty { return imgs }
            if let imgs = dict["images"] as? [String], !imgs.isEmpty { return imgs }
            // sdcpp async jobs nest data under "result".
            if let result = dict["result"] as? [String: Any],
               let imgs = result["images"] as? [String], !imgs.isEmpty {
                return imgs
            }
        }
        return []
    }

    private static func base64FileContents(at path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else { return nil }
        return data.base64EncodedString()
    }

    private func pollProgress(base: URL, totalSteps: Int) async {
        let url = base.appendingPathComponent("sdapi/v1/progress")
        while !Task.isCancelled {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let prog = (json["progress"] as? Double) ?? 0
                    let eta  = (json["eta_relative"] as? Double) ?? 0
                    var step = 0
                    if let state = json["state"] as? [String: Any] {
                        step = (state["sampling_step"] as? Int) ?? 0
                    }
                    await MainActor.run {
                        self.progress = ImageGenProgress(
                            step: step,
                            totalSteps: totalSteps,
                            fraction: prog,
                            etaSeconds: eta,
                            previewURL: nil,
                            message: prog >= 1 ? "Decoding…" : "Step \(step)/\(totalSteps)"
                        )
                    }
                }
            } catch { /* tolerate transient */ }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    // MARK: - Helpers

    /// Decode a base64 PNG/JPEG to a file in the output root, return its URL.
    static func saveBase64Image(_ base64: String, in root: URL) -> URL? {
        // A1111 returns raw base64 (no data: prefix) but be defensive.
        let payload = base64.contains(",") ? String(base64.split(separator: ",")[1]) : base64
        guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else { return nil }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ts = DateFormatter.compactStamp.string(from: Date())
        let url = root.appendingPathComponent("img_\(ts)_\(Int.random(in: 1000...9999)).png")
        do { try data.write(to: url); return url } catch { return nil }
    }
}

extension DateFormatter {
    static let compactStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
