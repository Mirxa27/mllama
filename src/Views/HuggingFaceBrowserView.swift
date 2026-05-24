import SwiftUI

struct HuggingFaceBrowserView: View {
    @StateObject private var vm = HFBrowserVM()
    @StateObject private var downloads = HFDownloadManager.shared
    @State private var selectedModel: HFModel?

    var body: some View {
        HSplitView {
            // Left: search results
            VStack(spacing: 0) {
                header
                Divider().background(Theme.stroke)
                if vm.isLoading && vm.results.isEmpty {
                    loadingState
                } else if vm.results.isEmpty && !vm.lastQuerySent.isEmpty {
                    emptyState
                } else if vm.results.isEmpty {
                    curatedPicks
                } else {
                    resultsList
                }
                Divider().background(Theme.stroke)
                downloadsPanel
            }
            .frame(minWidth: 460, idealWidth: 540)

            // Right: details for the selected repo
            ModelDetailPanel(model: selectedModel, vm: vm, downloads: downloads)
                .frame(minWidth: 460)
        }
        .task {
            if vm.results.isEmpty { await vm.search() }
        }
    }

    // MARK: Header (search + filters)

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.brandGradient).frame(width: 28, height: 28)
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("HuggingFace Hub").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("Search & download local-runnable models")
                        .font(.caption).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                tokenPill
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted).font(.callout)
                TextField("Search HuggingFace (e.g. flux, sdxl, wan)…", text: $vm.filters.query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.text)
                    .tint(Theme.violet)
                    .onSubmit { Task { await vm.search() } }
                if vm.isLoading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .glass(cornerRadius: Theme.Radius.md)

            HStack(spacing: 8) {
                FilterPicker(title: "Task", selection: $vm.filters.task, cases: HFTask.allCases.map { ($0, $0.label, $0.sfSymbol) })
                FilterPicker(title: "Format", selection: $vm.filters.format, cases: HFFormat.allCases.map { ($0, $0.label, "doc") })
                FilterPicker(title: "Sort", selection: $vm.filters.sort, cases: HFSort.allCases.map { ($0, $0.label, "arrow.up.arrow.down") })
                Spacer()
                Button(action: { Task { await vm.search() } }) {
                    Label("Search", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.violet)
            }
        }
        .padding(Theme.Space.md)
    }

    private var tokenPill: some View {
        let hasToken = (UserDefaults.standard.string(forKey: HFKeys.token) ?? "").isEmpty == false
        return HStack(spacing: 5) {
            Image(systemName: hasToken ? "key.fill" : "key")
                .foregroundStyle(hasToken ? Theme.mint : Theme.textMuted)
                .font(.caption)
            Text(hasToken ? "Authenticated" : "Anonymous")
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .glass(cornerRadius: 999)
        .help(hasToken ? "Higher rate limits + access to gated models" : "Set HF token in Settings → HuggingFace")
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Searching HuggingFace…").foregroundStyle(Theme.textMuted).font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.circle").font(.system(size: 36)).foregroundStyle(Theme.textFaint)
            Text("No models matched your filters.").foregroundStyle(Theme.textMuted)
            Text("Try a broader search or change format / task.").font(.caption).foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var curatedPicks: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                ForYourMacSection()
                curatedSection(title: "Image generation", items: HFCurated.imageGen)
                curatedSection(title: "Video generation",  items: HFCurated.videoGen)
                curatedSection(title: "LLMs (text generation)", items: HFCurated.llm)
            }
            .padding(Theme.Space.md)
        }
    }

    private func curatedSection(title: String, items: [(id: String, label: String, blurb: String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textFaint)
            ForEach(items, id: \.id) { item in
                Button {
                    Task {
                        vm.filters.query = item.id
                        await vm.search()
                    }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "sparkles").foregroundStyle(Theme.violet).font(.callout)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                            Text(item.id).font(.caption2.monospaced()).foregroundStyle(Theme.textFaint)
                            Text(item.blurb).font(.caption).foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right.circle").foregroundStyle(Theme.textFaint)
                    }
                    .padding(10)
                    .glass(cornerRadius: Theme.Radius.md)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Results list

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(vm.results) { model in
                    ModelRow(model: model, isSelected: selectedModel?.id == model.id) {
                        selectedModel = model
                        Task { await vm.loadDetail(for: model.id) }
                    }
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
        }
    }

    // MARK: Downloads panel (bottom)

    @ViewBuilder
    private var downloadsPanel: some View {
        if !downloads.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.cyan)
                    Text("Downloads")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Button("Clear completed") { downloads.clearCompleted() }
                        .controlSize(.small)
                        .foregroundStyle(Theme.textMuted)
                }
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(downloads.jobs) { job in
                            DownloadJobRow(job: job)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            .padding(Theme.Space.sm)
            .background(VisualEffectBackground(material: .hudWindow, blendingMode: .withinWindow))
        }
    }
}

