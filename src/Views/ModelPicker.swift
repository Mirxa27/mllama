import SwiftUI
import AppKit

// MARK: - Open/close state

@MainActor
final class ModelPickerState: ObservableObject {
    @Published var visible: Bool = false
    @Published var initialKind: RecommendKind? = nil

    func open(initialKind: RecommendKind? = nil) {
        self.initialKind = initialKind
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            visible = true
        }
    }
    func close() {
        withAnimation(.easeOut(duration: 0.15)) { visible = false }
    }
    func toggle() { visible ? close() : open() }
}

// MARK: - The picker

struct ModelPicker: View {
    @EnvironmentObject var state: ModelPickerState
    @EnvironmentObject var catalog: UnifiedModelCatalog
    @EnvironmentObject var library: ModelLibrary
    @EnvironmentObject var downloads: HFDownloadManager
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var sdServer: SDServerController
    @EnvironmentObject var workspace: WorkspaceState
    @EnvironmentObject var monitor: ResourceMonitor

    @State private var query: String = ""
    @State private var kindFilter: RecommendKind? = nil
    @State private var selectedID: String? = nil
    @State private var hoverID: String? = nil
    @State private var statusMessage: String? = nil
    @FocusState private var searchFocused: Bool

    private var results: [UnifiedModel] {
        catalog.filtered(query: query, kind: kindFilter)
    }
    private var selected: UnifiedModel? {
        if let id = selectedID, let m = results.first(where: { $0.id == id }) { return m }
        return results.first
    }

    var body: some View {
        ZStack {
            // Dim backdrop, click-through to dismiss
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { state.close() }

            // Card
            VStack(spacing: 0) {
                searchBar
                Divider().background(Theme.stroke)
                filterRow
                Divider().background(Theme.stroke)
                HSplitView {
                    resultsList
                        .frame(minWidth: 380, idealWidth: 460)
                    detailPanel
                        .frame(minWidth: 280, idealWidth: 320)
                }
                if let msg = statusMessage {
                    Divider().background(Theme.stroke)
                    statusBar(msg)
                }
                Divider().background(Theme.stroke)
                footer
            }
            .frame(maxWidth: 920, maxHeight: 640)
            .glassCard(cornerRadius: Theme.Radius.xl)
            .shadow(color: .black.opacity(0.55), radius: 40, x: 0, y: 18)
            .padding(40)
        }
        .background(KeyEventCatcher(onArrowDown: moveSelectionDown,
                                    onArrowUp: moveSelectionUp,
                                    onReturn: activateSelection,
                                    onEscape: { state.close() }))
        .onAppear { handleOpen() }
        .onChange(of: state.initialKind) { kindFilter = $0 }
        .onChange(of: query) { _ in selectedID = results.first?.id }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    private func handleOpen() {
        catalog.rebuild()
        query = ""
        kindFilter = state.initialKind
        selectedID = results.first?.id
        searchFocused = true
        statusMessage = nil
    }

    // MARK: Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(Theme.violet)
            TextField("Search models — name, repo, quant…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .foregroundStyle(Theme.text)
                .tint(Theme.violet)
                .onSubmit(activateSelection)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
            }
            Text("\(results.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.pane, in: Capsule())
        }
        .padding(Theme.Space.md)
    }

    // MARK: Kind filter chips

