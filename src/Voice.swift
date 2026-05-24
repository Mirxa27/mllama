import Foundation
import AVFoundation
import Speech
import SwiftUI

// MARK: - Defaults keys (voice)

enum VoiceKeys {
    static let autoSpeak        = "voice.autoSpeak"
    static let voiceIdentifier  = "voice.voiceIdentifier"
    static let voiceRate        = "voice.voiceRate"
    static let preferOnDevice   = "voice.preferOnDevice"
    static let recognizerLocale = "voice.recognizerLocale"
    static let sttEngine        = "voice.sttEngine"   // "whisper" | "apple"
    static let whisperLanguage  = "voice.whisperLanguage" // "auto" | "en" | "es" | …
}

enum STTEngine: String, CaseIterable, Identifiable {
    case whisper = "whisper"
    case apple   = "apple"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .whisper: "Whisper (bundled, 99 languages, on-device)"
        case .apple:   "Apple Speech (built-in, on-device)"
        }
    }
}

// MARK: - Text-to-Speech

@MainActor
final class SpeechSynthesizer: NSObject, ObservableObject {
    static let shared = SpeechSynthesizer()

    @Published private(set) var isSpeaking: Bool = false
    @Published private(set) var spokenText: String = ""

    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: VoiceKeys.autoSpeak) }
        set { UserDefaults.standard.set(newValue, forKey: VoiceKeys.autoSpeak) }
    }

    var rate: Float {
        let v = UserDefaults.standard.float(forKey: VoiceKeys.voiceRate)
        return v == 0 ? AVSpeechUtteranceDefaultSpeechRate : v
    }

    var voice: AVSpeechSynthesisVoice {
        if let id = UserDefaults.standard.string(forKey: VoiceKeys.voiceIdentifier),
           let v = AVSpeechSynthesisVoice(identifier: id) {
            return v
        }
        // Sensible default: highest-quality system voice for current locale.
        let localeId = AVSpeechSynthesisVoice.currentLanguageCode()
        return Self.preferredVoice(for: localeId)
    }

    /// Voices ranked by quality (premium > enhanced > default) for picker UI.
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        let all = AVSpeechSynthesisVoice.speechVoices()
        return all.sorted { a, b in
            if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
            if a.language != b.language { return a.language < b.language }
            return a.name < b.name
        }
    }

    static func preferredVoice(for localeId: String) -> AVSpeechSynthesisVoice {
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(localeId.prefix(2)) }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
        return candidates.first
            ?? AVSpeechSynthesisVoice(language: localeId)
            ?? AVSpeechSynthesisVoice(language: "en-US")!
    }

    /// Speak text. Strips markdown / code blocks / urls so we don't read junk aloud.
    func speak(_ text: String) {
        let clean = Self.stripForSpeech(text)
        guard !clean.isEmpty else { return }
        stop()
        let utt = AVSpeechUtterance(string: clean)
        utt.voice = voice
        utt.rate = rate
        utt.preUtteranceDelay = 0.05
        spokenText = clean
        synth.speak(utt)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    func toggleSpeak(_ text: String) {
        if synth.isSpeaking { stop() } else { speak(text) }
    }

    /// Convert markdown/code-fenced text into something pleasant to listen to.
    static func stripForSpeech(_ raw: String) -> String {
        var out = ""
        var inCode = false
        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if inCode { continue }
            var l = line
            // Strip simple markdown markers — leave the readable text intact.
            for token in ["**", "__", "`", "~~"] {
                l = l.replacingOccurrences(of: token, with: "")
            }
            // Strip list bullets at line start.
            if let r = l.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
                l.removeSubrange(r)
            }
            // Strip heading hashes.
            if let r = l.range(of: #"^\s*#{1,6}\s+"#, options: .regularExpression) {
                l.removeSubrange(r)
            }
            if !l.trimmingCharacters(in: .whitespaces).isEmpty {
                out += l + "\n"
            }
        }
        // Trim runaway length so we don't speak novel-sized outputs.
        if out.count > 4000 { out = String(out.prefix(4000)) + "… (truncated)" }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension SpeechSynthesizer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false; self.spokenText = "" }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false; self.spokenText = "" }
    }
}

// MARK: - Speech-to-Text

