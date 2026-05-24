import SwiftUI
import AVKit
import AppKit

/// Long-video storyboard editor + executor. Each scene is a clip; scenes
/// chain together by reusing the previous clip's last frame as the next clip's
/// init image, so cuts feel continuous.
struct StoryboardView: View {
    @EnvironmentObject var pipeline: VideoPipeline
    @State private var selectedSceneId: UUID?
    @State private var showTemplates = false

    var body: some View {
        VSplitView {
            // Top: scenes + final preview
            HSplitView {
                sceneList
                    .frame(minWidth: 280, idealWidth: 320)
                sceneInspector
                    .frame(minWidth: 320, idealWidth: 360)
                previewPane
                    .frame(minWidth: 420)
            }
            // Bottom: timeline + run controls
            controlsAndTimeline
                .frame(minHeight: 130, idealHeight: 150, maxHeight: 200)
        }
    }

    // MARK: Scene list (left)

    private var sceneList: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "rectangle.stack.fill").foregroundStyle(Theme.violet)
                Text("Scenes").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Menu {
                    Button("Cinematic short") {
                        pipeline.load(StoryboardTemplate.cinematicShort)
                        selectedSceneId = pipeline.storyboard.scenes.first?.id
                    }
                    Button("Product reel") {
                        pipeline.load(StoryboardTemplate.productReel)
                        selectedSceneId = pipeline.storyboard.scenes.first?.id
                    }
                    Button("Abstract loop") {
                        pipeline.load(StoryboardTemplate.abstractLoop)
                        selectedSceneId = pipeline.storyboard.scenes.first?.id
                    }
                    Divider()
                    Button("Clear all", role: .destructive) {
                        pipeline.load(Storyboard())
                        selectedSceneId = nil
                    }
                } label: {
                    Image(systemName: "wand.and.sparkles").foregroundStyle(Theme.cyan)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
                .help("Load template")
            }
            .padding(Theme.Space.md)
            Divider().background(Theme.stroke)

            if pipeline.storyboard.scenes.isEmpty {
                emptyScenes
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(pipeline.storyboard.scenes.enumerated()), id: \.element.id) { idx, scene in
                            SceneRow(
                                index: idx,
                                scene: scene,
                                status: pipeline.sceneStatuses[scene.id] ?? .pending,
                                isCurrent: pipeline.currentSceneIndex == idx,
                                isSelected: selectedSceneId == scene.id,
                                onTap: { selectedSceneId = scene.id },
                                onDelete: { pipeline.removeScene(at: idx) }
                            )
                        }
                    }
                    .padding(Theme.Space.sm)
                }
            }

            Divider().background(Theme.stroke)
            HStack {
                Button {
                    pipeline.appendScene()
                    selectedSceneId = pipeline.storyboard.scenes.last?.id
                } label: {
                    Label("Add scene", systemImage: "plus.circle.fill")
                        .font(.callout)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.violet)
                Spacer()
                Text(durationLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(Theme.Space.sm)
        }
        .background(VisualEffectBackground(material: .sidebar, blendingMode: .withinWindow))
    }

    private var emptyScenes: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack").font(.system(size: 36)).foregroundStyle(Theme.textFaint)
            Text("No scenes yet").foregroundStyle(Theme.textMuted)
            Text("Add scenes or load a template to start a long video.")
                .font(.caption).foregroundStyle(Theme.textFaint).multilineTextAlignment(.center).padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var durationLabel: String {
        let total = pipeline.storyboard.scenes.reduce(0.0) { $0 + $1.seconds }
        return String(format: "%.1f s total", total)
    }

    // MARK: Scene inspector (middle)

    @ViewBuilder
    private var sceneInspector: some View {
        if let id = selectedSceneId,
           let idx = pipeline.storyboard.scenes.firstIndex(where: { $0.id == id }) {
            let scene = pipeline.storyboard.scenes[idx]
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    HStack {
                        Text("Scene \(idx + 1)").font(.headline).foregroundStyle(Theme.text)
                        Spacer()
                        Text(scene.id.uuidString.prefix(8))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.textFaint)
                    }
                    Text("PROMPT").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
                    TextEditor(text: Binding(
                        get: { scene.prompt },
                        set: { v in pipeline.updateScene(id) { $0.prompt = v } }
                    ))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 100, maxHeight: 160)
                    .padding(8)
                    .foregroundStyle(Theme.text)
                    .tint(Theme.violet)
                    .glass(cornerRadius: Theme.Radius.md,
                           tint: Color.white.opacity(0.05), stroke: Theme.strokeStrong)

                    DisclosureGroup {
                        TextEditor(text: Binding(
                            get: { scene.negativePrompt },
                            set: { v in pipeline.updateScene(id) { $0.negativePrompt = v } }
                        ))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 60, maxHeight: 100)
                        .padding(8)
                        .foregroundStyle(Theme.text)
                        .tint(Theme.violet)
                        .glass(cornerRadius: Theme.Radius.sm)
                    } label: {
                        Text("Negative").font(.caption).foregroundStyle(Theme.textMuted)
                    }

                    HStack {
                        LabeledField(label: "Duration") {
                            HStack(spacing: 4) {
                                TextField("", value: Binding(
                                    get: { scene.seconds },
                                    set: { v in pipeline.updateScene(id) { $0.seconds = max(0.5, v) } }
                                ), format: .number).frame(width: 50)
                                Text("s").font(.caption).foregroundStyle(Theme.textFaint)
                            }
                        }
                        LabeledField(label: "FPS") {
                            TextField("", value: Binding(
                                get: { scene.fps },
                                set: { v in pipeline.updateScene(id) { $0.fps = max(8, v) } }
                            ), format: .number).frame(width: 50)
                        }
                    }
                    Text("= \(scene.frames) frames")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textFaint)

                    HStack {
                        LabeledField(label: "Width") {
                            TextField("", value: Binding(
                                get: { scene.width },
                                set: { v in pipeline.updateScene(id) { $0.width = v } }
                            ), format: .number).frame(width: 70)
                        }
                        LabeledField(label: "Height") {
                            TextField("", value: Binding(
                                get: { scene.height },
                                set: { v in pipeline.updateScene(id) { $0.height = v } }
                            ), format: .number).frame(width: 70)
                        }
                    }
                    HStack {
                        LabeledField(label: "Steps") {
                            TextField("", value: Binding(
                                get: { scene.steps },
                                set: { v in pipeline.updateScene(id) { $0.steps = v } }
                            ), format: .number).frame(width: 50)
                        }
                        LabeledField(label: "CFG") {
                            TextField("", value: Binding(
                                get: { scene.cfgScale },
                                set: { v in pipeline.updateScene(id) { $0.cfgScale = v } }
                            ), format: .number).frame(width: 60)
                        }
                    }
                    LabeledField(label: "Seed") {
                        HStack(spacing: 4) {
                            TextField("-1", value: Binding(
                                get: { scene.seed },
                                set: { v in pipeline.updateScene(id) { $0.seed = v } }
                            ), format: .number).frame(maxWidth: .infinity)
                            Button {
                                pipeline.updateScene(id) { $0.seed = Int64.random(in: 0...Int64.max) }
                            } label: { Image(systemName: "dice") }.buttonStyle(.borderless)
                        }
                    }

                    Toggle("Continue from previous scene", isOn: Binding(
                        get: { scene.chainFromPrevious },
                        set: { v in pipeline.updateScene(id) { $0.chainFromPrevious = v } }
                    ))
                    .tint(Theme.violet)
                    .disabled(idx == 0)
                    .help("Uses the last frame of the prior scene as the init image for this one — gives a smooth visual handoff.")
                }
                .padding(Theme.Space.md)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "wand.and.stars").font(.system(size: 36)).foregroundStyle(Theme.textFaint)
                Text("Select a scene").foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Preview pane (right)

    private var previewPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PREVIEW").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
                Spacer()
                if let url = pipeline.finalVideoURL {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Label("Reveal", systemImage: "folder").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.cyan)
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, 8)
            .background(VisualEffectBackground(material: .titlebar, blendingMode: .withinWindow))
            .overlay(Rectangle().fill(Theme.stroke).frame(height: 0.5), alignment: .bottom)

            if let url = pipeline.finalVideoURL {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(Theme.Space.md)
            } else if pipeline.isRunning {
                runningOverlay
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: Theme.Space.md) {
            ZStack {
                Circle().fill(Theme.brandGradient).frame(width: 80, height: 80)
                    .shadow(color: Theme.violet.opacity(0.4), radius: 20)
                Image(systemName: "wand.and.stars").font(.system(size: 32)).foregroundStyle(.white)
            }
            Text("Storyboard")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.text)
            Text("Add scenes, then click Generate. Each scene becomes a clip; cuts chain via the last frame for smooth transitions.")
                .font(.callout)
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var runningOverlay: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Generating storyboard…")
                .font(.headline).foregroundStyle(Theme.text)
            if pipeline.currentSceneIndex >= 0 && pipeline.currentSceneIndex < pipeline.storyboard.scenes.count {
                let scene = pipeline.storyboard.scenes[pipeline.currentSceneIndex]
                let status = pipeline.sceneStatuses[scene.id] ?? .pending
                Text("Scene \(pipeline.currentSceneIndex + 1) of \(pipeline.storyboard.scenes.count) · \(status.label)")
                    .font(.callout)
                    .foregroundStyle(Theme.textMuted)
            }
            Text("Elapsed: \(formatElapsed(pipeline.elapsed))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Bottom timeline + controls

    private var controlsAndTimeline: some View {
        VStack(spacing: 0) {
            Divider().background(Theme.stroke)
            HStack(spacing: 12) {
                if pipeline.isRunning {
                    if pipeline.isPaused {
                        Button { pipeline.resume() } label: {
                            Label("Resume", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.mint)
                    } else {
                        Button { pipeline.pause() } label: {
                            Label("Pause", systemImage: "pause.fill")
                        }
                        .buttonStyle(.bordered)
                    }
                    Button { pipeline.cancel() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.coral)
                } else {
                    Button { pipeline.run() } label: {
                        Label("Generate \(pipeline.storyboard.scenes.count)-scene story", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.violet)
                    .controlSize(.large)
                    .disabled(pipeline.storyboard.scenes.isEmpty)
                }
                Spacer()
                interpolateMenu
                audioPicker
            }
            .padding(Theme.Space.md)

            // Per-scene timeline strip
            timelineStrip
                .frame(height: 60)
                .padding(.horizontal, Theme.Space.md)
                .padding(.bottom, Theme.Space.sm)

            if let err = pipeline.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(Theme.coral)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.bottom, Theme.Space.sm)
            }
        }
        .background(VisualEffectBackground(material: .hudWindow, blendingMode: .withinWindow))
    }

    @ViewBuilder
    private var interpolateMenu: some View {
        let fps = pipeline.storyboard.interpolateTo
        Menu {
            Button("Off (use scene FPS)") { setInterp(0) }
            Button("Interpolate to 30 fps") { setInterp(30) }
            Button("Interpolate to 60 fps") { setInterp(60) }
            Button("Interpolate to 120 fps") { setInterp(120) }
        } label: {
            Label(fps == 0 ? "No interpolation" : "Interp → \(fps) fps", systemImage: "speedometer")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Smooth the final video using ffmpeg's motion-compensated frame interpolation.")
    }

    @ViewBuilder
    private var audioPicker: some View {
        let hasAudio = pipeline.storyboard.audioTrackPath != nil
        Button {
            if hasAudio {
                setAudio(nil)
            } else {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, .wav]
                if panel.runModal() == .OK, let url = panel.url {
                    setAudio(url.path)
                }
            }
        } label: {
            Label(hasAudio ? "Audio attached" : "Add audio", systemImage: hasAudio ? "music.note" : "music.note.list")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(hasAudio ? Theme.mint : Theme.textMuted)
    }

    private func setInterp(_ fps: Int) {
        var s = pipeline.storyboard
        s.interpolateTo = fps
        pipeline.load(s)
    }

    private func setAudio(_ path: String?) {
        var s = pipeline.storyboard
        s.audioTrackPath = path
        pipeline.load(s)
    }

    private var timelineStrip: some View {
        GeometryReader { geo in
            let total = pipeline.storyboard.scenes.reduce(0.0) { $0 + $1.seconds }
            HStack(spacing: 2) {
                ForEach(Array(pipeline.storyboard.scenes.enumerated()), id: \.element.id) { idx, scene in
                    let status = pipeline.sceneStatuses[scene.id] ?? .pending
                    TimelineSegment(
                        index: idx,
                        scene: scene,
                        status: status,
                        widthFraction: total > 0 ? scene.seconds / total : 1.0 / Double(max(1, pipeline.storyboard.scenes.count))
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func formatElapsed(_ s: TimeInterval) -> String {
        let m = Int(s) / 60
        let sec = Int(s) % 60
        return m > 0 ? "\(m)m \(sec)s" : "\(sec)s"
    }
}

// MARK: - Scene row

struct SceneRow: View {
    let index: Int
    let scene: StoryScene
    let status: StorySceneStatus
    let isCurrent: Bool
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(rowColor)
                        .frame(width: 30, height: 30)
                    Text("\(index + 1)")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(scene.prompt.isEmpty ? "(empty prompt)" : scene.prompt)
                        .font(.caption)
                        .foregroundStyle(scene.prompt.isEmpty ? Theme.textFaint : Theme.text)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Label(String(format: "%.1fs", scene.seconds), systemImage: "clock")
                            .font(.system(size: 9))
                        Label("\(scene.width)×\(scene.height)", systemImage: "ruler")
                            .font(.system(size: 9))
                        if scene.chainFromPrevious && index > 0 {
                            Image(systemName: "link").font(.system(size: 9)).foregroundStyle(Theme.violet)
                                .help("Chains from previous scene")
                        }
                    }
                    .foregroundStyle(Theme.textFaint)
                    statusLine
                }
                Spacer()
                if hovering && !isCurrent {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textFaint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Theme.violet.opacity(0.18) : hovering ? Theme.paneHover : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isCurrent ? Theme.violet : Color.clear, lineWidth: isCurrent ? 1.5 : 0)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var rowColor: AnyShapeStyle {
        switch status {
        case .done:                   return AnyShapeStyle(Theme.mint)
        case .failed:                 return AnyShapeStyle(Theme.coral)
        case .generating, .extractingTransition:
                                      return AnyShapeStyle(Theme.brandGradient)
        default:                      return AnyShapeStyle(Theme.violet.opacity(0.55))
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .pending:
            EmptyView()
        case .extractingTransition:
            Label("Linking…", systemImage: "link")
                .font(.system(size: 9)).foregroundStyle(Theme.violet)
        case .generating(let s, let t):
            HStack(spacing: 5) {
                ProgressView(value: Double(s) / Double(max(1, t)))
                    .progressViewStyle(.linear)
                    .tint(Theme.violet)
                Text("\(s)/\(t)").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.text)
            }
        case .stitching:
            Label("Stitching…", systemImage: "rectangle.stack")
                .font(.system(size: 9)).foregroundStyle(Theme.cyan)
        case .done:
            Label("Done", systemImage: "checkmark.seal.fill")
                .font(.system(size: 9)).foregroundStyle(Theme.mint)
        case .failed(let m):
            Label(String(m.prefix(40)), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 9)).foregroundStyle(Theme.coral)
                .lineLimit(1)
        }
    }
}

// MARK: - Timeline segment

struct TimelineSegment: View {
    let index: Int
    let scene: StoryScene
    let status: StorySceneStatus
    let widthFraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Theme.pane)
                RoundedRectangle(cornerRadius: 6)
                    .fill(statusColor.opacity(0.45))
                    .frame(width: geo.size.width * CGFloat(status.fraction))
                    .animation(.easeOut(duration: 0.3), value: status.fraction)
                HStack {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(String(format: "%.1fs", scene.seconds))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 6)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6).strokeBorder(statusColor.opacity(0.7), lineWidth: 0.7)
            )
        }
        .frame(maxWidth: .infinity)
        .frame(width: nil)
        .layoutPriority(widthFraction)
    }

    private var statusColor: Color {
        switch status {
        case .done:      return Theme.mint
        case .failed:    return Theme.coral
        case .generating, .extractingTransition: return Theme.violet
        case .stitching: return Theme.cyan
        case .pending:   return Theme.textFaint
        }
    }
}
