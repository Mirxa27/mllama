import SwiftUI

// MARK: - Dismiss button (banner close)

/// Accessible, focus-visible "X" close button used by banner-style strips.
/// Apple-style: subtle by default, lifts on hover, system-default focus
/// ring via .borderless rather than .plain so keyboard nav users can see it.
struct DismissButton: View {
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(hovering ? Theme.text : Theme.textMuted)
                .font(.callout)
                .padding(4)               // expand hit area to ~28pt
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)         // keeps the system focus ring on Tab
        .onHover { hovering = $0 }
        .accessibilityLabel("Dismiss")
        .help("Dismiss")
    }
}

// MARK: - Banner container

/// Standard banner chrome used by error / warning / info strips so they all
/// share the same padding ladder, stroke weight, and animation transition.
/// Centralising this prevents the per-banner one-off styling drift the audit
/// flagged.
struct InfoBanner<Content: View>: View {
    enum Severity { case info, success, warning, error }
    let severity: Severity
    let content: Content

    init(severity: Severity, @ViewBuilder content: () -> Content) {
        self.severity = severity
        self.content = content()
    }

    private var accent: Color {
        switch severity {
        case .info:    return Theme.cyan
        case .success: return Theme.mint
        case .warning: return Theme.amber
        case .error:   return Theme.coral
        }
    }

    private var ruleHeight: CGFloat {
        switch severity {
        case .error:           return 1.0
        case .warning, .info, .success: return 0.5
        }
    }

    private var ruleAlpha: Double {
        switch severity {
        case .error:           return 0.55
        case .warning, .info, .success: return 0.35
        }
    }

    var body: some View {
        content
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, severity == .error ? Theme.Space.sm + 2 : Theme.Space.xs + 2)
            .background(accent.opacity(0.12))
            .overlay(Rectangle().fill(accent.opacity(ruleAlpha)).frame(height: ruleHeight),
                     alignment: .bottom)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
