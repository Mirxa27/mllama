import SwiftUI

/// Surface missing native binaries (sd-cli for video, ffmpeg for editing,
/// sd-server for image) BEFORE the user hits Generate. Each row carries a
/// one-click recovery action — either "Build now" (opens Quick Setup,
/// which runs cmake in Terminal), "Install" (brew install ffmpeg), or
/// "Open Settings" (so the user can point us at a custom path).
///
/// The capability set re-detects every time the view re-appears or the
/// app comes back to the foreground, so dragging a freshly-built binary
/// into ~/.mllama/bin/ reflects without a relaunch.
struct CapabilitiesBanner: View {
    /// Which binaries the caller needs. Each is rendered as its own row
    /// when missing, with a tailored action button.
    let need: Set<Binary>
    let onOpenQuickSetup: () -> Void
    let onOpenSettings: () -> Void

    @State private var state: [Binary: Bool] = [:]

    enum Binary: String, Hashable {
        case sdServer  = "sd-server"
        case sdCli     = "sd-cli"
        case ffmpeg    = "ffmpeg"

        var humanName: String {
            switch self {
            case .sdServer: return "sd-server"
            case .sdCli:    return "sd-cli"
            case .ffmpeg:   return "ffmpeg"
            }
        }
        var purpose: String {
            switch self {
            case .sdServer: return "image generation"
            case .sdCli:    return "video generation"
            case .ffmpeg:   return "video editing"
            }
        }
        var installHint: String {
            switch self {
            case .sdServer, .sdCli:
                return "Build stable-diffusion.cpp via Quick Setup (~5 min on Apple Silicon)."
            case .ffmpeg:
                return "Install via Homebrew: brew install ffmpeg."
            }
        }
        var sfSymbol: String {
            switch self {
            case .sdServer: return "photo.artframe"
            case .sdCli:    return "film.stack"
            case .ffmpeg:   return "scissors"
            }
        }
        var userOverrideKey: String? {
            switch self {
            case .sdServer: return SDKeys.binaryOverride
            case .sdCli:    return SDKeys.cliOverride
            case .ffmpeg:   return nil
            }
        }
    }

    var body: some View {
        let missing = need.filter { state[$0] == false }
        Group {
            if !missing.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(missing).sorted(by: { $0.rawValue < $1.rawValue }),
                            id: \.self) { bin in
                        row(for: bin)
                    }
                }
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, Theme.Space.sm)
                .background(Theme.amber.opacity(0.10))
                .overlay(Rectangle().fill(Theme.amber.opacity(0.4)).frame(height: 0.5),
                         alignment: .bottom)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: missing.count)
        .onAppear { detect() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            detect()
        }
    }

    private func row(for bin: Binary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: bin.sfSymbol)
                .foregroundStyle(Theme.amber)
                .font(.caption)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(bin.humanName) not installed — needed for \(bin.purpose).")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Text(bin.installHint)
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            HStack(spacing: 6) {
                switch bin {
                case .sdServer, .sdCli:
                    Button("Build now", action: onOpenQuickSetup)
                        .controlSize(.small)
                        .help("Open Quick Setup. Builds sd-server + sd-cli with Metal + server support.")
                case .ffmpeg:
                    Button("Install", action: onOpenQuickSetup)
                        .controlSize(.small)
                        .help("Open Quick Setup. Installs ffmpeg via Homebrew.")
                }
                Button("Set path", action: onOpenSettings)
                    .controlSize(.small)
                    .help("Point Mllama at an already-built binary.")
            }
        }
    }

    private func detect() {
        var out: [Binary: Bool] = [:]
        for bin in need {
            out[bin] = InstallPaths.locate(bin.rawValue,
                                             userOverrideKey: bin.userOverrideKey) != nil
        }
        state = out
    }
}
