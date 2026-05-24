import SwiftUI

struct ChatView: View {
    @EnvironmentObject var agent: Agent
    @EnvironmentObject var server: ServerController
    @StateObject private var recorder = VoiceRecorder.shared
    @StateObject private var tts = SpeechSynthesizer.shared
    @State private var input: String = ""

    var body: some View {
        VStack(spacing: 0) {
            transcript
            recordingRibbon
            composer
        }
        .background(Color.clear)
        .overlay(approvalSheet)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if agent.messages.isEmpty { emptyState }
                    ForEach(agent.messages) { msg in
                        MessageView(message: msg).id(msg.id)
                    }
                    if let err = agent.lastError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(Theme.coral)
                            .padding(.horizontal, Theme.Space.lg)
                            .padding(.vertical, Theme.Space.sm)
                    }
                    Color.clear.frame(height: 1).id("BOTTOM")
                }
                .padding(.vertical, Theme.Space.md)
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .onChange(of: agent.messages.count) { _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("BOTTOM", anchor: .bottom)
                }
            }
            .onChange(of: agent.messages.last?.content) { _ in
                proxy.scrollTo("BOTTOM", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.md) {
            Spacer().frame(height: 60)
            ZStack {
                Circle()
                    .fill(Theme.brandGradient)
                    .frame(width: 92, height: 92)
                    .shadow(color: Theme.violet.opacity(0.45), radius: 30)
                Image(systemName: "circle.hexagonpath.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("Mllama")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(Theme.text)
            Text(subtitleLine)
                .font(.callout)
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack(spacing: 10) {
                QuickStarter(title: "Summarize ~/Downloads", icon: "folder.fill") {
                    input = "List the files in ~/Downloads and tell me what stands out."
                }
                QuickStarter(title: "Inspect this Mac", icon: "cpu") {
                    input = "Run `uname -a` and `sw_vers` and summarize what kind of Mac this is."
                }
                QuickStarter(title: "Read me a poem", icon: "speaker.wave.2.fill") {
                    input = "Write a short, original 4-line poem about the ocean."
                }
            }
            .padding(.top, Theme.Space.sm)
            Spacer().frame(height: 60)
        }
        .frame(maxWidth: .infinity)
    }

    private var subtitleLine: String {
        switch server.status {
        case .running:  "Local · agentic · voice in / out · MCP"
        case .starting: "Loading model into memory…"
        case .stopped:  "Pick a model in the sidebar to begin."
        case .failed(let m): "Server error — \(m)"
        }
    }

    // MARK: Recording ribbon (live transcript)

    @ViewBuilder
    private var recordingRibbon: some View {
        if recorder.isRecording || recorder.isTranscribing || recorder.errorMessage != nil {
            HStack(spacing: 10) {
                if recorder.isTranscribing {
                    ProgressView().controlSize(.small)
                    Text("Transcribing with Whisper…")
                        .font(.callout)
                        .foregroundStyle(Theme.text)
                } else if recorder.isRecording {
                    PulsingDot()
                    Text(recorder.liveTranscript.isEmpty ? "Listening…" : recorder.liveTranscript)
                        .font(.callout)
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                } else if let err = recorder.errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.coral)
                    Text(err).font(.caption).foregroundStyle(Theme.coral).lineLimit(2)
                }
                Spacer()
                if recorder.isRecording || recorder.isTranscribing {
                    Button(recorder.isTranscribing ? "Transcribing…" : "Stop & Insert") {
                        Task { await consumeTranscript() }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.violet)
                    .disabled(recorder.isTranscribing)
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, 10)
            .glass(cornerRadius: 0, tint: Theme.violet.opacity(0.12), stroke: Theme.violet.opacity(0.35))
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 0) {
            ComposerBar(
                input: $input,
                isStreaming: agent.isStreaming,
                isRecording: recorder.isRecording,
                ttsSpeaking: tts.isSpeaking,
                canSend: server.status == .running && !input.trimmingCharacters(in: .whitespaces).isEmpty,
                onSend: send,
                onStop: { agent.cancel() },
                onMic: toggleMic,
                onStopSpeaking: { tts.stop() }
            )
            .padding(Theme.Space.sm)
        }
        .background(VisualEffectBackground(material: .hudWindow, blendingMode: .withinWindow))
        .overlay(Rectangle().fill(Theme.stroke).frame(height: 0.5), alignment: .top)
    }

    private func send() {
        let text = input
        input = ""
        agent.send(text)
    }

    private func toggleMic() {
        if recorder.isRecording || recorder.isTranscribing {
            Task { await consumeTranscript() }
        } else {
            tts.stop()
            Task { await recorder.start() }
        }
    }

    private func consumeTranscript() async {
        let text = await recorder.finishAndConsume()
        guard !text.isEmpty else { return }
        if !input.isEmpty && !input.hasSuffix(" ") { input += " " }
        input += text
    }

    @ViewBuilder
    private var approvalSheet: some View {
        if let p = agent.pendingApproval {
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()
                ApprovalDialog(pending: p, autoApprove: $agent.autoApproveInSession)
                    .frame(maxWidth: 560)
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Pulsing dot for recording indicator

struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Theme.coral)
            .frame(width: 10, height: 10)
            .scaleEffect(on ? 1.0 : 0.55)
            .opacity(on ? 1.0 : 0.5)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    on.toggle()
                }
            }
    }
}

