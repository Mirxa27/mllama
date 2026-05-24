import SwiftUI
import AVFoundation
import AVKit
import AppKit
import UniformTypeIdentifiers

struct VideoStudio: View {
    @EnvironmentObject var generator: VideoGenerator
    @EnvironmentObject var catalog: UnifiedModelCatalog
    @EnvironmentObject var downloads: HFDownloadManager
    @EnvironmentObject var pickerState: ModelPickerState
    @AppStorage(SDKeys.videoModelPath) private var videoModelPath: String = ""
    @StateObject private var editor = VideoEditor()
    @State private var params = VideoGenParams()
    @State private var mode: VideoMode = .generate
    @State private var loadedVideo: URL?
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 5
    @State private var didApplyFamilyDefaults: Bool = false
    @State private var lastSeenVideoPath: String = ""

    enum VideoMode: String, CaseIterable, Identifiable {
        case generate   = "Generate"
        case storyboard = "Storyboard"
        case edit       = "Edit"
        var id: String { rawValue }
        var sfSymbol: String {
            switch self {
            case .generate:   return "sparkles.tv"
            case .storyboard: return "rectangle.stack.fill"
            case .edit:       return "scissors"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            modeBar
            if mode == .generate {
                // Binary-level capabilities: sd-cli is required for video
                // generation, ffmpeg for the webp→mp4 transcode + clip editor.
                CapabilitiesBanner(
                    need: [.sdCli, .ffmpeg],
                    onOpenQuickSetup: { OnboardingState.shared.show() },
                    onOpenSettings:   { openSettingsFallback() }
                )
                videoCompanionBanner
            }
            if mode == .edit {
                CapabilitiesBanner(
                    need: [.ffmpeg],
                    onOpenQuickSetup: { OnboardingState.shared.show() },
                    onOpenSettings:   { openSettingsFallback() }
                )
            }
            switch mode {
            case .generate, .edit:
                HSplitView {
                    controlPanel
                        .frame(minWidth: 360, idealWidth: 440)
                    previewPane
                }
            case .storyboard:
                StoryboardView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .insertPromptIntoVideoStudio)) { note in
            if let p = note.userInfo?["prompt"] as? String { params.prompt = p }
        }
        .onAppear { applyFamilyDefaultsIfNeeded() }
        .onChange(of: videoModelPath) { newPath in
            if newPath != lastSeenVideoPath {
                lastSeenVideoPath = newPath
                didApplyFamilyDefaults = false
                applyFamilyDefaultsIfNeeded()
            }
        }
    }

    private func applyFamilyDefaultsIfNeeded() {
        guard !didApplyFamilyDefaults else { return }
        guard !videoModelPath.isEmpty else { return }
        let family = DiffusionFamily.detect(path: videoModelPath)
        guard family == .wan21 || family == .ltx else { return }
        let d = family.defaults
        let initial = VideoGenParams()
        if params.cfgScale == initial.cfgScale { params.cfgScale = d.cfgScale }
        if params.guidance == initial.guidance { params.guidance = d.guidance }
        if params.steps    == initial.steps    { params.steps    = d.steps }
        if params.sampler  == initial.sampler  { params.sampler  = d.sampler }
        didApplyFamilyDefaults = true
    }

    /// Companion banner for video — uses the shared async-cached component.
    private var videoCompanionBanner: some View {
        CompanionBanner(diffusionPath: videoModelPath,
                        isVideo: true,
                        downloadsRoot: downloads.rootDirectory,
                        catalog: catalog,
                        jobs: downloads.jobs,
                        onPickModel: { pickerState.open(initialKind: .video) })
    }

    private var modeBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $mode) {
                ForEach(VideoMode.allCases) { m in
                    Label(m.rawValue, systemImage: m.sfSymbol).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 340)
            Spacer()
            if let v = loadedVideo {
                Text(v.lastPathComponent).font(.caption.monospaced()).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, 8)
        .background(VisualEffectBackground(material: .titlebar, blendingMode: .withinWindow))
        .overlay(Rectangle().fill(Theme.stroke).frame(height: 0.5), alignment: .bottom)
    }

    @ViewBuilder
    private var controlPanel: some View {
        switch mode {
        case .generate:   generateControls
        case .edit:       editControls
        case .storyboard: EmptyView()   // Storyboard provides its own full-width UI
        }
    }

    // MARK: Generate side

