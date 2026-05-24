import SwiftUI
import AppKit

/// Routes to a workspace-specific sidebar so each tab gets context-relevant
/// content instead of always showing the chat model list.
struct AdaptiveSidebar: View {
    @EnvironmentObject var workspace: WorkspaceState

    var body: some View {
        Group {
            switch workspace.current {
            case .chat:        Sidebar()
            case .imageStudio: ImageGenSidebar()
            case .videoStudio: VideoGenSidebar()
            case .models:      ModelBrowserSidebar()
            case .gallery:     GallerySidebar()
            }
        }
    }
}

// MARK: - Image Gen sidebar

struct ImageGenSidebar: View {
    @EnvironmentObject var sd: SDServerController
    @EnvironmentObject var prompts: PromptLibrary
    @EnvironmentObject var generator: ImageGenerator

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    serverCard
                    promptsSection
                    recentSection
                }
                .padding(Theme.Space.sm)
            }
        }
    }

    private var header: some View {
        VStack(spacing: Theme.Space.sm) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Theme.brandGradient).frame(width: 28, height: 28)
                    Image(systemName: "photo.artframe").foregroundStyle(.white).font(.caption)
                }
                Text("Image Studio").font(.headline).foregroundStyle(Theme.text)
                Spacer()
            }
        }
        .padding(Theme.Space.sm)
        .overlay(Rectangle().fill(Theme.stroke).frame(height: 0.5), alignment: .bottom)
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text(statusLabel).font(.caption.weight(.medium)).foregroundStyle(Theme.text)
                Spacer()
                if case .stopped = sd.status { Button { sd.start() } label: { Image(systemName: "play.circle").font(.caption) }.buttonStyle(.borderless) }
                if case .running = sd.status { Button { sd.restart() } label: { Image(systemName: "arrow.clockwise").font(.caption) }.buttonStyle(.borderless) }
            }
            if let model = sd.modelPath {
                Text((model as NSString).lastPathComponent)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1).truncationMode(.middle)
            }
            if case .running = sd.status {
                Text("Port \(sd.runtimePort)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: Theme.Radius.md)
    }

    private var statusColor: Color {
        switch sd.status {
        case .running:        return Theme.mint
        case .starting:       return Theme.amber
        case .failed:         return Theme.coral
        case .notConfigured:  return Theme.textFaint
        case .stopped:        return Theme.textFaint
        }
    }
    private var statusLabel: String {
        switch sd.status {
        case .running:        return "Image server running"
        case .starting:       return "Loading model…"
        case .stopped:        return "Image server idle"
        case .failed:         return "Image server error"
        case .notConfigured:  return "Not configured"
        }
    }

    private var promptsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("SAVED PROMPTS").font(.caption2.weight(.bold)).foregroundStyle(Theme.textFaint)
                Spacer()
                Text("\(prompts.saved.filter { $0.kind == .image }.count)").font(.caption2).foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 4).padding(.top, 6)
            let imagePrompts = prompts.saved.filter { $0.kind == .image }.prefix(8)
            if imagePrompts.isEmpty {
                Text("Save prompts you like with the bookmark icon in the studio.")
                    .font(.caption).foregroundStyle(Theme.textMuted)
                    .padding(8)
            } else {
                ForEach(Array(imagePrompts), id: \.id) { p in
                    PromptRow(prompt: p, onUse: {
                        NotificationCenter.default.post(name: .insertPromptIntoImageStudio,
                                                       object: nil, userInfo: ["prompt": p.prompt])
                    })
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("RECENT").font(.caption2.weight(.bold)).foregroundStyle(Theme.textFaint)
                Spacer()
                Text("\(generator.results.count)").font(.caption2).foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 4).padding(.top, 6)
            ForEach(generator.results.prefix(6)) { r in
                HStack(spacing: 8) {
                    AsyncImageThumbnail(url: r.url, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.params.prompt).font(.caption2).foregroundStyle(Theme.text).lineLimit(1)
                        Text(r.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 9)).foregroundStyle(Theme.textFaint)
                    }
                    Spacer()
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
            }
            if generator.results.isEmpty {
                Text("Nothing generated yet.").font(.caption).foregroundStyle(Theme.textMuted).padding(8)
            }
        }
    }
}

// MARK: - Video Gen sidebar

