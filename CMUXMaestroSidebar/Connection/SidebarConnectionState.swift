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
    let copilot: SidebarCopilotPolling
    let navigation = SidebarNavigation()
    private var latestSequence: UInt64?

    init(copilot: SidebarCopilotPolling? = nil) {
        if let copilot {
            self.copilot = copilot
        } else {
            self.copilot = SidebarCopilotPolling()
        }
    }

    func acceptSnapshot(sequence: UInt64) -> Bool {
        guard latestSequence.map({ sequence >= $0 }) ?? true else { return false }
        latestSequence = sequence
        return true
    }

    func resetSnapshotOrderingForDisconnectedHost() {
        // The SDK filters replaced-transport callbacks; redacted window IDs are not a new transport.
        latestSequence = nil
    }

    func showWaiting() {
        state = .waiting
        copilot.update(topology: SidebarTopology(hierarchy), connected: false)
        navigation.disconnect()
    }

    func showConnected(workspaceCount: Int, surfaceCount: Int) {
        state = .connected(
            workspaceCount: workspaceCount,
            surfaceCount: surfaceCount
        )
    }

    func showDegraded(message: String) {
        state = .degraded(message: message)
        copilot.update(topology: SidebarTopology(hierarchy), connected: false)
        navigation.disconnect()
    }

    func replaceHierarchy(with snapshot: HierarchySnapshot) {
        hierarchy = snapshot
    }

    func setVisible(_ visible: Bool) {
        copilot.setVisible(visible)
        if !visible { navigation.cancelPending() }
    }
}
