import Foundation

// MARK: - Helpers

private func mcpText(_ s: String) -> [String: Any] {
    ["type": "text", "text": s]
}

private func mcpImage(data: Data, mimeType: String = "image/png") -> [String: Any] {
    ["type": "image", "data": data.base64EncodedString(), "mimeType": mimeType]
}

private func mcpResult(_ items: [[String: Any]], isError: Bool = false) -> [String: Any] {
    ["content": items, "isError": isError]
}

private func mcpError(_ message: String) -> [String: Any] {
    mcpResult([mcpText("error: " + message)], isError: true)
}

// MARK: - Generate image tool (returns image inline so callers can SEE it)

struct MCPGenerateImageTool: MCPHostTool {
    let name = "generate_image"
    let description = """
        Generate an image from a text prompt using Mllama's local stable-diffusion.cpp
        engine. Returns the generated image inline (base64 PNG) so the calling agent
        can view it directly, plus the on-disk file path.
        Requires the local image server to be running with a model configured.
        """

    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "prompt":          ["type": "string", "description": "What to generate."],
            "negative_prompt": ["type": "string", "description": "What to avoid."],
            "width":           ["type": "integer", "default": 1024],
            "height":          ["type": "integer", "default": 1024],
            "steps":           ["type": "integer", "default": 24],
            "cfg_scale":       ["type": "number",  "default": 7.0],
            "seed":            ["type": "integer", "description": "-1 for random.", "default": -1],
            "sampler":         ["type": "string",  "description": "euler|dpm++2m|lcm|tcd|…"]
        ],
        "required": ["prompt"]
    ]

    private let _generator: @Sendable () -> ImageGenerator?

    init(generator: @escaping @Sendable () -> ImageGenerator?) {
        self._generator = generator
    }

    func run(arguments: [String: Any]) async -> [String: Any] {
        guard let gen = await MainActor.run(body: { _generator() }) else {
            return mcpError("image generator not available")
        }
        var p = ImageGenParams()
        p.prompt         = (arguments["prompt"] as? String) ?? ""
        p.negativePrompt = (arguments["negative_prompt"] as? String) ?? ""
        p.width          = (arguments["width"]  as? Int) ?? 1024
        p.height         = (arguments["height"] as? Int) ?? 1024
        p.steps          = (arguments["steps"]  as? Int) ?? 24
        if let c = arguments["cfg_scale"] as? Double { p.cfgScale = c }
        if let c = arguments["cfg_scale"] as? Int    { p.cfgScale = Double(c) }
        if let s = arguments["seed"] as? Int         { p.seed = Int64(s) }
        if let s = arguments["sampler"] as? String, let sm = SDSampler(rawValue: s) {
            p.sampler = sm
        }
        if p.prompt.trimmingCharacters(in: .whitespaces).isEmpty {
            return mcpError("prompt is required")
        }

        // Snapshot to identify our own result.
        let frozen = p
        let knownIDs: Set<UUID> = await MainActor.run {
            let ids = Set(gen.results.map(\.id))
            gen.generate(frozen)
            return ids
        }
        let deadline = Date().addingTimeInterval(600)
        var ours: ImageGenResult?
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let snap: (Bool, ImageGenResult?) = await MainActor.run {
                let r = gen.results.first { !knownIDs.contains($0.id) }
                return (gen.isGenerating, r)
            }
            if let r = snap.1 { ours = r }
            if !snap.0 && ours != nil { break }
            if !snap.0 && snap.1 == nil { break }
        }
        guard let r = ours else {
            return mcpError("generation produced no image")
        }
        // Embed the result inline so the caller can view it.
        let data = (try? Data(contentsOf: r.url)) ?? Data()
        var content: [[String: Any]] = []
        content.append(mcpText(
            "Image generated · \(p.width)×\(p.height) · \(p.steps) steps · seed \(p.seed)\nSaved to: \(r.url.path)"
        ))
        if !data.isEmpty {
            // Cap inline bytes at 12 MB to be safe with MCP framing.
            if data.count <= 12 * 1024 * 1024 {
                let mime = mimeForExt(r.url.pathExtension)
                content.append(mcpImage(data: data, mimeType: mime))
            } else {
                content.append(mcpText("(image too large to embed inline; \(data.count / 1024 / 1024) MB — see file path)"))
            }
        }
        return mcpResult(content)
    }
}

