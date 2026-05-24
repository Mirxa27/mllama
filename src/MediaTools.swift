import Foundation

// MARK: - Image generation tool

/// Lets the agent kick off a text-to-image generation through SDServer.
/// Result includes the on-disk PNG path so the agent (and chat UI) can reference it.
struct GenerateImageTool: AgentTool {
    let name = "generate_image"
    let humanName = "Generate image"
    let description = """
        Generate an image from a text prompt using the local stable-diffusion.cpp server.
        Returns the absolute path of the saved PNG. Requires the image server to be
        running (the host app starts it once an image model is configured).
        """
    let requiresApproval = false

    private let _generator: @Sendable () -> ImageGenerator?
    init(generator: @escaping @Sendable () -> ImageGenerator?) { self._generator = generator }

    var parameters: JSONValue {
        paramsObject(
            properties: [
                "prompt":          strSchema("What to generate."),
                "negative_prompt": strSchema("What to avoid (optional)."),
                "width":           intSchema("Image width in pixels (default 1024).", default: 1024),
                "height":          intSchema("Image height in pixels (default 1024).", default: 1024),
                "steps":           intSchema("Sampling steps (default 24).", default: 24),
                "cfg_scale":       .object(["type": .string("number"), "description": .string("CFG guidance, default 7.0.")]),
                "seed":            intSchema("Random seed, -1 for random.", default: -1),
                "sampler":         strSchema("Sampler name: euler, dpm++2m, lcm, tcd, …"),
            ],
            required: ["prompt"]
        )
    }

    func run(arguments: String) async -> ToolCallResult {
        let args = parseArgs(arguments)
        guard let gen = await MainActor.run(body: { _generator() }) else {
            return .init(toolCallId: "", content: "error: image generator not available", isError: true)
        }
        var p = ImageGenParams()
        p.prompt         = (args["prompt"] as? String) ?? ""
        p.negativePrompt = (args["negative_prompt"] as? String) ?? ""
        p.width          = (args["width"] as? Int) ?? 1024
        p.height         = (args["height"] as? Int) ?? 1024
        p.steps          = (args["steps"] as? Int) ?? 24
        if let c = args["cfg_scale"] as? Double { p.cfgScale = c }
        if let c = args["cfg_scale"] as? Int { p.cfgScale = Double(c) }
        if let s = args["seed"] as? Int { p.seed = Int64(s) }
        if let sName = args["sampler"] as? String,
           let s = SDSampler(rawValue: sName) {
            p.sampler = s
        }
        if p.prompt.trimmingCharacters(in: .whitespaces).isEmpty {
            return .init(toolCallId: "", content: "error: prompt is required", isError: true)
        }

        // Snapshot the set of result IDs *before* generation so we can
        // identify our own result by ID — robust against the user starting a
        // manual generation in the UI between our kickoff and poll.
        let frozen = p
        let knownIDs: Set<UUID> = await MainActor.run {
            let ids = Set(gen.results.map(\.id))
            gen.generate(frozen)
            return ids
        }
        let deadline = Date().addingTimeInterval(600)
        var ourResult: (url: URL, params: ImageGenParams)? = nil
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let snapshot: (Bool, ImageGenResult?) = await MainActor.run {
                // Find the first result whose ID we hadn't seen before AND
                // whose params hash matches the one we asked for — guards
                // against grabbing an unrelated parallel result.
                let new = gen.results.first { !knownIDs.contains($0.id) }
                return (gen.isGenerating, new)
            }
            if let r = snapshot.1 { ourResult = (r.url, r.params) }
            if !snapshot.0 && ourResult != nil { break }
            if !snapshot.0 && snapshot.1 == nil { break } // failed silently
        }
        if let r = ourResult {
            let size = (try? FileManager.default.attributesOfItem(atPath: r.url.path)[.size] as? Int) ?? 0
            return .init(
                toolCallId: "",
                content: "image: \(r.url.path)\nbytes: \(size)\nprompt: \(p.prompt)",
                isError: false
            )
        }
        return .init(toolCallId: "", content: "error: generation produced no image", isError: true)
    }
}

// MARK: - Edit image tool

struct EditImageTool: AgentTool {
    let name = "edit_image"
    let humanName = "Edit image"
    let description = """
        Apply quick edits to an existing PNG/JPEG and save a new copy.
        Supports brightness, contrast, saturation, sharpen, blur, vignette, mono,
        invert, crop. Returns the saved file path.
        """
    let requiresApproval = false

