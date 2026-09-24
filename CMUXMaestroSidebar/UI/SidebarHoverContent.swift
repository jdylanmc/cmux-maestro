import Foundation

enum SidebarHoverContent {
    static func workspace(_ id: UUID, hierarchy: HierarchySnapshot, connected: Bool) -> SidebarHoverCardData? {
        guard connected, SidebarTopology(hierarchy).workspaceIDs.contains(id),
              let workspace = hierarchy.workspaces.first(where: { $0.id == id }) else { return nil }
        guard hierarchy.workspaceMetadataAvailable else {
            return .init(id: "workspace-\(id)", category: "Workspace preview", title: "Workspace",
                         notice: "Workspace metadata unavailable")
        }
        let title: String
        if case .available(let name) = workspace.title, !name.isEmpty { title = name }
        else { title = "Workspace" }
        let detail: String?
        if case .available(let value) = workspace.detail { detail = value }
        else { detail = nil }
        var lines: [SidebarDetailLine] = []
        if case .available(let surfaces) = workspace.surfaces {
            let ids = surfaces.map(\.id)
            if Set(ids).count == ids.count,
               surfaces.allSatisfy({ SidebarTopology(hierarchy).workspaceBySurface[$0.id] == id }) {
                let groups = Dictionary(grouping: surfaces, by: \.kind)
                let summary = HierarchySurfaceKind.allCases.compactMap { kind -> String? in
                    guard let count = groups[kind]?.count else { return nil }
                    return "\(count) \(kind.title.lowercased())"
                }
                lines.append(.init(title: "Shared surfaces", value: summary.isEmpty ? "None" : summary.joined(separator: ", ")))
            } else {
                lines.append(.init(title: "Shared surfaces", value: "Count unavailable; placement is ambiguous"))
            }
        } else {
            lines.append(.init(title: "Shared surfaces", value: "Metadata unavailable"))
        }
        lines += [
            .init(title: "Workspace path", value: workspace.rootPath.pathDisplayText),
            .init(title: "Project path", value: workspace.projectRootPath.pathDisplayText),
            .init(title: "Workspace ID", value: id.uuidString)
        ]
        return .init(id: "workspace-\(id)", category: "Workspace preview", title: title, subtitle: detail, lines: lines)
    }
}
