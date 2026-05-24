import SwiftUI
import AppKit

@main
struct MllamaApp: App {
    @StateObject private var server   = ServerController()
    @StateObject private var library: ModelLibrary
    @StateObject private var agent: Agent
    @StateObject private var mcp: MCPManager
    @StateObject private var tts      = SpeechSynthesizer.shared
    @StateObject private var recorder = VoiceRecorder.shared

    // New media subsystem
    @StateObject private var workspace = WorkspaceState()
    @StateObject private var sdServer: SDServerController
    @StateObject private var imageGen: ImageGenerator
    @StateObject private var videoGen: VideoGenerator
    @StateObject private var videoPipeline: VideoPipeline
    @StateObject private var mediaLib = MediaLibrary.shared
    @StateObject private var downloads = HFDownloadManager.shared
    @StateObject private var prompts = PromptLibrary.shared
    @StateObject private var onboarding = OnboardingState.shared
    @StateObject private var monitor: ResourceMonitor
    @StateObject private var catalog: UnifiedModelCatalog
    @StateObject private var pickerState = ModelPickerState()
    @StateObject private var mcpHostRegistry: MCPHostToolRegistry
    @StateObject private var mcpHost: MCPServerHost
    @StateObject private var evolution: SelfImprovementCoordinator

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private static let toolRegistry: ToolRegistry = ToolRegistry()

    init() {
        UserDefaults.standard.register(defaults: [
            Keys.port: 8080,
            Keys.contextSize: 0,
            Keys.ngl: 99,
            Keys.host: "127.0.0.1",
            Keys.threads: 8,
            Keys.flashAttn: true,
            Keys.mlock: true,
            Keys.systemPrompt: defaultSystemPrompt,
            Keys.autoCompact: true,
            VoiceKeys.autoSpeak: false,
            VoiceKeys.voiceRate: Float(0),
            VoiceKeys.preferOnDevice: true,
            // SD defaults
            SDKeys.port: 1235,
            SDKeys.host: "127.0.0.1",
            SDKeys.flashAttn: true,
            SDKeys.vaeTiling: true,
        ])

        let serverInstance = ServerController()
        let libraryInstance = ModelLibrary()
        let agentInstance = Agent(server: serverInstance, registry: Self.toolRegistry)
        let mcpInstance   = MCPManager(registry: Self.toolRegistry)
        let sdInstance    = SDServerController()
        let imgGenInstance = ImageGenerator(server: sdInstance)
        let vidGenInstance = VideoGenerator(server: sdInstance)
        let pipelineInstance = VideoPipeline(server: sdInstance)
        let monitorInstance = ResourceMonitor()
        let catalogInstance = UnifiedModelCatalog(
            library: libraryInstance,
            downloads: HFDownloadManager.shared,
            server: serverInstance,
            sdServer: sdInstance,
            monitor: monitorInstance
        )
        let mcpHostRegistryInstance = MCPHostToolRegistry()
        let mcpHostInstance = MCPServerHost(registry: mcpHostRegistryInstance)
        let evolutionInstance = SelfImprovementCoordinator(registry: Self.toolRegistry)

        _server        = StateObject(wrappedValue: serverInstance)
        _library       = StateObject(wrappedValue: libraryInstance)
        _agent         = StateObject(wrappedValue: agentInstance)
        _mcp           = StateObject(wrappedValue: mcpInstance)
        _sdServer      = StateObject(wrappedValue: sdInstance)
        _imageGen      = StateObject(wrappedValue: imgGenInstance)
        _videoGen      = StateObject(wrappedValue: vidGenInstance)
        _videoPipeline = StateObject(wrappedValue: pipelineInstance)
        _monitor       = StateObject(wrappedValue: monitorInstance)
        _catalog       = StateObject(wrappedValue: catalogInstance)
        _mcpHostRegistry = StateObject(wrappedValue: mcpHostRegistryInstance)
        _mcpHost         = StateObject(wrappedValue: mcpHostInstance)
        _evolution       = StateObject(wrappedValue: evolutionInstance)

        // Create the user-writable bin directory up-front so QuickSetup
        // commands have a known target.
        InstallPaths.ensureBinRoot()
    }