// MARK: - "For Your Mac" hardware-aware recommendations

struct ForYourMacSection: View {
    @EnvironmentObject var monitor: ResourceMonitor
    @EnvironmentObject var downloads: HFDownloadManager
    @State private var showAll = false
    @State private var selectedKind: RecommendKind? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(Theme.violet)
                Text("FOR YOUR \(monitor.hardware.chipVariant.shortName.uppercased()) · \(Int(monitor.hardware.totalRamGB)) GB")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.violet)
                Spacer()
                Picker("", selection: $selectedKind) {
                    Text("All").tag(RecommendKind?.none)
                    Text("LLM").tag(RecommendKind?.some(.llm))
                    Text("Image").tag(RecommendKind?.some(.image))
                    Text("Video").tag(RecommendKind?.some(.video))
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            // System-aware blurb
            Text(blurb)
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
                .padding(.bottom, 2)

            ForEach(visibleModels) { rec in
                RecommendedRow(rec: rec)
            }

            if !showAll, ModelRecommender.canRun(on: monitor.hardware, kind: selectedKind).count > 4 {
                Button {
                    withAnimation { showAll = true }
                } label: {
                    Label("Show \(ModelRecommender.canRun(on: monitor.hardware, kind: selectedKind).count - 4) more compatible models",
                          systemImage: "chevron.down.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.violet)
            }

            // Also mention what you'd unlock with more RAM
            if let nextTierCount = nextTierCount, nextTierCount > 0 {
                Text("With more RAM you'd unlock \(nextTierCount) larger model\(nextTierCount == 1 ? "" : "s").")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .padding(.top, 4)
            }
        }
        .padding(Theme.Space.md)
        .glassCard(cornerRadius: Theme.Radius.md,
                   tint: Theme.violet.opacity(0.08),
                   stroke: Theme.violet.opacity(0.35))
    }

    private var visibleModels: [ModelRec] {
        let all = ModelRecommender.canRun(on: monitor.hardware, kind: selectedKind)
        return showAll ? all : Array(all.prefix(4))
    }

    private var nextTierCount: Int? {
        let cant = ModelRecommender.cannotRun(on: monitor.hardware, kind: selectedKind)
        return cant.isEmpty ? nil : cant.count
    }

    private var blurb: String {
        let hw = monitor.hardware
        let canCount = ModelRecommender.canRun(on: hw).count
        switch hw.ramTier {
        case .small:
            return "Your \(Int(hw.totalRamGB)) GB Mac runs \(canCount) curated models. Stick to small Llamas and SDXL Turbo for snappy generation."
        case .mid:
            return "Your \(Int(hw.totalRamGB)) GB Mac runs \(canCount) curated models — great range, including FLUX schnell and 7-8B LLMs."
        case .large:
            return "Your \(Int(hw.totalRamGB)) GB Mac runs \(canCount) curated models including FLUX dev Q8, SD3.5 Large, and Wan2.1 video."
        case .xl:
            return "Your \(Int(hw.totalRamGB)) GB Mac runs every model in the catalog (\(canCount)) — including Llama 3.3 70B and high-quality video."
        }
    }
}

struct RecommendedRow: View {
    let rec: ModelRec
    @EnvironmentObject var downloads: HFDownloadManager
    @State private var hovering = false
    @State private var queued = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(kindColor.opacity(0.18)).frame(width: 38, height: 38)
                Image(systemName: rec.kind.sfSymbol).foregroundStyle(kindColor).font(.callout)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rec.label).font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                    if rec.tags.contains("recommended") {
                        Text("recommended").font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.violet.opacity(0.22), in: Capsule())
                            .foregroundStyle(Theme.violet)
                    }
                    if rec.tags.contains("fast") {
                        Text("fast").font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.cyan.opacity(0.22), in: Capsule())
                            .foregroundStyle(Theme.cyan)
                    }
                }
                Text(rec.blurb).font(.caption2).foregroundStyle(Theme.textMuted).lineLimit(2)
                HStack(spacing: 10) {
                    Label(rec.humanDownload, systemImage: "arrow.down.circle").font(.system(size: 9))
                    Label(rec.humanRam, systemImage: "memorychip").font(.system(size: 9))
                    Text(rec.repoId).font(.system(size: 9, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                }
                .foregroundStyle(Theme.textFaint)
            }
            Spacer()
            Button {
                downloads.enqueue(repoId: rec.repoId, file: rec.filename)
                queued = true
            } label: {
                if queued {
                    Label("Queued", systemImage: "checkmark")
                        .font(.caption)
                } else {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(queued ? Theme.mint : Theme.violet)
            .controlSize(.small)
            .disabled(queued)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Theme.paneHover : Theme.pane)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(hovering ? Theme.violet.opacity(0.4) : Theme.stroke, lineWidth: 0.7)
        )
        .onHover { hovering = $0 }
    }

    private var kindColor: Color {
        switch rec.kind {
        case .llm:   return Theme.cyan
        case .image: return Theme.violet
        case .video: return Theme.magenta
        }
    }
}

