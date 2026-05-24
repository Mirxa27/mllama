import Foundation

// MARK: - Domain

enum ModelSource: String, CaseIterable, Codable, Hashable {
    case lmStudio = "LM Studio"
    case ollama   = "Ollama"
    case local    = "Local"
    case custom   = "Custom"

    var sfSymbol: String {
        switch self {
        case .lmStudio: "macwindow"
        case .ollama:   "shippingbox"
        case .local:    "folder"
        case .custom:   "tray"
        }
    }
}

struct DiscoveredModel: Identifiable, Hashable {
    let id: String           // stable identity = main model path
    let displayName: String
    let path: String         // absolute path to main GGUF / Ollama blob
    let mmprojPath: String?
    let sizeBytes: Int64
    let source: ModelSource
    let quantization: String?

    var isVision: Bool { mmprojPath != nil }

    var humanSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

// MARK: - Library

@MainActor
final class ModelLibrary: ObservableObject {
    @Published private(set) var models: [DiscoveredModel] = []
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var lastError: String?

    private let fm = FileManager.default

    func grouped() -> [(ModelSource, [DiscoveredModel])] {
        let byGroup = Dictionary(grouping: models, by: \.source)
        return ModelSource.allCases.compactMap { src in
            guard let items = byGroup[src], !items.isEmpty else { return nil }
            return (src, items.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending })
        }
    }

    func model(forPath path: String) -> DiscoveredModel? {
        models.first { $0.path == path }
    }

    func rescan(extraDirs: [String] = []) async {
        if isScanning { return }
        isScanning = true
        lastError = nil
        defer { isScanning = false }

        let home = NSHomeDirectory()
        let lmStudioRoots = [
            "\(home)/.lmstudio/models",
            "\(home)/.cache/lm-studio/models",
        ]
        let ollamaRoot = "\(home)/.ollama/models"
        let localRoots = [
            "\(home)/models",
            "\(home)/Documents/models",
        ] + extraDirs

        await Task.detached(priority: .userInitiated) { [weak self] in
            var found: [DiscoveredModel] = []
            let scanner = Scanner()
            for root in lmStudioRoots { found.append(contentsOf: scanner.scanGGUFTree(root: root, source: .lmStudio)) }
            found.append(contentsOf: scanner.scanOllama(root: ollamaRoot))
            for root in localRoots { found.append(contentsOf: scanner.scanGGUFTree(root: root, source: extraDirs.contains(root) ? .custom : .local)) }
            // De-duplicate by path.
            var seen = Set<String>()
            let unique = found.filter { seen.insert($0.path).inserted }
            await MainActor.run { [weak self] in
                self?.models = unique
            }
        }.value
    }
}

// MARK: - Scanner

/// Filesystem walker. Lives off the main actor; only returns plain values.
private struct Scanner {
    let fm = FileManager.default