struct VideoGenSidebar: View {
    @EnvironmentObject var prompts: PromptLibrary
    @EnvironmentObject var generator: VideoGenerator
    @EnvironmentObject var pipeline: VideoPipeline

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Theme.brandGradient).frame(width: 28, height: 28)
                    Image(systemName: "film.stack").foregroundStyle(.white).font(.caption)
                }
                Text("Video Studio").font(.headline).foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(Theme.Space.sm)
            .overlay(Rectangle().fill(Theme.stroke).frame(height: 0.5), alignment: .bottom)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    if pipeline.isRunning {
                        pipelineCard
                    }
                    promptsSection
                    storyboardTemplates
                    recentSection
                }
                .padding(Theme.Space.sm)
            }
        }
    }

    private var pipelineCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ProgressView().controlSize(.small)
                Text("Storyboard running").font(.caption.weight(.medium)).foregroundStyle(Theme.text)
                Spacer()
                Button { pipeline.cancel() } label: {
                    Image(systemName: "stop.circle.fill").foregroundStyle(Theme.coral)
                }
                .buttonStyle(.borderless)
            }
            if pipeline.currentSceneIndex >= 0 {
                Text("Scene \(pipeline.currentSceneIndex + 1) of \(pipeline.storyboard.scenes.count)")
                    .font(.caption2).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: Theme.Radius.md,
               tint: Theme.violet.opacity(0.12),
               stroke: Theme.violet.opacity(0.4))
    }

    private var promptsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("SAVED VIDEO PROMPTS").font(.caption2.weight(.bold)).foregroundStyle(Theme.textFaint)
                Spacer()
            }
            .padding(.horizontal, 4).padding(.top, 6)
            ForEach(Array(prompts.saved.filter { $0.kind == .video }.prefix(6)), id: \.id) { p in
                PromptRow(prompt: p, onUse: {
                    NotificationCenter.default.post(name: .insertPromptIntoVideoStudio,
                                                   object: nil, userInfo: ["prompt": p.prompt])
                })
            }
        }
    }

    private var storyboardTemplates: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("STORYBOARD TEMPLATES").font(.caption2.weight(.bold)).foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 4).padding(.top, 6)
            ForEach(Array(StoryboardTemplate.all.enumerated()), id: \.offset) { _, tpl in
                Button {
                    pipeline.load(tpl)
                } label: {
                    HStack {
                        Image(systemName: "rectangle.stack.fill").foregroundStyle(Theme.violet)
                        Text(tpl.title).font(.caption).foregroundStyle(Theme.text)
                        Spacer()
                        Text("\(tpl.scenes.count) scenes").font(.caption2).foregroundStyle(Theme.textFaint)
                    }
                    .padding(8)
                    .glass(cornerRadius: Theme.Radius.sm)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("RECENT VIDEOS").font(.caption2.weight(.bold)).foregroundStyle(Theme.textFaint)
                Spacer()
                Text("\(generator.results.count)").font(.caption2).foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 4).padding(.top, 6)
            ForEach(generator.results.prefix(5)) { r in
                HStack(spacing: 8) {
                    Image(systemName: "play.rectangle.fill")
                        .foregroundStyle(Theme.violet)
                        .frame(width: 32, height: 32)
                        .background(Theme.pane, in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.params.prompt).font(.caption2).foregroundStyle(Theme.text).lineLimit(1)
                        Text("\(r.params.frames)f @ \(r.params.fps)fps")
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.textFaint)
                    }
                    Spacer()
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
            }
            if generator.results.isEmpty {
                Text("Nothing generated yet.").font(.caption).foregroundStyle(Theme.textMuted).padding(8)
            }
        }
    }
}

// MARK: - Model browser sidebar

