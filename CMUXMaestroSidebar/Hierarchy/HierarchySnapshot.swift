import Foundation

enum HierarchyAvailability<Value: Equatable>: Equatable {
    case unavailable
    case available(Value)
}

struct HierarchySnapshot: Equatable {
    let sequence: UInt64
    let receivedSnapshot: Bool
    let workspaceListAvailable: Bool
    let workspaceMetadataAvailable: Bool
    let surfaceMetadataAvailable: Bool
    let workspacePathsAvailable: Bool
    let workspaces: [HierarchyWorkspace]

    static let empty = HierarchySnapshot(
        sequence: 0,
        receivedSnapshot: false,
        workspaceListAvailable: false,
        workspaceMetadataAvailable: false,
        surfaceMetadataAvailable: false,
        workspacePathsAvailable: false,
        workspaces: []
    )
}

struct HierarchyWorkspace: Equatable, Identifiable {
    let id: UUID
    let title: HierarchyAvailability<String>
    let detail: HierarchyAvailability<String?>
    let isSelected: HierarchyAvailability<Bool>
    let isPinned: HierarchyAvailability<Bool>
    let unreadCount: HierarchyAvailability<Int>
    let rootPath: HierarchyAvailability<String?>
    let projectRootPath: HierarchyAvailability<String?>
    let surfaces: HierarchyAvailability<[HierarchySurface]>
}

struct HierarchySurface: Equatable, Identifiable {
    let id: UUID
    let title: String
    let kind: HierarchySurfaceKind
    let isFocused: Bool
    let isPinned: Bool
    let unreadCount: Int
    let workingDirectory: HierarchyAvailability<String?>
}

enum HierarchySurfaceKind: String, CaseIterable, Equatable {
    case terminal
    case browser
    case agentSession
    case markdown
    case filePreview
    case project
    case rightSidebarTool
    case unknown

    var title: String {
        switch self {
        case .terminal:
            "Terminal"
        case .browser:
            "Browser"
        case .agentSession:
            "Agent Session"
        case .markdown:
            "Markdown"
        case .filePreview:
            "File Preview"
        case .project:
            "Project"
        case .rightSidebarTool:
            "Right Sidebar Tool"
        case .unknown:
            "Unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .terminal:
            "terminal"
        case .browser:
            "globe"
        case .agentSession:
            "person.crop.circle.badge.checkmark"
        case .markdown:
            "doc.richtext"
        case .filePreview:
            "doc.text.magnifyingglass"
        case .project:
            "folder"
        case .rightSidebarTool:
            "sidebar.right"
        case .unknown:
            "questionmark.square.dashed"
        }
    }
}