// MARK: - VM

@MainActor
final class HFBrowserVM: ObservableObject {
    @Published var filters: HFFilters = HFFilters()
    @Published var results: [HFModel] = []
    @Published var isLoading: Bool = false
    @Published var lastQuerySent: String = ""
    @Published var detail: HFModelDetail?
    @Published var lastError: String?

    func search() async {
        isLoading = true
        defer { isLoading = false }
        lastError = nil
        lastQuerySent = filters.query
        do {
            let models = try await HuggingFaceClient.shared.search(filters: filters)
            self.results = models
        } catch {
            self.lastError = error.localizedDescription
            self.results = []
        }
    }

    func loadDetail(for repoId: String) async {
        detail = nil
        do {
            let d = try await HuggingFaceClient.shared.detail(repoId: repoId)
            self.detail = d
        } catch {
            self.lastError = error.localizedDescription
        }
    }
}

// MARK: - Pieces

struct FilterPicker<T: Hashable & Identifiable>: View {
    let title: String
    @Binding var selection: T
    let cases: [(T, String, String)]   // (value, label, sfSymbol)

    var body: some View {
        Menu {
            ForEach(cases, id: \.0.id) { (val, label, sym) in
                Button {
                    selection = val
                } label: {
                    Label(label, systemImage: sym)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(title).font(.caption).foregroundStyle(Theme.textFaint)
                if let row = cases.first(where: { $0.0 == selection }) {
                    Text(row.1).font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
                }
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glass(cornerRadius: Theme.Radius.sm)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct ModelRow: View {
    let model: HFModel
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 6) {
                    Image(systemName: pipelineIcon)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.id)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Label(formatCount(model.downloads), systemImage: "arrow.down.circle")
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
                        Label(formatCount(model.likes), systemImage: "heart.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.coral.opacity(0.85))
                        if let lib = model.libraryName {
                            Text(lib).font(.caption2.monospaced())
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.violet.opacity(0.22), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(Theme.text)
                        }
                        if let pt = model.pipelineTag {
                            Text(pt).font(.caption2)
                                .foregroundStyle(Theme.cyan)
                        }
                    }
                    HStack(spacing: 4) {
                        ForEach(Array(model.tags.prefix(5)), id: \.self) { tag in
                            Text(tag).font(.system(size: 9))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .foregroundStyle(Theme.textMuted)
                                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                }
                Spacer()
                if model.gated {
                    Image(systemName: "lock.fill").foregroundStyle(Theme.amber).font(.caption)
                        .help("Gated — requires HF token + accepted terms")
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Theme.violet.opacity(0.18) : hovering ? Theme.paneHover : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Theme.violet.opacity(0.55) : Color.clear, lineWidth: 0.7)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
    }

    private var pipelineIcon: String {
        switch model.pipelineTag {
        case "text-to-image":     return "photo.on.rectangle.angled"
        case "image-to-image":    return "wand.and.rays"
        case "image-to-video":    return "play.rectangle.fill"
        case "text-to-video":     return "film"
        case "text-generation":   return "text.bubble"
        case "automatic-speech-recognition": return "waveform"
        case "text-to-speech":    return "speaker.wave.2.fill"
        default:                  return "shippingbox"
        }
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n)/1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n)/1_000) }
        return "\(n)"
    }
}

// MARK: - Detail panel

struct ModelDetailPanel: View {
    let model: HFModel?
    @ObservedObject var vm: HFBrowserVM
    @ObservedObject var downloads: HFDownloadManager
    @EnvironmentObject var catalog: UnifiedModelCatalog
    @State private var fileSelections: Set<String> = []

