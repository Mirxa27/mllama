import SwiftUI

/// Design tokens for Mllama — dark-first glassmorphism. All chrome surfaces
/// use real NSVisualEffectView-backed materials; tints are translucent over
/// the blurred substrate.
enum Theme {

    // MARK: Brand
    static let indigo  = Color(red: 0.36, green: 0.31, blue: 0.92)
    static let violet  = Color(red: 0.62, green: 0.40, blue: 0.98)
    static let cyan    = Color(red: 0.30, green: 0.82, blue: 0.96)
    static let mint    = Color(red: 0.34, green: 0.88, blue: 0.68)
    static let amber   = Color(red: 0.99, green: 0.72, blue: 0.20)
    static let coral   = Color(red: 0.96, green: 0.36, blue: 0.40)
    static let magenta = Color(red: 0.92, green: 0.36, blue: 0.78)

    // MARK: Text
    static let text       = Color.white.opacity(0.92)
    static let textMuted  = Color.white.opacity(0.62)
    static let textFaint  = Color.white.opacity(0.40)

    // MARK: Surfaces (used as tints OVER the material substrate)
    static let pane       = Color.white.opacity(0.04)
    static let paneHover  = Color.white.opacity(0.08)
    static let stroke     = Color.white.opacity(0.10)
    static let strokeStrong = Color.white.opacity(0.18)
    static let codeBg     = Color.black.opacity(0.32)

    // MARK: Role tints
    static let userBubble       = Color(red: 0.34, green: 0.22, blue: 0.62).opacity(0.55)
    static let userBubbleBorder = Color(red: 0.62, green: 0.40, blue: 0.98).opacity(0.55)
    static let assistantBubble  = Color.white.opacity(0.05)
    static let assistantBorder  = Color.white.opacity(0.12)
    static let toolCallBg       = Color(red: 0.30, green: 0.20, blue: 0.55).opacity(0.42)
    static let toolCallBorder   = Color(red: 0.62, green: 0.40, blue: 0.98).opacity(0.55)

    // MARK: Spacing
    enum Space {
        static let xxs: CGFloat = 4
        static let xs:  CGFloat = 6
        static let sm:  CGFloat = 10
        static let md:  CGFloat = 14
        static let lg:  CGFloat = 20
        static let xl:  CGFloat = 28
    }

    // MARK: Radii
    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
    }

    // MARK: Typography
    static let mono = Font.system(.body, design: .monospaced)
    static let monoSmall = Font.system(.caption, design: .monospaced)

    // MARK: Brand gradient
    static let brandGradient = LinearGradient(
        colors: [indigo, violet, magenta],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

// MARK: - Glass modifiers

/// Translucent floating panel: thin material with a soft inner stroke and a
/// barely-visible top highlight for depth.
struct Glass: ViewModifier {
    var cornerRadius: CGFloat = Theme.Radius.md
    var material: Material = .thinMaterial
    var tint: Color = Theme.pane
    var strokeColor: Color = Theme.stroke
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(material)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [strokeColor.opacity(0.9), strokeColor.opacity(0.2)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.7
                        )
                }
            )
    }
}

/// More opaque variant for primary content bubbles.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = Theme.Radius.lg
    var tint: Color = Color.white.opacity(0.06)
    var strokeColor: Color = Theme.strokeStrong
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.thinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(strokeColor, lineWidth: 0.7)
                }
            )
    }
}

extension View {
    func glass(cornerRadius: CGFloat = Theme.Radius.md,
               material: Material = .thinMaterial,
               tint: Color = Theme.pane,
               stroke: Color = Theme.stroke) -> some View {
        modifier(Glass(cornerRadius: cornerRadius, material: material, tint: tint, strokeColor: stroke))
    }

    func glassCard(cornerRadius: CGFloat = Theme.Radius.lg,
                   tint: Color = Color.white.opacity(0.06),
                   stroke: Color = Theme.strokeStrong) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, tint: tint, strokeColor: stroke))
    }
}
