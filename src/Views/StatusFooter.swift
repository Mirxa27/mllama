import SwiftUI
import AppKit

/// Thin live status bar at the bottom of the app showing real-time hardware
/// telemetry — chip, GPU cores, RAM, CPU, disk, model in memory, throughput.
/// Updates on the 2-second cadence of ResourceMonitor.
struct StatusFooter: View {
    @EnvironmentObject var monitor: ResourceMonitor
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var sdServer: SDServerController
    @EnvironmentObject var imageGen: ImageGenerator
    @EnvironmentObject var videoGen: VideoGenerator
    @EnvironmentObject var pipeline: VideoPipeline
    @State private var showDetails = false

    var body: some View {
        HStack(spacing: 14) {
            chipChip
            ramChip
            cpuChip
            diskChip
            Spacer()
            activityChip
            Button {
                showDetails.toggle()
            } label: {
                Image(systemName: showDetails ? "chevron.down.circle.fill" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.borderless)
            .help("System details")
            .popover(isPresented: $showDetails, arrowEdge: .top) {
                DetailedSystemPopover()
                    .environmentObject(monitor)
                    .environmentObject(server)
                    .environmentObject(sdServer)
                    .frame(width: 320)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 6)
        .background(VisualEffectBackground(material: .titlebar, blendingMode: .withinWindow))
        .overlay(Rectangle().fill(Theme.stroke).frame(height: 0.5), alignment: .top)
        .onAppear { monitor.start() }
    }

    // MARK: Pieces

    private var chipChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.violet)
            Text(monitor.hardware.chipVariant.shortName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.text)
            if monitor.hardware.gpuCores > 0 {
                Text("·").foregroundStyle(Theme.textFaint)
                Text("\(monitor.hardware.gpuCores)c GPU")
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .help(monitor.hardware.chipName)
    }

    private var ramChip: some View {
        let total = monitor.hardware.totalRamGB
        let used = monitor.sample.ramUsedGB
        let frac = total > 0 ? min(1, used / total) : 0
        let color: Color = frac > 0.85 ? Theme.coral : frac > 0.70 ? Theme.amber : Theme.mint
        return HStack(spacing: 5) {
            Image(systemName: "memorychip")
                .font(.system(size: 10))
                .foregroundStyle(Theme.cyan)
            HStack(spacing: 6) {
                Text(String(format: "%.1f / %.0f GB", used, total))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.text)
                MiniBar(value: frac, color: color, width: 60)
            }
        }
        .help("RAM in use · \(Int(frac * 100))% of \(Int(total)) GB")
    }

    private var cpuChip: some View {
        let pct = monitor.sample.cpuPercent
        let color: Color = pct > 80 ? Theme.coral : pct > 50 ? Theme.amber : Theme.mint
        return HStack(spacing: 5) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 10))
                .foregroundStyle(color)
            Text(String(format: "%d%%", Int(pct)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.text)
            MiniBar(value: pct / 100.0, color: color, width: 40)
        }
        .help("CPU usage · all cores averaged")
    }

    private var diskChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "internaldrive")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textMuted)
            Text(String(format: "%.0f GB free", monitor.sample.diskFreeGB))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(monitor.sample.diskFreeGB < 10 ? Theme.coral : Theme.text)
        }
        .help("Disk space free on /")
    }

    @ViewBuilder
    private var activityChip: some View {
        if imageGen.isGenerating, let p = imageGen.progress {
            ActivityChip(
                icon: "photo.artframe",
                label: "Image gen",
                detail: "\(Int(p.fraction * 100))% · step \(p.step)/\(p.totalSteps)",
                color: Theme.violet
            )
        } else if videoGen.isGenerating, let p = videoGen.progress {
            ActivityChip(
                icon: "film.stack",
                label: "Video gen",
                detail: "\(Int(p.fraction * 100))% · step \(p.step)/\(p.totalSteps)",
                color: Theme.magenta
            )
        } else if pipeline.isRunning {
            ActivityChip(
                icon: "rectangle.stack.fill",
                label: "Storyboard",
                detail: "scene \(pipeline.currentSceneIndex + 1)/\(pipeline.storyboard.scenes.count)",
                color: Theme.cyan
            )
        } else if case .running = sdServer.status {
            ActivityChip(icon: "photo.artframe", label: "image ready", detail: "port \(sdServer.runtimePort)", color: Theme.mint, dim: true)
        } else if case .running = server.status {
            ActivityChip(icon: "text.bubble", label: "chat ready", detail: server.modelName, color: Theme.mint, dim: true)
        } else {
            EmptyView()
        }
    }
}

// MARK: - Mini graphical bar

struct MiniBar: View {
    let value: Double      // 0..1
    let color: Color
    let width: CGFloat
    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.pane)
                .frame(width: width, height: 5)
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: width * CGFloat(max(0, min(1, value))), height: 5)
                .animation(.easeOut(duration: 0.4), value: value)
        }
        .frame(width: width)
    }
}

struct ActivityChip: View {
    let icon: String, label: String, detail: String, color: Color
    var dim: Bool = false
    var body: some View {
        HStack(spacing: 5) {
            if dim {
                Circle().fill(color).frame(width: 6, height: 6)
            } else {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(color)
            }
            Text(label).font(.caption.weight(.medium)).foregroundStyle(dim ? Theme.textMuted : Theme.text)
            Text("·").foregroundStyle(Theme.textFaint)
            Text(detail).font(.caption2.monospacedDigit()).foregroundStyle(Theme.textMuted).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .glass(cornerRadius: 999, tint: color.opacity(dim ? 0.05 : 0.15), stroke: color.opacity(dim ? 0.18 : 0.4))
    }
}

// MARK: - Detailed popover

struct DetailedSystemPopover: View {
    @EnvironmentObject var monitor: ResourceMonitor
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var sdServer: SDServerController

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            // Hardware
            sectionTitle("Hardware")
            row("Chip",      monitor.hardware.chipName)
            row("CPU cores", "\(monitor.hardware.performanceCores) performance + \(monitor.hardware.efficiencyCores) efficiency")
            row("GPU",       "\(monitor.hardware.gpuName) · \(monitor.hardware.gpuCores) cores")
            row("Total RAM", String(format: "%.0f GB", monitor.hardware.totalRamGB))
            row("Tier",      monitor.hardware.ramTier.label)

            Divider().background(Theme.stroke)
            sectionTitle("Live")
            row("RAM used",     String(format: "%.2f GB",  monitor.sample.ramUsedGB))
            row("RAM available", String(format: "%.2f GB", monitor.sample.ramAvailableGB))
            row("Swap used",    String(format: "%.2f GB",  monitor.sample.swapUsedGB))
            row("CPU %",        String(format: "%.0f%%",   monitor.sample.cpuPercent))
            row("Disk free",    String(format: "%.0f GB",  monitor.sample.diskFreeGB))

            Divider().background(Theme.stroke)
            sectionTitle("Loaded models")
            if case .running = server.status {
                row("LLM",   server.modelName.isEmpty ? "—" : server.modelName)
                row("LLM ctx", server.nCtx > 0 ? "\(server.nCtx) tokens" : "—")
            } else {
                row("LLM", "(server not running)")
            }
            if case .running = sdServer.status {
                row("Image", (sdServer.modelPath as NSString?)?.lastPathComponent ?? "—")
            } else {
                row("Image", "(server not running)")
            }
        }
        .padding(Theme.Space.md)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(Theme.textFaint)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(Theme.textMuted)
            Spacer()
            Text(v).font(.caption.monospacedDigit()).foregroundStyle(Theme.text)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}
