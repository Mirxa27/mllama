import Foundation
import SwiftUI

// MARK: - Workspace tabs

enum Workspace: String, CaseIterable, Identifiable, Codable {
    case chat        = "Chat"
    case imageStudio = "Images"
    case videoStudio = "Videos"
    case models      = "Models"
    case gallery     = "Gallery"

    var id: String { rawValue }

    var sfSymbol: String {
        switch self {
        case .chat:        return "bubble.left.and.text.bubble.right.fill"
        case .imageStudio: return "photo.artframe"
        case .videoStudio: return "film.stack"
        case .models:      return "shippingbox.fill"
        case .gallery:     return "square.grid.3x3.fill"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .chat:        return "1"
        case .imageStudio: return "2"
        case .videoStudio: return "3"
        case .models:      return "4"
        case .gallery:     return "5"
        }
    }

    var subtitle: String {
        switch self {
        case .chat:        return "Talk to the model with tools and MCP"
        case .imageStudio: return "Generate and edit images locally"
        case .videoStudio: return "Generate and edit videos locally"
        case .models:      return "Browse and download from HuggingFace"
        case .gallery:     return "Your generated assets, with prompts"
        }
    }
}

@MainActor
final class WorkspaceState: ObservableObject {
    @Published var current: Workspace = .chat
    @Published var inspectorVisible: Bool = false   // right-side panel toggle

    func go(_ w: Workspace) { current = w }
}
