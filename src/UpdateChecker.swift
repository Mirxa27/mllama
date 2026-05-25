import Foundation
import SwiftUI

/// Polls the GitHub Releases API for a newer tag and surfaces an in-app
/// banner if found. Lightweight alternative to Sparkle: no extra signing
/// infrastructure, no separate framework. Users still download the new DMG
/// through the existing GitHub release page (one click).
///
/// Cadence:
/// - First check ~5 s after launch (so the boot path isn't blocked).
/// - Subsequent check every 24 h while the app stays open.
/// - Skips entirely when offline.
///
/// Persists "last seen" via UserDefaults so we don't badge users after they
/// dismiss a known update.
@MainActor
final class UpdateChecker: ObservableObject {

    @Published private(set) var availableUpdate: AvailableUpdate?

    struct AvailableUpdate: Equatable {
        let version: String
        let releaseURL: URL
        let downloadURL: URL?
        let releaseNotes: String
        let publishedAt: Date
    }

    private let repo = "Mirxa27/mllama"
    private let pollInterval: TimeInterval = 24 * 60 * 60
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()
    private var pollTask: Task<Void, Never>?
    private let dismissedKey = "update.lastDismissedVersion"

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            // Defer the first call so the launch path isn't blocked.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            while !Task.isCancelled {
                await self?.checkOnce()
                try? await Task.sleep(nanoseconds: UInt64(self?.pollInterval ?? 86400) * 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Mark the current available-update as dismissed so we don't keep
    /// nagging until the next version ships.
    func dismissCurrent() {
        guard let v = availableUpdate?.version else { return }
        UserDefaults.standard.set(v, forKey: dismissedKey)
        availableUpdate = nil
    }

    func checkOnce() async {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Mllama/UpdateChecker", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                Log.update.debug("Update check HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)")
                return
            }
            guard let release = try? JSONDecoder.iso8601.decode(GitHubRelease.self, from: data) else {
                return
            }
            let remote = stripPrefix(release.tag_name)
            let local = Self.bundleVersion()
            guard isNewer(remote: remote, local: local) else {
                Log.update.debug("Up to date: local=\(local, privacy: .public) remote=\(remote, privacy: .public)")
                return
            }
            // Honour previous dismissal.
            let dismissed = UserDefaults.standard.string(forKey: dismissedKey) ?? ""
            if dismissed == remote { return }

            let releaseURL = URL(string: release.html_url) ?? url
            let downloadURL = release.assets.first(where: {
                $0.name.lowercased().hasSuffix(".dmg")
            }).flatMap { URL(string: $0.browser_download_url) }

            availableUpdate = AvailableUpdate(
                version: remote,
                releaseURL: releaseURL,
                downloadURL: downloadURL,
                releaseNotes: release.body,
                publishedAt: release.published_at ?? Date()
            )
            Log.update.notice("Update available: \(remote, privacy: .public)")
        } catch {
            Log.update.debug("Update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    /// Compare semantic version strings ("3.0.2" vs "3.0.3") tolerant of
    /// optional `v` prefixes and missing components. Returns true if
    /// `remote` is strictly greater than `local`.
    func isNewer(remote: String, local: String) -> Bool {
        let r = remote.split(separator: ".").map { Int($0) ?? 0 }
        let l = local.split(separator: ".").map { Int($0) ?? 0 }
        let pad = max(r.count, l.count)
        let rp = r + Array(repeating: 0, count: pad - r.count)
        let lp = l + Array(repeating: 0, count: pad - l.count)
        for (rv, lv) in zip(rp, lp) {
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    private func stripPrefix(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    static func bundleVersion() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}

// MARK: - GitHub release model

private struct GitHubRelease: Decodable {
    let tag_name: String
    let html_url: String
    let body: String
    let published_at: Date?
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