    var body: some View {
        if let m = model {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    header(m)
                    if let d = vm.detail, d.model.id == m.id {
                        filesList(d.files, repoId: m.id)
                        Divider().background(Theme.stroke)
                        actionBar(d, repoId: m.id)
                    } else {
                        HStack { ProgressView().controlSize(.small); Text("Loading files…").foregroundStyle(Theme.textMuted) }
                            .padding()
                    }
                }
                .padding(Theme.Space.md)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "shippingbox").font(.system(size: 44)).foregroundStyle(Theme.textFaint)
                Text("Select a model").foregroundStyle(Theme.textMuted)
                Text("Or browse the curated picks on the left.").font(.caption).foregroundStyle(Theme.textFaint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ m: HFModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Theme.brandGradient).frame(width: 44, height: 44)
                    Image(systemName: "shippingbox.fill").foregroundStyle(.white).font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.displayName).font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                    Text(m.author).font(.caption).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                Link(destination: m.urlOnHub) {
                    Label("View on Hub", systemImage: "safari")
                        .font(.caption)
                }
            }
            HStack(spacing: 10) {
                if let pt = m.pipelineTag {
                    Label(pt, systemImage: "tag")
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .glass(cornerRadius: 999, tint: Theme.cyan.opacity(0.15), stroke: Theme.cyan.opacity(0.45))
                        .foregroundStyle(Theme.cyan)
                }
                if let lib = m.libraryName {
                    Label(lib, systemImage: "doc")
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .glass(cornerRadius: 999, tint: Theme.violet.opacity(0.15), stroke: Theme.violet.opacity(0.45))
                        .foregroundStyle(Theme.violet)
                }
                Spacer()
            }
            HStack(spacing: 14) {
                Label("\(m.downloads) downloads", systemImage: "arrow.down.circle")
                    .font(.caption).foregroundStyle(Theme.textMuted)
                Label("\(m.likes) likes", systemImage: "heart.fill")
                    .font(.caption).foregroundStyle(Theme.coral.opacity(0.85))
                if let lm = m.lastModified {
                    Label(lm.prefix(10), systemImage: "calendar")
                        .font(.caption).foregroundStyle(Theme.textFaint)
                }
            }
        }
    }

    private func filesList(_ files: [HFFile], repoId: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("FILES").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
                Spacer()
                Text("\(files.count) files · \(ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.size }, countStyle: .file))")
                    .font(.caption).foregroundStyle(Theme.textFaint)
            }
            ForEach(files) { file in
                FileRow(file: file, repoId: repoId,
                        isSelected: fileSelections.contains(file.path),
                        toggle: {
                            if fileSelections.contains(file.path) {
                                fileSelections.remove(file.path)
                            } else {
                                fileSelections.insert(file.path)
                            }
                        })
            }
        }
    }

    private func actionBar(_ detail: HFModelDetail, repoId: String) -> some View {
        // Detect the family for the user-visible bundle button. We sniff
        // either the selected file or the first GGUF in the repo so a
        // FLUX/SD3/Wan/LTX checkpoint suggests its required companions.
        let probePath: String = {
            if let first = fileSelections.sorted().first { return first }
            if let f = detail.files.first(where: { $0.isGGUF }) { return f.path }
            return detail.files.first?.path ?? repoId
        }()
        let family = DiffusionFamily.detect(path: probePath)
        let needsCompanions = !ModelBundle.requiredCompanions(for: family).isEmpty
        return HStack(spacing: 10) {
            Button {
                let selected = detail.files.filter { fileSelections.contains($0.path) }
                let targets = selected.isEmpty ? detail.files.filter { isWorthDownloading($0) } : selected
                _ = downloads.enqueueRepo(repoId: repoId, files: targets)
            } label: {
                Label(fileSelections.isEmpty ? "Download recommended" : "Download \(fileSelections.count) selected",
                      systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.violet)

            if needsCompanions {
                Button {
                    // First push the diffusion file(s), then enqueue any
                    // companions that aren't already on disk. Catalog
                    // dedupe inside enqueueMissingCompanions guards against
                    // double-queuing.
                    let selected = detail.files.filter { fileSelections.contains($0.path) }
                    let targets = selected.isEmpty ? detail.files.filter { isWorthDownloading($0) } : selected
                    _ = downloads.enqueueRepo(repoId: repoId, files: targets)
                    _ = catalog.enqueueMissingCompanions(diffusionPath: probePath, family: family)
                } label: {
                    Label("Download + \(family.label) companions",
                          systemImage: "puzzlepiece.extension.fill")
                }
                .buttonStyle(.bordered)
                .tint(Theme.amber)
                .help("Also queues the T5 / CLIP / VAE files this family requires to actually generate.")
            }

            Button {
                if let f = detail.files.first(where: { $0.isGGUF }) {
                    let dest = downloads.destination(repoId: repoId, file: f.path)
                    NSWorkspace.shared.activateFileViewerSelecting([dest.deletingLastPathComponent()])
                }
            } label: {
                Label("Reveal cache folder", systemImage: "folder")
            }
            Spacer()
        }
    }

    private func isWorthDownloading(_ f: HFFile) -> Bool {
        // Conservative default selection: just the main GGUFs, mmproj projector, VAE, config.
        let n = f.displayName.lowercased()
        if f.isGGUF { return true }
        if n.hasSuffix(".safetensors") { return true }
        if n == "config.json" || n == "model.safetensors.index.json" { return true }
        return false
    }
}

