import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct SettingsView: View {
    @AppStorage(Keys.modelPath)    private var modelPath: String = ""
    @AppStorage(Keys.mmprojPath)   private var mmprojPath: String = ""
    @AppStorage(Keys.port)         private var port: Int = 8080
    @AppStorage(Keys.contextSize)  private var contextSize: Int = 0   // 0 = model max
    @AppStorage(Keys.ngl)          private var ngl: Int = 99
    @AppStorage(Keys.host)         private var host: String = "127.0.0.1"
    @AppStorage(Keys.extraArgs)    private var extraArgs: String = ""
    @AppStorage(Keys.customDirs)   private var customDirsJSON: String = "[]"
    @AppStorage(Keys.flashAttn)    private var flashAttn: Bool = true
    @AppStorage(Keys.mlock)        private var mlock: Bool = true
    @AppStorage(Keys.threads)      private var threads: Int = 8
    @AppStorage(Keys.systemPrompt) private var systemPrompt: String = defaultSystemPrompt
    @AppStorage(Keys.autoCompact)  private var autoCompact: Bool = true

    @AppStorage(VoiceKeys.autoSpeak)       private var autoSpeak: Bool = false
    @AppStorage(VoiceKeys.voiceIdentifier) private var voiceIdentifier: String = ""
    @AppStorage(VoiceKeys.voiceRate)       private var voiceRate: Double = 0
    @AppStorage(VoiceKeys.preferOnDevice)  private var preferOnDevice: Bool = true
    @AppStorage(VoiceKeys.sttEngine)       private var sttEngine: String = "whisper"
    @AppStorage(VoiceKeys.whisperLanguage) private var whisperLanguage: String = "auto"
    @AppStorage(VoiceKeys.recognizerLocale) private var recognizerLocale: String = ""

    @EnvironmentObject var server: ServerController
    @EnvironmentObject var library: ModelLibrary
    @EnvironmentObject var mcp: MCPManager
    @EnvironmentObject var tts: SpeechSynthesizer
    @EnvironmentObject var sdServer: SDServerController
    @EnvironmentObject var catalog: UnifiedModelCatalog
    @EnvironmentObject var downloads: HFDownloadManager
    @EnvironmentObject var imageGen: ImageGenerator
    @EnvironmentObject var videoGen: VideoGenerator
    @State private var smokeTestStatus: String = ""
    @State private var smokeTestRunning: Bool = false

    // SD-related defaults
    @AppStorage(SDKeys.imageModelPath)  private var sdModelPath: String = ""
    @AppStorage(SDKeys.vaePath)         private var sdVaePath: String = ""
    @AppStorage(SDKeys.clipLPath)       private var sdClipLPath: String = ""
    @AppStorage(SDKeys.clipGPath)       private var sdClipGPath: String = ""
    @AppStorage(SDKeys.t5Path)          private var sdT5Path: String = ""
    @AppStorage(SDKeys.loraDir)         private var sdLoraDir: String = ""
    @AppStorage(SDKeys.binaryOverride)  private var sdBinaryOverride: String = ""
    @AppStorage(SDKeys.cliOverride)     private var sdCliOverride: String = ""
    @AppStorage(SDKeys.port)            private var sdPort: Int = 1235
    @AppStorage(SDKeys.flashAttn)       private var sdFlashAttn: Bool = true
    @AppStorage(SDKeys.vaeTiling)       private var sdVaeTiling: Bool = true
    @AppStorage(SDKeys.vaeOnCpu)        private var sdVaeOnCpu: Bool = false
    @AppStorage(SDKeys.clipOnCpu)       private var sdClipOnCpu: Bool = false
    @AppStorage(SDKeys.threads)         private var sdThreads: Int = 0
    @AppStorage(SDKeys.outputRoot)      private var sdOutputRoot: String = ""
    @AppStorage(SDKeys.videoModelPath)  private var vidModelPath: String = ""
    @AppStorage(SDKeys.videoVaePath)    private var vidVaePath: String = ""
    @AppStorage(SDKeys.videoT5Path)     private var vidT5Path: String = ""

    // HF-related defaults
    @AppStorage(HFKeys.token)          private var hfToken: String = ""
    @AppStorage(HFKeys.downloadsRoot)  private var hfDownloadsRoot: String = ""

    var body: some View {
        TabView {
            modelTab.tabItem { Label("LLM", systemImage: "shippingbox") }
            imageGenTab.tabItem { Label("Image Gen", systemImage: "photo.artframe") }
            videoGenTab.tabItem { Label("Video Gen", systemImage: "film.stack") }
            huggingFaceTab.tabItem { Label("HuggingFace", systemImage: "key") }
            serverTab.tabItem { Label("Performance", systemImage: "speedometer") }
            voiceTab.tabItem { Label("Voice", systemImage: "waveform") }
            agentTab.tabItem { Label("Agent", systemImage: "circle.hexagonpath") }
            EvolutionSettingsView()
                .tabItem { Label("Evolution", systemImage: "wand.and.stars") }
            mcpTab.tabItem { Label("MCP", systemImage: "bolt.horizontal") }
        }
        .padding()
        .background(VisualEffectBackground().ignoresSafeArea())
    }

    // MARK: Image Gen tab

    private var imageGenTab: some View {
        Form {
            Section("Diffusion model") {
                pickerRow(title: "Image model (.gguf or .safetensors)",
                          path: sdModelPath, placeholder: "Not set",
                          onPick: { pickFile(.image, into: $sdModelPath) },
                          onClear: sdModelPath.isEmpty ? nil : { sdModelPath = "" })
                Text("Recommended: Flux GGUF (city96/FLUX.1-dev-gguf) or SDXL GGUF. Download via the Models tab.")
                    .font(.caption2).foregroundStyle(Theme.textFaint)
                if !sdModelPath.isEmpty {
                    let family = DiffusionFamily.detect(path: sdModelPath)
                    if family != .unknown {
                        Label("Detected family: \(family.label)", systemImage: "sparkles")
                            .font(.caption).foregroundStyle(Theme.violet)
                    }
                }
            }
            companionsSettingsSection()
            Section("Submodels (optional, separate from main checkpoint)") {
                pickerRow(title: "VAE",
                          path: sdVaePath, placeholder: "Embedded in checkpoint",
                          onPick: { pickFile(.weights, into: $sdVaePath) },
                          onClear: sdVaePath.isEmpty ? nil : { sdVaePath = "" })
                pickerRow(title: "CLIP-L encoder",
                          path: sdClipLPath, placeholder: "Embedded",
                          onPick: { pickFile(.weights, into: $sdClipLPath) },
                          onClear: sdClipLPath.isEmpty ? nil : { sdClipLPath = "" })
                pickerRow(title: "CLIP-G encoder",
                          path: sdClipGPath, placeholder: "Embedded",
                          onPick: { pickFile(.weights, into: $sdClipGPath) },
                          onClear: sdClipGPath.isEmpty ? nil : { sdClipGPath = "" })
                pickerRow(title: "T5-XXL encoder",
                          path: sdT5Path, placeholder: "Embedded",
                          onPick: { pickFile(.weights, into: $sdT5Path) },
                          onClear: sdT5Path.isEmpty ? nil : { sdT5Path = "" })
                pickerRow(title: "LoRA directory",
                          path: sdLoraDir, placeholder: "Not set",
                          onPick: { pickFolder(into: $sdLoraDir) },
                          onClear: sdLoraDir.isEmpty ? nil : { sdLoraDir = "" })
            }
            Section("sd-server binary") {
                pickerRow(title: "sd-server binary",
                          path: sdBinaryOverride, placeholder: "Auto (bundled / Homebrew)",
                          onPick: { pickFile(.exec, into: $sdBinaryOverride) },
                          onClear: sdBinaryOverride.isEmpty ? nil : { sdBinaryOverride = "" })
                Text("If not bundled, build from https://github.com/leejet/stable-diffusion.cpp with `cmake -DSD_METAL=ON -DSD_BUILD_SERVER=ON`.")
                    .font(.caption2).foregroundStyle(Theme.textFaint)
                HStack {
                    LabeledContent("Port") {
                        TextField("1235", value: $sdPort, format: .number.grouping(.never)).frame(width: 80)
                    }
                    Spacer()
                }
            }
            Section("Apple Silicon tuning") {
                Toggle("Flash attention (--fa --diffusion-fa)", isOn: $sdFlashAttn).tint(Theme.violet)
                Toggle("VAE tiling (saves VRAM)", isOn: $sdVaeTiling).tint(Theme.violet)
                Toggle("VAE on CPU (for low-RAM Macs)", isOn: $sdVaeOnCpu).tint(Theme.violet)
                Toggle("CLIP on CPU (for low-RAM Macs)", isOn: $sdClipOnCpu).tint(Theme.violet)
                HStack {
                    LabeledContent("Threads") {
                        TextField("auto", value: $sdThreads, format: .number.grouping(.never)).frame(width: 80)
                    }
                }
            }
            Section("Output") {
                pickerRow(title: "Output directory",
                          path: sdOutputRoot, placeholder: "~/.mllama/media",
                          onPick: { pickFolder(into: $sdOutputRoot) },
                          onClear: sdOutputRoot.isEmpty ? nil : { sdOutputRoot = "" })
            }
            Section {
                HStack {
                    Button("Apply & Restart Image Server") { sdServer.restart() }
                        .keyboardShortcut(.defaultAction)
                    if case .running = sdServer.status {
                        Label("Running on port \(sdServer.runtimePort)", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Theme.mint).font(.caption)
                    } else if case .failed(let m) = sdServer.status {
                        Label(m, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.coral).font(.caption).lineLimit(2)
                    }
                }
            }
            Section("Smoke test") {
                HStack(spacing: 8) {
                    Button {
                        runImageSmokeTest()
                    } label: {
                        Label(smokeTestRunning ? "Running…" : "Test image generation",
                              systemImage: smokeTestRunning ? "hourglass" : "checkmark.circle")
                    }
                    .disabled(smokeTestRunning || sdModelPath.isEmpty)
                    if smokeTestRunning {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                if !smokeTestStatus.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: smokeTestSymbol)
                            .foregroundStyle(smokeTestColor)
                            .font(.caption)
                            .accessibilityHidden(true)
                        Text(smokeTestStatusDisplay)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .lineLimit(3)
                        Spacer()
                    }
                }
                Text("Generates a tiny 256×256 / 4-step test image to verify the whole pipeline works. ~10 seconds on M-series.")
                    .font(.caption2).foregroundStyle(Theme.textFaint)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Smoke test runner

    /// Derives the SF Symbol used in the smoke-test result line. Replaces
    /// ASCII ✓/✗ prefixes with a proper icon for screen-reader users and
    /// to match Apple's status-row idiom.
    private var smokeTestSymbol: String {
        if smokeTestStatus.hasPrefix("✓") { return "checkmark.seal.fill" }
        if smokeTestStatus.hasPrefix("✗") { return "xmark.octagon.fill" }
        return "info.circle"
    }
    private var smokeTestColor: Color {
        if smokeTestStatus.hasPrefix("✓") { return Theme.mint }
        if smokeTestStatus.hasPrefix("✗") { return Theme.coral }
        return Theme.cyan
    }
    /// Strip the legacy ASCII prefix character — the SF Symbol now carries the meaning.
    private var smokeTestStatusDisplay: String {
        var s = smokeTestStatus
        if s.hasPrefix("✓ ") || s.hasPrefix("✗ ") {
            s = String(s.dropFirst(2))
        }
        return s
    }

    private func runImageSmokeTest() {
        smokeTestRunning = true
        smokeTestStatus = "Submitting request to sd-server…"
        let family = sdModelPath.isEmpty ? .unknown : DiffusionFamily.detect(path: sdModelPath)
        var params = ImageGenParams()
        // Small dims + low steps = fast smoke test.
        params.prompt = "a single red apple on a white background, studio lighting"
        params.negativePrompt = ""
        params.width = 256
        params.height = 256
        params.steps = family == .flux ? 4 : 8
        let d = family.defaults
        params.cfgScale = d.cfgScale
        params.guidance = d.guidance
        params.sampler = d.sampler
        params.scheduler = d.scheduler
        params.seed = 42

        // If the server is stopped, start it first (mirrors the ImageStudio flow).
        if case .stopped = sdServer.status { sdServer.start() }
        if case .failed = sdServer.status   { sdServer.restart() }

        // Snapshot of results *before* we submit so we can identify our own
        // generation. Both this snapshot and the subsequent `generate(...)`
        // call run synchronously on the main actor, so they can't race with
        // anything mutating `imageGen.results`. If a user manually triggers
        // a parallel generation that completes before ours, that result is
        // still NOT in `beforeIDs` and the smoke-test loop would pick it up
        // as "ours" — acceptable because the smoke test is user-initiated
        // and would only ever overlap a manual run if the user is testing
        // a misconfiguration.
        let beforeIDs = Set(imageGen.results.map(\.id))
        Task { @MainActor in
            // Wait up to 60s for the server to be ready.
            let serverDeadline = Date().addingTimeInterval(60)
            while Date() < serverDeadline {
                if case .running = sdServer.status { break }
                if case .failed(let m) = sdServer.status {
                    smokeTestStatus = "✗ Server failed: \(m)"
                    smokeTestRunning = false
                    return
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            guard case .running = sdServer.status else {
                smokeTestStatus = "✗ Server didn't become ready in 60s"
                smokeTestRunning = false
                return
            }
            smokeTestStatus = "Generating test image…"
            imageGen.generate(params)
            // Wait up to 5 minutes for a result.
            let resultDeadline = Date().addingTimeInterval(300)
            while Date() < resultDeadline {
                if let r = imageGen.results.first(where: { !beforeIDs.contains($0.id) }) {
                    smokeTestStatus = "✓ Success — saved \((r.url.lastPathComponent)) in \(String(format: "%.1fs", r.elapsedSeconds))"
                    smokeTestRunning = false
                    return
                }
                if let err = imageGen.lastError, !imageGen.isGenerating {
                    smokeTestStatus = "✗ \(err)"
                    smokeTestRunning = false
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            smokeTestStatus = "✗ Timed out after 5 minutes"
            smokeTestRunning = false
        }
    }

    // MARK: Video Gen tab

    private var videoGenTab: some View {
        Form {
            Section("Diffusion model") {
                pickerRow(title: "Video model (Wan2.x / LTX-2)",
                          path: vidModelPath, placeholder: "Not set",
                          onPick: { pickFile(.weights, into: $vidModelPath) },
                          onClear: vidModelPath.isEmpty ? nil : { vidModelPath = "" })
                pickerRow(title: "Video VAE",
                          path: vidVaePath, placeholder: "Not set",
                          onPick: { pickFile(.weights, into: $vidVaePath) },
                          onClear: vidVaePath.isEmpty ? nil : { vidVaePath = "" })
                pickerRow(title: "T5-XXL encoder",
                          path: vidT5Path, placeholder: "Not set",
                          onPick: { pickFile(.weights, into: $vidT5Path) },
                          onClear: vidT5Path.isEmpty ? nil : { vidT5Path = "" })
                Text("Recommended: Wan2.1-T2V-1.3B GGUF (small, ~3GB). LTX-2 (larger). Both supported by sd-cli --mode vid_gen.")
                    .font(.caption2).foregroundStyle(Theme.textFaint)
                if !vidModelPath.isEmpty {
                    let family = DiffusionFamily.detect(path: vidModelPath)
                    if family == .wan21 || family == .ltx {
                        Label("Detected family: \(family.label)", systemImage: "sparkles")
                            .font(.caption).foregroundStyle(Theme.violet)
                    }
                }
            }
            if !vidModelPath.isEmpty {
                let family = DiffusionFamily.detect(path: vidModelPath)
                if !ModelBundle.requiredCompanions(for: family).isEmpty {
                    CompanionsSettingsBlock(diffusionPath: vidModelPath,
                                            family: family,
                                            downloadsRoot: downloads.rootDirectory,
                                            catalog: catalog)
                }
            }
            Section("sd-cli binary (for video generation)") {
                pickerRow(title: "sd-cli binary",
                          path: sdCliOverride, placeholder: "Auto (bundled / Homebrew)",
                          onPick: { pickFile(.exec, into: $sdCliOverride) },
                          onClear: sdCliOverride.isEmpty ? nil : { sdCliOverride = "" })
            }
            Section {
                Text("Video editing uses ffmpeg (must be on PATH or in app bundle). Install: `brew install ffmpeg`.")
                    .font(.caption).foregroundStyle(Theme.textMuted)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: HuggingFace tab

    private var huggingFaceTab: some View {
        Form {
            Section("Access token") {
                SecureField("hf_xxxxxxxx", text: $hfToken)
                Text("Optional. Higher rate limits (5K vs 3K resolver calls per 5min) and access to gated models. Get one at huggingface.co/settings/tokens.")
                    .font(.caption2).foregroundStyle(Theme.textFaint)
                if !hfToken.isEmpty {
                    Label("Token set (used for all HF requests).", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.mint).font(.caption)
                }
            }
            Section("Downloads") {
                pickerRow(title: "Download root",
                          path: hfDownloadsRoot, placeholder: "~/.mllama/hf",
                          onPick: { pickFolder(into: $hfDownloadsRoot) },
                          onClear: hfDownloadsRoot.isEmpty ? nil : { hfDownloadsRoot = "" })
                Text("Layout: <root>/<author>/<repo>/<file>. Resumes interrupted downloads automatically.")
                    .font(.caption2).foregroundStyle(Theme.textFaint)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: File pickers

    private enum PickKind { case image, weights, exec }

    private func pickFile(_ kind: PickKind, into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        switch kind {
        case .image:
            panel.title = "Choose a model file"
            if let g = UTType(filenameExtension: "gguf"), let s = UTType(filenameExtension: "safetensors") {
                panel.allowedContentTypes = [g, s]
            }
        case .weights:
            panel.title = "Choose a weight file"
            // Allow any extension (gguf, safetensors, ckpt, pt, bin)
            panel.allowsOtherFileTypes = true
        case .exec:
            panel.title = "Choose binary"
            panel.allowsOtherFileTypes = true
        }
        if panel.runModal() == .OK, let url = panel.url { binding.wrappedValue = url.path }
    }

    private func pickFolder(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { binding.wrappedValue = url.path }
    }

    // MARK: Voice

    private var voiceTab: some View {
        Form {
            Section("Voice input (speech → text)") {
                Picker("Engine", selection: $sttEngine) {
                    ForEach(STTEngine.allCases) { e in
                        Text(e.label).tag(e.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                if sttEngine == STTEngine.whisper.rawValue {
                    HStack {
                        Image(systemName: WhisperEngine.shared.isAvailable ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(WhisperEngine.shared.isAvailable ? Theme.mint : Theme.coral)
                        Text(WhisperEngine.shared.isAvailable
                             ? "Bundled whisper.cpp tiny multilingual (~31 MB, Metal-accelerated). 99 languages."
                             : "Whisper assets missing from this build.")
                            .font(.caption).foregroundStyle(Theme.textMuted)
                    }
                    Picker("Language", selection: $whisperLanguage) {
                        Text("Auto-detect").tag("auto")
                        ForEach(whisperLanguages, id: \.0) { (code, name) in
                            Text("\(name) (\(code))").tag(code)
                        }
                    }
                } else {
                    Toggle("Prefer on-device recognition", isOn: $preferOnDevice).tint(Theme.violet)
                    Picker("Locale", selection: $recognizerLocale) {
                        Text("System default").tag("")
                        ForEach(VoiceRecorder.availableLocales(), id: \.identifier) { l in
                            Text(l.identifier).tag(l.identifier)
                        }
                    }
                }
            }
            Section("Voice output (text → speech)") {
                Toggle("Auto-speak Mllama's replies", isOn: $autoSpeak).tint(Theme.violet)
                Picker("Voice", selection: $voiceIdentifier) {
                    Text("System default").tag("")
                    ForEach(SpeechSynthesizer.availableVoices(), id: \.identifier) { v in
                        Text("\(v.name) — \(v.language) \(qualityBadge(v.quality))")
                            .tag(v.identifier)
                    }
                }
                LabeledContent("Rate") {
                    HStack {
                        Slider(value: $voiceRate,
                               in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate))
                            .tint(Theme.violet)
                            .frame(width: 220)
                        Text(voiceRate == 0
                             ? "default"
                             : String(format: "%.2f", voiceRate))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                HStack {
                    Button("Test voice") {
                        tts.speak("Hello — I'm Mllama, your local on-device assistant.")
                    }
                    if tts.isSpeaking {
                        Button("Stop") { tts.stop() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func qualityBadge(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: "★★★ premium"
        case .enhanced: "★★ enhanced"
        case .default: "★ default"
        @unknown default: ""
        }
    }

    private let whisperLanguages: [(String, String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("ru", "Russian"),
        ("pl", "Polish"), ("tr", "Turkish"), ("ar", "Arabic"), ("hi", "Hindi"),
        ("ur", "Urdu"), ("bn", "Bengali"), ("zh", "Chinese"), ("ja", "Japanese"),
        ("ko", "Korean"), ("vi", "Vietnamese"), ("th", "Thai"), ("id", "Indonesian"),
        ("ms", "Malay"), ("uk", "Ukrainian"), ("sv", "Swedish"), ("no", "Norwegian"),
        ("da", "Danish"), ("fi", "Finnish"), ("cs", "Czech"), ("ro", "Romanian"),
        ("el", "Greek"), ("he", "Hebrew"), ("fa", "Persian"),
    ]

    // MARK: Model

    private var modelTab: some View {
        Form {
            Section {
                pickerRow(
                    title: "Model file (.gguf)",
                    path: modelPath,
                    placeholder: "Not set",
                    onPick: pickModel
                )
                pickerRow(
                    title: "Vision projector (mmproj, optional)",
                    path: mmprojPath,
                    placeholder: "Not set",
                    onPick: pickMmproj,
                    onClear: mmprojPath.isEmpty ? nil : { mmprojPath = "" }
                )
            }
            Section("Custom directories") {
                Text("In addition to LM Studio, Ollama, and ~/models, scan these:")
                    .font(.caption).foregroundStyle(Theme.textMuted)
                TextEditor(text: customDirsBinding)
                    .font(Theme.monoSmall)
                    .frame(minHeight: 70)
                    .scrollContentBackground(.hidden)
                    .background(Theme.codeBg)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke))
                HStack {
                    Button("Add Folder…") { pickCustomDir() }
                    Spacer()
                    Button("Rescan") { Task { await library.rescan(extraDirs: customDirsArray()) } }
                }
            }
            Section {
                Button("Apply & Restart Server") { server.restart() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Performance

    private var serverTab: some View {
        Form {
            Section("Connection") {
                LabeledContent("Host") { TextField("127.0.0.1", text: $host).frame(width: 160) }
                LabeledContent("Port") { TextField("8080", value: $port, format: .number.grouping(.never)).frame(width: 100) }
            }
            Section("Context") {
                LabeledContent("Context size") {
                    HStack {
                        TextField("0", value: $contextSize, format: .number.grouping(.never)).frame(width: 100)
                        Text(contextSize == 0 ? "= model max" : "tokens")
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                Text("0 (default) loads each model at its native context window. Set a smaller value to save RAM.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                if server.nCtx > 0 {
                    HStack {
                        Image(systemName: "info.circle").font(.caption2).foregroundStyle(Theme.cyan)
                        Text("Current model loaded at \(server.nCtx) tokens.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                Toggle("Auto-compact conversation at 75% of context", isOn: $autoCompact)
                    .tint(Theme.violet)
            }
            Section("Inference (tuned for Apple Silicon)") {
                LabeledContent("GPU layers (-ngl)") { TextField("99", value: $ngl, format: .number.grouping(.never)).frame(width: 100) }
                LabeledContent("Threads (-t)") { TextField("8", value: $threads, format: .number.grouping(.never)).frame(width: 100) }
                Toggle("Flash attention (--flash-attn on)", isOn: $flashAttn).tint(Theme.violet)
                Toggle("Lock model in RAM (--mlock)", isOn: $mlock).tint(Theme.violet)
            }
            Section("Advanced") {
                LabeledContent("Extra args") {
                    TextField("--reasoning-format deepseek", text: $extraArgs).frame(minWidth: 240)
                }
            }
            Section {
                Button("Apply & Restart Server") { server.restart() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Agent

    private var agentTab: some View {
        Form {
            Section("System prompt") {
                Text("Tells Mllama who it is and how to use tools.")
                    .font(.caption).foregroundStyle(Theme.textMuted)
                TextEditor(text: $systemPrompt)
                    .font(Theme.monoSmall)
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                    .background(Theme.codeBg)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke))
                HStack {
                    Spacer()
                    Button("Reset to default") { systemPrompt = defaultSystemPrompt }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: MCP

    private var mcpTab: some View {
        Form {
            Section("Config file") {
                Text(MCPConfigStore.mllamaPath.path)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textMuted)
                    .textSelection(.enabled)
                HStack {
                    Button("Edit in default app") {
                        MCPConfigStore.ensureScaffold()
                        NSWorkspace.shared.open(MCPConfigStore.mllamaPath)
                    }
                    Button("Reveal in Finder") {
                        MCPConfigStore.ensureScaffold()
                        NSWorkspace.shared.activateFileViewerSelecting([MCPConfigStore.mllamaPath])
                    }
                    Spacer()
                    Button("Reload servers") { Task { await mcp.reload() } }
                }
                Text("If absent, Mllama falls back to ~/Library/Application Support/Claude/claude_desktop_config.json. Format is identical to Claude Desktop's.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
            }
            Section("Connected servers") {
                if mcp.servers.isEmpty {
                    Text("No MCP servers running.")
                        .font(.caption).foregroundStyle(Theme.textMuted)
                } else {
                    ForEach(mcp.servers, id: \.name) { row in
                        DisclosureGroup {
                            ForEach(row.tools, id: \.self) {
                                Text($0).font(Theme.monoSmall).foregroundStyle(Theme.textMuted)
                            }
                            if let err = row.error, !err.isEmpty {
                                Text(err).font(Theme.monoSmall).foregroundStyle(Theme.coral)
                            }
                        } label: {
                            HStack {
                                Image(systemName: row.error == nil ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(row.error == nil ? Theme.mint : Theme.coral)
                                Text(row.name).font(.callout.weight(.medium))
                                Spacer()
                                Text("\(row.tools.count) tools").font(.caption).foregroundStyle(Theme.textFaint)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Bits

    @ViewBuilder
    private func pickerRow(title: String, path: String, placeholder: String, onPick: @escaping () -> Void, onClear: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(path.isEmpty ? placeholder : path)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
            Spacer()
            // 8 pt gap satisfies macOS HIG minimum spacing between adjacent
            // controls when they're vertically stacked. The previous 4 pt
            // packed the Clear button uncomfortably close to Choose…
            VStack(spacing: 8) {
                Button("Choose…", action: onPick)
                if let clear = onClear {
                    Button("Clear", action: clear).controlSize(.small)
                }
            }
        }
    }

    private var customDirsBinding: Binding<String> {
        Binding(
            get: { customDirsArray().joined(separator: "\n") },
            set: { new in
                let lines = new.split(separator: "\n").map(String.init)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if let data = try? JSONEncoder().encode(lines),
                   let s = String(data: data, encoding: .utf8) {
                    customDirsJSON = s
                }
            }
        )
    }

    private func customDirsArray() -> [String] {
        guard let data = customDirsJSON.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }

    private func pickModel() {
        let panel = NSOpenPanel()
        panel.title = "Choose a GGUF model file"
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        if let t = UTType(filenameExtension: "gguf") { panel.allowedContentTypes = [t] }
        if panel.runModal() == .OK, let url = panel.url { modelPath = url.path }
    }
    private func pickMmproj() {
        let panel = NSOpenPanel()
        panel.title = "Choose a vision projector"
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        if let t = UTType(filenameExtension: "gguf") { panel.allowedContentTypes = [t] }
        if panel.runModal() == .OK, let url = panel.url { mmprojPath = url.path }
    }
    private func pickCustomDir() {
        let panel = NSOpenPanel()
        panel.title = "Add custom model directory"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            var arr = customDirsArray()
            if !arr.contains(url.path) {
                arr.append(url.path)
                if let data = try? JSONEncoder().encode(arr),
                   let s = String(data: data, encoding: .utf8) {
                    customDirsJSON = s
                }
            }
        }
    }

    // MARK: Required companions widget

    /// Inline section that mirrors the picker's companion widget for the
    /// settings surface. Only renders when the chosen diffusion model
    /// belongs to a family that needs separate encoders / VAE.
    ///
    /// Uses `CompanionStatusCache` to avoid running the filesystem walk
    /// on every body re-eval (downloads tick `@Published` updates often).
    @ViewBuilder
    private func companionsSettingsSection() -> some View {
        if !sdModelPath.isEmpty {
            let family = DiffusionFamily.detect(path: sdModelPath)
            let reqs = ModelBundle.requiredCompanions(for: family)
            if !reqs.isEmpty {
                CompanionsSettingsBlock(diffusionPath: sdModelPath,
                                         family: family,
                                         downloadsRoot: downloads.rootDirectory,
                                         catalog: catalog)
            }
        }
    }
}

// MARK: - Companions section (extracted so it owns its own async state)

/// Standalone view so it can hold `@State` for the resolved companion list.
/// `CompanionResolver.status(...)` walks the HF cache on a worst-case path;
/// running it from a SwiftUI body re-eval (which Settings does every time
/// a download progress tick publishes) would block the main actor. We
/// resolve asynchronously and only when the inputs actually change.
struct CompanionsSettingsBlock: View {
    let diffusionPath: String
    let family: DiffusionFamily
    let downloadsRoot: URL
    let catalog: UnifiedModelCatalog

    @State private var statuses: [CompanionStatus] = []
    @State private var isResolving: Bool = false

    var body: some View {
        Section("Required companions for \(family.label)") {
            if statuses.isEmpty && isResolving {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Scanning for companion files…").font(.caption).foregroundStyle(Theme.textMuted)
                }
            }
            ForEach(statuses, id: \.label) { s in
                HStack(spacing: 8) {
                    Image(systemName: s.localPath != nil ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(s.localPath != nil ? Theme.mint : Theme.amber)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.label).font(.callout)
                        if let p = s.localPath {
                            Text((p as NSString).lastPathComponent)
                                .font(Theme.monoSmall).foregroundStyle(Theme.textMuted)
                                .lineLimit(1).truncationMode(.middle)
                        } else if let rec = s.curated {
                            Text("\(rec.repoId) · \(rec.humanDownload)")
                                .font(Theme.monoSmall).foregroundStyle(Theme.textFaint)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer()
                }
            }
            let missing = statuses.filter { $0.isMissing && $0.curated != nil }
            if !missing.isEmpty {
                Button {
                    _ = catalog.enqueueMissingCompanions(diffusionPath: diffusionPath, family: family)
                } label: {
                    Label("Get missing files (\(missing.count))", systemImage: "arrow.down.circle.fill")
                }
            }
        }
        .task(id: diffusionPath) { await resolve() }
    }

    private func resolve() async {
        isResolving = true
        let path = diffusionPath
        let root = downloadsRoot
        let resolved = await Task.detached(priority: .userInitiated) {
            CompanionResolver.scanOffActor(forDiffusion: path, downloadsRoot: root)
        }.value
        // Off-actor scan only reports found files; fill missing-role placeholders
        // so the UI renders the full requirement list.
        var byRole: [CompanionRole: CompanionStatus] = [:]
        for s in resolved { byRole[s.role] = s }
        var out: [CompanionStatus] = []
        for req in ModelBundle.requiredCompanions(for: family) {
            if let s = byRole[req.role] {
                out.append(s)
            } else {
                out.append(CompanionStatus(role: req.role, label: req.label,
                                           localPath: nil,
                                           curated: ModelBundle.catalogEntry(for: req)))
            }
        }
        statuses = out
        isResolving = false
    }
}
