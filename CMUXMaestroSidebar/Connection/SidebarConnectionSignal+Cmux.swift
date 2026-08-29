import CmuxExtensionKit

extension SidebarSnapshotSummary {
    init(_ snapshot: CmuxSidebarSnapshot) {
        self.init(
            workspaceCount: snapshot.workspaces.count,
            surfaceCount: snapshot.workspaces.reduce(0) { $0 + $1.surfaces.count }
        )
    }
}

extension SidebarConnectionSignal {
    init(_ status: CmuxSidebarConnectionStatus) {
        switch status {
        case .connected:
            self = .connected
        case .waitingForHost:
            self = .waitingForHost
        case .error(let message):
            self = .error(message: message)
        }
    }
}