@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    static let shared = VoiceRecorder()

    enum PermissionState { case unknown, granted, denied }

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var isTranscribing: Bool = false
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var permission: PermissionState = .unknown

    // Apple Speech path
    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    // Whisper path
    private var audioRecorder: AVAudioRecorder?
    private var tempWavURL: URL?

    var engine: STTEngine {
        let raw = UserDefaults.standard.string(forKey: VoiceKeys.sttEngine) ?? STTEngine.whisper.rawValue
        return STTEngine(rawValue: raw) ?? .whisper
    }

    var preferOnDevice: Bool {
        UserDefaults.standard.object(forKey: VoiceKeys.preferOnDevice) as? Bool ?? true
    }

    var locale: Locale {
        if let id = UserDefaults.standard.string(forKey: VoiceKeys.recognizerLocale), !id.isEmpty {
            return Locale(identifier: id)
        }
        return .current
    }

    var whisperLanguageCode: String {
        UserDefaults.standard.string(forKey: VoiceKeys.whisperLanguage) ?? "auto"
    }

    /// Request mic + speech permissions; returns true if both granted.
    func ensurePermissions() async -> Bool {
        let speech = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        let ok = (speech == .authorized) && mic
        self.permission = ok ? .granted : .denied
        if !ok {
            errorMessage = (speech != .authorized)
                ? "Speech recognition permission denied. Grant access in System Settings → Privacy & Security → Speech Recognition."
                : "Microphone access denied. Grant access in System Settings → Privacy & Security → Microphone."
        }
        return ok
    }

    /// Start recording. Behavior depends on the selected engine.
    /// - Whisper: capture audio to a temp WAV; transcribe after stop.
    /// - Apple: stream audio buffers into SFSpeechRecognizer for live results.
    func start() async {
        errorMessage = nil
        guard !isRecording else { return }
        guard await ensurePermissions() else { return }

        switch engine {
        case .whisper: await startWhisper()
        case .apple:   await startApple()
        }
    }

    /// Stop recording. Whisper engine transcribes after stop; Apple emits final result via callback.
    func stop() {
        switch engine {
        case .whisper:
            if let r = audioRecorder, r.isRecording { r.stop() }
            audioRecorder = nil
            // isRecording stays true while transcription runs; flipped in finishAndConsume.
            isRecording = false
        case .apple:
            if audioEngine.isRunning {
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
            }
            request?.endAudio()
            task?.cancel()
            request = nil
            task = nil
            isRecording = false
        }
    }

    /// Stop, run transcription (if Whisper), and return final transcript.
    func finishAndConsume() async -> String {
        switch engine {
        case .apple:
            stop()
            let text = liveTranscript
            liveTranscript = ""
            return text
        case .whisper:
            // Stop recorder; transcribe the captured wav with whisper-cli.
            if let r = audioRecorder, r.isRecording { r.stop() }
            audioRecorder = nil
            isRecording = false
            guard let wav = tempWavURL, FileManager.default.fileExists(atPath: wav.path) else {
                return ""
            }
            isTranscribing = true
            defer {
                isTranscribing = false
                try? FileManager.default.removeItem(at: wav)
                tempWavURL = nil
                liveTranscript = ""
            }
            let transcript = await WhisperEngine.shared.transcribe(wavPath: wav.path,
                                                                   language: whisperLanguageCode)
            return transcript
        }
    }

    // MARK: Apple Speech path

    private func startApple() async {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognizer not available for \(locale.identifier)."
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if preferOnDevice, recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        request = req

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        audioEngine.prepare()
        do { try audioEngine.start() }
        catch {
            errorMessage = "Audio engine failed: \(error.localizedDescription)"
            stop()
            return
        }
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.liveTranscript = result.bestTranscription.formattedString
                    if result.isFinal { self.stop() }
                }
                if let error {
                    let ns = error as NSError
                    if !(ns.domain == "kAFAssistantErrorDomain" && [216, 203, 1110].contains(ns.code)) {
                        self.errorMessage = error.localizedDescription
                    }
                    self.stop()
                }
            }
        }
        isRecording = true
    }

    // MARK: Whisper path (record-then-transcribe)

    private func startWhisper() async {
        // Record 16-bit PCM at 16 kHz, mono — exactly what whisper expects.
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("mllama-rec-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.prepareToRecord()
            if !r.record() {
                errorMessage = "Could not start audio recorder."
                return
            }
            audioRecorder = r
            tempWavURL = url
            liveTranscript = "Recording… release the mic to transcribe."
            isRecording = true
        } catch {
            errorMessage = "Recorder error: \(error.localizedDescription)"
        }
    }

    static func availableLocales() -> [Locale] {
        Array(SFSpeechRecognizer.supportedLocales())
            .sorted { ($0.identifier) < ($1.identifier) }
    }
}

// MARK: - Whisper subprocess wrapper

@MainActor
final class WhisperEngine {
    static let shared = WhisperEngine()

    var binaryURL: URL? {
        Bundle.main.url(forResource: "whisper-cli", withExtension: nil, subdirectory: "whisper")
    }

    var modelURL: URL? {
        Bundle.main.url(forResource: "ggml-tiny-q5_1", withExtension: "bin", subdirectory: "whisper/models")
    }

    var isAvailable: Bool {
        guard let bin = binaryURL, let model = modelURL else { return false }
        return FileManager.default.fileExists(atPath: bin.path)
            && FileManager.default.fileExists(atPath: model.path)
    }

    /// Run whisper-cli on a WAV file. Pure stdout transcript, no timestamps.
    func transcribe(wavPath: String, language: String) async -> String {
        guard let bin = binaryURL, let model = modelURL else { return "" }
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let p = Process()
            p.executableURL = bin
            var args = [
                "-m", model.path,
                "-f", wavPath,
                "-nt",       // no timestamps
                "-np",       // no progress prints
                "-t", "6",
            ]
            // "auto" lets whisper detect language; otherwise force it.
            if language != "auto" && !language.isEmpty {
                args.append(contentsOf: ["-l", language])
            }
            p.arguments = args
            let out = Pipe(); let err = Pipe()
            p.standardOutput = out
            p.standardError = err

            DispatchQueue.global(qos: .userInitiated).async {
                do { try p.run() } catch {
                    cont.resume(returning: ""); return
                }
                p.waitUntilExit()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let text = (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: text)
            }
        }
    }
}
