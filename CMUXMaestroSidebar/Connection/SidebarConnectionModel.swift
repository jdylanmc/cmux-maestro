import CmuxExtensionKit

extension SidebarConnectionModel {
    func update(context: CmuxSidebarContext) {
        let workspaces = context.snapshot.workspaces
        showConnected(
            workspaceCount: workspaces.count,
            surfaceCount: workspaces.reduce(0) { $0 + $1.surfaces.count }
        )
    }

    func connectionStatusDidChange(_ status: CmuxSidebarConnectionStatus) {
        switch status {
        case .connected:
            if case .degraded = state {
                showWaiting()
            }
        case .waitingForHost:
            showWaiting()
        case .error(let message):
            showDegraded(message: message)
        }
    }
}
