import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImageStudio: View {
    @EnvironmentObject var sd: SDServerController
    @EnvironmentObject var generator: ImageGenerator
    @EnvironmentObject var prompts: PromptLibrary
    @EnvironmentObject var catalog: UnifiedModelCatalog
    @EnvironmentObject var pickerState: ModelPickerState
    @EnvironmentObject var downloads: HFDownloadManager
    @State private var params = ImageGenParams()
    @State private var mode: GenMode = .txt2img
    @State private var showEditor = false
    @State private var editingURL: URL?
    @State private var lastResult: ImageGenResult?
    @State private var showSavedConfirmation = false
    @State private var didApplyFamilyDefaults: Bool = false
    @State private var lastSeenModelPath: String = ""
    /// Stored so a second Generate tap before the server is up doesn't spawn
    /// a duplicate polling task (which would race-cancel the first request).
    @State private var pendingGenerateTask: Task<Void, Never>? = nil

    enum GenMode: String, CaseIterable, Identifiable {
        case txt2img = "Text → Image"
        case img2img = "Image → Image"
        case inpaint = "Inpaint"
        var id: String { rawValue }
        var sfSymbol: String {
            switch self {
            case .txt2img: return "text.below.photo"
            case .img2img: return "wand.and.rays"
            case .inpaint: return "lasso"
            }
        }
    }

    var body: some View {
        HSplitView {
            // Left: controls
            controlPanel
                .frame(minWidth: 360, idealWidth: 420)

            // Right: preview + results
            VStack(spacing: 0) {
                serverBanner
                companionBanner
                if showEditor, let url = editingURL {
                    ImageEditorView(sourceURL: url) {
                        showEditor = false
                        editingURL = nil
                    }
                } else {
                    previewPane
                }
                Divider().background(Theme.stroke)
                recentStrip
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .insertPromptIntoImageStudio)) { note in
            if let p = note.userInfo?["prompt"] as? String { params.prompt = p }
        }
        .onAppear {
            applyFamilyDefaultsIfNeeded()
        }
        .onChange(of: sd.modelPath ?? "") { newPath in
            // When the user switches model, re-apply family-appropriate defaults
            // (low CFG + distilled guidance for FLUX, etc.) once per model.
            if newPath != lastSeenModelPath {
                lastSeenModelPath = newPath
                didApplyFamilyDefaults = false
                applyFamilyDefaultsIfNeeded()
            }
        }
    }

    private func applyFamilyDefaultsIfNeeded() {
        guard !didApplyFamilyDefaults else { return }
        guard let path = sd.modelPath, !path.isEmpty else { return }
        let family = DiffusionFamily.detect(path: path)
        guard family != .unknown else { return }
        let d = family.defaults
        // Only overwrite values that look "untouched" — avoid stomping
        // explicit user changes. We treat "default" as the initial template.
        let initial = ImageGenParams()
        if params.cfgScale == initial.cfgScale { params.cfgScale = d.cfgScale }
        if params.guidance == initial.guidance { params.guidance = d.guidance }
        if params.steps    == initial.steps    { params.steps    = d.steps }
        if params.sampler  == initial.sampler  { params.sampler  = d.sampler }
        if params.scheduler == initial.scheduler { params.scheduler = d.scheduler }
        didApplyFamilyDefaults = true
    }

    // MARK: Server banner

    @ViewBuilder
    private var serverBanner: some View {
        switch sd.status {
        case .running:
            EmptyView()
        case .starting:
            statusStrip(color: Theme.amber, icon: "hourglass", text: "Loading image model into memory…")
        case .stopped:
            statusStrip(color: Theme.textMuted, icon: "circle.dashed",
                       text: "Image server idle. Click Generate to launch with the configured model.")
        case .failed(let m):
            statusStrip(color: Theme.coral, icon: "exclamationmark.triangle.fill", text: m)
        case .notConfigured:
            statusStrip(color: Theme.cyan, icon: "questionmark.circle",
                       text: "No image model configured. Go to Models tab to download one (e.g. FLUX.1-schnell-gguf).")
        }
    }

    private func statusStrip(color: Color, icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.caption).foregroundStyle(Theme.text)
            Spacer()
            if case .notConfigured = sd.status {
                Button("Pick model") { pickerState.open(initialKind: .image) }
                    .controlSize(.small)
            }
            if case .stopped = sd.status, sd.modelPath != nil {
                Button("Start") { sd.start() }.controlSize(.small)
            }
            if case .failed = sd.status {
                Button("Retry") { sd.restart() }.controlSize(.small)
            }
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, 8)
        .background(color.opacity(0.12))
        .overlay(Rectangle().fill(color.opacity(0.4)).frame(height: 0.5), alignment: .bottom)
    }

    /// Companion-file status strip — surfaces missing T5 / CLIP / VAE for
    /// FLUX, SD3.5, Wan, LTX so users don't get cryptic server errors.
    /// Backed by the async-cached CompanionBanner so we don't walk the HF
    /// cache on the main actor every download progress tick.
    private var companionBanner: some View {
        CompanionBanner(diffusionPath: sd.modelPath ?? "",
                        isVideo: false,
                        downloadsRoot: downloads.rootDirectory,
                        catalog: catalog,
                        jobs: downloads.jobs,
                        onPickModel: nil)
    }

    // MARK: Control panel

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                modeSwitcher
                promptArea
                if mode != .txt2img {
                    initImageSection
                }
                if mode == .inpaint {
                    maskSection
                }
                generationParams
                advancedParams
                actionRow
            }
            .padding(Theme.Space.md)
        }
        .background(VisualEffectBackground(material: .sidebar, blendingMode: .withinWindow))
    }

    private var modeSwitcher: some View {
        Picker("", selection: $mode) {
            ForEach(GenMode.allCases) { m in
                Label(m.rawValue, systemImage: m.sfSymbol).tag(m)
            }
        }
        .pickerStyle(.segmented)
    }

    private var promptArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROMPT").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
            TextEditor(text: $params.prompt)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 100, maxHeight: 160)
                .padding(8)
                .foregroundStyle(Theme.text)
                .tint(Theme.violet)
                .glass(cornerRadius: Theme.Radius.md, tint: Color.white.opacity(0.05), stroke: Theme.strokeStrong)

            DisclosureGroup {
                TextEditor(text: $params.negativePrompt)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 70, maxHeight: 120)
                    .padding(8)
                    .foregroundStyle(Theme.text)
                    .tint(Theme.violet)
                    .glass(cornerRadius: Theme.Radius.sm, tint: Color.white.opacity(0.04), stroke: Theme.stroke)
            } label: {
                Text("Negative prompt").font(.caption).foregroundStyle(Theme.textMuted)
            }
        }
    }

    private var initImageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SOURCE IMAGE").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
            ImageDropTarget(path: $params.initImagePath)
            sliderRow(title: "Strength", value: $params.strength, range: 0...1, format: "%.2f")
                .help("How much to deviate from the source. 1.0 = full repaint.")
        }
    }

    private var maskSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MASK (white = paint, black = keep)").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
            ImageDropTarget(path: $params.maskImagePath)
        }
    }

    private var generationParams: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GENERATION").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
            HStack(spacing: 8) {
                LabeledField(label: "W") {
                    TextField("", value: $params.width, format: .number).frame(width: 70)
                }
                LabeledField(label: "H") {
                    TextField("", value: $params.height, format: .number).frame(width: 70)
                }
                Menu {
                    ForEach([(512,512,"1:1 · 512"),
                             (768,768,"1:1 · 768"),
                             (1024,1024,"1:1 · 1024"),
                             (1024,1536,"2:3 · 1024×1536"),
                             (1536,1024,"3:2 · 1536×1024"),
                             (1920,1080,"16:9 · 1920×1080"),
                             (832,1216,"SDXL portrait"),
                             (1216,832,"SDXL landscape")], id: \.2) { (w, h, label) in
                        Button(label) { params.width = w; params.height = h }
                    }
                } label: {
                    Label("Presets", systemImage: "rectangle.on.rectangle")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                Spacer()
            }
            sliderRow(title: "Steps", value: Binding(
                get: { Double(params.steps) },
                set: { params.steps = Int($0) }
            ), range: 1...80, format: "%.0f")
            sliderRow(title: "CFG", value: $params.cfgScale, range: 1...20, format: "%.1f")
            sliderRow(title: "Guidance (distilled)", value: $params.guidance, range: 0...10, format: "%.1f")
                .help("For Flux / SD3-family distilled models.")
            HStack(spacing: 8) {
                LabeledField(label: "Seed") {
                    TextField("-1 random", value: $params.seed, format: .number).frame(maxWidth: .infinity)
                }
                Button { params.seed = Int64.random(in: 0...Int64.max) } label: {
                    Image(systemName: "dice")
                }
                .buttonStyle(.borderless)
                .help("Random seed")
                .accessibilityLabel("Randomize seed")
            }
        }
    }

    private var advancedParams: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Sampler", selection: $params.sampler) {
                    ForEach(SDSampler.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                Picker("Schedule", selection: $params.scheduler) {
                    ForEach(SDScheduler.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                LabeledField(label: "Batch") {
                    Stepper("\(params.batchCount)", value: $params.batchCount, in: 1...8)
                }
                LabeledField(label: "Clip skip") {
                    Stepper("\(params.clipSkip)", value: $params.clipSkip, in: -1...12)
                }
                Toggle("Hi-res fix (upscale pass)", isOn: $params.hires).tint(Theme.violet)
                if params.hires {
                    sliderRow(title: "  Hi-res scale", value: $params.hiresScale, range: 1.1...3.0, format: "%.2f")
                    sliderRow(title: "  Hi-res steps", value: Binding(
                        get: { Double(params.hiresSteps) },
                        set: { params.hiresSteps = Int($0) }
                    ), range: 5...40, format: "%.0f")
                    sliderRow(title: "  Hi-res denoise", value: $params.hiresDenoisingStrength, range: 0.1...0.9, format: "%.2f")
                }
                LabeledField(label: "LoRAs") {
                    TextField("<lora:name:0.7>", text: $params.loraDirectives)
                        .help("Stackable: <lora:a:0.7> <lora:b:0.4>")
                }
                LabeledField(label: "ControlNet image") {
                    ImageDropTarget(path: $params.controlImagePath)
                        .frame(minHeight: 56)
                }
                if params.controlImagePath != nil {
                    sliderRow(title: "  ControlNet strength", value: $params.controlStrength, range: 0...2, format: "%.2f")
                }
            }
        } label: {
            HStack {
                Image(systemName: "slider.horizontal.3")
                Text("Advanced").font(.caption.weight(.semibold))
            }
            .foregroundStyle(Theme.text)
        }
        .padding(Theme.Space.sm)
        .glass(cornerRadius: Theme.Radius.md)
    }

    private var actionRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                if generator.isGenerating {
                    Button {
                        generator.cancel()
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.coral)
                    .controlSize(.large)
                } else {
                    Button {
                        prompts.use(params.prompt, negative: params.negativePrompt, kind: .image)
                        triggerGenerate()
                    } label: {
                        Label(generateButtonLabel, systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.violet)
                    .controlSize(.large)
                    .disabled(params.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }
            HStack(spacing: 8) {
                Button {
                    let _ = prompts.save(params.prompt,
                                         negative: params.negativePrompt,
                                         kind: .image)
                    showSavedConfirmation = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { showSavedConfirmation = false }
                } label: {
                    Label(showSavedConfirmation ? "Saved!" : "Save prompt",
                          systemImage: showSavedConfirmation ? "checkmark" : "bookmark")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(params.prompt.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    var p = params
                    p.seed = -1  // force re-roll
                    prompts.use(p.prompt, negative: p.negativePrompt, kind: .image)
                    generator.generate(p)
                } label: {
                    Label("Variation", systemImage: "wand.and.rays").font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(generator.isGenerating || params.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Generate again with a new random seed.")

                if let last = lastResult {
                    Button {
                        editingURL = last.url
                        showEditor = true
                    } label: { Label("Edit", systemImage: "wand.and.stars").font(.caption) }
                        .buttonStyle(.bordered)
                }
                Spacer()
            }
        }
    }

    // MARK: Preview pane

    private var previewPane: some View {
        ZStack {
            VisualEffectBackground(material: .underWindowBackground, blendingMode: .behindWindow).ignoresSafeArea()
            GradientAtmosphere().ignoresSafeArea()
            VStack(spacing: 0) {
                Group {
                    if let err = generator.lastError, generator.progress == nil {
                        errorBanner(err)
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: generator.lastError ?? "")
                if let p = generator.progress {
                    progressView(p)
                } else if let r = generator.results.first {
                    ImagePreview(url: r.url, params: r.params, onEdit: {
                        editingURL = r.url
                        showEditor = true
                    }, onReuse: {
                        self.params = r.params
                    })
                    .onAppear { lastResult = r }
                } else {
                    emptyPreview
                }
            }
        }
    }

    private func errorBanner(_ msg: String) -> some View {
        // Heuristics: pattern-match common failure modes so we can offer a
        // one-click recovery rather than dumping the user into Settings.
        let lower = msg.lowercased()
        let isWarning = lower.contains("won't apply")
                     || lower.contains("controlnet")
        let suggestsRestart = lower.contains("server exited")
                           || lower.contains("connection")
                           || lower.contains("missing encoder")
                           || lower.contains("missing companion")
        let suggestsPickModel = lower.contains("not running")
                             || lower.contains("not configured")
                             || lower.contains("pick a model")
                             || lower.contains("missing companion")
        let suggestsRetry = lower.contains("timed out")
                         || lower.contains("didn't become ready")
        let accentColor: Color = isWarning ? Theme.amber : Theme.coral
        let headline = isWarning ? "Heads up" : "Generation failed"
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isWarning ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(accentColor)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                // Headline rendered in Theme.text (high contrast on the
                // tinted backdrop) — the accent lives on the icon and the
                // surrounding stroke. Coral text on coral@0.12 would fail
                // WCAG 1.4.3.
                Text(headline).font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Text(msg)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .lineLimit(6)
                HStack(spacing: 8) {
                    if suggestsRestart {
                        Button("Restart server") {
                            sd.restart()
                            generator.lastError = nil
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                    if suggestsRetry {
                        Button("Retry") {
                            generator.lastError = nil
                            triggerGenerate()
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                    if suggestsPickModel {
                        Button("Pick model") {
                            pickerState.open(initialKind: .image)
                            generator.lastError = nil
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding(.top, 2)
            }
            Spacer()
            DismissButton(tint: accentColor) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    generator.lastError = nil
                }
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm + 2)
        .background(accentColor.opacity(0.12))
        // Stronger stroke + slightly thicker rule so a failed generation
        // visually outranks the merely-informational server-status strip.
        .overlay(Rectangle().fill(accentColor.opacity(isWarning ? 0.35 : 0.55))
            .frame(height: isWarning ? 0.5 : 1.0), alignment: .bottom)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func progressView(_ p: ImageGenProgress) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Theme.stroke, lineWidth: 6)
                    .frame(width: 120, height: 120)
                Circle()
                    .trim(from: 0, to: max(0.02, p.fraction))
                    .stroke(Theme.brandGradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: p.fraction)
                VStack {
                    Text("\(Int(p.fraction*100))%").font(.title2.weight(.semibold)).foregroundStyle(Theme.text)
                    Text(p.message).font(.caption).foregroundStyle(Theme.textMuted)
                }
            }
            if p.etaSeconds > 0 {
                Text(String(format: "ETA %.0fs", p.etaSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textFaint)
            }
            Button("Cancel") { generator.cancel() }
                .buttonStyle(.bordered)
        }
    }

    private var emptyPreview: some View {
        ScrollView {
            VStack(spacing: Theme.Space.lg) {
                Spacer().frame(height: 20)
                ZStack {
                    Circle().fill(Theme.brandGradient).frame(width: 100, height: 100)
                        .shadow(color: Theme.violet.opacity(0.4), radius: 30)
                    Image(systemName: "photo.artframe")
                        .font(.system(size: 40))
                        .foregroundStyle(.white)
                }
                VStack(spacing: 6) {
                    Text("Image Studio").font(.system(size: 28, weight: .heavy)).foregroundStyle(Theme.text)
                    Text("Type a prompt below and hit ⌘↩ to generate.")
                        .font(.callout).foregroundStyle(Theme.textMuted)
                }

                if !showServerSetupHint {
                    Text("TRY ONE OF THESE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.textFaint)
                        .padding(.top, 8)
                    VStack(spacing: 6) {
                        ForEach(starterPrompts, id: \.0) { pair in
                            StarterRow(title: pair.0, prompt: pair.1) {
                                params.prompt = pair.1
                            }
                        }
                    }
                    .frame(maxWidth: 600)
                }
                Spacer().frame(height: 20)
            }
            .padding(.horizontal, Theme.Space.lg)
            .frame(maxWidth: .infinity)
        }
    }

    private var showServerSetupHint: Bool {
        if case .notConfigured = sd.status { return true }
        return false
    }

    private let starterPrompts: [(String, String)] = [
        ("Cinematic portrait",
         "cinematic portrait of a lone traveler in a misty forest, volumetric god rays through the canopy, 35mm film grain, anamorphic lens flares, soft rim light"),
        ("Cyberpunk alley",
         "neon-lit cyberpunk alley after heavy rain, holographic billboards reflecting in puddles, dense smog, dramatic perspective, octane render"),
        ("Studio product shot",
         "minimalist studio product photography of a matte black ceramic mug, seamless white background, soft top light, hyper-detailed, depth of field"),
        ("Watercolor landscape",
         "loose watercolor painting of rolling hills at golden hour, soft pastel washes, visible paper texture, traditional media, painterly"),
        ("Cosmic abstract",
         "abstract cosmic nebula rendered as liquid acrylic paint, deep purple and cyan, swirling galactic patterns, hyperreal"),
    ]

    // MARK: Recent strip

    private var recentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(generator.results) { r in
                    Button {
                        editingURL = r.url
                        showEditor = false
                        lastResult = r
                    } label: {
                        AsyncImageThumbnail(url: r.url, size: 80)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke, lineWidth: 0.7))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Reuse prompt") { self.params = r.params }
                        Button("Edit") { editingURL = r.url; showEditor = true }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([r.url])
                        }
                    }
                }
                if generator.results.isEmpty {
                    Text("Recent generations appear here.")
                        .font(.caption).foregroundStyle(Theme.textFaint)
                        .padding(.horizontal, 8)
                }
            }
            .padding(8)
        }
        .frame(height: 96)
        .background(VisualEffectBackground(material: .hudWindow, blendingMode: .withinWindow))
    }

    // MARK: Helpers

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(Theme.textMuted).frame(width: 130, alignment: .leading)
            Slider(value: value, in: range).tint(Theme.violet)
            Text(String(format: format, value.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.text)
                .frame(width: 50, alignment: .trailing)
        }
    }

    // MARK: Generate triggering

    private var generateButtonLabel: String {
        switch sd.status {
        case .running:        return "Generate"
        case .starting:       return "Loading model…"
        case .stopped:        return sd.modelPath == nil ? "Pick a model first" : "Start & Generate"
        case .notConfigured:  return "Pick a model first"
        case .failed:         return "Retry & Generate"
        }
    }

    private func triggerGenerate() {
        switch sd.status {
        case .running:
            generator.generate(params)
        case .stopped, .failed:
            // If a model is configured, boot the server and queue the request.
            guard sd.modelPath != nil else {
                pickerState.open(initialKind: .image)
                return
            }
            generator.lastError = nil
            sd.start()
            queueGenerationWhenReady()
        case .starting:
            queueGenerationWhenReady()
        case .notConfigured:
            pickerState.open(initialKind: .image)
        }
    }

    /// Poll sd.status briefly so the user can hit Generate even before the
    /// server is up. Times out cleanly after ~90s with a clear message.
    /// Cancels any prior pending poll so we never double-dispatch.
    private func queueGenerationWhenReady() {
        pendingGenerateTask?.cancel()
        let snapshot = params
        pendingGenerateTask = Task { @MainActor in
            defer { pendingGenerateTask = nil }
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline {
                if Task.isCancelled { return }
                if case .running = sd.status {
                    generator.generate(snapshot)
                    return
                }
                if case .failed(let m) = sd.status {
                    generator.lastError = "Server failed to start: \(m)"
                    return
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            generator.lastError = "Server didn't become ready in time. Check Settings → Image Gen."
        }
    }
}

// MARK: - Helpers

struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(Theme.textMuted).frame(width: 70, alignment: .leading)
            content()
        }
    }
}

