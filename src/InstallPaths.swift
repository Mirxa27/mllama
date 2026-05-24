import Foundation

/// Centralized lookup for external binaries (sd-server, sd-cli, ffmpeg).
///
/// The macOS app bundle is read-only at runtime, so we can't drop user-built
/// binaries inside `Mllama.app/Contents/Resources/bin/`. Instead, the Quick
/// Setup flow installs them to `~/.mllama/bin/`. All discovery looks in three
/// places in this order:
///   1. user override path stored in UserDefaults
///   2. ~/.mllama/bin/<name>            (where Quick Setup installs)
///   3. Bundle.main Resources/bin/<name> (where the build script can pre-bundle)
///   4. /opt/homebrew/bin, /usr/local/bin, /usr/bin
enum InstallPaths {

    /// User-writable bin directory. Created on demand.
    static var binRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".mllama/bin")
    }

    /// Build / source directory for stable-diffusion.cpp checkout.
    static var buildRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".mllama/build")
    }

    static func ensureBinRoot() {
        try? FileManager.default.createDirectory(at: binRoot,
                                                 withIntermediateDirectories: true)
    }

    /// Find a binary by name. Returns nil if not found.
    ///
    /// `userOverrideKey` is an optional UserDefaults key; if set and the value
    /// is a path to an existing file, that wins.
    static func locate(_ name: String,
                       userOverrideKey: String? = nil,
                       homebrew: [String] = []) -> URL? {
        let fm = FileManager.default

        // 1. User-set override (Settings → … → binary path)
        if let key = userOverrideKey,
           let path = UserDefaults.standard.string(forKey: key),
           !path.isEmpty, fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        // 2. ~/.mllama/bin/<name>
        let userInstall = binRoot.appendingPathComponent(name)
        if fm.fileExists(atPath: userInstall.path) {
            return userInstall
        }

        // 3. Bundle Resources/bin/<name>
        if let b = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "bin"),
           fm.fileExists(atPath: b.path) {
            return b
        }

        // 4. Common Homebrew / system paths
        let candidates: [String] = homebrew.isEmpty
            ? ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
            : homebrew
        for p in candidates {
            if fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }
}
