import Foundation
import SwiftUI
import AppKit
import UserNotifications
import AVFoundation
import Speech
import ServiceManagement

// MARK: - Permission state

/// Every macOS-level permission Mllama touches. The PermissionManager
/// surfaces these in Settings and re-checks on app foreground.
enum AppPermission: String, CaseIterable, Identifiable {
    case notifications
    case microphone
    case speechRecognition
    case appleEvents          // Used when QuickSetup runs Terminal via osascript

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notifications:     return "Notifications"
        case .microphone:        return "Microphone"
        case .speechRecognition: return "Speech recognition"
        case .appleEvents:       return "Automation (Apple Events)"
        }
    }

    var purpose: String {
        switch self {
        case .notifications:
            return "Let Mllama notify you when long generations or downloads finish in the background."
        case .microphone:
            return "Required to dictate chat messages with the microphone button."
        case .speechRecognition:
            return "Apple Speech framework — used as a fallback when whisper-cli isn't loaded."
        case .appleEvents:
            return "Lets Mllama open Terminal automatically during Quick Setup to run `cmake`, `brew install ffmpeg`, etc."
        }
    }

    var sfSymbol: String {
        switch self {
        case .notifications:     return "bell.badge"
        case .microphone:        return "mic.fill"
        case .speechRecognition: return "text.bubble"
        case .appleEvents:       return "applescript"
        }
    }

    /// Whether granting this permission requires the user to flip a switch
    /// in System Settings rather than answer a modal prompt. macOS does NOT
    /// expose a programmatic granted/denied check for Apple Events without
    /// actually trying to send one, so we always classify it as "tap to test".
    var requiresSystemSettings: Bool {
        switch self {
        case .appleEvents: return true   // Privacy → Automation pane
        default:           return false
        }
    }
}

enum PermissionStatus: Equatable {
    case unknown              // not yet checked
    case notDetermined        // user hasn't answered the prompt yet
    case granted
    case denied
    case restricted           // parental controls etc.

    var label: String {
        switch self {
        case .unknown:        return "Checking…"
        case .notDetermined:  return "Not asked yet"
        case .granted:        return "Granted"
        case .denied:         return "Denied"
        case .restricted:     return "Restricted"
        }
    }

    var color: Color {
        switch self {
        case .granted:                    return Theme.mint
        case .denied, .restricted:        return Theme.coral
        case .notDetermined, .unknown:    return Theme.amber
        }
    }
}

// MARK: - Permission manager

