import Testing

/// Exercises the same `SidebarConnectionModel` and reducer the shipped sidebar
/// uses.
///
/// This suite covers only the SDK-free core: it starts from already-reduced
/// core values and cannot observe how CMUX SDK values are folded or mapped.
/// `SidebarCmuxAdapterTests` covers that production adapter against real CMUX
/// ExtensionKit value types.
@MainActor
struct SidebarConnectionModelTests {
    @Test
    func startsWaitingForCmux() {
        let model = SidebarConnectionModel()

        #expect(model.state == .waiting)
    }

    @Test
    func snapshotReportsWorkspaceAndSurfaceCounts() {
        let model = SidebarConnectionModel()

        model.apply(.snapshot(SidebarSnapshotSummary(workspaceCount: 2, surfaceCount: 3)))

        #expect(model.state == .connected(workspaceCount: 2, surfaceCount: 3))
    }

    @Test
    func errorSurfacesTheExactCmuxMessage() {
        let model = SidebarConnectionModel()
        let message = "cmux did not send a workspace snapshot"

        model.apply(.error(message: message))

        #expect(model.state == .degraded(message: message))
    }

    @Test
    func waitingForHostClearsPreviousCounts() {
        let model = SidebarConnectionModel()
        model.apply(.snapshot(SidebarSnapshotSummary(workspaceCount: 2, surfaceCount: 3)))

        model.apply(.waitingForHost)

        #expect(model.state == .waiting)
    }

    @Test
    func recoveringFromDegradedWaitsForTheNextSnapshot() {
        let model = SidebarConnectionModel()
        model.apply(.snapshot(SidebarSnapshotSummary(workspaceCount: 2, surfaceCount: 3)))
        model.apply(.error(message: "cmux connection was interrupted"))

        model.apply(.connected)

        #expect(model.state == .waiting)

        model.apply(.snapshot(SidebarSnapshotSummary(workspaceCount: 1, surfaceCount: 4)))

        #expect(model.state == .connected(workspaceCount: 1, surfaceCount: 4))
    }

    @Test
    func connectedStatusDoesNotDisturbReportedCounts() {
        let model = SidebarConnectionModel()
        model.apply(.snapshot(SidebarSnapshotSummary(workspaceCount: 2, surfaceCount: 3)))

        model.apply(.connected)

        #expect(model.state == .connected(workspaceCount: 2, surfaceCount: 3))
    }

    @Test
    func emptySnapshotReportsZeroCounts() {
        let model = SidebarConnectionModel()

        model.apply(.snapshot(SidebarSnapshotSummary(workspaceCount: 0, surfaceCount: 0)))

        #expect(model.state == .connected(workspaceCount: 0, surfaceCount: 0))
    }
}
