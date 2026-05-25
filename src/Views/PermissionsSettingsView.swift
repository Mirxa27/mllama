import SwiftUI

/// Settings tab showing every macOS permission Mllama touches plus the
/// Launch-at-Login toggle. Users can re-prompt or deep-link to the right
/// System Settings pane from here without having to know which Privacy
/// sub-pane to find.
struct PermissionsSettingsView: View {
    // ObservedObject (not StateObject) because PermissionManager.shared is a
    // singleton — its lifetime is the process, not this view. StateObject
    // would have SwiftUI take ownership and create a second strong reference.
    @ObservedObject private var perm = PermissionManager.shared
    @State private var loginAtStart: Bool = LoginItem.isEnabled
    @State private var loginNeedsApproval: Bool = LoginItem.needsApproval
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("System permissions") {
                ForEach(AppPermission.allCases) { p in
                    permissionRow(p)
                }
                Text("Mllama runs entirely on this Mac — these permissions only unlock optional features (voice input, automatic setup, completion notifications).")
                    .font(.caption2).foregroundStyle(Theme.textFaint)
            }
            Section("Launch") {
                Toggle("Open Mllama at login", isOn: loginBinding)
                    .tint(Theme.violet)
                if loginNeedsApproval {
                    Label("macOS needs you to approve this in System Settings → General → Login Items.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.amber)
                }
                if let err = loginError {
                    Label(err, systemImage: "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.coral)
                        .textSelection(.enabled)
                }
            }
            Section("Deep linking") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mllama responds to `mllama://` URLs. Try these in Terminal:")
                        .font(.caption).foregroundStyle(Theme.textMuted)
                    deepLinkRow("mllama://chat",   "Open chat")
                    deepLinkRow("mllama://image",  "Open Image Studio")
                    deepLinkRow("mllama://video",  "Open Video Studio")
                    deepLinkRow("mllama://generate/image?prompt=a%20red%20apple",
                                "Open Image Studio prefilled")
                    deepLinkRow("mllama://pick?kind=llm",
                                "Open the model picker filtered to LLMs")
                }
            }
        }
        .formStyle(.grouped)
        .task { await perm.refreshAll() }
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { loginAtStart },
            set: { new in
                let result = LoginItem.setEnabled(new)
                switch result {
                case .ok:
                    loginAtStart = new
                    loginError = nil
                case .needsApproval:
                    loginAtStart = new
                    loginError = nil
                case .unsupported:
                    loginAtStart = false
                    loginError = "Requires macOS 13 or newer."
                case .failed(let msg):
                    loginAtStart = LoginItem.isEnabled
                    loginError = msg
                }
                loginNeedsApproval = LoginItem.needsApproval
            }
        )
    }

    // MARK: Rows

    @ViewBuilder
    private func permissionRow(_ p: AppPermission) -> some View {
        let s = perm.status[p] ?? .unknown
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: p.sfSymbol)
                .foregroundStyle(s.color)
                .font(.title3)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.label).font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                    statusPill(s)
                }
                Text(p.purpose)
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            actionButton(for: p, status: s)
        }
        .padding(.vertical, 4)
    }

    private func statusPill(_ s: PermissionStatus) -> some View {
        Text(s.label)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(s.color.opacity(0.18), in: Capsule())
            .foregroundStyle(s.color)
    }

    @ViewBuilder
    private func actionButton(for p: AppPermission, status: PermissionStatus) -> some View {
        switch status {
        case .granted:
            Button("Open Settings") { perm.openSystemSettings(for: p) }
                .controlSize(.small)
                .help("Manage in System Settings.")
        case .denied, .restricted:
            Button("Open Settings") { perm.openSystemSettings(for: p) }
                .controlSize(.small)
                .help("macOS denied this earlier. Flip the switch in System Settings to re-enable.")
        case .notDetermined, .unknown:
            Button("Grant") { Task { _ = await perm.request(p) } }
                .controlSize(.small)
                .help(p.requiresSystemSettings
                      ? "Opens System Settings → Privacy → Automation."
                      : "Triggers the macOS permission prompt.")
        }
    }

    private func deepLinkRow(_ url: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "link").foregroundStyle(Theme.violet).font(.caption)
                .accessibilityHidden(true)
            Text(url).font(Theme.monoSmall).foregroundStyle(Theme.text)
                .textSelection(.enabled)
            Spacer()
            Text(label).font(.caption2).foregroundStyle(Theme.textMuted)
            Button {
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            } label: {
                Image(systemName: "play.fill").font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("Open this URL")
            .accessibilityLabel("Open \(url)")
        }
        .padding(.vertical, 2)
    }
}
