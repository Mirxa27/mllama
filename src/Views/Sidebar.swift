import SwiftUI

struct Sidebar: View {
    @EnvironmentObject var library: ModelLibrary
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var agent: Agent
    @EnvironmentObject var mcp: MCPManager
    @State private var query: String = ""
    @AppStorage(Keys.customDirs) private var customDirsJSON: String = "[]"

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    statusCard
                    modelsSection
                    mcpSection
                }
                .padding(Theme.Space.sm)
            }
        }
        .navigationTitle("Mllama")
        .task { if library.models.isEmpty { await library.rescan(extraDirs: customDirs()) } }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: Theme.Space.sm) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Theme.brandGradient)
                        .frame(width: 32, height: 32)
                        .shadow(color: Theme.violet.opacity(0.45), radius: 8)
                    Image(systemName: "circle.hexagonpath.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text("Mllama")
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                Spacer()
                Button { agent.reset() } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 26)
                        .glass(cornerRadius: Theme.Radius.sm)
                }
                .buttonStyle(.plain)
                .help("New chat (⌘N)")
            }

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textMuted)
                    .font(.caption)
                TextField("Search models", text: $query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.text)
                    .tint(Theme.violet)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .glass(cornerRadius: Theme.Radius.sm)
        }
        .padding(Theme.Space.sm)
        .overlay(Rectangle().fill(Theme.stroke).frame(height: 0.5), alignment: .bottom)
    }

    // MARK: Status card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text(statusLine).font(.caption.weight(.medium)).foregroundStyle(Theme.text)
                Spacer()
                Button { server.restart() } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textMuted)
                .help("Restart server")
            }
            if case .running = server.status {
                if server.nCtx > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.compress.vertical").font(.caption2)
                        Text("ctx \(formatThousands(server.nCtx))").font(.caption2.monospacedDigit())
                    }
                    .foregroundStyle(Theme.textFaint)
                }
                if let url = server.serverURL {
                    Text(url.absoluteString)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: Theme.Radius.md)
    }

    private var statusColor: Color {
        switch server.status {
        case .running: Theme.mint
        case .starting: Theme.amber
        case .stopped: Theme.textFaint
        case .failed: Theme.coral
        }
    }

    private var statusLine: String {
        switch server.status {
        case .running:  "Running"
        case .starting: "Starting…"
        case .stopped:  "Stopped"
        case .failed:   "Error"
        }
    }

    // MARK: Models

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader(title: "MODELS", count: library.models.count, action: { Task { await library.rescan(extraDirs: customDirs()) } }, busy: library.isScanning)
            if library.isScanning && library.models.isEmpty {
                ProgressView().padding()
            } else if library.models.isEmpty {
                Text("Drop .gguf files into ~/models, install LM Studio / Ollama, or add a folder in Settings.")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .padding(Theme.Space.sm)
            } else {
                VStack(spacing: 2) {
                    ForEach(library.grouped(), id: \.0) { (source, items) in
                        let filtered = items.filter { matches($0, query: query) }
                        if !filtered.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: source.sfSymbol).font(.caption2)
                                Text(source.rawValue.uppercased()).font(.caption2.weight(.bold))
                            }
                            .foregroundStyle(Theme.textFaint)
                            .padding(.horizontal, 8)
                            .padding(.top, 6)
                            ForEach(filtered) { model in
                                SidebarModelRow(model: model, isActive: model.path == server.modelPath) {
                                    server.activate(modelPath: model.path, mmprojPath: model.mmprojPath)
                                    agent.reset()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader(title: "MCP SERVERS", count: mcp.servers.count, action: { Task { await mcp.reload() } }, busy: false)
            if mcp.servers.isEmpty {
                Text("No MCP servers connected. Add to mcp.json (or your Claude Desktop config).")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .padding(Theme.Space.sm)
            } else {
                ForEach(mcp.servers, id: \.name) { row in
                    HStack(spacing: 8) {
                        Image(systemName: row.error == nil ? "shippingbox.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(row.error == nil ? Theme.cyan : Theme.coral)
                            .font(.caption)
                        VStack(alignment: .leading) {
                            Text(row.name).font(.caption).foregroundStyle(Theme.text)
                            Text("\(row.tools.count) tool\(row.tools.count == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(Theme.textFaint)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glass(cornerRadius: Theme.Radius.sm)
                }
            }
        }
    }

    private func sectionHeader(title: String, count: Int, action: @escaping () -> Void, busy: Bool) -> some View {
        HStack {
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(Theme.textFaint)
            Spacer()
            Text("\(count)").font(.caption2).foregroundStyle(Theme.textFaint)
            Button(action: action) {
                if busy { ProgressView().controlSize(.mini) }
                else { Image(systemName: "arrow.clockwise").font(.caption2) }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.textMuted)
            .disabled(busy)
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
    }

    // MARK: Helpers

    private func matches(_ m: DiscoveredModel, query q: String) -> Bool {
        guard !q.isEmpty else { return true }
        let n = q.lowercased()
        return m.displayName.lowercased().contains(n)
            || (m.quantization?.lowercased().contains(n) ?? false)
    }

    private func customDirs() -> [String] {
        guard let data = customDirsJSON.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }

    private func formatThousands(_ n: Int) -> String {
        if n >= 1000 {
            let k = Double(n) / 1000.0
            return String(format: k < 10 ? "%.1fk" : "%.0fk", k)
        }
        return "\(n)"
    }
}

struct SidebarModelRow: View {
    let model: DiscoveredModel
    let isActive: Bool
    let onActivate: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onActivate) {
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 3) {
                    Image(systemName: isActive ? "play.circle.fill" : "circle")
                        .foregroundStyle(isActive ? Theme.mint : Theme.textFaint)
                        .font(.callout)
                    if model.isVision {
                        Image(systemName: "eye.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.violet)
                            .help("Vision (mmproj paired)")
                    }
                }
                .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(Theme.text)
                    HStack(spacing: 5) {
                        if let q = model.quantization {
                            Text(q).font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Theme.violet.opacity(0.22), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(Theme.text)
                        }
                        Text(model.humanSize)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Theme.violet.opacity(0.16) : hovering ? Theme.paneHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Activate", action: onActivate)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.path)])
            }
            Button("Copy Path") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(model.path, forType: .string)
            }
        }
    }
}
