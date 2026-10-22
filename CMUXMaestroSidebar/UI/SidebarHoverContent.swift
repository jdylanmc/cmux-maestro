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
                let counts = summary.isEmpty ? "None" : summary.joined(separator: ", ")
                lines.append(.init(title: "Shared surfaces", value: counts, copyableValue: counts))
            } else {
                lines.append(.init(title: "Shared surfaces", value: "Unavailable · Placement: Ambiguous"))
            }
        } else {
            lines.append(.init(title: "Shared surfaces", value: "Metadata unavailable"))
        }
        lines.append(ports(workspace.listeningPorts))
        lines += [
            .init(title: "Workspace path", value: workspace.rootPath.pathDisplayText,
                  copyableValue: workspace.rootPath.copyablePathValue),
            .init(title: "Project path", value: workspace.projectRootPath.pathDisplayText,
                  copyableValue: workspace.projectRootPath.copyablePathValue),
            .init(title: "Workspace ID", value: id.uuidString, copyableValue: id.uuidString)
        ]
        return .init(id: "workspace-\(id)", category: "Workspace preview", title: title, subtitle: detail, lines: lines)
    }

    static let portsTitle = "Ports (CMUX, workspace-wide)"

    /// CMUX reports port numbers only; an empty list is not proof that nothing listens.
    static func ports(_ ports: HierarchyAvailability<[Int]>) -> SidebarDetailLine {
        guard case .available(let ports) = ports else { return .init(title: portsTitle, value: "Not granted") }
        guard !ports.isEmpty else { return .init(title: portsTitle, value: "None reported") }
        let value = ports.map(String.init).joined(separator: ", ")
        return .init(title: portsTitle, value: value, copyableValue: value)
    }
}
