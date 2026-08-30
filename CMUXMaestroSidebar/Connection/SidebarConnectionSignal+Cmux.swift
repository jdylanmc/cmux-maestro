import CmuxExtensionKit

// The production CMUX SDK adapter.
//
// These initializers are the only place where CMUX ExtensionKit value types are
// translated into the SDK-free `CMUXMaestroSidebarCore` values the reducer
// consumes. The extension entry point calls them; it does not perform the
// mapping itself. This file is compiled into both the shipped sidebar and the
// test target, so `SidebarCmuxAdapterTests` covers the shipped mapping rather
// than a copy of it.

extension SidebarSnapshotSummary {
    /// Folds a CMUX snapshot into the only two facts this bootstrap reports:
    /// the workspace count and the total surface count across every workspace.
    init(_ snapshot: CmuxSidebarSnapshot) {
        self.init(
            workspaceCount: snapshot.workspaces.count,
            surfaceCount: snapshot.workspaces.reduce(0) { $0 + $1.surfaces.count }
        )
    }
}

extension SidebarConnectionSignal {
    /// Maps a CMUX connection status onto its signal, preserving the exact
    /// error message CMUX reported.
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
