/// Connection health the sidebar renders.
///
/// This bootstrap deliberately reports only connection health, never provider
/// or agent data.
enum SidebarConnectionState: Equatable, Sendable {
    case waiting
    case connected(workspaceCount: Int, surfaceCount: Int)
    case degraded(message: String)
}

/// The only snapshot facts this bootstrap derives from CMUX.
///
/// This is a plain core value, not the CMUX adapter. It carries no CMUX
/// ExtensionKit types, so the reducer stays free of the CMUX context and its
/// transport SPI. `SidebarConnectionSignal+Cmux.swift` is the adapter that
/// folds a real `CmuxSidebarSnapshot` into these counts.
struct SidebarSnapshotSummary: Equatable, Sendable {
    let workspaceCount: Int
    let surfaceCount: Int

    init(workspaceCount: Int, surfaceCount: Int) {
        self.workspaceCount = workspaceCount
        self.surfaceCount = surfaceCount
    }
}

/// Core value mirror of every CMUX event that can move the sidebar's state.
///
/// The mapping from real `CmuxSidebarConnectionStatus` cases onto these cases
/// lives in the adapter, `SidebarConnectionSignal+Cmux.swift`.
enum SidebarConnectionSignal: Equatable, Sendable {
    case snapshot(SidebarSnapshotSummary)
    case connected
    case waitingForHost
    case error(message: String)
}

/// Pure state logic shared by the shipped sidebar and its tests.
enum SidebarConnectionReducer {
    static let initialState: SidebarConnectionState = .waiting

    static func reduce(
        _ state: SidebarConnectionState,
        _ signal: SidebarConnectionSignal
    ) -> SidebarConnectionState {
        switch signal {
        case .snapshot(let summary):
            .connected(
                workspaceCount: summary.workspaceCount,
                surfaceCount: summary.surfaceCount
            )
        case .connected:
            // A bare connected status carries no counts. Recovering from a
            // degraded connection therefore returns to waiting until the next
            // snapshot arrives, rather than reporting stale counts.
            if case .degraded = state { .waiting } else { state }
        case .waitingForHost:
            .waiting
        case .error(let message):
            .degraded(message: message)
        }
    }
}
