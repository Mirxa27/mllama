import SwiftUI
import AppKit
import AVKit

struct MessageView: View {
    let message: ChatMessage
    @EnvironmentObject var tts: SpeechSynthesizer

    var body: some View {
        switch message.role {
        case .user:      userView
        case .assistant: assistantView
        case .tool:      EmptyView()
        case .system:    systemNoteView
        }
    }

    // MARK: System (compaction note)

    private var systemNoteView: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").font(.caption2)
                Text("conversation compacted").font(.caption2)
            }
            .foregroundStyle(Theme.violet)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .glass(cornerRadius: 999, tint: Theme.violet.opacity(0.15), stroke: Theme.violet.opacity(0.35))
            Spacer()
        }
        .padding(.vertical, 6)
    }

    // MARK: User

    private var userView: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Spacer(minLength: Theme.Space.xl)
            VStack(alignment: .trailing, spacing: Theme.Space.xxs) {
                richText(message.content)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, Theme.Space.sm)
                    .glassCard(cornerRadius: Theme.Radius.lg,
                               tint: Theme.userBubble,
                               stroke: Theme.userBubbleBorder)
                    .frame(maxWidth: 720, alignment: .trailing)
                Text("you").font(.caption2).foregroundStyle(Theme.textFaint)
            }
            avatar(symbol: "person.fill",
                   gradient: LinearGradient(colors: [Theme.cyan, Theme.indigo],
                                            startPoint: .top, endPoint: .bottom))
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.xs)
    }

    // MARK: Assistant

    private var assistantView: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            avatar(symbol: "circle.hexagonpath.fill", gradient: Theme.brandGradient)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if !message.content.isEmpty || message.streaming {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .bottom, spacing: 0) {
                            richText(message.content)
                            if message.streaming { TypingCursor() }
                        }
                    }
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, Theme.Space.sm)
                    .glassCard(cornerRadius: Theme.Radius.lg)
                    .frame(maxWidth: 760, alignment: .leading)
                }
                ForEach(message.toolCalls) { call in
                    ToolCallCard(
                        call: call,
                        state: message.toolApprovals[call.id] ?? .pending,
                        result: message.toolResults[call.id]
                    )
                }
                HStack(spacing: 12) {
                    Text("mllama").font(.caption2).foregroundStyle(Theme.textFaint)
                    if !message.streaming && !message.content.isEmpty {
                        Button {
                            tts.toggleSpeak(message.content)
                        } label: {
                            Image(systemName: tts.isSpeaking && tts.spokenText == SpeechSynthesizer.stripForSpeech(message.content)
                                  ? "speaker.wave.2.circle.fill"
                                  : "speaker.wave.2")
                                .font(.caption)
                                .foregroundStyle(Theme.violet)
                        }
                        .buttonStyle(.borderless)
                        .help("Speak this message")

                        Button {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(message.content, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(Theme.textFaint)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy")
                    }
                }
            }
            Spacer(minLength: Theme.Space.xl)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.xs)
    }

    private func avatar(symbol: String, gradient: LinearGradient) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(gradient, in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
    }

    @ViewBuilder
    private func richText(_ s: String) -> some View {
        let blocks = parseRich(s)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let t):
                    InlineMarkdownText(text: t)
                case .code(let t, let lang):
                    CodeBlock(text: t, lang: lang)
                }
            }
        }
    }
}

// MARK: - Inline markdown / autolink renderer

/// Renders text using SwiftUI's AttributedString markdown parser (bold, italic,
/// inline code, links), with automatic URL detection on plain spans the parser
/// missed. Keeps each line tight and selectable.
struct InlineMarkdownText: View {
    let text: String

    var body: some View {
        Text(attributed())
            .font(.body)
            .foregroundStyle(Theme.text)
            .textSelection(.enabled)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .tint(Theme.cyan)
    }

