import CmuxExtensionKit
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

    func update(context: CmuxSidebarContext) {
        let workspaces = context.snapshot.workspaces
        state = .connected(
            workspaceCount: workspaces.count,
            surfaceCount: workspaces.reduce(0) { $0 + $1.surfaces.count }
        )
    }

    func connectionStatusDidChange(_ status: CmuxSidebarConnectionStatus) {
        switch status {
        case .connected:
            if case .degraded = state {
                state = .waiting
            }
        case .waitingForHost:
            state = .waiting
        case .error(let message):
            state = .degraded(message: message)
        }
    }
}
