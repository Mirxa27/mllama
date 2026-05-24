import Foundation
import SwiftUI

// MARK: - Domain

enum PromptKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case image, video, chat
    var id: String { rawValue }
    var label: String {
        switch self {
        case .image: return "Image"
        case .video: return "Video"
        case .chat:  return "Chat"
        }
    }
    var sfSymbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .chat:  return "text.bubble"
        }
    }
}

struct SavedPrompt: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var prompt: String
    var negativePrompt: String = ""
    var kind: PromptKind
    var tags: [String] = []
    var favorite: Bool = false
    var createdAt: Date = .init()
    var usedCount: Int = 0
    var lastUsedAt: Date? = nil

    var displayTitle: String { title.isEmpty ? String(prompt.prefix(40)) : title }
}

// MARK: - Library

/// Persists user-saved prompts plus a rolling history of recently-used prompts.
/// Stored at ~/.mllama/prompts.json. History self-trims to 200 entries.
@MainActor
final class PromptLibrary: ObservableObject {
    static let shared = PromptLibrary()

    @Published private(set) var saved: [SavedPrompt] = []
    @Published private(set) var history: [SavedPrompt] = []
    @Published var searchQuery: String = ""
    @Published var kindFilter: PromptKind? = nil

    private let url: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".mllama/prompts.json")
    }()

    init() {
        load()
        seedStartersIfEmpty()
    }

    // MARK: Filtering

    var filteredSaved: [SavedPrompt] {
        applyFilter(saved)
    }
    var filteredHistory: [SavedPrompt] {
        applyFilter(history).prefix(50).map { $0 }
    }

    private func applyFilter(_ items: [SavedPrompt]) -> [SavedPrompt] {
        var out = items
        if let k = kindFilter { out = out.filter { $0.kind == k } }
        let q = searchQuery.lowercased()
        if !q.isEmpty {
            out = out.filter {
                $0.title.lowercased().contains(q)
                || $0.prompt.lowercased().contains(q)
                || $0.tags.contains(where: { $0.lowercased().contains(q) })
            }
        }
        return out.sorted {
            if $0.favorite != $1.favorite { return $0.favorite && !$1.favorite }
            return ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt)
        }
    }

    // MARK: Mutations

    @discardableResult
    func save(_ prompt: String,
              negative: String = "",
              kind: PromptKind,
              title: String = "",
              tags: [String] = []) -> SavedPrompt {
        let entry = SavedPrompt(
            title: title,
            prompt: prompt, negativePrompt: negative,
            kind: kind, tags: tags
        )
        saved.append(entry)
        persist()
        return entry
    }

    func toggleFavorite(_ id: UUID) {
        if let idx = saved.firstIndex(where: { $0.id == id }) {
            saved[idx].favorite.toggle()
            persist()
        }
    }

    func remove(_ id: UUID) {
        saved.removeAll { $0.id == id }
        persist()
    }

    func update(_ id: UUID, _ mutate: (inout SavedPrompt) -> Void) {
        if let idx = saved.firstIndex(where: { $0.id == id }) {
            mutate(&saved[idx])
            persist()
        }
    }

    /// Record a prompt as used. Bumps history.
    func use(_ prompt: String, negative: String = "", kind: PromptKind) {
        // Bump saved entry usage count if this is a saved prompt
        if let idx = saved.firstIndex(where: { $0.prompt == prompt && $0.kind == kind }) {
            saved[idx].usedCount += 1
            saved[idx].lastUsedAt = Date()
        }
        // Add to history (dedupe by prompt text)
        history.removeAll { $0.prompt == prompt && $0.kind == kind }
        history.insert(SavedPrompt(
            title: "", prompt: prompt, negativePrompt: negative,
            kind: kind, createdAt: Date(), usedCount: 1, lastUsedAt: Date()
        ), at: 0)
        if history.count > 200 { history = Array(history.prefix(200)) }
        persist()
    }

    // MARK: Persistence

    private struct DiskShape: Codable {
        var saved: [SavedPrompt]
        var history: [SavedPrompt]
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let s = try? dec.decode(DiskShape.self, from: data) {
            self.saved = s.saved
            self.history = s.history
        }
    }

    private func persist() {
        let shape = DiskShape(saved: saved, history: history)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? enc.encode(shape) {
            try? data.write(to: url)
        }
    }

    // MARK: Seed starters

    private func seedStartersIfEmpty() {
        guard saved.isEmpty else { return }
        let starters: [SavedPrompt] = [
            .init(title: "Cinematic portrait", prompt: "cinematic portrait of a lone traveler in a misty forest, volumetric god rays, 35mm film grain, anamorphic lens, soft rim light", kind: .image, tags: ["cinematic", "portrait"], favorite: true),
            .init(title: "Cyberpunk alley", prompt: "neon-lit cyberpunk alley after rain, reflective puddles, holographic billboards, dense smog, octane render, ultra-detailed", kind: .image, tags: ["cyberpunk"], favorite: true),
            .init(title: "Watercolor landscape", prompt: "loose watercolor painting of rolling hills at dawn, soft pastel colors, paper texture visible, traditional media", kind: .image, tags: ["watercolor"]),
            .init(title: "Studio product shot", prompt: "minimalist studio product photography, soft seamless white background, dramatic top lighting, hyper-detailed", kind: .image, tags: ["product"]),
            .init(title: "Ocean drone shot", prompt: "aerial drone shot flying low over crystal turquoise ocean waves, sunset golden hour, cinematic 4k", kind: .video, tags: ["aerial", "nature"], favorite: true),
            .init(title: "Time-lapse city", prompt: "time-lapse of a busy intersection at night, light trails, blooming neon, slow camera push-in", kind: .video, tags: ["timelapse"]),
            .init(title: "Liquid metal", prompt: "macro shot of iridescent liquid mercury flowing in slow motion, dark background, holographic surface reflections", kind: .video, tags: ["abstract"]),
        ]
        // Defer negative prompt defaults to studio defaults; keep clean
        self.saved = starters
        persist()
    }
}

