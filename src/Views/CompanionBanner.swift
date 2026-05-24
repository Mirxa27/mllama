import SwiftUI

/// Async-cached companion status strip used by both ImageStudio and
/// VideoStudio. Replaces synchronous `catalog.companionStatus(for:)` calls
/// from inside view body — those were re-running the HF cache filesystem
/// walk on the main actor every time a `@Published` ticked (e.g., download
/// progress, ~0.5 s cadence). This view holds its own `@State` and only
/// re-resolves when the diffusion path or download-completion count
/// actually changes.
struct CompanionBanner: View {
    /// Path to the active diffusion model (`""` when nothing is set).
    let diffusionPath: String
    /// Whether this is a video model (governs which UserDefaults keys the
    /// resolver writes; also enables a different empty-state message).
    let isVideo: Bool
    let downloadsRoot: URL
    let catalog: UnifiedModelCatalog
    /// Live job array — drives "downloading…" rows.
    let jobs: [HFDownloadJob]
    /// Optional "pick model" handler — when set the empty-state banner
    /// renders a button that opens the picker.
    let onPickModel: (() -> Void)?

    @State private var statuses: [CompanionStatus] = []

    private var family: DiffusionFamily {
        diffusionPath.isEmpty ? .unknown : DiffusionFamily.detect(path: diffusionPath)
    }

    private var activeJobs: [HFDownloadJob] {
        jobs.filter { job in
            guard !job.state.isTerminal else { return false }
            return ModelRecommender.catalog.contains { rec in
                guard rec.tags.contains("companion") else { return false }
                if isVideo && rec.kind != .video { return false }
                if !isVideo && rec.kind != .image { return false }
                return rec.repoId == job.repoId && rec.filename == job.file
            }
        }
    }

    var body: some View {
        // Wrap the whole body in a Group so the `.task(id:)` is guaranteed
        // to mount regardless of which branch renders. Animations on the
        // outer transition give the strip a Pro Max feel — instant pops
        // would feel jarring against the otherwise restrained UI.
        Group {
            if diffusionPath.isEmpty, let onPick = onPickModel, isVideo {
                pickModelStrip(action: onPick)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if !activeJobs.isEmpty {
                downloadingStrip(jobs: activeJobs)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if statuses.isEmpty && !diffusionPath.isEmpty &&
                        !ModelBundle.requiredCompanions(for: family).isEmpty {
                // Resolution in flight — show a 1-line skeleton so users
                // don't see an unannounced banner pop in seconds later.
                resolvingStrip
                    .transition(.opacity)
            } else if !statuses.filter({ $0.isMissing }).isEmpty {
                missingStrip(missing: statuses.filter { $0.isMissing })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: bannerState)
        .task(id: resolveKey) { await resolve() }
    }

    // MARK: Banner content

    @ViewBuilder
    private func pickModelStrip(action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "film")
                .foregroundStyle(Theme.cyan)
                .accessibilityHidden(true)
            Text("No video model selected.")
                .font(.caption).foregroundStyle(Theme.text)
            Spacer()
            Button("Pick model", action: action).controlSize(.small)
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, 8)
        .background(Theme.cyan.opacity(0.10))
        .overlay(Rectangle().fill(Theme.cyan.opacity(0.4)).frame(height: 0.5), alignment: .bottom)
    }

    @ViewBuilder
    private func downloadingStrip(jobs: [HFDownloadJob]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(jobs) { job in
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Theme.cyan).font(.caption)
                        .accessibilityHidden(true)
                    Text("Downloading \(job.displayName)")
                        .font(.caption).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                    Text("\(Int(job.progress.fraction * 100))% · \(job.progress.humanETA)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                        .accessibilityLabel(
                            "\(Int(job.progress.fraction * 100)) percent, ETA \(job.progress.humanETA)")
                }
                ProgressView(value: job.progress.fraction).tint(Theme.cyan)
            }
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
        .background(Theme.cyan.opacity(0.10))
        .overlay(Rectangle().fill(Theme.cyan.opacity(0.4)).frame(height: 0.5), alignment: .bottom)
    }

    @ViewBuilder
    private var resolvingStrip: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Checking companion files…")
                .font(.caption).foregroundStyle(Theme.textMuted)
            Spacer()
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, 8)
        .background(Theme.pane)
        .overlay(Rectangle().fill(Theme.stroke).frame(height: 0.5), alignment: .bottom)
    }

    @ViewBuilder
    private func missingStrip(missing: [CompanionStatus]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(Theme.amber)
                .accessibilityHidden(true)
            Text("Missing: \(missing.map { $0.label }.joined(separator: ", "))")
                .font(.caption).foregroundStyle(Theme.text).lineLimit(1)
            Spacer()
            Button("Get files") {
                _ = catalog.enqueueMissingCompanions(diffusionPath: diffusionPath,
                                                      family: family)
            }
            .controlSize(.small)
            .help("Queue all missing companion files for download.")
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, 8)
        .background(Theme.amber.opacity(0.10))
        .overlay(Rectangle().fill(Theme.amber.opacity(0.4)).frame(height: 0.5), alignment: .bottom)
    }

    /// Coarse string identity used as the `value:` for the `.animation`
    /// modifier — when this changes, the transition fires.
    private var bannerState: String {
        if diffusionPath.isEmpty { return "empty" }
        if !activeJobs.isEmpty { return "downloading:\(activeJobs.count)" }
        if statuses.isEmpty { return "resolving" }
        let missingCount = statuses.filter { $0.isMissing }.count
        return missingCount > 0 ? "missing:\(missingCount)" : "ok"
    }

    /// Combined key that triggers a re-resolve when either the path changes
    /// or another download completes (so a freshly-arrived companion shows
    /// up as ✓ in the banner without waiting for the user to navigate).
    private var resolveKey: String {
        let completedCount = jobs.filter { $0.state.isTerminal }.count
        return "\(diffusionPath)|\(completedCount)"
    }

    @MainActor
    private func resolve() async {
        guard !diffusionPath.isEmpty else {
            statuses = []
            return
        }
        let path = diffusionPath
        let root = downloadsRoot
        let resolvedFound = await Task.detached(priority: .userInitiated) {
            CompanionResolver.scanOffActor(forDiffusion: path, downloadsRoot: root)
        }.value
        // Combine found + placeholder-for-missing so the missing-list shown
        // in the banner is the full requirement set.
        var byRole: [CompanionRole: CompanionStatus] = [:]
        for s in resolvedFound { byRole[s.role] = s }
        let reqs = ModelBundle.requiredCompanions(for: family)
        var full: [CompanionStatus] = []
        for req in reqs {
            if let s = byRole[req.role] {
                full.append(s)
            } else {
                full.append(CompanionStatus(role: req.role, label: req.label,
                                            localPath: nil,
                                            curated: ModelBundle.catalogEntry(for: req)))
            }
        }
        statuses = full
    }
}
