import SwiftUI
import AppKit

/// Settings panel for the *outgoing* MCP server — the one external agents
/// (Claude Desktop, Cursor, etc.) connect to so they can drive Mllama's
/// image / video generation remotely.
struct MCPHostSettingsView: View {
    @EnvironmentObject var host: MCPServerHost
    @EnvironmentObject var registry: MCPHostToolRegistry

    @AppStorage(MCPHostKeys.enabled) private var enabled: Bool = false
    @AppStorage(MCPHostKeys.port)    private var port: Int = 3737
    @AppStorage(MCPHostKeys.host)    private var bindHost: String = "127.0.0.1"
    @State private var copyConfirmation: String = ""

    var body: some View {
        Form {
            Section("Server") {
                Toggle("Expose Mllama as MCP server", isOn: $enabled)
                    .tint(Theme.violet)
                    .onChange(of: enabled) { newValue in
                        if newValue { host.start() } else { host.stop() }
                    }
                Text("When on, other AI agents can call this app's image and video generation as a remote tool source. Bound to localhost only.")
                    .font(.caption2).foregroundStyle(Theme.textFaint)

                LabeledContent("Port") {
                    HStack {
                        TextField("3737", value: $port, format: .number.grouping(.never))
                            .frame(width: 100)
                            .onChange(of: port) { _ in
                                if case .running = host.status {
                                    host.start()  // restart on new port
                                }
                            }
                        Text("(restart server after changing)").font(.caption2).foregroundStyle(Theme.textFaint)
                    }
                }
                LabeledContent("Bind host") {
                    TextField("127.0.0.1", text: $bindHost).frame(width: 160)
                }

                statusRow
            }

            Section("Exposed tools") {
                if registry.tools.isEmpty {
                    Text("Tool registry not initialized yet.")
                        .font(.caption).foregroundStyle(Theme.textMuted)
                } else {
                    ForEach(registry.tools.values.sorted { $0.name < $1.name }, id: \.name) { tool in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: iconFor(tool.name))
                                    .foregroundStyle(Theme.violet)
                                    .frame(width: 16)
                                Text(tool.name)
                                    .font(.callout.monospaced().weight(.semibold))
                                    .foregroundStyle(Theme.text)
                                Spacer()
                            }
                            Text(tool.description)
                                .font(.caption)
                                .foregroundStyle(Theme.textMuted)
                                .padding(.leading, 22)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Connect from Claude Desktop / Cursor") {
                Text("Add this to your `~/Library/Application Support/Claude/claude_desktop_config.json` (using the `mcp-remote` bridge, since Claude Desktop currently expects stdio).")
                    .font(.caption).foregroundStyle(Theme.textMuted)
                copyableCode(label: "Claude Desktop", code: claudeDesktopSnippet)

                Text("Cursor and other clients that support HTTP MCP can use the URL directly:")
                    .font(.caption).foregroundStyle(Theme.textMuted)
                copyableCode(label: "Direct URL", code: directURLSnippet)

                Text("Quick sanity check (from Terminal):")
                    .font(.caption).foregroundStyle(Theme.textMuted)
                copyableCode(label: "curl test", code: curlSnippet)
            }

            Section("Recent requests") {
                if host.recentRequests.isEmpty {
                    Text("No requests yet. Start the server and connect a client.")
                        .font(.caption).foregroundStyle(Theme.textMuted)
                } else {
                    ForEach(host.recentRequests.prefix(15)) { r in
                        HStack(spacing: 8) {
                            Image(systemName: r.okOrErrCode.hasPrefix("err") ? "exclamationmark.triangle.fill" : "checkmark")
                                .foregroundStyle(r.okOrErrCode.hasPrefix("err") ? Theme.coral : Theme.mint)
                                .font(.caption2)
                            Text(r.at.formatted(date: .omitted, time: .standard))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.textFaint)
                            Text(r.method)
                                .font(.caption.monospaced())
                                .foregroundStyle(Theme.text)
                            if let t = r.toolName {
                                Text("→ \(t)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Theme.violet)
                            }
                            Spacer()
                            Text(r.okOrErrCode)
                                .font(.caption2.monospaced())
                                .foregroundStyle(Theme.textFaint)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Pieces

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 8) {
            switch host.status {
            case .running(let port):
                Circle().fill(Theme.mint).frame(width: 9, height: 9)
                Text("Running on http://\(bindHost):\(port)/mcp")
                    .font(.callout.monospaced())
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("\(host.requestCount) requests").font(.caption.monospacedDigit()).foregroundStyle(Theme.textFaint)
            case .stopped:
                Circle().fill(Theme.textFaint).frame(width: 9, height: 9)
                Text("Stopped")
                    .font(.callout).foregroundStyle(Theme.textMuted)
                Spacer()
            case .failed(let msg):
                Circle().fill(Theme.coral).frame(width: 9, height: 9)
                Text(msg).font(.caption).foregroundStyle(Theme.coral).lineLimit(2)
                Spacer()
                Button("Retry") { host.start() }.controlSize(.small)
            }
        }
        .padding(.top, 4)
    }

    private func copyableCode(label: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(Theme.textMuted)
                Spacer()
                if copyConfirmation == label {
                    Label("Copied!", systemImage: "checkmark")
                        .font(.caption2).foregroundStyle(Theme.mint)
                }
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(code, forType: .string)
                    copyConfirmation = label
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if copyConfirmation == label { copyConfirmation = "" }
                    }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.violet)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).stroke(Theme.stroke, lineWidth: 0.5))
        }
    }

    private var url: String { "http://\(bindHost):\(port)/mcp" }

    private var claudeDesktopSnippet: String {
        """
        {
          "mcpServers": {
            "mllama": {
              "command": "npx",
              "args": ["-y", "mcp-remote", "\(url)"]
            }
          }
        }
        """
    }

    private var directURLSnippet: String { url }

    private var curlSnippet: String {
        """
        # 1. initialize
        curl -s \(url) -H 'Content-Type: application/json' \\
          -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'

        # 2. list tools
        curl -s \(url) -H 'Content-Type: application/json' \\
          -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

        # 3. generate an image
        curl -s \(url) -H 'Content-Type: application/json' \\
          -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"generate_image","arguments":{"prompt":"a sunset","width":512,"height":512,"steps":20}}}'
        """
    }

    private func iconFor(_ name: String) -> String {
        switch name {
        case "generate_image":   return "photo.artframe"
        case "edit_image":       return "wand.and.rays"
        case "generate_video":   return "film.stack"
        case "search_hf_models": return "magnifyingglass"
        case "list_media":       return "square.grid.3x3"
        case "get_media_file":   return "doc.on.doc.fill"
        case "server_info":      return "info.circle"
        default:                 return "bolt.fill"
        }
    }
}