/// Row-style starter prompt that fills its full width.
struct StarterRow: View {
    let title: String
    let prompt: String
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(Theme.violet).font(.callout)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                    Text(prompt).font(.caption).foregroundStyle(Theme.textMuted).lineLimit(2)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(hovering ? Theme.violet : Theme.textFaint)
                    .font(.caption)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(cornerRadius: Theme.Radius.md,
                   tint: hovering ? Theme.violet.opacity(0.12) : Theme.pane,
                   stroke: hovering ? Theme.violet.opacity(0.45) : Theme.stroke)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct PromptStarter: View {
    let text: String
    let onTap: (String) -> Void
    @State private var hovering = false
    var body: some View {
        Button { onTap(text) } label: {
            Text("· " + text.prefix(60) + (text.count > 60 ? "…" : ""))
                .font(.caption)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .glass(cornerRadius: 999,
                       tint: hovering ? Theme.paneHover : Theme.pane,
                       stroke: hovering ? Theme.strokeStrong : Theme.stroke)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// File-drop / browse area for image inputs.
struct ImageDropTarget: View {
    @Binding var path: String?
    @State private var isHovering = false
    @State private var preview: NSImage?

    var body: some View {
        Group {
            if let path = path, let img = preview ?? NSImage(contentsOfFile: path) {
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Button {
                        self.path = nil; self.preview = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white)
                            .background(Circle().fill(.black.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }
            } else {
                Button(action: pick) {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus").font(.title2).foregroundStyle(Theme.violet)
                        Text("Drop or click to choose").font(.caption).foregroundStyle(Theme.textMuted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .glass(cornerRadius: Theme.Radius.md,
                           tint: isHovering ? Theme.violet.opacity(0.15) : Theme.pane,
                           stroke: isHovering ? Theme.violet.opacity(0.45) : Theme.stroke)
                }
                .buttonStyle(.plain)
                .onDrop(of: [.fileURL], isTargeted: $isHovering) { providers in
                    handleDrop(providers)
                }
            }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            self.path = url.path
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first else { return false }
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                self.path = url.path
            }
        }
        return true
    }
}

/// Lightweight thumbnail loader.
struct AsyncImageThumbnail: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task {
            await load()
        }
    }

    private func load() async {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let img = NSImage(contentsOfFile: url.path)
                DispatchQueue.main.async {
                    self.image = img
                    cont.resume()
                }
            }
        }
    }
}

/// Big preview with metadata + actions.
struct ImagePreview: View {
    let url: URL
    let params: ImageGenParams
    let onEdit: () -> Void
    let onReuse: () -> Void
    @State private var img: NSImage?

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            ZStack {
                if let img {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
                        .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .padding(Theme.Space.md)
            HStack(spacing: 10) {
                metaPill(icon: "ruler", text: "\(params.width)×\(params.height)")
                metaPill(icon: "list.number", text: "\(params.steps) steps")
                metaPill(icon: "wand.and.stars", text: params.sampler.label)
                metaPill(icon: "number", text: params.seed == -1 ? "rand" : "\(params.seed)")
                Spacer()
                Button(action: onEdit)  { Label("Edit", systemImage: "wand.and.rays") }
                Button(action: onReuse) { Label("Reuse params", systemImage: "arrow.uturn.up.circle") }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: { Label("Reveal", systemImage: "folder") }
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.writeObjects([url as NSURL])
                } label: { Label("Copy file", systemImage: "doc.on.doc") }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.bottom, Theme.Space.sm)
        }
        .task { await loadFull() }
    }