    var body: some Scene {
        WindowGroup("Mllama") {
            RootView()
                .environmentObject(server)
                .environmentObject(library)
                .environmentObject(agent)
                .environmentObject(mcp)
                .environmentObject(tts)
                .environmentObject(recorder)
                .environmentObject(workspace)
                .environmentObject(sdServer)
                .environmentObject(imageGen)
                .environmentObject(videoGen)
                .environmentObject(videoPipeline)
                .environmentObject(mediaLib)
                .environmentObject(downloads)
                .environmentObject(prompts)
                .environmentObject(onboarding)
                .environmentObject(monitor)
                .environmentObject(catalog)
                .environmentObject(pickerState)
                .environmentObject(mcpHost)
                .environmentObject(mcpHostRegistry)
                .environmentObject(evolution)
                .preferredColorScheme(.dark)
                .onAppear {
                    appDelegate.server = server
                    appDelegate.sdServer = sdServer
                    appDelegate.mcpHost = mcpHost
                    bootstrap()
                }
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { agent.reset() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Restart Server") { server.restart() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Restart Image Server") { sdServer.restart() }
                    .keyboardShortcut("R", modifiers: [.command, .option])
                Button("Compact Conversation") { Task { await agent.manualCompact() } }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            }
            CommandMenu("Workspace") {
                ForEach(Workspace.allCases) { w in
                    Button(w.rawValue) { workspace.go(w) }
                        .keyboardShortcut(w.shortcut, modifiers: .command)
                }
                Divider()
                Button("Quick Model Picker…") { pickerState.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Welcome to Mllama…") { onboarding.show() }
                Button("Mllama Help") {
                    if let url = URL(string: "https://github.com/ggerganov/llama.cpp") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(server)
                .environmentObject(library)
                .environmentObject(mcp)
                .environmentObject(tts)
                .environmentObject(recorder)
                .environmentObject(sdServer)
                .environmentObject(imageGen)
                .environmentObject(videoGen)
                .environmentObject(mcpHost)
                .environmentObject(mcpHostRegistry)
                // Needed for the new "required companions" widget in Settings → Image Gen.
                .environmentObject(catalog)
                .environmentObject(downloads)
                .environmentObject(evolution)
                .preferredColorScheme(.dark)
                .frame(minWidth: 720, minHeight: 600)
        }
    }

    /// Append a diagnostic line to ~/.mllama/diag.log. Used so we can verify
    /// the boot path without relying on stdout/stderr capture.
    static func diagLog(_ msg: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mllama/diag.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(msg)\n"
        if let data = line.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
                try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
        NSLog("[Mllama] \(msg)")
    }

    private func bootstrap() {
        Self.diagLog("bootstrap() entered")
        // Capture references for the closures so tools can dispatch back into
        // the live MainActor objects.
        let imgRef = imageGen
        let vidRef = videoGen
        let registry = mcpHostRegistry
        let host = mcpHost

        // Let the catalog defer sd-server restarts (triggered by a companion
        // download completing) until image generation is idle — otherwise we'd
        // kill an in-flight request.
        catalog.isImageGeneratorBusy = { [weak imgRef] in
            imgRef?.isGenerating ?? false
        }

        // --- Track 1: local agent tools (fast) ---
        Task {
            Self.diagLog("track1: registering local tools")
            await Self.toolRegistry.register(ShellTool())
            await Self.toolRegistry.register(ReadFileTool())
            await Self.toolRegistry.register(WriteFileTool())
            await Self.toolRegistry.register(ListDirectoryTool())
            await Self.toolRegistry.register(FetchURLTool())
            await Self.toolRegistry.register(GetDateTimeTool())

            // Media tools — exposed to the local agent (and a parallel set
            // is registered to the MCP host registry on a separate track).
            await Self.toolRegistry.register(GenerateImageTool(generator: { [weak imgRef] in imgRef }))
            await Self.toolRegistry.register(EditImageTool())
            await Self.toolRegistry.register(GenerateVideoTool(generator: { [weak vidRef] in vidRef }))
            await Self.toolRegistry.register(EditVideoTool())
            await Self.toolRegistry.register(SearchHuggingFaceTool())
            await Self.toolRegistry.register(DownloadHFModelTool())
            await Self.toolRegistry.register(ListMediaTool())

            // Self-improvement loop: the agent can inspect its own failures,
            // rewrite its own instructions, author new tools, and use them
            // on the next turn. These four tools plus the reflection log
            // make the agent able to evolve in-session.
            let registry = Self.toolRegistry
            let coord = self.evolution
            let onChanged: @Sendable () async -> Void = {
                await coord.refresh()
            }
            await registry.register(ReflectTool())
            await registry.register(UpdateInstructionsTool())
            await registry.register(CreateToolTool(registry: registry, onChanged: onChanged))
            await registry.register(ListDynamicToolsTool())
            await registry.register(DisableToolTool(registry: registry, onChanged: onChanged))

            let toolCount = await registry.count()
            Self.diagLog("track1: local tools registered (\(toolCount) tools incl. self-improvement loop)")
        }

        // --- Track 2: MCP host (decoupled from MCP client bootstrap) ---
        // We do NOT await mcp.bootstrap here because a hung external MCP
        // server would block our own MCP host from starting.
        Task { @MainActor in
            registry.register(MCPGenerateImageTool(generator: { [weak imgRef] in imgRef }))
            registry.register(MCPEditImageTool())
            registry.register(MCPGenerateVideoTool(generator: { [weak vidRef] in vidRef }))
            registry.register(MCPSearchHFTool())
            registry.register(MCPListMediaTool())
            registry.register(MCPGetMediaFileTool())
            registry.register(MCPServerInfoTool())
            Self.diagLog("track2: MCP host tools registered: \(registry.tools.count)")
            let enabled = UserDefaults.standard.bool(forKey: MCPHostKeys.enabled)
            Self.diagLog("track2: MCP host enabled = \(enabled)")
            if enabled { host.start() }
        }

        // --- Track 3: MCP client bootstrap (can hang on bad config — own task) ---
        Task {
            Self.diagLog("track3: ensureScaffold + mcp.bootstrap")
            MCPConfigStore.ensureScaffold()
            await mcp.bootstrap()
            Self.diagLog("track3: mcp.bootstrap returned")
        }
    }
}

// MARK: - Settings opener

struct OpenSettingsButton<Label: View>: View {
    @ViewBuilder var label: () -> Label
    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink(label: label).buttonStyle(.borderless)
        } else {
            Button(action: openSettingsFallback, label: label).buttonStyle(.borderless)
        }
    }
}