// MARK: - Edit image (Core Image preset application)

struct MCPEditImageTool: MCPHostTool {
    let name = "edit_image"
    let description = """
        Apply quick edits (presets, brightness, contrast, saturation, blur, sharpen,
        mono, invert) to an existing image file and save a copy. Returns the new
        image inline.
        """
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path":       ["type": "string", "description": "Absolute path to source image."],
            "preset":     ["type": "string", "description": "dramatic|lush|cool|warm|noir|faded|sharp"],
            "brightness": ["type": "number", "description": "-0.5 to +0.5"],
            "contrast":   ["type": "number", "description": "0.5 to 1.8 (1=identity)"],
            "saturation": ["type": "number", "description": "0 to 2 (1=identity)"],
            "sharpen":    ["type": "number", "description": "0 to 2"],
            "blur":       ["type": "number", "description": "0 to 30 pixels"],
            "mono":       ["type": "boolean"],
            "invert":     ["type": "boolean"]
        ],
        "required": ["path"]
    ]

    func run(arguments: [String: Any]) async -> [String: Any] {
        guard let path = arguments["path"] as? String, !path.isEmpty else {
            return mcpError("path is required")
        }
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return mcpError("no such file: \(expanded)")
        }
        let url = URL(fileURLWithPath: expanded)
        let saved: URL? = await MainActor.run {
            let editor = ImageEditor()
            editor.load(url: url)
            if let presetName = arguments["preset"] as? String,
               let preset = ImagePreset(rawValue: presetName) {
                preset.ops.forEach { editor.append($0) }
            }
            if let v = arguments["brightness"] as? Double { editor.append(.brightness(v)) }
            if let v = arguments["contrast"]   as? Double { editor.append(.contrast(v)) }
            if let v = arguments["saturation"] as? Double { editor.append(.saturation(v)) }
            if let v = arguments["sharpen"]    as? Double { editor.append(.sharpen(v)) }
            if let v = arguments["blur"]       as? Double { editor.append(.blur(v)) }
            if (arguments["mono"]   as? Bool) == true { editor.append(.mono) }
            if (arguments["invert"] as? Bool) == true { editor.append(.invert) }
            return editor.exportPNG()
        }
        guard let out = saved else {
            return mcpError("failed to render")
        }
        let data = (try? Data(contentsOf: out)) ?? Data()
        var content: [[String: Any]] = [mcpText("Edited → \(out.path)")]
        if !data.isEmpty, data.count <= 12 * 1024 * 1024 {
            content.append(mcpImage(data: data, mimeType: "image/png"))
        }
        return mcpResult(content)
    }
}

// MARK: - Generate video (returns path; videos are too big to embed)

