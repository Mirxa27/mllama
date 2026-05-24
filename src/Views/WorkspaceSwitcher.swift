import SwiftUI

/// Left-rail vertical tab bar that switches between Chat / Image / Video / Models / Gallery.
/// Sits between the macOS sidebar and the chat detail.
struct WorkspaceRail: View {
    @EnvironmentObject var workspace: WorkspaceState

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Workspace.allCases) { w in
                WorkspaceTabButton(workspace: w, isActive: workspace.current == w) {
                    withAnimation(.easeOut(duration: 0.15)) { workspace.go(w) }
                }
                .keyboardShortcut(w.shortcut, modifiers: .command)
            }
            Spacer()
        }
        .padding(.vertical, Theme.Space.md)
        .padding(.horizontal, Theme.Space.xs)
        .frame(width: 60)
        .background(VisualEffectBackground(material: .sidebar, blendingMode: .withinWindow)
            .overlay(Rectangle().fill(Theme.stroke).frame(width: 0.5), alignment: .trailing)
            .ignoresSafeArea())
    }
}

struct WorkspaceTabButton: View {
    let workspace: Workspace
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isActive ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.clear))
                        .frame(width: 42, height: 42)
                        .shadow(color: isActive ? Theme.violet.opacity(0.45) : .clear, radius: isActive ? 12 : 0)
                    if !isActive {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(hovering ? Theme.paneHover : Theme.pane)
                            .frame(width: 42, height: 42)
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.stroke, lineWidth: 0.7)
                            .frame(width: 42, height: 42)
                    }
                    Image(systemName: workspace.sfSymbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isActive ? .white : Theme.text)
                }
                Text(workspace.rawValue)
                    .font(.system(size: 9, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? Theme.text : Theme.textMuted)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(workspace.rawValue) (⌘\(String(describing: workspace.shortcut.character)))")
    }
}

// MARK: - Workspace detail router

/// Renders the detail view for whichever workspace tab is active.
struct WorkspaceDetail: View {
    @EnvironmentObject var workspace: WorkspaceState

    var body: some View {
        Group {
            switch workspace.current {
            case .chat:        ChatView()
            case .imageStudio: ImageStudio()
            case .videoStudio: VideoStudio()
            case .models:      HuggingFaceBrowserView()
            case .gallery:     GalleryView()
            }
        }
        .transition(.opacity)
    }
}
