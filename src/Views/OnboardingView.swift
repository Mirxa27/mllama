import SwiftUI
import AppKit

/// First-run welcome flow. Detects what's installed, walks the user through
/// the missing pieces, and routes them to their first action. Friendly,
/// skippable, can be re-opened from Help → Welcome.
struct OnboardingView: View {
    @ObservedObject var state: OnboardingState
    @EnvironmentObject var workspace: WorkspaceState
    @State private var step: Int = 0
    @State private var caps: OnboardingState.Capabilities

    init(state: OnboardingState) {
        self.state = state
        _caps = State(initialValue: state.detectCapabilities())
    }

    var body: some View {
        ZStack {
            // Full-window blur backdrop
            VisualEffectBackground(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
            GradientAtmosphere().ignoresSafeArea()
            Color.black.opacity(0.35).ignoresSafeArea()

            // Card
            VStack(spacing: 0) {
                content
                Divider().background(Theme.stroke)
                footer
            }
            .frame(maxWidth: 720, maxHeight: 620)
            .glassCard(cornerRadius: Theme.Radius.xl)
            .shadow(color: .black.opacity(0.5), radius: 40, x: 0, y: 16)
            .padding(40)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcome
        case 1: QuickSetupView()
        case 2: pickFirstWorkspace
        default: welcome
        }
    }

    // MARK: Step 1 — welcome

    private var welcome: some View {
        VStack(spacing: Theme.Space.lg) {
            Spacer().frame(height: 12)
            ZStack {
                Circle().fill(Theme.brandGradient).frame(width: 96, height: 96)
                    .shadow(color: Theme.violet.opacity(0.55), radius: 28)
                Image(systemName: "circle.hexagonpath.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("Welcome to Mllama")
                .font(.system(size: 32, weight: .heavy))
                .foregroundStyle(Theme.text)
            Text("Run any LLM, generate images and videos, and edit them — all locally on your Mac.")
                .font(.title3)
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            HStack(spacing: 12) {
                FeatureChip(icon: "text.bubble", title: "Chat with LLMs", color: Theme.cyan)
                FeatureChip(icon: "photo.artframe", title: "Generate images", color: Theme.violet)
                FeatureChip(icon: "film.stack", title: "Generate videos", color: Theme.magenta)
                FeatureChip(icon: "wand.and.rays", title: "Edit anything", color: Theme.mint)
            }
            .padding(.top, 8)
            Spacer()
            Text("Everything runs on your Mac — no API keys, no cloud, no telemetry.")
                .font(.caption)
                .foregroundStyle(Theme.textFaint)
                .padding(.bottom, Theme.Space.md)
        }
        .padding(Theme.Space.xl)
    }

    // MARK: Step 2 — capability check

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: 10) {
                Image(systemName: "checklist.checked")
                    .font(.title)
                    .foregroundStyle(Theme.violet)
                VStack(alignment: .leading) {
                    Text("Setup check").font(.title2.weight(.semibold)).foregroundStyle(Theme.text)
                    Text("Here's what's ready and what's missing.")
                        .font(.callout).foregroundStyle(Theme.textMuted)
                }
            }
            Divider().background(Theme.stroke)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    CapabilityRow(name: "LLM model (for chat & agents)",
                                  ready: caps.hasLLM,
                                  helpReady: "✓ Will run via the bundled llama-server.",
                                  helpMissing: "Pick a .gguf model in the sidebar, or download one from the Models tab.")
                    CapabilityRow(name: "Image generator (sd-server)",
                                  ready: caps.hasSDServer,
                                  helpReady: "✓ sd-server binary found.",
                                  helpMissing: "Build from github.com/leejet/stable-diffusion.cpp and drop into Mllama.app/Contents/Resources/bin/, or set the path in Settings → Image Gen.")
                    CapabilityRow(name: "Image model",
                                  ready: caps.hasImageModel,
                                  helpReady: "✓ A diffusion model is configured.",
                                  helpMissing: "Search 'FLUX' in the Models tab and download one (Q4 = 7GB).")
                    CapabilityRow(name: "Video generator (sd-cli)",
                                  ready: caps.hasSDCli,
                                  helpReady: "✓ sd-cli binary found.",
                                  helpMissing: "Same build as sd-server. Ships in the same release.")
                    CapabilityRow(name: "Video model (Wan / LTX-2)",
                                  ready: caps.hasVideoModel,
                                  helpReady: "✓ A video model is configured.",
                                  helpMissing: "Optional. Required only for the Video Studio.")
                    CapabilityRow(name: "ffmpeg (video editing)",
                                  ready: caps.hasFFmpeg,
                                  helpReady: "✓ Found on PATH.",
                                  helpMissing: "Install with `brew install ffmpeg`.")
                    CapabilityRow(name: "HuggingFace token (optional)",
                                  ready: caps.hasHFToken,
                                  helpReady: "✓ You'll get higher download rate limits.",
                                  helpMissing: "Optional. Set it in Settings → HuggingFace for higher rate limits and access to gated models.")
                }
            }
            Divider().background(Theme.stroke)
            HStack(spacing: 8) {
                Button {
                    self.caps = state.detectCapabilities()
                } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                }
                Spacer()
                summaryPill
            }
        }
        .padding(Theme.Space.xl)
    }

    private var summaryPill: some View {
        let ready = [caps.readyForChat, caps.readyForImage, caps.readyForVideo].filter { $0 }.count
        let total = 3
        let color: Color = ready == total ? Theme.mint : ready > 0 ? Theme.amber : Theme.coral
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text("\(ready)/\(total) workspaces ready").font(.caption).foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .glass(cornerRadius: 999)
    }

    // MARK: Step 3 — choose first workspace

    private var pickFirstWorkspace: some View {
        VStack(spacing: Theme.Space.md) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.3.group.fill")
                    .font(.title)
                    .foregroundStyle(Theme.violet)
                VStack(alignment: .leading) {
                    Text("Where to next?").font(.title2.weight(.semibold)).foregroundStyle(Theme.text)
                    Text("You can switch any time with the left rail or ⌘1–⌘5.")
                        .font(.callout).foregroundStyle(Theme.textMuted)
                }
                Spacer()
            }
            Divider().background(Theme.stroke)
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                StartCard(workspace: .chat,
                          headline: "Chat with your LLM",
                          blurb: "Conversational AI with agentic tools and MCP.",
                          ready: caps.readyForChat) { goTo(.chat) }
                StartCard(workspace: .imageStudio,
                          headline: "Generate an image",
                          blurb: "Text → image with FLUX, SDXL, SD3, etc. Plus a built-in editor.",
                          ready: caps.readyForImage) { goTo(.imageStudio) }
                StartCard(workspace: .videoStudio,
                          headline: "Make a video",
                          blurb: "Text → video, image → video, or storyboard long clips.",
                          ready: caps.readyForVideo) { goTo(.videoStudio) }
                StartCard(workspace: .models,
                          headline: "Browse HuggingFace",
                          blurb: "Search & download local-runnable models.",
                          ready: true) { goTo(.models) }
            }
        }
        .padding(Theme.Space.xl)
    }

    private func goTo(_ w: Workspace) {
        workspace.go(w)
        state.complete()
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                state.skip()
            } label: {
                Text("Skip").foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.borderless)

            // Progress dots
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(i == step ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.stroke))
                        .frame(width: i == step ? 10 : 7, height: i == step ? 10 : 7)
                }
            }
            .frame(maxWidth: .infinity)

            if step > 0 {
                Button("Back") { withAnimation { step -= 1 } }
            }
            if step < 2 {
                Button(step == 0 ? "Get started →" : "Continue →") {
                    withAnimation { step += 1 }
                    if step == 1 { caps = state.detectCapabilities() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.violet)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(Theme.Space.md)
    }
}