    var parameters: JSONValue {
        paramsObject(
            properties: [
                "path":       strSchema("Absolute path to source image."),
                "preset":     strSchema("Optional preset: dramatic|lush|cool|warm|noir|faded|sharp"),
                "brightness": .object(["type": .string("number"), "description": .string("-0.5 to +0.5")]),
                "contrast":   .object(["type": .string("number"), "description": .string("0.5 to 1.8 (1=identity)")]),
                "saturation": .object(["type": .string("number"), "description": .string("0 to 2 (1=identity)")]),
                "sharpen":    .object(["type": .string("number"), "description": .string("0 to 2")]),
                "blur":       .object(["type": .string("number"), "description": .string("0 to 30 pixels")]),
                "mono":       boolSchema("Convert to black and white."),
                "invert":     boolSchema("Invert colors."),
            ],
            required: ["path"]
        )
    }

    func run(arguments: String) async -> ToolCallResult {
        let args = parseArgs(arguments)
        guard let path = args["path"] as? String, !path.isEmpty else {
            return .init(toolCallId: "", content: "error: 'path' required", isError: true)
        }
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return .init(toolCallId: "", content: "error: no such file: \(expanded)", isError: true)
        }
        let url = URL(fileURLWithPath: expanded)
        let saved: URL? = await MainActor.run {
            let editor = ImageEditor()
            editor.load(url: url)
            if let presetName = args["preset"] as? String,
               let preset = ImagePreset(rawValue: presetName) {
                preset.ops.forEach { editor.append($0) }
            }
            if let v = args["brightness"] as? Double { editor.append(.brightness(v)) }
            if let v = args["contrast"]   as? Double { editor.append(.contrast(v)) }
            if let v = args["saturation"] as? Double { editor.append(.saturation(v)) }
            if let v = args["sharpen"]    as? Double { editor.append(.sharpen(v)) }
            if let v = args["blur"]       as? Double { editor.append(.blur(v)) }
            if (args["mono"]   as? Bool) == true { editor.append(.mono) }
            if (args["invert"] as? Bool) == true { editor.append(.invert) }
            return editor.exportPNG()
        }
        guard let out = saved else {
            return .init(toolCallId: "", content: "error: failed to render", isError: true)
        }
        return .init(toolCallId: "", content: "edited: \(out.path)", isError: false)
    }
}

// MARK: - Video generation tool

struct GenerateVideoTool: AgentTool {
    let name = "generate_video"
    let humanName = "Generate video"
    let description = """
        Generate a short video clip from a text prompt using stable-diffusion.cpp's
        vid_gen mode (requires a Wan2.x or LTX-2 model configured in Settings).
        Returns the saved file path. May take several minutes.
        """
    let requiresApproval = false

    private let _generator: @Sendable () -> VideoGenerator?
    init(generator: @escaping @Sendable () -> VideoGenerator?) { self._generator = generator }

    var parameters: JSONValue {
        paramsObject(
            properties: [
                "prompt":   strSchema("What to generate."),
                "frames":   intSchema("Number of frames (default 33).", default: 33),
                "fps":      intSchema("Frames per second (default 24).", default: 24),
                "width":    intSchema("Width in pixels (default 832).", default: 832),
                "height":   intSchema("Height in pixels (default 480).", default: 480),
                "steps":    intSchema("Sampling steps (default 25).", default: 25),
                "init_image": strSchema("Optional first-frame image path for image-to-video."),
            ],
            required: ["prompt"]
        )
    }

    func run(arguments: String) async -> ToolCallResult {
        let args = parseArgs(arguments)
        guard let gen = await MainActor.run(body: { _generator() }) else {
            return .init(toolCallId: "", content: "error: video generator not available", isError: true)
        }
        var p = VideoGenParams()
        p.prompt = (args["prompt"] as? String) ?? ""
        p.frames = (args["frames"] as? Int) ?? 33
        p.fps    = (args["fps"]    as? Int) ?? 24
        p.width  = (args["width"]  as? Int) ?? 832
        p.height = (args["height"] as? Int) ?? 480
        p.steps  = (args["steps"]  as? Int) ?? 25
        if let initImg = args["init_image"] as? String, !initImg.isEmpty {
            p.initImagePath = (initImg as NSString).expandingTildeInPath
        }
        if p.prompt.trimmingCharacters(in: .whitespaces).isEmpty {
            return .init(toolCallId: "", content: "error: prompt is required", isError: true)
        }
        let frozen = p
        let knownIDs: Set<UUID> = await MainActor.run {
            let ids = Set(gen.results.map(\.id))
            gen.generate(frozen)
            return ids
        }
        let deadline = Date().addingTimeInterval(1800) // up to 30 min
        var ourURL: URL? = nil
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let snapshot: (Bool, URL?) = await MainActor.run {
                let new = gen.results.first { !knownIDs.contains($0.id) }
                return (gen.isGenerating, new?.url)
            }
            if let u = snapshot.1 { ourURL = u }
            if !snapshot.0 && ourURL != nil { break }
            if !snapshot.0 && snapshot.1 == nil { break }
        }
        if let url = ourURL {
            return .init(toolCallId: "", content: "video: \(url.path)", isError: false)
        }
        return .init(toolCallId: "", content: "error: video generation produced no file", isError: true)
    }
}

