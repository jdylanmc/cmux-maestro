import Observation

enum SidebarConnectionState: Equatable {
    case waiting
    case connected(workspaceCount: Int, surfaceCount: Int)
    case degraded(message: String)
}

@Observable
@MainActor
final class SidebarConnectionModel {
    private(set) var state: SidebarConnectionState = .waiting
    private(set) var hierarchy: HierarchySnapshot = .empty

    func showWaiting() {
        state = .waiting
    }

    func showConnected(workspaceCount: Int, surfaceCount: Int) {
        state = .connected(
            workspaceCount: workspaceCount,
            surfaceCount: surfaceCount
        )
    }

    func showDegraded(message: String) {
        state = .degraded(message: message)
    }

    func replaceHierarchy(with snapshot: HierarchySnapshot) {
        hierarchy = snapshot
    }
}
