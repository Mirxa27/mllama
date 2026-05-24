import SwiftUI
import AppKit
import AVFoundation
import AVKit

struct GalleryView: View {
    @StateObject private var library = MediaLibrary.shared
    @State private var selected: MediaAsset?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                if library.filtered.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .frame(minWidth: 520, idealWidth: 680)

            // Detail
            if let asset = selected {
                AssetDetail(asset: asset, onDelete: {
                    library.remove(asset, deleteFiles: true)
                    selected = nil
                })
                .frame(minWidth: 380)
            } else {
                placeholderDetail
                    .frame(minWidth: 380)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Theme.brandGradient).frame(width: 28, height: 28)
                    Image(systemName: "square.grid.3x3.fill").foregroundStyle(.white).font(.caption)
                }
                Text("Gallery")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("\(library.filtered.count) of \(library.assets.count)")
                    .font(.caption)
                    .foregroundStyle(Theme.textFaint)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted).font(.caption)
                TextField("Search prompts, model names…", text: $library.searchQuery)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.text)
                    .tint(Theme.violet)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .glass(cornerRadius: Theme.Radius.sm)

            HStack(spacing: 6) {
                FilterChip(title: "All",    active: library.filter == nil)        { library.filter = nil }
                FilterChip(title: "Images", active: library.filter == .image)     { library.filter = .image }
                FilterChip(title: "Videos", active: library.filter == .video)     { library.filter = .video }
                Spacer()
                if !library.assets.isEmpty {
                    Menu {
                        Button("Clear gallery index (keep files)") { library.clear() }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(Theme.textMuted)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 22)
                }
            }
        }
        .padding(Theme.Space.md)
        .overlay(Rectangle().fill(Theme.stroke).frame(height: 0.5), alignment: .bottom)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                ForEach(library.filtered) { asset in
                    AssetTile(asset: asset, isSelected: selected?.id == asset.id) {
                        selected = asset
                    }
                }
            }
            .padding(Theme.Space.md)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.3x3").font(.system(size: 44)).foregroundStyle(Theme.textFaint)
            Text("No assets yet").foregroundStyle(Theme.textMuted)
            Text("Generate images or videos and they'll land here automatically.")
                .font(.caption).foregroundStyle(Theme.textFaint).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholderDetail: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 36)).foregroundStyle(Theme.textFaint)
            Text("Select an asset").foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Filter chip

struct FilterChip: View {
    let title: String
    let active: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(active ? Color.white : Theme.text)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(active ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.pane),
                            in: Capsule())
                .overlay(Capsule().strokeBorder(active ? Color.clear : Theme.stroke, lineWidth: 0.7))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Asset tile

struct AssetTile: View {
    let asset: MediaAsset
    let isSelected: Bool
    let action: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.codeBg)
                        .frame(height: 140)
                    if let img = image {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                            .frame(height: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    if asset.kind == .video {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "play.fill")
                                    .padding(6)
                                    .background(Color.black.opacity(0.55), in: Circle())
                                    .foregroundStyle(.white)
                            }
                            Spacer()
                        }
                        .padding(6)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? Theme.violet : Theme.stroke, lineWidth: isSelected ? 1.5 : 0.7)
                )
                Text(asset.prompt.isEmpty ? asset.displayName : asset.prompt)
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Image(systemName: asset.kind == .image ? "photo" : "play.rectangle.fill")
                        .font(.system(size: 8))
                    Text(asset.modelName)
                        .font(.system(size: 9))
                }
                .foregroundStyle(Theme.textFaint)
            }
        }
        .buttonStyle(.plain)
        .task { await load() }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([asset.url])
            }
            Button("Copy file") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([asset.url as NSURL])
            }
            Divider()
            Button("Remove from gallery") {
                MediaLibrary.shared.remove(asset, deleteFiles: false)
            }
            Button(role: .destructive) {
                MediaLibrary.shared.remove(asset, deleteFiles: true)
            } label: {
                Text("Delete file from disk…")
            }
        }
    }

    private func load() async {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let path: String
                switch asset.kind {
                case .image: path = asset.url.path
                case .video: path = asset.thumbnailURL?.path ?? asset.url.path
                }
                let img: NSImage?
                if asset.kind == .video, asset.thumbnailURL == nil {
                    img = Self.makeVideoThumbnail(at: asset.url)
                } else {
                    img = NSImage(contentsOfFile: path)
                }
                DispatchQueue.main.async {
                    self.image = img
                    cont.resume()
                }
            }
        }
    }

    static func makeVideoThumbnail(at url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        do {
            let cg = try gen.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } catch { return nil }
    }
}

// MARK: - Asset detail panel

struct AssetDetail: View {
    let asset: MediaAsset
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                bigPreview
                metaRows
                if !asset.prompt.isEmpty {
                    Text("PROMPT").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
                    Text(asset.prompt)
                        .font(.callout)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .padding(10)
                        .glass(cornerRadius: Theme.Radius.sm)
                }
                if !asset.negativePrompt.isEmpty {
                    Text("NEGATIVE").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
                    Text(asset.negativePrompt)
                        .font(.callout)
                        .foregroundStyle(Theme.textMuted)
                        .textSelection(.enabled)
                        .padding(10)
                        .glass(cornerRadius: Theme.Radius.sm)
                }
                if !asset.parameters.isEmpty {
                    Text("PARAMETERS").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(asset.parameters.keys.sorted(), id: \.self) { k in
                            HStack {
                                Text(k).font(.caption.monospaced()).foregroundStyle(Theme.textMuted)
                                Spacer()
                                Text(asset.parameters[k] ?? "").font(.caption.monospaced()).foregroundStyle(Theme.text)
                            }
                        }
                    }
                    .padding(10).glass(cornerRadius: Theme.Radius.sm)
                }
                HStack {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([asset.url]) } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.writeObjects([asset.url as NSURL])
                    } label: { Label("Copy file", systemImage: "doc.on.doc") }
                    Spacer()
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete file", systemImage: "trash")
                    }
                }
            }
            .padding(Theme.Space.md)
        }
    }

    @ViewBuilder
    private var bigPreview: some View {
        switch asset.kind {
        case .image:
            if let img = NSImage(contentsOfFile: asset.url.path) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .shadow(color: .black.opacity(0.4), radius: 14, x: 0, y: 6)
            }
        case .video:
            VideoPlayer(player: AVPlayer(url: asset.url))
                .frame(minHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
    }

    private var metaRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            metaRow("Model", asset.modelName)
            metaRow("Created", asset.createdAt.formatted(date: .abbreviated, time: .shortened))
            if asset.width > 0 {
                metaRow("Dimensions", "\(asset.width) × \(asset.height)")
            }
            metaRow("File size", asset.humanSize)
            if asset.elapsedSeconds > 0 {
                metaRow("Render time", String(format: "%.1fs", asset.elapsedSeconds))
            }
        }
    }

    private func metaRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(Theme.textMuted)
            Spacer()
            Text(v).font(.caption.monospacedDigit()).foregroundStyle(Theme.text)
        }
    }
}