struct MCPGenerateVideoTool: MCPHostTool {
    let name = "generate_video"
    let description = """
        Generate a short video clip from a text prompt using Mllama's stable-diffusion.cpp
        vid_gen mode (requires Wan2.x or LTX-2 model configured). Returns the saved
        file path plus the first-frame as an embedded image preview. May take several
        minutes.
        """
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "prompt":     ["type": "string"],
            "frames":     ["type": "integer", "default": 33],
            "fps":        ["type": "integer", "default": 24],
            "width":      ["type": "integer", "default": 832],
            "height":     ["type": "integer", "default": 480],
            "steps":      ["type": "integer", "default": 25],
            "init_image": ["type": "string", "description": "Optional first-frame image path for image-to-video."]
        ],
        "required": ["prompt"]
    ]

    private let _generator: @Sendable () -> VideoGenerator?

    init(generator: @escaping @Sendable () -> VideoGenerator?) {
        self._generator = generator
    }

    func run(arguments: [String: Any]) async -> [String: Any] {
        guard let gen = await MainActor.run(body: { _generator() }) else {
            return mcpError("video generator not available")
        }
        var p = VideoGenParams()
        p.prompt = (arguments["prompt"] as? String) ?? ""
        p.frames = (arguments["frames"] as? Int) ?? 33
        p.fps    = (arguments["fps"]    as? Int) ?? 24
        p.width  = (arguments["width"]  as? Int) ?? 832
        p.height = (arguments["height"] as? Int) ?? 480
        p.steps  = (arguments["steps"]  as? Int) ?? 25
        if let init_ = arguments["init_image"] as? String, !init_.isEmpty {
            p.initImagePath = (init_ as NSString).expandingTildeInPath
        }
        if p.prompt.trimmingCharacters(in: .whitespaces).isEmpty {
            return mcpError("prompt is required")
        }
        let frozen = p
        let knownIDs: Set<UUID> = await MainActor.run {
            let ids = Set(gen.results.map(\.id))
            gen.generate(frozen)
            return ids
        }
        let deadline = Date().addingTimeInterval(1800)
        var ours: VideoGenResult?
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let snap: (Bool, VideoGenResult?) = await MainActor.run {
                let r = gen.results.first { !knownIDs.contains($0.id) }
                return (gen.isGenerating, r)
            }
            if let r = snap.1 { ours = r }
            if !snap.0 && ours != nil { break }
            if !snap.0 && snap.1 == nil { break }
        }
        guard let r = ours else {
            return mcpError("video generation produced no file")
        }
        var content: [[String: Any]] = [
            mcpText("Video generated · \(p.frames) frames @ \(p.fps) fps · \(p.width)×\(p.height)\nSaved to: \(r.url.path)")
        ]
        if let thumb = r.thumbnailURL, let data = try? Data(contentsOf: thumb) {
            content.append(mcpImage(data: data, mimeType: "image/jpeg"))
        }
        return mcpResult(content)
    }
}

// MARK: - Search HuggingFace

struct MCPSearchHFTool: MCPHostTool {
    let name = "search_hf_models"
    let description = "Search the HuggingFace Hub. Returns a compact list of matching models."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query":  ["type": "string"],
            "task":   ["type": "string", "description": "text-to-image|image-to-image|text-to-video|text-generation"],
            "format": ["type": "string", "description": "gguf|safetensors|diffusers|any (default gguf)"],
            "limit":  ["type": "integer", "default": 20]
        ],
        "required": ["query"]
    ]

    func run(arguments: [String: Any]) async -> [String: Any] {
        var f = HFFilters()
        f.query = (arguments["query"] as? String) ?? ""
        if let t = arguments["task"]   as? String, let tt = HFTask(rawValue: t)   { f.task = tt }
        if let fmt = arguments["format"] as? String, let ff = HFFormat(rawValue: fmt) { f.format = ff }
        let limit = min(max((arguments["limit"] as? Int) ?? 20, 1), 100)
        do {
            let models = try await HuggingFaceClient.shared.search(filters: f, limit: limit)
            var lines: [String] = ["Found \(models.count) models:"]
            for m in models {
                lines.append("• \(m.id)  [\(m.pipelineTag ?? "?")]  ⬇\(m.downloads) ♥\(m.likes)")
            }
            return mcpResult([mcpText(lines.joined(separator: "\n"))])
        } catch {
            return mcpError(error.localizedDescription)
        }
    }
}

// MARK: - List local media library