    private var generateControls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("PROMPT").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
                TextEditor(text: $params.prompt)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 100, maxHeight: 180)
                    .padding(8)
                    .foregroundStyle(Theme.text)
                    .tint(Theme.violet)
                    .glass(cornerRadius: Theme.Radius.md,
                           tint: Color.white.opacity(0.05), stroke: Theme.strokeStrong)

                DisclosureGroup {
                    TextEditor(text: $params.negativePrompt)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 60, maxHeight: 100)
                        .padding(8)
                        .foregroundStyle(Theme.text)
                        .tint(Theme.violet)
                        .glass(cornerRadius: Theme.Radius.sm)
                } label: {
                    Text("Negative prompt").font(.caption).foregroundStyle(Theme.textMuted)
                }

                Text("FIRST FRAME (optional – img→vid)").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
                ImageDropTarget(path: $params.initImagePath)
                Text("END FRAME (optional – interpolation)").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
                ImageDropTarget(path: $params.endImagePath)

                Text("DIMENSIONS").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
                HStack {
                    LabeledField(label: "W") { TextField("", value: $params.width, format: .number).frame(width: 70) }
                    LabeledField(label: "H") { TextField("", value: $params.height, format: .number).frame(width: 70) }
                    Menu {
                        Button("832 × 480 (Wan)")  { params.width = 832; params.height = 480 }
                        Button("960 × 544 (LTX)")  { params.width = 960; params.height = 544 }
                        Button("1280 × 720 (HD)")  { params.width = 1280; params.height = 720 }
                        Button("480 × 832 (vertical)") { params.width = 480; params.height = 832 }
                    } label: { Label("Presets", systemImage: "rectangle.on.rectangle") }
                        .menuStyle(.borderlessButton)
                }

                Text("TIMING").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
                sliderRow(title: "Frames", value: Binding(
                    get: { Double(params.frames) }, set: { params.frames = Int($0) }
                ), range: 8...129, format: "%.0f")
                sliderRow(title: "FPS", value: Binding(
                    get: { Double(params.fps) }, set: { params.fps = Int($0) }
                ), range: 8...60, format: "%.0f")
                Text("≈ \(String(format: "%.1f", Double(params.frames)/Double(params.fps))) seconds")
                    .font(.caption2).foregroundStyle(Theme.textFaint)

                Text("SAMPLING").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
                sliderRow(title: "Steps", value: Binding(
                    get: { Double(params.steps) }, set: { params.steps = Int($0) }
                ), range: 5...60, format: "%.0f")
                sliderRow(title: "CFG", value: $params.cfgScale, range: 1...12, format: "%.1f")
                Picker("Sampler", selection: $params.sampler) {
                    ForEach(SDSampler.allCases) { s in Text(s.label).tag(s) }
                }
                HStack {
                    LabeledField(label: "Seed") {
                        TextField("-1", value: $params.seed, format: .number)
                    }
                    Button { params.seed = Int64.random(in: 0...Int64.max) } label: {
                        Image(systemName: "dice")
                    }
                    .buttonStyle(.borderless)
                    .help("Random seed")
                    .accessibilityLabel("Randomize seed")
                }

                if generator.isGenerating {
                    Button { generator.cancel() } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.coral)
                } else {
                    Button { generator.generate(params) } label: {
                        Label("Generate Video", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.violet).controlSize(.large)
                    .disabled(params.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(Theme.Space.md)
        }
        .background(VisualEffectBackground(material: .sidebar, blendingMode: .withinWindow))
    }

    // MARK: Edit side

    private var editControls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("SOURCE").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
                Button(action: pickVideo) {
                    HStack {
                        Image(systemName: "film")
                        Text(loadedVideo?.lastPathComponent ?? "Choose video file…")
                            .font(.caption.monospaced())
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                    .padding(10).glass(cornerRadius: Theme.Radius.sm)
                }
                .buttonStyle(.plain)

                if let url = loadedVideo {
                    editorActions(for: url)
                }
            }
            .padding(Theme.Space.md)
        }
        .background(VisualEffectBackground(material: .sidebar, blendingMode: .withinWindow))
    }

    @ViewBuilder
    private func editorActions(for url: URL) -> some View {
        Group {
            Text("TRIM").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
            HStack {
                LabeledField(label: "Start (s)") { TextField("", value: $trimStart, format: .number) }
                LabeledField(label: "End (s)")   { TextField("", value: $trimEnd, format: .number) }
            }
            Button { applyOp(.trim(start: trimStart, end: trimEnd), to: url) } label: {
                Label("Apply trim", systemImage: "scissors")
            }

            Divider().background(Theme.stroke)
            Text("TRANSFORMS").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
            HStack(spacing: 8) {
                Button { applyOp(.rotate(degrees: 90), to: url) } label: { Image(systemName: "rotate.right") }
                    .help("Rotate 90° clockwise")
                    .accessibilityLabel("Rotate 90° clockwise")
                Button { applyOp(.rotate(degrees: 270), to: url) } label: { Image(systemName: "rotate.left") }
                    .help("Rotate 90° counter-clockwise")
                    .accessibilityLabel("Rotate 90° counter-clockwise")
                Button { applyOp(.flipHorizontal, to: url) } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .help("Flip horizontally")
                    .accessibilityLabel("Flip horizontally")
                Button { applyOp(.flipVertical, to: url) } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                    .help("Flip vertically")
                    .accessibilityLabel("Flip vertically")
                Button { applyOp(.grayscale, to: url) } label: { Label("Gray", systemImage: "circle.lefthalf.filled") }
                Button { applyOp(.mute, to: url) } label: { Label("Mute", systemImage: "speaker.slash") }
            }

            Divider().background(Theme.stroke)
            Text("SPEED").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
            HStack(spacing: 8) {
                Button { applyOp(.speed(factor: 0.5), to: url) } label: { Text("0.5x") }
                Button { applyOp(.speed(factor: 2.0), to: url) } label: { Text("2x")   }
                Button { applyOp(.speed(factor: 4.0), to: url) } label: { Text("4x")   }
                Button { applyOp(.interpolate(targetFps: 60), to: url) } label: { Text("Interp 60fps") }
            }

            Divider().background(Theme.stroke)
            Text("RESIZE / CROP").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
            HStack {
                Button { applyOp(.scale(width: 1920, height: -2), to: url) } label: { Text("1080p") }
                Button { applyOp(.scale(width: 1280, height: -2), to: url) } label: { Text("720p") }
                Button { applyOp(.scale(width: 854,  height: -2), to: url) } label: { Text("480p") }
            }

            Divider().background(Theme.stroke)
            Text("EXPORT").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
            HStack {
                Button { applyOp(.toGIF(fps: 15, width: 480), to: url, ext: "gif") } label: {
                    Label("To GIF", systemImage: "photo.stack")
                }
                Button { applyOp(.extractFrames(fps: 24, outputDir: framesDir(for: url)), to: url, ext: "frames") } label: {
                    Label("Extract frames", systemImage: "rectangle.split.3x3")
                }
            }

            if editor.isProcessing {
                Divider().background(Theme.stroke)
                ProgressView(value: editor.progress) {
                    Text(editor.statusMessage).font(.caption).foregroundStyle(Theme.textMuted)
                }.tint(Theme.violet)
            }
            if let err = editor.lastError {
                Text(err).font(.caption2.monospaced()).foregroundStyle(Theme.coral)
                    .padding(8).background(Theme.codeBg)
            }
        }
    }

    // MARK: Preview

    private var previewPane: some View {
        ZStack {
            VisualEffectBackground(material: .underWindowBackground, blendingMode: .behindWindow).ignoresSafeArea()
            GradientAtmosphere().ignoresSafeArea()
            VStack(spacing: 0) {
                Group {
                    if let err = generator.lastError,
                       generator.progress == nil,
                       mode == .generate {
                        videoErrorBanner(err)
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: generator.lastError ?? "")
                if let p = generator.progress, mode == .generate {
                    videoProgressView(p)
                } else if let r = generator.results.first, mode == .generate {
                    VideoPlayerView(url: r.url, params: r.params)
                        .onAppear { loadedVideo = r.url }
                } else if let url = loadedVideo {
                    VideoPlayerView(url: url, params: nil)
                } else {
                    emptyState
                }
            }
        }
    }

    private func videoErrorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.coral)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Video generation failed").font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Text(msg)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
            Spacer()
            DismissButton(tint: Theme.coral) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    generator.lastError = nil
                }
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm + 2)
        .background(Theme.coral.opacity(0.12))
        .overlay(Rectangle().fill(Theme.coral.opacity(0.55)).frame(height: 1.0), alignment: .bottom)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func videoProgressView(_ p: VideoGenProgress) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(Theme.stroke, lineWidth: 6).frame(width: 120, height: 120)
                Circle()
                    .trim(from: 0, to: max(0.02, p.fraction))
                    .stroke(Theme.brandGradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                VStack {
                    Text("\(Int(p.fraction*100))%").font(.title2.weight(.semibold)).foregroundStyle(Theme.text)
                    Text(p.message).font(.caption).foregroundStyle(Theme.textMuted)
                }
            }
            Text("Generating video — this can take several minutes")
                .font(.caption).foregroundStyle(Theme.textFaint)
            Button("Cancel") { generator.cancel() }.buttonStyle(.bordered)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.md) {
            ZStack {
                Circle().fill(Theme.brandGradient).frame(width: 100, height: 100)
                    .shadow(color: Theme.violet.opacity(0.4), radius: 30)
                Image(systemName: "film.stack").font(.system(size: 40)).foregroundStyle(.white)
            }
            Text("Video Studio").font(.system(size: 28, weight: .heavy)).foregroundStyle(Theme.text)
            Text(mode == .generate
                 ? "Type a prompt → generate. Requires Wan2.x or LTX-2 model."
                 : "Choose a video → trim, scale, restyle, export.")
                .font(.callout).foregroundStyle(Theme.textMuted).multilineTextAlignment(.center)
        }
    }

    // MARK: Helpers

    private func pickVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        if panel.runModal() == .OK, let url = panel.url {
            loadedVideo = url
            Task {
                let d = await VideoEditor.duration(of: url)
                if d > 0 {
                    trimEnd = min(d, trimStart + 5)
                }
            }
        }
    }

    private func applyOp(_ op: VideoEditOp, to input: URL, ext: String = "mp4") {
        let outDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mllama/media")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let stamp = DateFormatter.compactStamp.string(from: Date())
        let out = outDir.appendingPathComponent("\(input.deletingPathExtension().lastPathComponent)-\(stamp).\(ext)")
        Task {
            let result = await editor.apply(op, to: input, output: out)
            switch result {
            case .success(let url):
                self.loadedVideo = url
                MediaLibrary.shared.record(imported: url, kind: .video)
            case .failure(let msg):
                editor.lastError = msg.message
            }
        }
    }

    private func framesDir(for url: URL) -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mllama/media/frames")
        let dir = base.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-" + DateFormatter.compactStamp.string(from: Date()))
        return dir
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(Theme.textMuted).frame(width: 70, alignment: .leading)
            Slider(value: value, in: range).tint(Theme.violet)
            Text(String(format: format, value.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.text)
                .frame(width: 50, alignment: .trailing)
        }
    }
}

