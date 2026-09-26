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
    var windowID: UUID? = nil

    static let empty = HierarchySnapshot(
        sequence: 0,
        receivedSnapshot: false,
        workspaceListAvailable: false,
        workspaceMetadataAvailable: false,
        surfaceMetadataAvailable: false,
        workspacePathsAvailable: false,
        workspaces: []
    )

    func pathContext(workspaceID: UUID, surfaceID: UUID) -> HierarchyPathContext {
        guard SidebarTopology(self).workspaceBySurface[surfaceID] == workspaceID else { return .unavailable }
        let matches = workspaces.filter { $0.id == workspaceID }
        guard matches.count == 1, case .available(let surfaces) = matches[0].surfaces else {
            return .unavailable
        }
        let surfaceMatches = surfaces.filter { $0.id == surfaceID }
        guard surfaceMatches.count == 1 else { return .unavailable }
        return HierarchyPathContext(
            rootPath: matches[0].rootPath,
            projectRootPath: matches[0].projectRootPath,
            workingDirectory: surfaceMatches[0].workingDirectory
        )
    }
}

struct HierarchyPathContext: Equatable {
    let rootPath: HierarchyAvailability<String?>
    let projectRootPath: HierarchyAvailability<String?>
    let workingDirectory: HierarchyAvailability<String?>

    static let unavailable = HierarchyPathContext(
        rootPath: .unavailable, projectRootPath: .unavailable, workingDirectory: .unavailable
    )

    var accessibilityDescription: String {
        "Workspace: \(rootPath.pathDisplayText). Project: \(projectRootPath.pathDisplayText). Path: \(workingDirectory.pathDisplayText)."
    }
}

extension HierarchyAvailability where Value == String? {
    var pathDisplayText: String {
        switch self {
        case .unavailable: "Path unavailable"
        case .available(let path): path.map(SidebarPathDisplay.text) ?? "No path shared"
        }
    }
}

enum SidebarPathDisplay {
    private static let humanHome = Result { try CopilotPaths.realUserHome().path }

    static func text(_ path: String) -> String {
        guard !path.isEmpty else { return "No path shared" }
        guard path.hasPrefix("/") else { return path }
        switch humanHome {
        case .success(let home): return text(path, home: home)
        case .failure: return "\(path) (Home directory unavailable)"
        }
    }

    static func text(_ path: String, home: String) -> String {
        guard !path.isEmpty else { return "No path shared" }
        guard path.hasPrefix("/"), home.hasPrefix("/") else { return path }
        let components = normalizedComponents(path)
        let homeComponents = normalizedComponents(home)
        // Lexical display only: never resolve symlinks or rewrite an operation target.
        guard !homeComponents.isEmpty, components.starts(with: homeComponents) else {
            return "/" + components.joined(separator: "/")
        }
        let relative = components.dropFirst(homeComponents.count)
        return relative.isEmpty ? "~" : "~/" + relative.joined(separator: "/")
    }

    private static func normalizedComponents(_ path: String) -> [Substring] {
        var result: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                if !result.isEmpty { result.removeLast() }
            } else {
                result.append(component)
            }
        }
        return result
    }
}

struct SidebarTopology: Equatable, Sendable {
    let windowID: UUID?
    let workspaceIDs: Set<UUID>
    let workspaceBySurface: [UUID: UUID]
    let canReadSessions: Bool

    init(_ snapshot: HierarchySnapshot) {
        windowID = snapshot.windowID
        let groupedWorkspaces = Dictionary(grouping: snapshot.workspaces, by: \.id)
        let allowedWorkspaces = snapshot.workspaceListAvailable
            ? Set(groupedWorkspaces.filter { $0.value.count == 1 }.keys) : []
        workspaceIDs = allowedWorkspaces
        var placements: [UUID: [UUID]] = [:]
        for workspace in snapshot.workspaces {
            if case .available(let surfaces) = workspace.surfaces {
                for surface in surfaces {
                    placements[surface.id, default: []].append(workspace.id)
                }
            }
        }
        canReadSessions = snapshot.receivedSnapshot
            && snapshot.windowID != nil
            && snapshot.workspaceMetadataAvailable
            && snapshot.surfaceMetadataAvailable
        workspaceBySurface = canReadSessions
            ? placements.compactMapValues {
                $0.count == 1 && allowedWorkspaces.contains($0[0]) ? $0.first : nil
            } : [:]
    }
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