    /// Walk a directory tree, find .gguf files, pair each non-mmproj model
    /// with a sibling mmproj-*.gguf (vision projector) when present.
    func scanGGUFTree(root: String, source: ModelSource) -> [DiscoveredModel] {
        guard fm.fileExists(atPath: root) else { return [] }
        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: root),
                                             includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        // Group .gguf files by parent directory so we can pair mmproj siblings.
        var byDir: [String: [URL]] = [:]
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "gguf" else { continue }
            byDir[url.deletingLastPathComponent().path, default: []].append(url)
        }

        var out: [DiscoveredModel] = []
        for (_, urls) in byDir {
            let mmprojURL = urls.first { isMmprojName($0.lastPathComponent) }
            for url in urls where !isMmprojName(url.lastPathComponent) {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
                let base = url.deletingPathExtension().lastPathComponent
                let model = DiscoveredModel(
                    id: url.path,
                    displayName: prettifyName(base, rootDir: root, fileURL: url),
                    path: url.path,
                    mmprojPath: mmprojURL?.path,
                    sizeBytes: size,
                    source: source,
                    quantization: extractQuant(base)
                )
                out.append(model)
            }
        }
        return out
    }

    /// Walk Ollama's manifest tree, parse JSON, resolve sha256 blobs.
    func scanOllama(root: String) -> [DiscoveredModel] {
        let manifestsRoot = "\(root)/manifests"
        let blobsRoot = "\(root)/blobs"
        guard fm.fileExists(atPath: manifestsRoot), fm.fileExists(atPath: blobsRoot) else { return [] }
        guard let enumerator = fm.enumerator(atPath: manifestsRoot) else { return [] }

        var out: [DiscoveredModel] = []
        while let rel = enumerator.nextObject() as? String {
            let full = "\(manifestsRoot)/\(rel)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
            if rel.hasSuffix(".DS_Store") { continue }
            // Manifest path looks like: <registry>/<owner>/<repo>/<tag>
            // Skip files that don't follow that depth (best-effort).
            let parts = rel.split(separator: "/").map(String.init)
            guard parts.count >= 3 else { continue }

            guard let data = fm.contents(atPath: full),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let layers = json["layers"] as? [[String: Any]] else { continue }

            var modelDigest: String?
            var projectorDigest: String?
            for layer in layers {
                let media = (layer["mediaType"] as? String ?? "").lowercased()
                let digest = layer["digest"] as? String ?? ""
                if media.contains("ollama.image.model") || media.contains("application/vnd.ollama.image.model") {
                    modelDigest = digest
                } else if media.contains("projector") {
                    projectorDigest = digest
                }
            }
            guard let mDigest = modelDigest else { continue }
            let mPath = blobsRoot + "/" + mDigest.replacingOccurrences(of: ":", with: "-")
            guard fm.fileExists(atPath: mPath) else { continue }
            let mSize = (try? fm.attributesOfItem(atPath: mPath)[.size] as? Int64) ?? 0

            let pPath: String? = projectorDigest.flatMap { d in
                let p = blobsRoot + "/" + d.replacingOccurrences(of: ":", with: "-")
                return fm.fileExists(atPath: p) ? p : nil
            }

            out.append(DiscoveredModel(
                id: mPath,
                displayName: ollamaDisplayName(rel: rel),
                path: mPath,
                mmprojPath: pPath,
                sizeBytes: mSize,
                source: .ollama,
                quantization: extractQuant(rel)
            ))
        }
        return out
    }
}

// MARK: - Helpers

private func isMmprojName(_ name: String) -> Bool {
    name.lowercased().hasPrefix("mmproj")
}

/// Pulls "Q4_K_M", "Q5_K_S", "f16", "bf16", "IQ2_XS" etc. out of a filename.
private func extractQuant(_ name: String) -> String? {
    let upper = name.uppercased()
    let patterns = [
        #"\b(IQ\d[A-Z_]*)\b"#,
        #"\b(Q\d+(?:_[KMSL0-9]+)*)\b"#,
        #"\b(F16|BF16|F32|FP16|FP32)\b"#,
    ]
    for p in patterns {
        if let r = upper.range(of: p, options: .regularExpression) {
            return String(upper[r])
        }
    }
    return nil
}

/// Make a nicer display name for a GGUF model based on path layout.
private func prettifyName(_ base: String, rootDir: String, fileURL: URL) -> String {
    // For models nested like .lmstudio/models/<Author>/<Repo>/<file>.gguf
    // prefer "<Author>/<Repo>" over the long filename.
    let parent = fileURL.deletingLastPathComponent().path
    if parent != rootDir,
       let rootURL = URL(string: "file://" + rootDir),
       let parentURL = URL(string: "file://" + parent),
       let rel = parentURL.path.removingPrefix(rootURL.path + "/")
    {
        let pretty = rel.replacingOccurrences(of: "/", with: " / ")
        return "\(pretty)\n\(base)"
    }
    return base
}

private func ollamaDisplayName(rel: String) -> String {
    // rel = "registry.ollama.ai/library/gemma4unc/latest"  -> "gemma4unc:latest"
    // rel = "hf.co/mirxa2/Foo/Q4_K_M"                       -> "mirxa2/Foo:Q4_K_M"
    let parts = rel.split(separator: "/").map(String.init)
    guard parts.count >= 2 else { return rel }
    let tag = parts.last ?? ""
    let head = parts.dropLast()
    // Strip well-known registry prefixes.
    var trimmed = Array(head)
    if let first = trimmed.first, first == "registry.ollama.ai" || first == "hf.co" {
        trimmed.removeFirst()
    }
    if trimmed.first == "library" { trimmed.removeFirst() }
    let name = trimmed.joined(separator: "/")
    return name.isEmpty ? tag : "\(name):\(tag)"
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