// MARK: - AVKit-backed player

struct VideoPlayerView: View {
    let url: URL
    let params: VideoGenParams?
    @State private var player: AVPlayer?

    var body: some View {
        VStack {
            if let player {
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
                    .padding(Theme.Space.md)
                    .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
            } else {
                ProgressView().controlSize(.large)
            }
            if let p = params {
                HStack(spacing: 10) {
                    metaPill(icon: "ruler", text: "\(p.width)×\(p.height)")
                    metaPill(icon: "film", text: "\(p.frames)f@\(p.fps)fps")
                    metaPill(icon: "list.number", text: "\(p.steps) steps")
                    Spacer()
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: { Label("Reveal", systemImage: "folder") }
                }
                .padding(.horizontal, Theme.Space.md).padding(.bottom, Theme.Space.sm)
            }
        }
        .onAppear { setupPlayer(for: url) }
        .onChange(of: url) { newURL in setupPlayer(for: newURL) }
        .onDisappear { player?.pause() }
    }

    private func setupPlayer(for url: URL) {
        // AVPlayer cleanly handles mp4 / mov / m4v. For webp / webm it
        // silently fails to load — transcode to a sibling mp4 (best-effort)
        // and hand AVPlayer the new file.
        let ext = url.pathExtension.lowercased()
        if ["mp4", "mov", "m4v"].contains(ext) {
            self.player = AVPlayer(url: url)
            self.player?.play()
            return
        }
        // Try a sibling .mp4 first (the generator usually produces one).
        let sibling = url.deletingPathExtension().appendingPathExtension("mp4")
        if FileManager.default.fileExists(atPath: sibling.path) {
            self.player = AVPlayer(url: sibling)
            self.player?.play()
            return
        }
        // Last resort: transcode on demand.
        Task { @MainActor in
            if let mp4 = await VideoTranscoder.toMP4(from: url) {
                self.player = AVPlayer(url: mp4)
                self.player?.play()
            } else {
                self.player = nil
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