struct ModelBrowserSidebar: View {
    @EnvironmentObject var downloads: HFDownloadManager
    @EnvironmentObject var library: ModelLibrary

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Theme.brandGradient).frame(width: 28, height: 28)
                    Image(systemName: "shippingbox.fill").foregroundStyle(.white).font(.caption)
                }
                Text("Models").font(.headline).foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(Theme.Space.sm)
            .overlay(Rectangle().fill(Theme.stroke).frame(height: 0.5), alignment: .bottom)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    queueSection
                    localModelsSection
                    helpCard
                }
                .padding(Theme.Space.sm)
            }
        }
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("DOWNLOAD QUEUE").font(.caption2.weight(.bold)).foregroundStyle(Theme.textFaint)
                Spacer()
                Text("\(downloads.jobs.count)").font(.caption2).foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 4).padding(.top, 6)
            if downloads.jobs.isEmpty {
                Text("No downloads yet. Browse the right panel to find models.")
                    .font(.caption).foregroundStyle(Theme.textMuted).padding(8)
            } else {
                ForEach(downloads.jobs.prefix(8)) { job in
                    DownloadJobRow(job: job)
                }
            }
        }
    }

    private var localModelsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("LOCAL LLM MODELS").font(.caption2.weight(.bold)).foregroundStyle(Theme.textFaint)
                Spacer()
                Text("\(library.models.count)").font(.caption2).foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 4).padding(.top, 6)
            ForEach(library.models.prefix(8)) { m in
                HStack(spacing: 6) {
                    Image(systemName: m.source.sfSymbol).font(.caption2).foregroundStyle(Theme.violet)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.displayName).font(.caption2).foregroundStyle(Theme.text).lineLimit(1)
                        Text(m.humanSize).font(.system(size: 9)).foregroundStyle(Theme.textFaint)
                    }
                    Spacer()
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
            }
        }
    }

    private var helpCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Recommended", systemImage: "sparkles").font(.caption.weight(.semibold))
                .foregroundStyle(Theme.cyan)
            Text("Start with a small fast model:\n• Llama 3.2 3B (LLM, ~2GB)\n• FLUX.1 schnell GGUF (image, ~7GB)\n• Wan2.1 1.3B (video, ~3GB)")
                .font(.caption).foregroundStyle(Theme.textMuted)
        }
        .padding(10)
        .glass(cornerRadius: Theme.Radius.md, tint: Theme.cyan.opacity(0.08), stroke: Theme.cyan.opacity(0.3))
    }
}

// MARK: - Gallery sidebar

struct GallerySidebar: View {
    @EnvironmentObject var library: MediaLibrary

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Theme.brandGradient).frame(width: 28, height: 28)
                    Image(systemName: "square.grid.3x3.fill").foregroundStyle(.white).font(.caption)
                }
                Text("Gallery").font(.headline).foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(Theme.Space.sm)
            .overlay(Rectangle().fill(Theme.stroke).frame(height: 0.5), alignment: .bottom)

            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                statsCard
                Spacer()
            }
            .padding(Theme.Space.sm)
        }
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LIBRARY").font(.caption2.weight(.bold)).foregroundStyle(Theme.textFaint)
            HStack {
                statBox(label: "Images", value: library.assets.filter { $0.kind == .image }.count, color: Theme.violet)
                statBox(label: "Videos", value: library.assets.filter { $0.kind == .video }.count, color: Theme.cyan)
            }
            HStack {
                Image(systemName: "internaldrive").foregroundStyle(Theme.textMuted).font(.caption)
                Text(totalDiskUsage)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    private func statBox(label: String, value: Int, color: Color) -> some View {
        VStack {
            Text("\(value)").font(.title2.weight(.bold)).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .glass(cornerRadius: Theme.Radius.sm, tint: color.opacity(0.08), stroke: color.opacity(0.3))
    }

    private var totalDiskUsage: String {
        let bytes = library.assets.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Pieces

struct PromptRow: View {
    let prompt: SavedPrompt
    let onUse: () -> Void
    @State private var hovering = false
    @EnvironmentObject var prompts: PromptLibrary

    var body: some View {
        Button(action: onUse) {
            HStack(alignment: .top, spacing: 6) {
                if prompt.favorite {
                    Image(systemName: "star.fill").foregroundStyle(Theme.amber).font(.system(size: 9))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(prompt.displayTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(prompt.prompt)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.paneHover : Theme.pane))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(prompt.favorite ? "Unfavorite" : "Favorite") { prompts.toggleFavorite(prompt.id) }
            Button(role: .destructive) { prompts.remove(prompt.id) } label: { Text("Delete prompt") }
        }
    }
}

// MARK: - Cross-view notifications for sidebar→studio prompt insertion

extension Notification.Name {
    static let insertPromptIntoImageStudio = Notification.Name("Mllama.insertPromptIntoImageStudio")
    static let insertPromptIntoVideoStudio = Notification.Name("Mllama.insertPromptIntoVideoStudio")
}