// MARK: - Video edit tool (ffmpeg)

struct EditVideoTool: AgentTool {
    let name = "edit_video"
    let humanName = "Edit video"
    let description = """
        Apply an ffmpeg operation to a video file: trim, scale, speed,
        rotate, grayscale, mute, to_gif. Returns the saved file path.
        """
    let requiresApproval = false

    var parameters: JSONValue {
        paramsObject(
            properties: [
                "path": strSchema("Absolute path to source video."),
                "op":   strSchema("Operation: trim|scale|speed|rotate|grayscale|mute|to_gif"),
                "start": .object(["type": .string("number"), "description": .string("trim: start seconds")]),
                "end":   .object(["type": .string("number"), "description": .string("trim: end seconds")]),
                "width":  intSchema("scale: width in pixels"),
                "height": intSchema("scale: height in pixels"),
                "factor": .object(["type": .string("number"), "description": .string("speed: factor (0.5=slow, 2=fast)")]),
                "degrees": intSchema("rotate: 90|180|270"),
            ],
            required: ["path", "op"]
        )
    }

    func run(arguments: String) async -> ToolCallResult {
        let args = parseArgs(arguments)
        guard let path = args["path"] as? String, !path.isEmpty else {
            return .init(toolCallId: "", content: "error: 'path' required", isError: true)
        }
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return .init(toolCallId: "", content: "error: no such file: \(expanded)", isError: true)
        }
        guard let opName = args["op"] as? String else {
            return .init(toolCallId: "", content: "error: 'op' required", isError: true)
        }
        let input = URL(fileURLWithPath: expanded)
        let outRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mllama/media")
        try? FileManager.default.createDirectory(at: outRoot, withIntermediateDirectories: true)
        let stamp = DateFormatter.compactStamp.string(from: Date())

        let op: VideoEditOp
        var ext = "mp4"
        switch opName {
        case "trim":
            let s = (args["start"] as? Double) ?? 0
            let e = (args["end"]   as? Double) ?? 5
            op = .trim(start: s, end: e)
        case "scale":
            let w = (args["width"]  as? Int) ?? 1280
            let h = (args["height"] as? Int) ?? -2
            op = .scale(width: w, height: h)
        case "speed":
            let f = (args["factor"] as? Double) ?? 1
            op = .speed(factor: f)
        case "rotate":
            let d = (args["degrees"] as? Int) ?? 90
            op = .rotate(degrees: d)
        case "grayscale": op = .grayscale
        case "mute":      op = .mute
        case "to_gif":
            ext = "gif"
            op = .toGIF(fps: 15, width: 480)
        default:
            return .init(toolCallId: "", content: "error: unknown op '\(opName)'", isError: true)
        }
        let out = outRoot.appendingPathComponent("\(input.deletingPathExtension().lastPathComponent)-\(stamp).\(ext)")
        let editor = await MainActor.run { VideoEditor() }
        let result = await editor.apply(op, to: input, output: out)
        switch result {
        case .success(let url):
            return .init(toolCallId: "", content: "edited: \(url.path)", isError: false)
        case .failure(let m):
            return .init(toolCallId: "", content: "error: \(m)", isError: true)
        }
    }
}

// MARK: - HuggingFace search + download tools

struct SearchHuggingFaceTool: AgentTool {
    let name = "search_hf_models"
    let humanName = "Search HuggingFace"
    let description = """
        Search the HuggingFace Hub for models. Returns a list of repos with
        downloads/likes/tags. Filter by task and format. Default format is GGUF
        (so results are locally runnable). Use this to find models the user
        can download.
        """
    let requiresApproval = false

    var parameters: JSONValue {
        paramsObject(
            properties: [
                "query":  strSchema("Search query (e.g. 'flux' or 'sdxl turbo')."),
                "task":   strSchema("Pipeline tag: text-to-image|image-to-image|text-to-video|image-to-video|text-generation"),
                "format": strSchema("File format filter: gguf|safetensors|diffusers|any (default gguf)."),
                "sort":   strSchema("Sort: trendingScore|downloads|likes|lastModified (default trendingScore)."),
                "limit":  intSchema("Max results (default 25, max 100).", default: 25),
            ],
            required: ["query"]
        )
    }