struct QuickStarter: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption)
                Text(title).font(.caption)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glass(cornerRadius: 999,
                   tint: hovering ? Theme.paneHover : Theme.pane,
                   stroke: hovering ? Theme.strokeStrong : Theme.stroke)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ComposerBar: View {
    @Binding var input: String
    let isStreaming: Bool
    let isRecording: Bool
    let ttsSpeaking: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    let onMic: () -> Void
    let onStopSpeaking: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.sm) {
            ZStack(alignment: .topLeading) {
                if input.isEmpty {
                    Text("Ask Mllama anything — or press the mic and speak.")
                        .foregroundStyle(Theme.textFaint)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                }
                TextEditor(text: $input)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(minHeight: 48, maxHeight: 180)
                    .foregroundStyle(Theme.text)
                    .tint(Theme.violet)
            }
            .glass(cornerRadius: Theme.Radius.md,
                   tint: Color.white.opacity(0.06),
                   stroke: Theme.strokeStrong)

            // Microphone / TTS-stop button stack
            VStack(spacing: 8) {
                Button(action: onMic) {
                    ZStack {
                        Circle()
                            .fill(isRecording ? Theme.coral : Color.white.opacity(0.08))
                            .frame(width: 36, height: 36)
                            .overlay(Circle().stroke(isRecording ? Theme.coral.opacity(0.7) : Theme.strokeStrong, lineWidth: 0.7))
                        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .help(isRecording ? "Stop recording" : "Voice input")

                if ttsSpeaking {
                    Button(action: onStopSpeaking) {
                        ZStack {
                            Circle()
                                .fill(Theme.violet.opacity(0.25))
                                .frame(width: 28, height: 28)
                                .overlay(Circle().stroke(Theme.violet.opacity(0.5), lineWidth: 0.7))
                            Image(systemName: "speaker.slash.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.violet)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Stop speaking")
                }
            }

            if isStreaming {
                Button(action: onStop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.coral)
                }
                .buttonStyle(.plain)
                .help("Stop")
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(canSend
                                         ? AnyShapeStyle(Theme.brandGradient)
                                         : AnyShapeStyle(Theme.textFaint))
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send (⌘↩)")
            }
        }
    }
}

struct ApprovalDialog: View {
    let pending: Agent.PendingApproval
    @Binding var autoApprove: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.amber)
                VStack(alignment: .leading) {
                    Text("Approve tool call?")
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                    Text(pending.humanName).font(.caption).foregroundStyle(Theme.textMuted)
                }
                Spacer()
            }
            Text("Arguments").font(.caption2).foregroundStyle(Theme.textFaint)
            ScrollView {
                Text(prettyJSON(pending.arguments))
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 220)
            .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))

            Toggle("Auto-approve all tool calls in this conversation", isOn: $autoApprove)
                .toggleStyle(.switch)
                .font(.caption)
                .tint(Theme.violet)
                .foregroundStyle(Theme.text)

            HStack {
                Spacer()
                Button("Deny") { pending.onResolve(false) }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Approve") { pending.onResolve(true) }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.violet)
            }
        }
        .padding(Theme.Space.lg)
        .glassCard(cornerRadius: Theme.Radius.lg)
        .shadow(color: .black.opacity(0.45), radius: 30, x: 0, y: 18)
    }

    private func prettyJSON(_ s: String) -> String {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              let str = String(data: pretty, encoding: .utf8)
        else { return s }
        return str
    }
}
