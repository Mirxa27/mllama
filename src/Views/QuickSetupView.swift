import SwiftUI
import AppKit

/// Replaces the static capability check in onboarding with a section that
/// actually *does* things: install ffmpeg, open the sd-server build commands
/// in Terminal, queue downloads of recommended models, etc.
struct QuickSetupView: View {
    @EnvironmentObject var monitor: ResourceMonitor
    @EnvironmentObject var downloads: HFDownloadManager
    @EnvironmentObject var onboarding: OnboardingState
    @State private var caps: OnboardingState.Capabilities
    @State private var brewInstalled: Bool? = nil
    @State private var actionLog: [String] = []

    init() {
        _caps = State(initialValue: OnboardingState.shared.detectCapabilities())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                hardwareCard
                Divider().background(Theme.stroke)
                actionsList
                Divider().background(Theme.stroke)
                starterPackCard
                if !actionLog.isEmpty {
                    Divider().background(Theme.stroke)
                    activityLog
                }
            }
            .padding(Theme.Space.lg)
        }
        .task {
            brewInstalled = await Self.detectBrew()
            // Re-poll caps every 4s while view is up to catch newly-installed binaries
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self.caps = OnboardingState.shared.detectCapabilities()
            }
        }
    }

    // MARK: Hardware card

    private var hardwareCard: some View {
        let hw = monitor.hardware
        return HStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.brandGradient).frame(width: 56, height: 56)
                Image(systemName: "cpu.fill").foregroundStyle(.white).font(.title2)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Detected: \(hw.chipName)")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.text)
                HStack(spacing: 12) {
                    Label("\(Int(hw.totalRamGB)) GB RAM", systemImage: "memorychip")
                        .font(.caption)
                    Label("\(hw.gpuCores)c GPU", systemImage: "circle.hexagonpath.fill")
                        .font(.caption)
                    Label("\(hw.totalCores) CPU cores", systemImage: "cpu")
                        .font(.caption)
                }
                .foregroundStyle(Theme.textMuted)
                Text(hw.ramTier.label)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Theme.violet.opacity(0.18), in: Capsule())
                    .foregroundStyle(Theme.violet)
            }
            Spacer()
        }
        .padding(Theme.Space.md)
        .glassCard(cornerRadius: Theme.Radius.md)
    }

    // MARK: Actions

    private var actionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ONE-CLICK SETUP")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textFaint)

            ActionCard(
                ready: caps.hasFFmpeg,
                title: "ffmpeg",
                blurb: "Required for video editing (trim, scale, GIF, etc).",
                buttonText: "Install via Homebrew",
                buttonDisabled: brewInstalled == false,
                disabledReason: "Homebrew not detected. Install brew first from brew.sh."
            ) {
                logLine("Running: brew install ffmpeg")
                Task {
                    let result = await Self.runInTerminal("brew install ffmpeg")
                    switch result {
                    case .opened:
                        logLine("Opened Terminal — accept the brew prompts. Re-check after install.")
                    case .denied:
                        logLine("⚠️ Terminal automation denied. Go to System Settings → Privacy → Automation, enable Terminal for Mllama, then try again.")
                    case .failed(let m):
                        logLine("⚠️ Couldn't launch Terminal: \(m)")
                    }
                    self.caps = OnboardingState.shared.detectCapabilities()
                }
            }

            ActionCard(
                ready: caps.hasSDServer && caps.hasSDCli,
                title: "stable-diffusion.cpp",
                blurb: "Builds sd-server + sd-cli with Metal support. Takes ~5 min on M-series.",
                buttonText: "Build in Terminal",
                buttonDisabled: false,
                disabledReason: ""
            ) {
                // Install into a user-writable directory (~/.mllama/bin). The
                // app bundle itself is read-only on macOS, so we can't drop
                // binaries into Resources/bin/ at runtime. SDServer / sd-cli
                // discovery checks ~/.mllama/bin/ first, so this Just Works.
                let installRoot = InstallPaths.binRoot.path
                let srcDir = "\(NSHomeDirectory())/.mllama/build"
                let esc = { (s: String) -> String in s.replacingOccurrences(of: " ", with: "\\ ") }
                let cmd = """
                set -e
                mkdir -p \(esc(srcDir))
                mkdir -p \(esc(installRoot))
                cd \(esc(srcDir))
                if [ ! -d stable-diffusion.cpp ]; then
                  git clone --recursive https://github.com/leejet/stable-diffusion.cpp
                fi
                cd stable-diffusion.cpp
                git pull --recurse-submodules
                mkdir -p build && cd build
                cmake .. -DSD_METAL=ON -DSD_BUILD_SERVER=ON -DCMAKE_BUILD_TYPE=Release
                cmake --build . --config Release -j
                cp -v bin/sd-cli bin/sd-server \(esc(installRoot))/
                echo
                echo \"=== Done. Restart Mllama (binaries installed to \(installRoot)). ===\"
                """
                logLine("Opening Terminal with build commands…")
                Task {
                    let result = await Self.runInTerminal(cmd)
                    switch result {
                    case .opened:
                        logLine("Building to \(srcDir); binaries will land in \(installRoot).")
                    case .denied:
                        logLine("⚠️ Terminal automation denied. Go to System Settings → Privacy → Automation, enable Terminal for Mllama, then try again.")
                    case .failed(let m):
                        logLine("⚠️ Couldn't open Terminal: \(m)")
                    }
                }
            }

            ActionCard(
                ready: caps.hasLLM,
                title: "Chat model (LLM)",
                blurb: "A small Llama or Qwen for chat + tool use.",
                buttonText: "Download recommended",
                buttonDisabled: false,
                disabledReason: ""
            ) {
                if let rec = ModelRecommender.canRun(on: monitor.hardware, kind: .llm).first {
                    HFDownloadManager.shared.enqueue(repoId: rec.repoId, file: rec.filename)
                    logLine("Queued \(rec.label) (\(rec.humanDownload)). Watch downloads in the Models tab.")
                }
            }

            ActionCard(
                ready: caps.hasImageModel,
                title: "Image model",
                blurb: "A diffusion checkpoint for the Image Studio.",
                buttonText: "Download recommended",
                buttonDisabled: false,
                disabledReason: ""
            ) {
                if let rec = ModelRecommender.canRun(on: monitor.hardware, kind: .image).first {
                    HFDownloadManager.shared.enqueue(repoId: rec.repoId, file: rec.filename)
                    logLine("Queued \(rec.label) (\(rec.humanDownload)). Set the path in Settings → Image Gen once download finishes.")
                }
            }

            // Always show the video card. Even mid-tier Macs can run
            // LTX 0.9.6 Q4 (~1.2 GB download, ~6 GB RAM).
            ActionCard(
                ready: caps.hasVideoModel,
                title: "Video model (LTX / Wan)",
                blurb: monitor.hardware.ramTier == .small
                    ? "Tight on small RAM — LTX 0.9.6 Q4 is the smallest verified option."
                    : "Optional. Required only for the Video Studio.",
                buttonText: "Download recommended",
                buttonDisabled: false,
                disabledReason: ""
            ) {
                // Prefer LTX (smaller / mid-friendly) when available — falls
                // back to the heaviest model the system can run if not.
                let candidates = ModelRecommender.canRun(on: monitor.hardware, kind: .video)
                let pick = candidates.first(where: { $0.id.hasPrefix("vid.ltx") })
                    ?? candidates.first
                if let rec = pick {
                    HFDownloadManager.shared.enqueue(repoId: rec.repoId, file: rec.filename)
                    logLine("Queued \(rec.label) (\(rec.humanDownload)).")
                } else {
                    logLine("No verified video model fits your Mac. See Models browser.")
                }
            }
        }
    }

    // MARK: Starter pack

    private var starterPackCard: some View {
        let pack = ModelRecommender.starterPack(for: monitor.hardware)
        let totalGB = ModelRecommender.totalBytesFor(pack)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("STARTER PACK FOR YOUR MAC")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                Text(String(format: "%.1f GB total", totalGB))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textFaint)
            }
            ForEach(pack) { m in
                HStack(spacing: 10) {
                    Image(systemName: m.kind.sfSymbol)
                        .foregroundStyle(Theme.violet)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.label).font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                        Text(m.blurb).font(.caption2).foregroundStyle(Theme.textMuted).lineLimit(2)
                    }
                    Spacer()
                    Text(m.humanDownload)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textFaint)
                }
                .padding(8)
                .glass(cornerRadius: Theme.Radius.sm)
            }
            Button {
                for m in pack {
                    HFDownloadManager.shared.enqueue(repoId: m.repoId, file: m.filename)
                }
                logLine("Queued \(pack.count) downloads (~\(Int(totalGB)) GB total).")
            } label: {
                Label("Download all", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.violet)
            .disabled(pack.isEmpty)
        }
    }

    // MARK: Activity log

    private var activityLog: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ACTIVITY").font(.caption.weight(.bold)).foregroundStyle(Theme.textFaint)
            ForEach(actionLog.suffix(8).reversed(), id: \.self) { line in
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.mint)
                        .font(.system(size: 10))
                    Text(line).font(.caption.monospaced()).foregroundStyle(Theme.text).lineLimit(2)
                }
            }
        }
    }

    private func logLine(_ s: String) {
        actionLog.append(s)
        if actionLog.count > 40 { actionLog.removeFirst(actionLog.count - 40) }
    }

    // MARK: Terminal & brew detection

    enum TerminalResult { case opened, denied, failed(String) }

    /// Open Terminal.app and run the given command. Uses AppleScript via osascript.
    /// Returns a typed result so callers can distinguish the user denying
    /// automation permission (very common on first run) from a real failure.
    static func runInTerminal(_ command: String) async -> TerminalResult {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        return await withCheckedContinuation { (cont: CheckedContinuation<TerminalResult, Never>) in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            let errPipe = Pipe()
            task.standardError = errPipe
            let errBox = LockedBox<Data>(Data())
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { errBox.mutate { $0.append(d) } }
            }
            task.terminationHandler = { p in
                errPipe.fileHandleForReading.readabilityHandler = nil
                if p.terminationStatus == 0 {
                    cont.resume(returning: .opened)
                    return
                }
                let err = String(data: errBox.read(), encoding: .utf8) ?? ""
                // macOS reports "Not authorized to send Apple events to Terminal"
                // when the user has denied (or not granted) automation access.
                if err.contains("Not authorized") || err.contains("(-1743)") {
                    cont.resume(returning: .denied)
                } else {
                    cont.resume(returning: .failed(String(err.prefix(120))))
                }
            }
            do { try task.run() }
            catch { cont.resume(returning: .failed(error.localizedDescription)) }
        }
    }

    /// Best-effort: is Homebrew installed?
    static func detectBrew() async -> Bool {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for c in candidates {
            if FileManager.default.fileExists(atPath: c) { return true }
        }
        return false
    }
}

// MARK: - Action card

struct ActionCard: View {
    let ready: Bool
    let title: String
    let blurb: String
    let buttonText: String
    let buttonDisabled: Bool
    let disabledReason: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ready ? Theme.mint : Theme.textFaint)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                    if ready {
                        Text("Installed").font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.mint.opacity(0.22), in: Capsule())
                            .foregroundStyle(Theme.mint)
                    }
                }
                Text(blurb).font(.caption).foregroundStyle(Theme.textMuted)
                if buttonDisabled, !disabledReason.isEmpty {
                    Text(disabledReason).font(.caption2).foregroundStyle(Theme.amber)
                }
            }
            Spacer()
            Button(action: action) {
                Text(ready ? "Re-install" : buttonText).font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .disabled(buttonDisabled)
            .tint(ready ? Theme.textMuted : Theme.violet)
        }
        .padding(10)
        .glass(cornerRadius: Theme.Radius.md,
               tint: ready ? Theme.mint.opacity(0.05) : Theme.pane,
               stroke: ready ? Theme.mint.opacity(0.25) : Theme.stroke)
    }
}
