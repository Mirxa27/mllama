import SwiftUI
import AppKit

/// NSVisualEffectView wrapped for SwiftUI. Used for the whole-window
/// translucent substrate that everything sits on top of.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var emphasized: Bool

    init(material: NSVisualEffectView.Material = .hudWindow,
         blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
         emphasized: Bool = false) {
        self.material = material
        self.blendingMode = blendingMode
        self.emphasized = emphasized
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = emphasized
        view.autoresizingMask = [.width, .height]
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.isEmphasized = emphasized
    }
}

/// Decorative gradient orbs behind the visual-effect substrate. Subtle, slow,
/// adds depth without distracting.
struct GradientAtmosphere: View {
    @State private var phase: CGFloat = 0
    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Theme.indigo.opacity(0.55), .clear],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 760, height: 760)
                .blur(radius: 120)
                .offset(x: -200 + phase * 30, y: -260 + phase * 20)
            Circle()
                .fill(LinearGradient(colors: [Theme.magenta.opacity(0.45), .clear],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 680, height: 680)
                .blur(radius: 130)
                .offset(x: 380 - phase * 30, y: -100 - phase * 25)
            Circle()
                .fill(LinearGradient(colors: [Theme.cyan.opacity(0.35), .clear],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 620, height: 620)
                .blur(radius: 120)
                .offset(x: -60 - phase * 20, y: 280 + phase * 15)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }
}