// MARK: - Pieces

struct FeatureChip: View {
    let icon: String, title: String, color: Color
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(color.opacity(0.18)).frame(width: 44, height: 44)
                Image(systemName: icon).foregroundStyle(color).font(.title3)
            }
            Text(title).font(.caption).foregroundStyle(Theme.text)
        }
        .frame(width: 90)
    }
}

struct CapabilityRow: View {
    let name: String
    let ready: Bool
    let helpReady: String
    let helpMissing: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ready ? Theme.mint : Theme.amber)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.callout.weight(.medium)).foregroundStyle(Theme.text)
                Text(ready ? helpReady : helpMissing)
                    .font(.caption)
                    .foregroundStyle(ready ? Theme.textMuted : Theme.textMuted)
            }
            Spacer()
        }
        .padding(10)
        .glass(cornerRadius: Theme.Radius.sm,
               tint: ready ? Theme.mint.opacity(0.06) : Theme.amber.opacity(0.06),
               stroke: ready ? Theme.mint.opacity(0.30) : Theme.amber.opacity(0.35))
    }
}

struct StartCard: View {
    let workspace: Workspace
    let headline: String
    let blurb: String
    let ready: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(Theme.brandGradient).frame(width: 36, height: 36)
                        Image(systemName: workspace.sfSymbol).foregroundStyle(.white).font(.system(size: 17, weight: .semibold))
                    }
                    Spacer()
                    if !ready {
                        Text("Setup needed").font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.amber.opacity(0.22), in: Capsule())
                            .foregroundStyle(Theme.amber)
                    } else {
                        Text("Ready").font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.mint.opacity(0.22), in: Capsule())
                            .foregroundStyle(Theme.mint)
                    }
                }
                Text(headline).font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                Text(blurb).font(.caption).foregroundStyle(Theme.textMuted).lineLimit(3)
                Spacer(minLength: 0)
                Text("Open " + workspace.rawValue + " →").font(.caption.weight(.medium)).foregroundStyle(Theme.violet)
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
            .padding(Theme.Space.md)
            .glass(cornerRadius: Theme.Radius.md,
                   tint: hovering ? Theme.paneHover : Theme.pane,
                   stroke: hovering ? Theme.violet.opacity(0.4) : Theme.stroke)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
