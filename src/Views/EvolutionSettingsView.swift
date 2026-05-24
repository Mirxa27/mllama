import SwiftUI

/// Shows the agent's self-modification state — every version of the system
/// prompt it has authored, the runtime tools it has created, and a tail of
/// the reflection log. Lets the user roll back changes if the agent went
/// off the rails.
struct EvolutionSettingsView: View {
    @EnvironmentObject var evolution: SelfImprovementCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                headerCard
                promptSection
                Divider().background(Theme.stroke)
                dynamicToolsSection
                Divider().background(Theme.stroke)
                reflectionSection
            }
            .padding(Theme.Space.md)
        }
        .task { await evolution.refresh() }
    }

    // MARK: Header

    private var headerCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.brandGradient).frame(width: 44, height: 44)
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.white)
                    .font(.title3)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Self-improvement")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Text("The agent's record of identifying weaknesses, rewriting its own rules, and authoring new tools.")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
        }
        .padding(Theme.Space.md)
        .glassCard(cornerRadius: Theme.Radius.md)
    }

    // MARK: Prompt versions

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SYSTEM PROMPT VERSIONS")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                Text("v\(evolution.currentPromptVersion)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.violet)
            }
            if evolution.promptVersions.isEmpty {
                emptyHint(icon: "doc.text", text: "Baseline prompt active — no edits yet.")
            } else {
                ForEach(evolution.promptVersions.reversed()) { v in
                    PromptVersionRow(version: v,
                                     isCurrent: v.version == evolution.currentPromptVersion,
                                     onRollback: { await evolution.rollbackPrompt(to: v.version) })
                }
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        Task { await evolution.resetPromptToBaseline() }
                    } label: {
                        Label("Reset to baseline", systemImage: "arrow.counterclockwise")
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: Dynamic tools

    private var dynamicToolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RUNTIME-CREATED TOOLS")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textFaint)
            if evolution.dynamicTools.isEmpty {
                emptyHint(icon: "wrench.adjustable",
                          text: "The agent hasn't authored any new tools yet. When it does, they appear here and become callable immediately.")
            } else {
                ForEach(evolution.dynamicTools) { spec in
                    DynamicToolRow(spec: spec) {
                        Task { await evolution.disableDynamicTool(name: spec.name) }
                    }
                }
            }
        }
    }

    // MARK: Reflection log

    private var reflectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("REFLECTION LOG")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                if !evolution.failurePatterns.isEmpty {
                    Text("\(evolution.failurePatterns.count) recurring pattern\(evolution.failurePatterns.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.amber.opacity(0.20), in: Capsule())
                        .foregroundStyle(Theme.amber)
                }
                Button("Clear") {
                    Task { await evolution.clearReflectionLog() }
                }
                .controlSize(.small)
                .disabled(evolution.reflectionRecent.isEmpty)
            }
            if !evolution.failurePatterns.isEmpty {
                ForEach(evolution.failurePatterns, id: \.toolName) { pattern in
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(Theme.amber).font(.caption)
                        Text("\(pattern.toolName) — \(pattern.count) errors in last 30 min")
                            .font(.caption).foregroundStyle(Theme.text)
                        Spacer()
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            if evolution.reflectionRecent.isEmpty {
                emptyHint(icon: "rectangle.dashed",
                          text: "No tool calls recorded yet. Once the agent uses tools, outcomes show up here.")
            } else {
                ForEach(evolution.reflectionRecent.prefix(40)) { rec in
                    ReflectionRow(rec: rec)
                }
            }
        }
    }

    // MARK: Bits

    private func emptyHint(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Theme.textFaint)
                .accessibilityHidden(true)
            Text(text).font(.caption).foregroundStyle(Theme.textMuted)
            Spacer()
        }
        .padding(Theme.Space.sm)
        .glass(cornerRadius: Theme.Radius.sm)
    }
}

// MARK: - Rows

private struct PromptVersionRow: View {
    let version: PromptVersion
    let isCurrent: Bool
    let onRollback: () async -> Void
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("v\(version.version)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(isCurrent ? Theme.violet.opacity(0.25) : Theme.pane,
                                in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(isCurrent ? Theme.violet : Theme.text)
                Text(version.timestamp, style: .date)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                Text(version.timestamp, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                if !isCurrent {
                    Button("Roll back") {
                        Task { await onRollback() }
                    }
                    .controlSize(.small)
                    .help("Restore this version of the system prompt.")
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(expanded ? "Collapse" : "Expand")
            }
            Text("Reason: \(version.reason)")
                .font(.caption).foregroundStyle(Theme.textMuted)
                .lineLimit(2)
            if expanded {
                Text(version.prompt)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(Theme.Space.sm)
        .glass(cornerRadius: Theme.Radius.sm,
               tint: isCurrent ? Theme.violet.opacity(0.08) : Theme.pane,
               stroke: isCurrent ? Theme.violet.opacity(0.35) : Theme.stroke)
    }
}

private struct DynamicToolRow: View {
    let spec: ScriptedToolSpec
    let onDisable: () -> Void
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "wrench.adjustable.fill")
                    .foregroundStyle(Theme.violet)
                    .accessibilityHidden(true)
                Text(spec.name)
                    .font(.callout.monospaced().weight(.semibold))
                    .foregroundStyle(Theme.text)
                Text("v\(spec.version)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.pane, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(Theme.textMuted)
                if spec.requiresApproval {
                    Text("approval")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.amber.opacity(0.18), in: Capsule())
                        .foregroundStyle(Theme.amber)
                        .help("Each invocation needs user approval.")
                }
                Spacer()
                Button("Disable", role: .destructive, action: onDisable)
                    .controlSize(.small)
                    .help("Remove this tool. The agent won't see it on the next turn.")
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(expanded ? "Collapse" : "Expand")
            }
            Text(spec.description)
                .font(.caption).foregroundStyle(Theme.textMuted).lineLimit(expanded ? nil : 2)
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text("command_template").font(.caption2.weight(.bold)).foregroundStyle(Theme.textFaint)
                    Text(spec.commandTemplate)
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 6))
                    Text("parameters").font(.caption2.weight(.bold)).foregroundStyle(Theme.textFaint)
                    Text(spec.parametersJSON)
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(Theme.Space.sm)
        .glass(cornerRadius: Theme.Radius.sm)
    }
}

private struct ReflectionRow: View {
    let rec: ReflectionRecord

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: rec.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                .foregroundStyle(rec.isError ? Theme.coral : Theme.mint)
                .font(.caption)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(rec.toolName)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(Theme.text)
                    Text(rec.timestamp, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textFaint)
                    Text("\(rec.durationMs) ms")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textFaint)
                    Spacer()
                }
                if rec.isError {
                    Text(rec.resultHead)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            (rec.isError ? Theme.coral.opacity(0.05) : Color.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }
}