    private var filterRow: some View {
        HStack(spacing: 6) {
            FilterChip(title: "All", active: kindFilter == nil) { kindFilter = nil }
            FilterChip(title: "Chat (LLM)", active: kindFilter == .llm) { kindFilter = .llm }
            FilterChip(title: "Image", active: kindFilter == .image) { kindFilter = .image }
            FilterChip(title: "Video", active: kindFilter == .video) { kindFilter = .video }
            Spacer()
            Menu {
                Button("Rebuild catalog") {
                    catalog.rebuild()
                    selectedID = results.first?.id
                }
                Button("Open Models browser") {
                    workspace.go(.models)
                    state.close()
                }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(Theme.textMuted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 8)
    }

    // MARK: Results list

    private var resultsList: some View {
        Group {
            if results.isEmpty {
                emptyResults
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4, pinnedViews: [.sectionHeaders]) {
                            ForEach(groupedResults, id: \.0) { (section, models) in
                                Section(header: sectionHeader(section)) {
                                    ForEach(models) { m in
                                        ModelPickerRow(
                                            model: m,
                                            compatibility: catalog.compatibility(of: m),
                                            isSelected: m.id == (selectedID ?? results.first?.id),
                                            isHovered: m.id == hoverID,
                                            onHover: { hoverID = $0 ? m.id : (hoverID == m.id ? nil : hoverID) },
                                            onTap: {
                                                selectedID = m.id
                                            },
                                            onActivate: {
                                                selectedID = m.id
                                                activateSelection()
                                            }
                                        )
                                        .id(m.id)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, Theme.Space.sm)
                        .padding(.vertical, Theme.Space.xs)
                    }
                    .onChange(of: selectedID) { id in
                        if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
    }

    private var emptyResults: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 36)).foregroundStyle(Theme.textFaint)
            Text(query.isEmpty ? "No models found." : "Nothing matches \"\(query)\".")
                .foregroundStyle(Theme.textMuted)
            if query.isEmpty {
                Button("Open Models browser") {
                    workspace.go(.models)
                    state.close()
                }
                .buttonStyle(.borderedProminent).tint(Theme.violet)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Group results into sections so the user can mentally map them.
    private var groupedResults: [(String, [UnifiedModel])] {
        var groups: [(String, [UnifiedModel])] = []
        let active = results.filter { $0.isActive }
        if !active.isEmpty { groups.append(("Active now", active)) }
        let downloaded = results.filter {
            !$0.isActive && $0.origin != .curated
        }
        if !downloaded.isEmpty { groups.append(("Installed", downloaded)) }
        let curated = results.filter { $0.origin == .curated }
        if !curated.isEmpty { groups.append(("Available to download", curated)) }
        return groups
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textFaint)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(VisualEffectBackground(material: .hudWindow, blendingMode: .withinWindow))
    }

    // MARK: Detail panel

    private var detailPanel: some View {
        Group {
            if let m = selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Kind banner
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10).fill(Theme.brandGradient)
                                    .frame(width: 44, height: 44)
                                Image(systemName: m.kind.sfSymbol)
                                    .foregroundStyle(.white).font(.title3)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.kind.label.uppercased())
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Theme.violet)
                                Text(m.displayName)
                                    .font(.headline)
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(2)
                            }
                        }

                        if m.isActive {
                            Label("Active in \(m.kind.label.lowercased()) engine", systemImage: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.mint)
                        }

                        // Compatibility
                        compatibilityBadge(for: m)

                        Divider().background(Theme.stroke)

                        // Metadata
                        infoRow("Origin", m.origin.label, icon: m.origin.sfSymbol)
                        infoRow("Size", m.humanSize, icon: "arrow.down.circle")
                        if !m.humanRAM.isEmpty {
                            infoRow("Runtime RAM", m.humanRAM, icon: "memorychip")
                        }
                        if let q = m.quantization {
                            infoRow("Quantization", q, icon: "doc.badge.gearshape")
                        }
                        if let repo = m.repoId {
                            infoRow("Repository", repo, icon: "tag", monospaced: true)
                        }
                        if let path = m.path {
                            infoRow("Path", (path as NSString).abbreviatingWithTildeInPath,
                                    icon: "folder", monospaced: true)
                        }
                        if !m.tags.isEmpty {
                            HStack {
                                Image(systemName: "circle.hexagonpath").foregroundStyle(Theme.textMuted).font(.caption2)
                                ForEach(m.tags, id: \.self) { t in
                                    Text(t).font(.system(size: 9, weight: .semibold))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Theme.violet.opacity(0.22), in: Capsule())
                                        .foregroundStyle(Theme.violet)
                                }
                                Spacer()
                            }
                        }

                        // Companions (only meaningful for diffusion models)
                        if m.kind == .image || m.kind == .video {
                            companionsSection(for: m)
                        }

                        Divider().background(Theme.stroke)