func openSettingsFallback() {
    if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) { return }
    if NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil) { return }
    NSApp.activate(ignoringOtherApps: true)
}

// MARK: - Root view (workspace switcher + sidebar + detail)

struct RootView: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var sdServer: SDServerController
    @EnvironmentObject var agent: Agent
    @EnvironmentObject var workspace: WorkspaceState
    @EnvironmentObject var onboarding: OnboardingState
    @EnvironmentObject var pickerState: ModelPickerState
    @EnvironmentObject var catalog: UnifiedModelCatalog
    @EnvironmentObject var library: ModelLibrary
    @EnvironmentObject var downloads: HFDownloadManager
    /// Drives the video pill label — SwiftUI re-renders when the underlying
    /// UserDefaults key changes via `@AppStorage`.
    @AppStorage(SDKeys.videoModelPath) private var videoModelPathStored: String = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showLog: Bool = false

    var body: some View {
        ZStack {
            VisualEffectBackground().ignoresSafeArea()
            GradientAtmosphere().ignoresSafeArea()

            HStack(spacing: 0) {
                WorkspaceRail()
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    AdaptiveSidebar()
                        .navigationSplitViewColumnWidth(min: 270, ideal: 310, max: 380)
                        .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
                } detail: {
                    VStack(spacing: 0) {
                        topBar
                        WorkspaceDetail()
                        if showLog {
                            Divider().background(Theme.stroke)
                            logPanel
                        }
                        StatusFooter()
                    }
                    .background(Color.clear)
                }
                .scrollContentBackground(.hidden)
            }

            if onboarding.visible {
                OnboardingView(state: onboarding)
                    .zIndex(100)
            }

            if pickerState.visible {
                ModelPicker()
                    .zIndex(110)
            }
        }
        .frame(minWidth: 1280, minHeight: 800)
        .onAppear {
            ensureModelThenStart()
            catalog.rebuild()
        }
        // Keep the unified catalog in sync as state changes.
        .onChange(of: library.models.count)            { _ in catalog.rebuild() }
        .onChange(of: server.modelPath ?? "")          { _ in catalog.rebuild() }
        .onChange(of: sdServer.modelPath ?? "")        { _ in catalog.rebuild() }
        // When a download (companion file or otherwise) completes, rebuild
        // so we re-link any newly available T5 / CLIP / VAE companions and
        // restart sd-server if needed.
        .onChange(of: completedDownloadCount)          { _ in catalog.rebuild() }
    }

    /// Cheap signal that something finished — count of terminal-state jobs.
    /// Driving rebuild off this avoids fighting HFDownloadManager's
    /// per-second progress updates.
    private var completedDownloadCount: Int {
        downloads.jobs.reduce(0) { acc, job in
            switch job.state {
            case .completed, .failed, .cancelled: return acc + 1
            default: return acc
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: Theme.Space.sm) {
            workspaceCrumb
            llamaModelButton
            sdModelButton
            videoModelButton
            quickPickerButton
            if workspace.current == .chat {
                ContextUsageBar()
            }
            Spacer()
            if workspace.current == .chat && agent.autoApproveInSession {
                Label("auto-approve", systemImage: "shield.slash")
                    .font(.caption2)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.amber.opacity(0.18), in: Capsule())
                    .overlay(Capsule().stroke(Theme.amber.opacity(0.55), lineWidth: 0.7))
                    .foregroundStyle(Theme.amber)
            }
            Toggle(isOn: $showLog) { Label("Log", systemImage: "terminal") }
                .toggleStyle(.button)
                .controlSize(.small)
            OpenSettingsButton {
                Image(systemName: "gear")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
                    .glass(cornerRadius: Theme.Radius.sm)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.xs)
        .background(VisualEffectBackground(material: .titlebar, blendingMode: .withinWindow))
        .overlay(Rectangle().fill(Theme.stroke).frame(height: 0.5), alignment: .bottom)
    }

    private var quickPickerButton: some View {
        Button { pickerState.open() } label: {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.caption2)
                Text("Models").font(.caption.weight(.semibold))
                Text("⌘K").font(.system(size: 9, design: .monospaced))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glass(cornerRadius: 999, tint: Theme.violet.opacity(0.18),
                   stroke: Theme.violet.opacity(0.45))
        }
        .buttonStyle(.plain)
        .help("Open the model picker (⌘K)")
    }

    /// Clickable LLM pill — shows status + current model, opens picker pre-filtered.
    private var llamaModelButton: some View {
        Button { pickerState.open(initialKind: .llm) } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble").font(.caption2)
                    .foregroundStyle(Theme.textMuted).accessibilityHidden(true)
                statusDot(for: server.status)
                Text(currentLLMLabel)
                    .font(.caption2)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 200)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glass(cornerRadius: 999)
        }
        .buttonStyle(.borderless)
        .help(llmHelpText)
        .accessibilityLabel("LLM: \(currentLLMLabel), \(serverStatusLabel(server.status))")
    }

    @ViewBuilder
    private func statusDot(for status: ServerController.Status) -> some View {
        switch status {
        case .running:
            Circle().fill(Theme.mint).frame(width: 7, height: 7)
        case .starting:
            ProgressView().controlSize(.mini)
        case .stopped:
            Circle().fill(Theme.textFaint).frame(width: 7, height: 7)
        case .failed:
            Circle().fill(Theme.coral).frame(width: 7, height: 7)
        }
    }

    private func serverStatusLabel(_ status: ServerController.Status) -> String {
        switch status {
        case .running:  return "running"
        case .starting: return "starting"
        case .stopped:  return "stopped"
        case .failed:   return "failed"
        }
    }

    private var llmHelpText: String {
        guard let path = server.modelPath, !path.isEmpty else {
            return "Pick an LLM (⌘K)"
        }
        return "\(path)\n(⌘K to switch)"
    }

    /// Clickable image-model pill.
    private var sdModelButton: some View {
        Button { pickerState.open(initialKind: .image) } label: {
            HStack(spacing: 6) {
                Image(systemName: "photo.artframe").font(.caption2)
                    .foregroundStyle(Theme.textMuted).accessibilityHidden(true)
                sdStatusDot
                Text(currentImageLabel)
                    .font(.caption2)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 200)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glass(cornerRadius: 999)
        }
        .buttonStyle(.borderless)
        .help(sdHelpText)
        .accessibilityLabel("Image model: \(currentImageLabel), \(sdStatusLabel)")
    }

    @ViewBuilder
    private var sdStatusDot: some View {
        switch sdServer.status {
        case .running:
            Circle().fill(Theme.mint).frame(width: 7, height: 7)
        case .starting:
            ProgressView().controlSize(.mini)
        case .stopped:
            Circle().fill(Theme.textFaint).frame(width: 7, height: 7)
        case .failed:
            Circle().fill(Theme.coral).frame(width: 7, height: 7)
        case .notConfigured:
            Image(systemName: "questionmark.circle").foregroundStyle(Theme.textFaint).font(.caption2)
        }
    }

    private var sdStatusLabel: String {
        switch sdServer.status {
        case .running:        return "running"
        case .starting:       return "starting"
        case .stopped:        return "stopped"
        case .failed:         return "failed"
        case .notConfigured:  return "not configured"
        }
    }

    private var sdHelpText: String {
        guard let path = sdServer.modelPath, !path.isEmpty else {
            return "Pick an image model (⌘K)"
        }
        return "\(path)\n(⌘K to switch)"
    }

    private var currentLLMLabel: String {
        if !server.modelName.isEmpty { return server.modelName }
        if let path = server.modelPath { return (path as NSString).lastPathComponent }
        return "Pick LLM"
    }
    private var currentImageLabel: String {
        if let path = sdServer.modelPath { return (path as NSString).lastPathComponent }
        return "Pick image model"
    }
    private var currentVideoLabel: String {
        if !videoModelPathStored.isEmpty {
            return (videoModelPathStored as NSString).lastPathComponent
        }
        return "Pick video model"
    }

    /// Video pill — no live server status (sd-cli is one-shot), but shows
    /// the active model name. Click to open the picker pre-filtered to video.
    private var videoModelButton: some View {
        Button { pickerState.open(initialKind: .video) } label: {
            HStack(spacing: 6) {
                Image(systemName: "film.stack").font(.caption2).foregroundStyle(Theme.textMuted)
                    .accessibilityHidden(true)
                Text(currentVideoLabel)
                    .font(.caption2)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 200)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glass(cornerRadius: 999)
        }
        .buttonStyle(.borderless)   // keeps system focus ring for keyboard nav
        .help(videoModelPathStored.isEmpty
              ? "Pick a video model (⌘K)"
              : "\(videoModelPathStored)\n(⌘K to switch)")
        .accessibilityLabel(videoModelPathStored.isEmpty
                            ? "Pick a video model"
                            : "Video model: \(currentVideoLabel)")
    }

    private var workspaceCrumb: some View {
        HStack(spacing: 6) {
            Image(systemName: workspace.current.sfSymbol).font(.caption)
                .foregroundStyle(Theme.violet)
            Text(workspace.current.rawValue).font(.caption.weight(.semibold))
                .foregroundStyle(Theme.text)
            Text("· " + workspace.current.subtitle)
                .font(.caption2)
                .foregroundStyle(Theme.textFaint)
                .lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .glass(cornerRadius: 999)
    }

    private var logPanel: some View {
        ScrollView {
            Text(combinedLog.isEmpty ? "(no output yet)" : combinedLog)
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(height: 160)
        .background(Theme.codeBg)
    }

    private var combinedLog: String {
        var out = ""
        if !server.log.isEmpty   { out += "=== llama-server ===\n\(server.log)\n" }
        if !sdServer.log.isEmpty { out += "=== sd-server ===\n\(sdServer.log)\n" }
        return out
    }

    private func ensureModelThenStart() {
        if server.status == .stopped, server.modelPath != nil { server.start() }
        if sdServer.status == .stopped, sdServer.modelPath != nil { sdServer.start() }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var server: ServerController?
    weak var sdServer: SDServerController?
    weak var mcpHost: MCPServerHost?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        DispatchQueue.main.async { self.styleWindows() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        styleWindows()
    }

    private func styleWindows() {
        for window in NSApp.windows {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = false
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        sdServer?.stop()
        mcpHost?.stop()
    }
}