// MARK: - Onboarding state

@MainActor
final class OnboardingState: ObservableObject {
    static let shared = OnboardingState()

    @AppStorage("onboarding.completed") var hasCompleted: Bool = false
    @AppStorage("onboarding.skipped") var hasSkipped: Bool = false
    @Published var visible: Bool = false

    init() {
        // Show on first launch
        if !hasCompleted && !hasSkipped { visible = true }
    }

    func show() { visible = true }
    func skip() { hasSkipped = true; visible = false }
    func complete() { hasCompleted = true; visible = false }

    // MARK: Capability detection

    struct Capabilities {
        var hasSDServer: Bool
        var hasSDCli: Bool
        var hasFFmpeg: Bool
        var hasImageModel: Bool
        var hasVideoModel: Bool
        var hasLLM: Bool
        var hasHFToken: Bool

        var readyForChat: Bool { hasLLM }
        var readyForImage: Bool { hasSDServer && hasImageModel }
        var readyForVideo: Bool { hasSDCli && hasVideoModel && hasFFmpeg }
    }

    func detectCapabilities() -> Capabilities {
        // Reuse the centralized binary search so detection matches actual
        // runtime discovery (~/.mllama/bin, bundle, Homebrew).
        let sdServer = InstallPaths.locate("sd-server", userOverrideKey: SDKeys.binaryOverride) != nil
        let sdCli    = InstallPaths.locate("sd-cli",    userOverrideKey: SDKeys.cliOverride)    != nil
        let ffmpeg   = InstallPaths.locate("ffmpeg") != nil

        let imgModel = (UserDefaults.standard.string(forKey: SDKeys.imageModelPath) ?? "").isEmpty == false
        let vidModel = (UserDefaults.standard.string(forKey: SDKeys.videoModelPath) ?? "").isEmpty == false
        let llm = (UserDefaults.standard.string(forKey: Keys.modelPath) ?? "").isEmpty == false
        let token = (UserDefaults.standard.string(forKey: HFKeys.token) ?? "").isEmpty == false

        return Capabilities(
            hasSDServer: sdServer,
            hasSDCli: sdCli,
            hasFFmpeg: ffmpeg,
            hasImageModel: imgModel,
            hasVideoModel: vidModel,
            hasLLM: llm,
            hasHFToken: token
        )
    }
}