    private func loadFull() async {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let i = NSImage(contentsOfFile: url.path)
                DispatchQueue.main.async {
                    self.img = i
                    cont.resume()
                }
            }
        }
    }

    private func metaPill(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption2.monospacedDigit())
        }
        .foregroundStyle(Theme.textMuted)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .glass(cornerRadius: 999)
    }
}

// MARK: - Image editor view (in-Studio)

struct ImageEditorView: View {
    let sourceURL: URL
    let onDone: () -> Void

    @StateObject private var editor = ImageEditor()

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    Text("PRESETS").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
                    LazyVGrid(columns: [.init(.adaptive(minimum: 90))]) {
                        ForEach(ImagePreset.allCases) { preset in
                            Button {
                                for op in preset.ops { editor.append(op) }
                            } label: {
                                Text(preset.label)
                                    .font(.caption)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .glass(cornerRadius: Theme.Radius.sm)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Divider().background(Theme.stroke)
                    Text("ADJUST").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
                    EditSliderRow(label: "Brightness", min: -0.5, max: 0.5, defaultValue: 0) { v in
                        editor.append(.brightness(v))
                    }
                    EditSliderRow(label: "Contrast", min: 0.5, max: 1.8, defaultValue: 1) { v in
                        editor.append(.contrast(v))
                    }
                    EditSliderRow(label: "Saturation", min: 0, max: 2, defaultValue: 1) { v in
                        editor.append(.saturation(v))
                    }
                    EditSliderRow(label: "Exposure", min: -3, max: 3, defaultValue: 0) { v in
                        editor.append(.exposure(v))
                    }
                    EditSliderRow(label: "Sharpen", min: 0, max: 2, defaultValue: 0) { v in
                        editor.append(.sharpen(v))
                    }
                    EditSliderRow(label: "Vignette", min: 0, max: 1.5, defaultValue: 0) { v in
                        editor.append(.vignette(v, radius: 1200))
                    }
                    EditSliderRow(label: "Blur", min: 0, max: 30, defaultValue: 0) { v in
                        editor.append(.blur(v))
                    }
                    Divider().background(Theme.stroke)
                    HStack {
                        Button("Mono")    { editor.append(.mono) }
                        Button("Invert")  { editor.append(.invert) }
                        Button("Flip H")  { editor.append(.flip(horizontal: true)) }
                        Button("Flip V")  { editor.append(.flip(horizontal: false)) }
                    }
                    Divider().background(Theme.stroke)
                    HStack {
                        Button { editor.undoLast() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        Button { editor.resetToSource() } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                        Spacer()
                    }
                }
                .padding(Theme.Space.md)
            }
            .frame(minWidth: 280, idealWidth: 320)

            VStack {
                if let img = editor.renderedNSImage() {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                        .padding(Theme.Space.md)
                        .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
                } else {
                    Text("No image loaded").foregroundStyle(Theme.textMuted)
                }
                Spacer()
                HStack {
                    Spacer()
                    Button("Cancel", action: onDone)
                    Button {
                        if let saved = editor.exportPNG() {
                            MediaLibrary.shared.record(imported: saved, kind: .image)
                        }
                        onDone()
                    } label: { Label("Save copy", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.violet)
                }
                .padding(Theme.Space.md)
            }
        }
        .task { editor.load(url: sourceURL) }
    }
}

struct EditSliderRow: View {
    let label: String
    let min: Double
    let max: Double
    let defaultValue: Double
    let onApply: (Double) -> Void
    @State private var value: Double

    init(label: String, min: Double, max: Double, defaultValue: Double,
         onApply: @escaping (Double) -> Void) {
        self.label = label; self.min = min; self.max = max
        self.defaultValue = defaultValue
        self.onApply = onApply
        _value = State(initialValue: defaultValue)
    }

    var body: some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(Theme.textMuted).frame(width: 90, alignment: .leading)
            Slider(value: $value, in: min...max) { editing in
                if !editing { onApply(value); value = defaultValue }
            }
            .tint(Theme.violet)
            Text(String(format: "%.2f", value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.text)
                .frame(width: 50, alignment: .trailing)
        }
    }
}