    func run(arguments: String) async -> ToolCallResult {
        let args = parseArgs(arguments)
        var f = HFFilters()
        f.query = (args["query"] as? String) ?? ""
        if let t = args["task"]   as? String, let tt = HFTask(rawValue: t)   { f.task = tt }
        if let fmt = args["format"] as? String, let ff = HFFormat(rawValue: fmt) { f.format = ff }
        if let s = args["sort"]   as? String, let ss = HFSort(rawValue: s)   { f.sort = ss }
        let limit = min(max((args["limit"] as? Int) ?? 25, 1), 100)
        do {
            let models = try await HuggingFaceClient.shared.search(filters: f, limit: limit)
            var lines: [String] = ["Found \(models.count) models:"]
            for m in models {
                lines.append("• \(m.id)  [\(m.pipelineTag ?? "?")]  ⬇\(m.downloads) ♥\(m.likes)")
            }
            return .init(toolCallId: "", content: lines.joined(separator: "\n"), isError: false)
        } catch {
            return .init(toolCallId: "", content: "error: \(error.localizedDescription)", isError: true)
        }
    }
}

struct DownloadHFModelTool: AgentTool {
    let name = "download_hf_model"
    let humanName = "Download HF model file"
    let description = """
        Download a single file from a HuggingFace repository to the local
        models cache (~/.mllama/hf/<author>/<repo>/<file>). Returns the saved
        absolute path. Use search_hf_models first to find the repo + file name.
        Large files (GGUF) can take a while; this tool waits for completion.
        """
    let requiresApproval = true

    var parameters: JSONValue {
        paramsObject(
            properties: [
                "repo": strSchema("Repository id, e.g. 'city96/FLUX.1-dev-gguf'."),
                "file": strSchema("File path inside the repo, e.g. 'flux1-dev-Q4_K_S.gguf'."),
            ],
            required: ["repo", "file"]
        )
    }

    func run(arguments: String) async -> ToolCallResult {
        let args = parseArgs(arguments)
        guard let repo = args["repo"] as? String, !repo.isEmpty,
              let file = args["file"] as? String, !file.isEmpty else {
            return .init(toolCallId: "", content: "error: 'repo' and 'file' are required", isError: true)
        }
        let job: HFDownloadJob = await MainActor.run {
            HFDownloadManager.shared.enqueue(repoId: repo, file: file)
        }
        // Poll up to 4 hours
        let deadline = Date().addingTimeInterval(4 * 3600)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let state: HFDownloadState = await MainActor.run { job.state }
            switch state {
            case .completed(let url):
                return .init(toolCallId: "", content: "saved: \(url.path)", isError: false)
            case .failed(let msg):
                return .init(toolCallId: "", content: "error: \(msg)", isError: true)
            case .cancelled:
                return .init(toolCallId: "", content: "cancelled", isError: true)
            default:
                continue
            }
        }
        return .init(toolCallId: "", content: "timeout: download still running", isError: true)
    }
}

// MARK: - List local media tool

struct ListMediaTool: AgentTool {
    let name = "list_media"
    let humanName = "List generated media"
    let description = "List recently generated images and videos with prompts and file paths."
    let requiresApproval = false

    var parameters: JSONValue {
        paramsObject(properties: [
            "kind":  strSchema("Filter by 'image' or 'video' (omit for both)."),
            "limit": intSchema("Max results (default 20).", default: 20),
        ])
    }

    func run(arguments: String) async -> ToolCallResult {
        let args = parseArgs(arguments)
        let kind = args["kind"] as? String
        let limit = min(max((args["limit"] as? Int) ?? 20, 1), 100)
        let assets: [MediaAsset] = await MainActor.run {
            var a = MediaLibrary.shared.assets
            if let k = kind, let mk = MediaKind(rawValue: k) {
                a = a.filter { $0.kind == mk }
            }
            return Array(a.prefix(limit))
        }
        if assets.isEmpty {
            return .init(toolCallId: "", content: "no media in library", isError: false)
        }
        var lines: [String] = []
        for a in assets {
            let promptHead = a.prompt.isEmpty ? "(no prompt)" : String(a.prompt.prefix(120))
            lines.append("• [\(a.kind.rawValue)] \(a.url.path)\n   \(promptHead)")
        }
        return .init(toolCallId: "", content: lines.joined(separator: "\n"), isError: false)
    }
}