@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    @Published private(set) var status: [AppPermission: PermissionStatus] = [:]

    private init() {
        for p in AppPermission.allCases { status[p] = .unknown }
        Task { await refreshAll() }
        // Re-check whenever the app becomes active — covers the case where
        // the user toggled a permission in System Settings.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
    }

    func refreshAll() async {
        await refreshNotifications()
        refresh(.microphone)
        refresh(.speechRecognition)
        // Apple Events status can't be queried without triggering a prompt,
        // so leave it at .notDetermined until the user runs Quick Setup.
        if status[.appleEvents] == .unknown {
            status[.appleEvents] = .notDetermined
        }
    }

    // MARK: Individual refresh

    /// Synchronous status refresh for permissions whose APIs return
    /// immediately (camera / mic / speech). For notifications, see
    /// `refreshNotifications()` — its API is async.
    func refresh(_ permission: AppPermission) {
        switch permission {
        case .notifications:
            Task { await self.refreshNotifications() }
        case .microphone:
            let s = AVCaptureDevice.authorizationStatus(for: .audio)
            status[.microphone] = map(s)
        case .speechRecognition:
            let s = SFSpeechRecognizer.authorizationStatus()
            status[.speechRecognition] = map(s)
        case .appleEvents:
            break  // see comment above
        }
    }

    private func refreshNotifications() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        status[.notifications] = map(settings.authorizationStatus)
    }

    // MARK: Request flow

    /// Trigger the system prompt (or, for Apple Events, attempt an event).
    /// Returns true if granted after the user response.
    @discardableResult
    func request(_ permission: AppPermission) async -> Bool {
        switch permission {
        case .notifications:
            let center = UNUserNotificationCenter.current()
            let opts: UNAuthorizationOptions = [.alert, .badge, .sound]
            do {
                let granted = try await center.requestAuthorization(options: opts)
                await refreshNotifications()
                return granted
            } catch {
                status[.notifications] = .denied
                return false
            }
        case .microphone:
            let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
            refresh(.microphone)
            return ok
        case .speechRecognition:
            let st = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
            }
            status[.speechRecognition] = map(st)
            return status[.speechRecognition] == .granted
        case .appleEvents:
            // Ask via a benign osascript — Terminal must be running for this
            // to be a real test; otherwise it just queues an authorization
            // record without prompting. We open System Settings to the
            // Automation pane instead so the user can flip the switch.
            openAutomationSettings()
            return false
        }
    }

    /// Convenience: open System Settings → Privacy → Notifications (or
    /// the equivalent pane for whichever permission needs flipping). For
    /// users who denied first time and want to re-enable.
    func openSystemSettings(for p: AppPermission) {
        let urlString: String
        switch p {
        case .notifications:
            urlString = "x-apple.systempreferences:com.apple.preference.notifications"
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .speechRecognition:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case .appleEvents:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Status mapping

    private func map(_ s: UNAuthorizationStatus) -> PermissionStatus {
        switch s {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied:        return .denied
        case .notDetermined: return .notDetermined
        @unknown default:    return .unknown
        }
    }
    private func map(_ s: AVAuthorizationStatus) -> PermissionStatus {
        switch s {
        case .authorized:    return .granted
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined: return .notDetermined
        @unknown default:    return .unknown
        }
    }
    private func map(_ s: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch s {
        case .authorized:    return .granted
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined: return .notDetermined
        @unknown default:    return .unknown
        }
    }
}

// MARK: - User notifications

/// Thin wrapper around `UNUserNotificationCenter` that fires a notification
/// for long-running operations. No-ops gracefully if the user hasn't granted
/// notification permission yet — the work itself isn't gated on this.
enum NotificationKind: String {
    case imageReady    = "image_ready"
    case videoReady    = "video_ready"
    case downloadDone  = "download_done"
    case serverDied    = "server_died"
}

enum NotificationCenterBridge {
    /// Fire a user notification. Reads `NSApp.isActive` + authorization on
    /// the main actor (short hop), then jumps to a detached task for the
    /// UNNotificationAttachment file I/O so the main thread is never
    /// blocked staging the thumbnail into the sandbox container.
    @MainActor
    static func post(kind: NotificationKind,
                     title: String,
                     body: String,
                     filePath: String? = nil) {
        // Decisions that need the main actor: app-active check.
        let isActive = NSApp.isActive
        Task.detached(priority: .utility) {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }
            if isActive { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let filePath {
                // UNNotificationAttachment's init copies the source file into
                // a sandboxed container synchronously. We're off the main
                // actor here so blocking on disk is fine.
                do {
                    let att = try UNNotificationAttachment(
                        identifier: UUID().uuidString,
                        url: URL(fileURLWithPath: filePath),
                        options: nil
                    )
                    content.attachments = [att]
                } catch {
                    // Don't fail the whole notification just because the
                    // thumbnail couldn't be staged. Log so it's debuggable.
                    Log.app.error("Notification attachment failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            let req = UNNotificationRequest(
                identifier: kind.rawValue + "-" + UUID().uuidString,
                content: content,
                trigger: nil
            )
            do {
                try await center.add(req)
            } catch {
                Log.app.error("Notification.add failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Dock badge

/// Live count of background operations the user might care about.
/// `NSApp.dockTile.badgeLabel` is set to the total when > 0, cleared
/// otherwise. SwiftUI just calls into this from `ImageGenerator`,
/// `VideoGenerator`, and `HFDownloadManager`.
@MainActor
final class DockBadge: ObservableObject {
    static let shared = DockBadge()
    private init() {}

    @Published private(set) var imageJobsActive: Int = 0
    @Published private(set) var videoJobsActive: Int = 0
    @Published private(set) var downloadsActive: Int = 0

    private var total: Int { imageJobsActive + videoJobsActive + downloadsActive }

    func setImage(_ n: Int) { imageJobsActive = n; refresh() }
    func setVideo(_ n: Int) { videoJobsActive = n; refresh() }
    func setDownloads(_ n: Int) { downloadsActive = n; refresh() }

    private func refresh() {
        let tile = NSApp.dockTile
        tile.badgeLabel = total > 0 ? "\(total)" : nil
        tile.display()
    }
}

// MARK: - Launch at login

/// Typed outcome of toggling Open-at-Login. Lets the UI distinguish
/// "user needs to grant permission" from "platform unsupported" from
/// "system refused the registration for some other reason."
enum LoginItemResult {
    case ok
    case unsupported              // macOS < 13
    case needsApproval            // SMAppService returned .requiresApproval
    case failed(String)           // any thrown SMAppServiceError
}

/// Wrap `SMAppService.mainApp` so the UI can flip it on/off without leaking
/// platform-version checks across views. macOS 13+ only.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// Toggle Open-at-Login. Returns a typed result so the UI can show a
    /// meaningful error (or the "approve in System Settings" hint) instead
    /// of silently springing the switch back.
    static func setEnabled(_ enabled: Bool) -> LoginItemResult {
        guard #available(macOS 13.0, *) else { return .unsupported }
        let svc = SMAppService.mainApp
        do {
            if enabled { try svc.register() }
            else       { try svc.unregister() }
            // After register(), status may flip to .requiresApproval until the
            // user OKs it in System Settings → General → Login Items.
            if svc.status == .requiresApproval { return .needsApproval }
            return .ok
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// True if macOS hasn't yet recorded a definitive enabled/disabled
    /// status. Useful for showing "needs approval" hints.
    static var needsApproval: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .requiresApproval
    }
}

// MARK: - URL scheme handler

/// Wire `mllama://` deep links to in-app destinations. The actual scheme
/// registration lives in Info.plist (`CFBundleURLTypes`); this is the
/// runtime side that decodes the URL and forwards to WorkspaceState.
@MainActor
enum URLSchemeRouter {

    /// Route a `mllama://...` URL. Recognised shapes:
    ///
    ///   mllama://chat                      — open chat workspace
    ///   mllama://image                     — open image studio
    ///   mllama://video                     — open video studio
    ///   mllama://models                    — open model browser
    ///   mllama://gallery                   — open gallery
    ///   mllama://generate/image?prompt=…   — open image studio prefilled
    ///   mllama://generate/video?prompt=…   — open video studio prefilled
    ///   mllama://pick?kind=llm|image|video — open the model picker
    static func handle(_ url: URL,
                       workspace: WorkspaceState,
                       pickerState: ModelPickerState) {
        guard url.scheme?.lowercased() == "mllama" else { return }
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()

        switch host {
        case "chat":    workspace.go(.chat)
        case "image":   workspace.go(.imageStudio)
        case "video":   workspace.go(.videoStudio)
        case "models":  workspace.go(.models)
        case "gallery": workspace.go(.gallery)
        case "pick":
            let kind: RecommendKind? = {
                guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let raw = comps.queryItems?.first(where: { $0.name == "kind" })?.value
                else { return nil }
                return RecommendKind(rawValue: raw.lowercased())
            }()
            pickerState.open(initialKind: kind)
        case "generate":
            // /image or /video plus ?prompt=
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let prompt = comps?.queryItems?.first(where: { $0.name == "prompt" })?.value ?? ""
            if path.hasSuffix("/image") {
                workspace.go(.imageStudio)
                if !prompt.isEmpty {
                    NotificationCenter.default.post(
                        name: .insertPromptIntoImageStudio,
                        object: nil,
                        userInfo: ["prompt": prompt]
                    )
                }
            } else if path.hasSuffix("/video") {
                workspace.go(.videoStudio)
                if !prompt.isEmpty {
                    NotificationCenter.default.post(
                        name: .insertPromptIntoVideoStudio,
                        object: nil,
                        userInfo: ["prompt": prompt]
                    )
                }
            }
        default:
            break
        }
    }
}