                        // Actions
                        actionButtons(for: m)
                    }
                    .padding(Theme.Space.md)
                }
            } else {
                placeholderDetail
            }
        }
        .background(VisualEffectBackground(material: .hudWindow, blendingMode: .withinWindow))
    }

    private var placeholderDetail: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox").font(.system(size: 36)).foregroundStyle(Theme.textFaint)
            Text("Select a model").foregroundStyle(Theme.textMuted).font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func compatibilityBadge(for m: UnifiedModel) -> some View {
        let c = catalog.compatibility(of: m)
        return HStack(spacing: 6) {
            Circle().fill(c.color).frame(width: 9, height: 9)
            Text(compatibilityText(for: c, model: m))
                .font(.caption)
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .glass(cornerRadius: 999, tint: c.color.opacity(0.15), stroke: c.color.opacity(0.45))
    }

    private func compatibilityText(for c: ModelCompatibility, model: UnifiedModel) -> String {
        let totalRam = monitor.hardware.totalRamGB
        switch c {
        case .fits:        return "Fits comfortably on your \(Int(totalRam)) GB Mac"
        case .tight:       return "Tight on your \(Int(totalRam)) GB Mac — may swap"
        case .tooBig:      return "Too big for \(Int(totalRam)) GB. Pick a smaller quant"
        case .downloading: return "Downloading now…"
        case .unknown:     return "RAM requirement unknown"
        }
    }

    /// Shows what extra files (T5, CLIP-L, VAE…) this diffusion model needs
    /// and whether they're already on disk. Lets the user kick off all
    /// missing downloads with one click.
    @ViewBuilder
    private func companionsSection(for m: UnifiedModel) -> some View {
        let family: DiffusionFamily = {
            if let p = m.path { return DiffusionFamily.detect(path: p) }
            if let f = m.filename { return DiffusionFamily.detect(path: f) }
            return .unknown
        }()
        let reqs = ModelBundle.requiredCompanions(for: family)
        if !reqs.isEmpty {
            Divider().background(Theme.stroke)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "puzzlepiece.extension")
                        .foregroundStyle(Theme.violet)
                    Text("REQUIRED COMPANIONS — \(family.label)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textFaint)
                    Spacer()
                }
                let statuses = companionStatuses(for: m, family: family)
                ForEach(statuses, id: \.label) { s in
                    HStack(spacing: 8) {
                        Image(systemName: s.localPath != nil ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(s.localPath != nil ? Theme.mint : Theme.amber)
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.label).font(.caption).foregroundStyle(Theme.text)
                            if let rec = s.curated {
                                Text("\(rec.repoId) · \(rec.humanDownload)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Theme.textFaint)
                                    .lineLimit(1).truncationMode(.middle)
                            } else if let local = s.localPath {
                                Text((local as NSString).lastPathComponent)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Theme.textFaint)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer()
                    }
                }
                let missing = statuses.filter { $0.isMissing && $0.curated != nil }
                if !missing.isEmpty {
                    Button {
                        let diffusionPath = m.path  // may be nil for curated entries
                        let n = catalog.enqueueMissingCompanions(diffusionPath: diffusionPath,
                                                                  family: family)
                        statusMessage = n > 0
                            ? "Queued \(n) companion download\(n == 1 ? "" : "s") — watch the Models tab."
                            : "Companions already downloading or installed."
                    } label: {
                        Label("Get missing files (\(missing.count))",
                              systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.amber)
                }
            }
        }
    }

    /// Build a status array for the picker detail. For an already-downloaded
    /// model we can resolve relative to its real path; for a curated entry
    /// we only know the catalog ids of the companions.
    private func companionStatuses(for m: UnifiedModel,
                                    family: DiffusionFamily) -> [CompanionStatus] {
        if let path = m.path {
            return CompanionResolver.status(forDiffusion: path,
                                             downloadsRoot: downloads.rootDirectory)
        }
        // Curated case: report each requirement as missing-with-suggestion.
        return ModelBundle.requiredCompanions(for: family).map { req in
            CompanionStatus(role: req.role, label: req.label,
                            localPath: nil,
                            curated: ModelBundle.catalogEntry(for: req))
        }
    }

    @ViewBuilder
    private func actionButtons(for m: UnifiedModel) -> some View {
        VStack(spacing: 6) {
            switch m.origin {
            case .curated:
                Button(action: { activateSelection() }) {
                    Label("Download \(m.humanSize)", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.violet)
                .keyboardShortcut(.return, modifiers: [])
            default:
                if m.isActive {
                    Button(action: {}) {
                        Label("Active", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.mint).disabled(true)
                } else {
                    Button(action: { activateSelection() }) {
                        Label("Activate", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.violet)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            if let path = m.path {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            if let repo = m.repoId, let url = URL(string: "https://huggingface.co/\(repo)") {
                Link(destination: url) {
                    Label("View on HuggingFace", systemImage: "safari").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String, icon: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Theme.textMuted)
                .font(.caption)
                .frame(width: 14)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(monospaced ? Theme.monoSmall : .caption)
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 16) {
            shortcutHint(key: "↑↓", label: "Navigate")
            shortcutHint(key: "↩", label: "Activate")
            shortcutHint(key: "esc", label: "Close")
            shortcutHint(key: "1–4", label: "Filter kind")
            Spacer()
            if let t = catalog.lastRebuiltAt {
                Text("Updated \(timeAgo(t))")
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 8)
        .background(VisualEffectBackground(material: .titlebar, blendingMode: .withinWindow))
    }

    private func shortcutHint(key: String, label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.caption2.monospaced().weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Theme.pane, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.stroke, lineWidth: 0.7))
                .foregroundStyle(Theme.text)
            Text(label).font(.caption2).foregroundStyle(Theme.textMuted)
        }
    }

    private func statusBar(_ msg: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(msg).font(.caption).foregroundStyle(Theme.text)
            Spacer()
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 8)
        .background(Theme.violet.opacity(0.12))
    }

    private func timeAgo(_ d: Date) -> String {
        let i = Int(-d.timeIntervalSinceNow)
        if i < 5 { return "just now" }
        if i < 60 { return "\(i)s ago" }
        let m = i / 60
        return m < 60 ? "\(m)m ago" : "—"
    }

    // MARK: Keyboard navigation

    private func moveSelectionDown() {
        let r = results
        guard !r.isEmpty else { return }
        let idx = r.firstIndex { $0.id == selectedID } ?? -1
        let next = (idx + 1) % r.count
        selectedID = r[next].id
    }

    private func moveSelectionUp() {
        let r = results
        guard !r.isEmpty else { return }
        let idx = r.firstIndex { $0.id == selectedID } ?? r.count
        let prev = (idx - 1 + r.count) % r.count
        selectedID = r[prev].id
    }

    private func activateSelection() {
        guard let m = selected else { return }
        let msg = catalog.activate(m)
        statusMessage = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.state.close()
        }
    }
}

// MARK: - Picker row

struct ModelPickerRow: View {
    let model: UnifiedModel
    let compatibility: ModelCompatibility
    let isSelected: Bool
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onTap: () -> Void
    let onActivate: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                kindBadge
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        if model.isActive {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(Theme.mint)
                                .font(.caption2)
                        }
                        if model.isVisionCapable {
                            Image(systemName: "eye.fill")
                                .foregroundStyle(Theme.cyan)
                                .font(.caption2)
                        }
                    }
                    HStack(spacing: 8) {
                        if let repo = model.repoId {
                            Text(repo)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textFaint)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        if let q = model.quantization {
                            Text(q)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Theme.violet.opacity(0.20), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(Theme.violet)
                        }
                        ForEach(model.tags.prefix(2), id: \.self) { t in
                            Text(t)
                                .font(.system(size: 9))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Circle().fill(compatibility.color).frame(width: 7, height: 7)
                        Text(model.humanSize)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.text)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: model.origin.sfSymbol)
                            .font(.system(size: 9))
                        Text(model.origin.label)
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(Theme.textFaint)
                }
                if isSelected || isHovered {
                    Button(action: onActivate) {
                        Image(systemName: model.origin == .curated ? "arrow.down.circle.fill" : "play.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Theme.brandGradient, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Theme.violet.opacity(0.22) :
                          isHovered ? Theme.paneHover : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Theme.violet.opacity(0.5) : Color.clear, lineWidth: 0.7)
            )
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var kindBadge: some View {
        let kindColor: Color = {
            switch model.kind {
            case .llm:   return Theme.cyan
            case .image: return Theme.violet
            case .video: return Theme.magenta
            }
        }()
        return ZStack {
            RoundedRectangle(cornerRadius: 8).fill(kindColor.opacity(0.20))
                .frame(width: 36, height: 36)
            Image(systemName: model.kind.sfSymbol)
                .foregroundStyle(kindColor)
                .font(.callout)
        }
    }
}

// MARK: - Key event catcher (NSView-backed for arrow keys / enter / escape)

/// SwiftUI doesn't surface raw key events well for arrow keys on macOS;
/// this NSView swallows them and forwards via callbacks so the picker can do
/// keyboard navigation without losing text-field focus.
struct KeyEventCatcher: NSViewRepresentable {
    var onArrowDown: () -> Void
    var onArrowUp: () -> Void
    var onReturn: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        v.onArrowDown = onArrowDown
        v.onArrowUp = onArrowUp
        v.onReturn = onReturn
        v.onEscape = onEscape
        return v
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onArrowDown = onArrowDown
        nsView.onArrowUp = onArrowUp
        nsView.onReturn = onReturn
        nsView.onEscape = onEscape
    }

    final class KeyView: NSView {
        var onArrowDown: (() -> Void)?
        var onArrowUp: (() -> Void)?
        var onReturn: (() -> Void)?
        var onEscape: (() -> Void)?
        private var monitor: Any?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            installMonitor()
        }
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            installMonitor()
        }
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

        private func installMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
                guard let self = self, let window = self.window, window.isKeyWindow else { return ev }
                switch ev.keyCode {
                case 125: self.onArrowDown?(); return nil   // ↓
                case 126: self.onArrowUp?();   return nil   // ↑
                case 36:                                    // ↩
                    // Don't steal Return if the focused responder is a multi-line text view
                    if let fr = window.firstResponder as? NSTextView, fr.isFieldEditor == false {
                        return ev
                    }
                    self.onReturn?(); return nil
                case 53:  self.onEscape?();    return nil   // esc
                default: return ev
                }
            }
        }
    }
}