struct MCPListMediaTool: MCPHostTool {
    let name = "list_media"
    let description = "List recently generated images and videos in this app's library, with prompts and paths."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "kind":  ["type": "string", "description": "image|video (omit for both)"],
            "limit": ["type": "integer", "default": 20]
        ]
    ]

    func run(arguments: [String: Any]) async -> [String: Any] {
        let kind = arguments["kind"] as? String
        let limit = min(max((arguments["limit"] as? Int) ?? 20, 1), 100)
        let assets: [MediaAsset] = await MainActor.run {
            var a = MediaLibrary.shared.assets
            if let k = kind, let mk = MediaKind(rawValue: k) {
                a = a.filter { $0.kind == mk }
            }
            return Array(a.prefix(limit))
        }
        if assets.isEmpty {
            return mcpResult([mcpText("Library is empty.")])
        }
        var lines: [String] = []
        for a in assets {
            let p = a.prompt.isEmpty ? "(no prompt)" : String(a.prompt.prefix(140))
            lines.append("• [\(a.kind.rawValue)] \(a.url.path)\n   \(p)")
        }
        return mcpResult([mcpText(lines.joined(separator: "\n"))])
    }
}

// MARK: - Get media file (return existing asset inline as base64)

struct MCPGetMediaFileTool: MCPHostTool {
    let name = "get_media_file"
    let description = """
        Return an existing image file inline (base64) so a remote agent can view
        what's already been generated. For videos, returns the thumbnail.
        """
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": ["type": "string", "description": "Absolute path to image or video file."]
        ],
        "required": ["path"]
    ]

    func run(arguments: [String: Any]) async -> [String: Any] {
        guard let path = arguments["path"] as? String, !path.isEmpty else {
            return mcpError("path is required")
        }
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard FileManager.default.fileExists(atPath: expanded) else {
            return mcpError("no such file: \(expanded)")
        }
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "tiff"].contains(ext) {
            guard let data = try? Data(contentsOf: url) else {
                return mcpError("could not read file")
            }
            if data.count > 12 * 1024 * 1024 {
                return mcpResult([mcpText("File is \(data.count / 1024 / 1024) MB — too large to embed inline. Path: \(url.path)")])
            }
            return mcpResult([
                mcpText("File: \(url.path) (\(data.count) bytes)"),
                mcpImage(data: data, mimeType: mimeForExt(ext))
            ])
        }
        // For videos, attach a thumbnail if one exists in the library.
        let asset: MediaAsset? = await MainActor.run {
            MediaLibrary.shared.assets.first { $0.url.path == expanded }
        }
        if let asset, let thumb = asset.thumbnailURL,
           let thumbData = try? Data(contentsOf: thumb) {
            return mcpResult([
                mcpText("Video file: \(url.path) (thumbnail attached)"),
                mcpImage(data: thumbData, mimeType: "image/jpeg")
            ])
        }
        return mcpResult([mcpText("File: \(url.path) — no inline preview available.")])
    }
}

// MARK: - Server info

struct MCPServerInfoTool: MCPHostTool {
    let name = "server_info"
    let description = "Return a snapshot of Mllama's hardware, loaded models, and engine status."
    let inputSchema: [String: Any] = [
        "type": "object", "properties": [:]
    ]

    func run(arguments: [String: Any]) async -> [String: Any] {
        let info: String = await MainActor.run {
            let hw = SystemInfo.detect()
            let llmPath = UserDefaults.standard.string(forKey: Keys.modelPath) ?? "(none)"
            let imgPath = UserDefaults.standard.string(forKey: SDKeys.imageModelPath) ?? "(none)"
            let vidPath = UserDefaults.standard.string(forKey: SDKeys.videoModelPath) ?? "(none)"
            return """
            Host: \(hw.chipName) · \(Int(hw.totalRamGB)) GB RAM · \(hw.gpuCores)c GPU
            Disk free: \(Int(hw.diskFreeGB)) GB
            LLM model: \((llmPath as NSString).lastPathComponent)
            Image model: \((imgPath as NSString).lastPathComponent)
            Video model: \((vidPath as NSString).lastPathComponent)
            """
        }
        return mcpResult([mcpText(info)])
    }
}

// MARK: - Mime helper

private func mimeForExt(_ ext: String) -> String {
    switch ext.lowercased() {
    case "png":  return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif":  return "image/gif"
    case "webp": return "image/webp"
    case "tiff": return "image/tiff"
    default:     return "application/octet-stream"
    }
}
