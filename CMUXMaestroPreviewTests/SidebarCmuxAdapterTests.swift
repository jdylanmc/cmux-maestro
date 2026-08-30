import CmuxExtensionKit
import Foundation
import Testing

/// Exercises the production CMUX SDK adapter in
/// `CMUXMaestroSidebar/Connection/SidebarConnectionSignal+Cmux.swift`.
///
/// That exact source file is compiled into this test target, so these tests
/// cover the shipped fold and status mapping rather than a copy of them. Only
/// public CMUX ExtensionKit value objects are constructed here; the host
/// transport SPI is deliberately never imported.
struct SidebarCmuxAdapterTests {
    /// Builds a real `CmuxSidebarSnapshot` with the requested per-workspace
    /// surface counts.
    private func makeSnapshot(surfacesPerWorkspace: [Int]) -> CmuxSidebarSnapshot {
        CmuxSidebarSnapshot(
            sequence: 1,
            selectedWorkspaceID: nil,
            workspaces: surfacesPerWorkspace.enumerated().map { workspaceIndex, surfaceCount in
                CmuxSidebarWorkspace(
                    id: UUID(),
                    title: "workspace-\(workspaceIndex)",
                    surfaces: (0..<surfaceCount).map { surfaceIndex in
                        CmuxSidebarSurface(
                            id: UUID(),
                            title: "surface-\(workspaceIndex)-\(surfaceIndex)",
                            kind: .terminal
                        )
                    }
                )
            }
        )
    }

    /// The uneven totals below are chosen so a wrong fold cannot pass: the
    /// surface total (6) differs from the workspace count (4), the largest
    /// single workspace (3), the first workspace (1), and the last (2).
    @Test
    func snapshotSumsSurfacesAcrossUnevenWorkspaces() {
        let snapshot = makeSnapshot(surfacesPerWorkspace: [1, 3, 0, 2])

        let summary = SidebarSnapshotSummary(snapshot)

        #expect(summary.workspaceCount == 4)
        #expect(summary.surfaceCount == 6)
    }

    @Test
    func snapshotWithNoWorkspacesFoldsToZeroCounts() {
        let snapshot = makeSnapshot(surfacesPerWorkspace: [])

        let summary = SidebarSnapshotSummary(snapshot)

        #expect(summary.workspaceCount == 0)
        #expect(summary.surfaceCount == 0)
    }

    /// Workspaces that expose no surfaces must still be counted as workspaces,
    /// so a fold that dropped empty workspaces would fail here.
    @Test
    func workspacesWithoutSurfacesStillCountAsWorkspaces() {
        let snapshot = makeSnapshot(surfacesPerWorkspace: [0, 0, 0])

        let summary = SidebarSnapshotSummary(snapshot)

        #expect(summary.workspaceCount == 3)
        #expect(summary.surfaceCount == 0)
    }

    @Test
    func connectedStatusMapsToTheConnectedSignal() {
        #expect(SidebarConnectionSignal(CmuxSidebarConnectionStatus.connected) == .connected)
    }

    @Test
    func waitingForHostStatusMapsToTheWaitingForHostSignal() {
        #expect(SidebarConnectionSignal(CmuxSidebarConnectionStatus.waitingForHost) == .waitingForHost)
    }

    @Test
    func errorStatusMapsToTheErrorSignalWithTheExactMessage() {
        let sentinel = "sentinel"

        #expect(SidebarConnectionSignal(CmuxSidebarConnectionStatus.error(sentinel)) == .error(message: sentinel))
    }

    /// Proves the adapter drives the shipped reducer end to end, exactly as the
    /// extension entry point does.
    @MainActor
    @Test
    func adaptedSnapshotAndStatusesDriveTheShippedModel() {
        let model = SidebarConnectionModel()

        model.apply(.snapshot(SidebarSnapshotSummary(makeSnapshot(surfacesPerWorkspace: [1, 3, 0, 2]))))
        #expect(model.state == .connected(workspaceCount: 4, surfaceCount: 6))

        model.apply(SidebarConnectionSignal(CmuxSidebarConnectionStatus.error("sentinel")))
        #expect(model.state == .degraded(message: "sentinel"))

        model.apply(SidebarConnectionSignal(CmuxSidebarConnectionStatus.waitingForHost))
        #expect(model.state == .waiting)
    }
}