struct FileRow: View {
    let file: HFFile
    let repoId: String
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Theme.violet : Theme.textFaint)
            }
            .buttonStyle(.plain)
            Image(systemName: iconForExt(file.ext))
                .foregroundStyle(Theme.cyan)
                .font(.caption)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.displayName).font(.caption.monospaced()).foregroundStyle(Theme.text)
                Text(file.humanSize).font(.system(size: 9)).foregroundStyle(Theme.textFaint)
            }
            Spacer()
            Button {
                HFDownloadManager.shared.enqueue(repoId: repoId, file: file.path)
            } label: {
                Image(systemName: "arrow.down.circle").font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.violet)
            .help("Download just this file")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Theme.violet.opacity(0.10) : Color.clear))
    }

    private func iconForExt(_ ext: String) -> String {
        switch ext {
        case "gguf":        return "shippingbox.fill"
        case "safetensors": return "doc.fill"
        case "json":        return "curlybraces"
        case "txt", "md":   return "doc.text"
        case "png", "jpg", "jpeg", "webp": return "photo"
        default:            return "doc"
        }
    }
}

struct DownloadJobRow: View {
    @ObservedObject var job: HFDownloadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                stateIcon
                Text(job.displayName).font(.caption.monospaced())
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
                Text(rateLabel).font(.caption2.monospaced()).foregroundStyle(Theme.textFaint)
                actionButton
            }
            ProgressView(value: job.progress.fraction)
                .progressViewStyle(.linear)
                .tint(Theme.violet)
            HStack {
                Text("\(job.progress.humanReceived) / \(job.progress.humanTotal)")
                    .font(.caption2.monospaced()).foregroundStyle(Theme.textFaint)
                Spacer()
                Text(statusText).font(.caption2).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(8)
        .glass(cornerRadius: Theme.Radius.sm)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch job.state {
        case .queued:    Image(systemName: "clock").foregroundStyle(Theme.amber).font(.caption)
        case .running:   ProgressView().controlSize(.mini)
        case .paused:    Image(systemName: "pause.fill").foregroundStyle(Theme.amber).font(.caption)
        case .completed: Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.mint).font(.caption)
        case .failed:    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.coral).font(.caption)
        case .cancelled: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.coral).font(.caption)
        }
    }

    private var rateLabel: String {
        switch job.state {
        case .running: return "\(job.progress.humanRate) · ETA \(job.progress.humanETA)"
        default:       return ""
        }
    }

    private var statusText: String {
        switch job.state {
        case .queued:        return "Queued"
        case .running:       return ""
        case .paused:        return "Paused"
        case .completed:     return "Saved to \(job.destination.deletingLastPathComponent().lastPathComponent)"
        case .failed(let m): return m.prefix(80) + ""
        case .cancelled:     return "Cancelled"
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch job.state {
        case .running:
            Button {
                HFDownloadManager.shared.pause(job: job)
            } label: { Image(systemName: "pause.circle").foregroundStyle(Theme.textMuted) }
                .buttonStyle(.borderless)
        case .paused, .failed, .cancelled:
            Button {
                Task { await HFDownloadManager.shared.resume(job: job) }
            } label: { Image(systemName: "play.circle").foregroundStyle(Theme.violet) }
                .buttonStyle(.borderless)
        case .completed:
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([job.destination])
            } label: { Image(systemName: "folder").foregroundStyle(Theme.cyan) }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
        case .queued: EmptyView()
        }
    }
}