    private func attributed() -> AttributedString {
        var combined = AttributedString("")
        var first = true
        for line in text.components(separatedBy: "\n") {
            if !first { combined.append(AttributedString("\n")) }
            first = false

            // Soft heading via leading ##
            var working = line
            var headerLevel = 0
            if let r = working.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let hashes = working[r].filter { $0 == "#" }.count
                headerLevel = hashes
                working.removeSubrange(r)
            }

            var line = (try? AttributedString(
                markdown: working,
                options: AttributedString.MarkdownParsingOptions(
                    allowsExtendedAttributes: false,
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )) ?? AttributedString(working)

            autolinkInPlace(&line)
            styleInlineCode(&line)

            if headerLevel > 0 {
                let size: CGFloat
                switch headerLevel {
                case 1: size = 22
                case 2: size = 19
                case 3: size = 17
                default: size = 15
                }
                line.font = .system(size: size, weight: .semibold)
            }

            combined.append(line)
        }
        return combined
    }

    /// Find http/https URLs that markdown didn't already turn into links.
    private func autolinkInPlace(_ a: inout AttributedString) {
        let pattern = #"https?://[^\s)\]\}<>'\"]+"#
        let plain = String(a.characters)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let nsRange = NSRange(plain.startIndex..., in: plain)
        for match in regex.matches(in: plain, range: nsRange).reversed() {
            guard let range = Range(match.range, in: plain),
                  let attrRange = a.range(of: String(plain[range])) else { continue }
            // Skip if already linked.
            if a[attrRange].link != nil { continue }
            if let url = URL(string: String(plain[range])) {
                a[attrRange].link = url
                a[attrRange].underlineStyle = .single
                a[attrRange].foregroundColor = Theme.cyan
            }
        }
    }

    /// Re-style inline code (`backticks`) inside attributed text. The markdown
    /// parser already wraps them in monospaced; we add a subtle background.
    private func styleInlineCode(_ a: inout AttributedString) {
        for run in a.runs {
            // Heuristic: if the run is monospaced (parser marked it as code),
            // tint it.
            if let inlinePresentation = run.inlinePresentationIntent,
               inlinePresentation.contains(.code) {
                a[run.range].backgroundColor = Color.white.opacity(0.12)
                a[run.range].foregroundColor = Theme.amber
            }
        }
    }
}

// MARK: - Code block

struct CodeBlock: View {
    let text: String
    let lang: String?
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.caption2)
                Text(lang?.isEmpty == false ? lang! : "code").font(.caption2.monospaced())
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption2)
                        if copied { Text("copied").font(.caption2) }
                    }
                    .foregroundStyle(copied ? Theme.mint : Theme.textMuted)
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
            .foregroundStyle(Theme.textMuted)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.text)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).stroke(Theme.stroke, lineWidth: 0.5))
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Tool call card

struct ToolCallCard: View {
    let call: ToolCallRequest
    let state: ToolApprovalState
    let result: ToolCallResult?
    @State private var expanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                stateIcon
                Text(call.name)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.violet)
                Spacer()
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textMuted)
            }
            if expanded {
                Text("arguments").font(.caption2).foregroundStyle(Theme.textFaint)
                Text(prettyJSON(call.arguments))
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.text)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                if let r = result {
                    Text(r.isError ? "error" : "result")
                        .font(.caption2)
                        .foregroundStyle(r.isError ? Theme.coral : Theme.textFaint)

                    // Detect media output and render inline. Recognized prefixes
                    // come from MediaTools.swift result strings.
                    if !r.isError, let media = ToolCallCard.detectMedia(in: r.content) {
                        InlineMediaResult(url: media.url, kind: media.kind, resultText: r.content)
                    } else {
                        Text(r.content)
                            .font(Theme.monoSmall)
                            .foregroundStyle(Theme.text)
                            .lineLimit(24)
                            .truncationMode(.tail)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(12)
        .glassCard(cornerRadius: Theme.Radius.md,
                   tint: Theme.toolCallBg,
                   stroke: Theme.toolCallBorder)
    }

    @ViewBuilder private var stateIcon: some View {
        switch state {
        case .pending:  Image(systemName: "clock").foregroundStyle(Theme.amber)
        case .approved: Image(systemName: "checkmark.circle").foregroundStyle(Theme.cyan)
        case .running:  ProgressView().controlSize(.mini)
        case .done:     Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.mint)
        case .denied:   Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.coral)
        case .errored:  Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.coral)
        }
    }

    private func prettyJSON(_ s: String) -> String {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              let str = String(data: pretty, encoding: .utf8)
        else { return s }
        return str
    }

    /// Parse a tool-result string for media file references. MediaTools writes
    /// results like "image: /path/to/file.png\n…" or "video: /path/to/file.mp4".
    static func detectMedia(in s: String) -> (url: URL, kind: MediaKind)? {
        let lines = s.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let prefixes: [(String, MediaKind)] = [
                ("image: ", .image),
                ("edited: ", .image),     // could be either; we sniff extension below
                ("saved: ", .image),      // download tool output — check extension
                ("video: ", .video),
            ]
            for (prefix, defaultKind) in prefixes {
                if trimmed.hasPrefix(prefix) {
                    let path = String(trimmed.dropFirst(prefix.count))
                    guard FileManager.default.fileExists(atPath: path) else { continue }
                    let url = URL(fileURLWithPath: path)
                    let ext = url.pathExtension.lowercased()
                    let kind: MediaKind
                    switch ext {
                    case "png", "jpg", "jpeg", "webp", "gif", "tiff": kind = .image
                    case "mp4", "mov", "webm", "m4v", "avi":          kind = .video
                    default: kind = defaultKind
                    }
                    return (url, kind)
                }
            }
        }
        return nil
    }
}

// MARK: - Inline media renderer for tool results

struct InlineMediaResult: View {
    let url: URL
    let kind: MediaKind
    let resultText: String
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.codeBg)
                    .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 360)
                switch kind {
                case .image:
                    if let img = image {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 360)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                case .video:
                    AVKitInlineVideoPlayer(url: url)
                        .frame(maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.strokeStrong, lineWidth: 0.7))
            HStack(spacing: 8) {
                Image(systemName: kind == .image ? "photo" : "play.rectangle.fill")
                    .font(.caption).foregroundStyle(Theme.violet)
                Text(url.lastPathComponent).font(.caption.monospaced()).foregroundStyle(Theme.text)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: { Image(systemName: "folder").font(.caption) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.cyan)
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.writeObjects([url as NSURL])
                } label: { Image(systemName: "doc.on.doc").font(.caption) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .task {
            if kind == .image { await loadImage() }
        }
    }

    private func loadImage() async {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let img = NSImage(contentsOfFile: url.path)
                DispatchQueue.main.async {
                    self.image = img
                    cont.resume()
                }
            }
        }
    }
}

/// Lightweight AVKit player wrapper for inline use (chat messages).
struct AVKitInlineVideoPlayer: View {
    let url: URL
    @State private var player: AVPlayer?
    var body: some View {
        Group {
            if let player { VideoPlayer(player: player) }
            else { ProgressView() }
        }
        .onAppear {
            let ext = url.pathExtension.lowercased()
            if ["mp4", "mov", "m4v", "webm"].contains(ext) {
                player = AVPlayer(url: url)
            }
        }
        .onDisappear { player?.pause() }
    }
}

struct TypingCursor: View {
    @State private var on = false
    var body: some View {
        Rectangle()
            .fill(Theme.violet)
            .frame(width: 8, height: 16)
            .opacity(on ? 0.9 : 0.2)
            .padding(.leading, 2)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    on.toggle()
                }
            }
    }
}

// MARK: - Rich text block splitter

enum TextBlock {
    case text(String)
    case code(String, String?)
}

func parseRich(_ s: String) -> [TextBlock] {
    var result: [TextBlock] = []
    var buf = ""
    var lang: String? = nil
    var inCode = false
    for line in s.components(separatedBy: "\n") {
        if line.hasPrefix("```") {
            if inCode {
                result.append(.code(buf, lang))
                buf = ""; lang = nil; inCode = false
            } else {
                if !buf.isEmpty { result.append(.text(buf)); buf = "" }
                let l = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                lang = l.isEmpty ? nil : l
                inCode = true
            }
            continue
        }
        if !buf.isEmpty { buf += "\n" }
        buf += line
    }
    if !buf.isEmpty {
        if inCode { result.append(.code(buf, lang)) } else { result.append(.text(buf)) }
    }
    return result
}
