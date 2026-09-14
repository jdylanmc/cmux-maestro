import Foundation
import Testing
@testable import CMUXMaestroPreview

@MainActor
struct SidebarOrchestrationTests {
    @Test func projectionKeepsExplicitAncestryWithoutDisclosingOffWindowCount() async throws {
        let workspace = UUID()
        let run = UUID()
        let coordinatorSurface = UUID()
        let workerSurface = UUID()
        let offWindowSurface = UUID()
        let root = node(
            run: run, role: "coordinator", parent: nil,
            workspace: workspace, surface: coordinatorSurface
        )
        let child = node(
            run: run, role: "worker", parent: root.id,
            workspace: workspace, surface: workerSurface
        )
        let omitted = node(
            run: run, role: "worker", parent: root.id,
            workspace: workspace, surface: offWindowSurface
        )
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date(), complete: true, omittedCount: 0,
            nodes: [root, child, omitted]
        )
        let poll = SidebarOrchestrationPolling(
            read: { snapshot },
            pause: { try await Task.sleep(for: .seconds(60)) }
        )
        poll.update(
            topology: topology(
                workspace: workspace, surfaces: [coordinatorSurface, workerSurface]
            ),
            connected: true
        )
        poll.setVisible(true)
        for _ in 0..<100 where poll.snapshot.nodes.isEmpty { await Task.yield() }

        #expect(poll.availability == .ready)
        #expect(poll.snapshot.nodes.map(\.id) == [root.id, child.id])
        #expect(poll.snapshot.omittedCount == 0)
        #expect(poll.roots.map(\.id) == [root.id])
        #expect(poll.children(of: root.id).map(\.id) == [child.id])
        poll.setVisible(false)
    }

    @Test func filteredCoordinatorDoesNotPromoteChildToProvenRoot() async {
        let workspace = UUID()
        let run = UUID()
        let root = node(run: run, role: "coordinator", parent: nil, workspace: workspace)
        let child = node(run: run, role: "worker", parent: root.id, workspace: workspace)
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date(), complete: true, omittedCount: 0,
            nodes: [root, child]
        )
        let poll = SidebarOrchestrationPolling(
            read: { snapshot },
            pause: { try await Task.sleep(for: .seconds(60)) }
        )
        poll.update(
            topology: topology(workspace: workspace, surfaces: [child.surfaceId]),
            connected: true
        )
        poll.setVisible(true)
        for _ in 0..<100 where poll.availability == .loading { await Task.yield() }
        #expect(poll.availability == .ready)
        #expect(poll.snapshot.nodes.isEmpty)
        #expect(poll.snapshot.omittedCount == 0)
        poll.setVisible(false)
    }

    @Test func staleSnapshotIsQualifiedWithoutDiscardingValidatedNodes() async {
        let workspace = UUID()
        let root = node(run: UUID(), role: "coordinator", parent: nil, workspace: workspace)
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date().addingTimeInterval(-120),
            complete: true, omittedCount: 0, nodes: [root]
        )
        let poll = SidebarOrchestrationPolling(
            read: { snapshot },
            pause: { try await Task.sleep(for: .seconds(60)) }
        )
        poll.update(
            topology: topology(workspace: workspace, surfaces: [root.surfaceId]),
            connected: true
        )
        poll.setVisible(true)
        for _ in 0..<100 where poll.availability == .loading { await Task.yield() }
        #expect(poll.availability == .stale)
        #expect(poll.snapshot.nodes == [root])
        poll.setVisible(false)
    }

    @Test func validationRejectsCyclesDuplicateSurfacesAndFutureEvidence() {
        let workspace = UUID()
        let run = UUID()
        let root = node(run: run, role: "coordinator", parent: nil, workspace: workspace)
        let child = node(run: run, role: "worker", parent: root.id, workspace: workspace)
        let duplicateSurface = node(
            run: run, role: "worker", parent: root.id,
            workspace: workspace, surface: child.surfaceId
        )
        let future = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date().addingTimeInterval(600),
            complete: true, omittedCount: 0, nodes: [root]
        )
        #expect(throws: CopilotFileError.self) {
            try SidebarOrchestrationReader.validate(
                .init(
                    version: 1, generatedAt: Date(), complete: true, omittedCount: 0,
                    nodes: [root, child, duplicateSurface]
                )
            )
        }
        #expect(throws: CopilotFileError.self) {
            try SidebarOrchestrationReader.validate(future)
        }

        let firstID = UUID()
        let secondID = UUID()
        let first = node(
            id: firstID, run: run, role: "worker", parent: secondID, workspace: workspace
        )
        let second = node(
            id: secondID, run: run, role: "worker", parent: firstID, workspace: workspace
        )
        #expect(throws: CopilotFileError.self) {
            try SidebarOrchestrationReader.validate(
                .init(
                    version: 1, generatedAt: Date(), complete: true, omittedCount: 0,
                    nodes: [first, second]
                )
            )
        }
    }

    @Test func validationRejectsCrossRunAncestryAndInvalidLifecycleShape() {
        let workspace = UUID()
        let root = node(run: UUID(), role: "coordinator", parent: nil, workspace: workspace)
        let crossRun = node(
            run: UUID(), role: "worker", parent: root.id, workspace: workspace
        )
        let invalid = node(
            run: root.runId, role: "worker", parent: root.id, workspace: workspace,
            phase: "reported-completed", availability: "busy"
        )
        for nodes in [[root, crossRun], [root, invalid]] {
            #expect(throws: CopilotFileError.self) {
                try SidebarOrchestrationReader.validate(
                    .init(
                        version: 1, generatedAt: Date(), complete: true,
                        omittedCount: 0, nodes: nodes
                    )
                )
            }
        }
    }

    @Test func everyAcceptedPhaseHasAnExplicitVisibleTitle() {
        let expected: [SidebarOrchestrationPhase: String] = [
            .registered: "Registered",
            .launching: "Launching",
            .turnQueued: "Queued",
            .turnRunning: "Working",
            .reportedBlocked: "Blocked",
            .reportedCompleted: "Completed · available",
            .reportedFailed: "Failed · available",
            .reportMissing: "Report missing",
            .permissionDenied: "Permission denied · available",
            .turnFailed: "Turn failed",
            .processDisappeared: "Process disappeared",
            .terminalDisappeared: "Terminal disappeared",
            .launchFailed: "Launch failed",
            .startupFailed: "Startup failed",
            .resourceRetired: "Resource retired"
        ]
        #expect(Set(expected.keys) == Set(SidebarOrchestrationPhase.allCases))
        for phase in SidebarOrchestrationPhase.allCases {
            let title = phase.title(availability: phase == .registered ? "active" : "idle")
            #expect(title == expected[phase])
            #expect(!phase.symbolName(role: "worker").isEmpty)
            #expect(title != "Unknown state")
        }
    }

    private func node(
        id: UUID = UUID(),
        run: UUID,
        role: String,
        parent: UUID?,
        workspace: UUID,
        surface: UUID = UUID(),
        phase: String? = nil,
        availability: String? = nil
    ) -> SidebarOrchestrationNode {
        let timestamp = Date()
        return SidebarOrchestrationNode(
            id: id, runId: run, parentId: parent, role: role,
            label: role == "worker" ? "Implementation" : "Coordinator",
            workspaceId: workspace, surfaceId: surface, generation: role == "worker" ? 1 : 0,
            phase: phase ?? (role == "worker" ? "turn-running" : "registered"),
            availability: availability ?? (role == "worker" ? "busy" : "active"),
            createdAt: timestamp, updatedAt: timestamp
        )
    }

    private func topology(workspace: UUID, surfaces: [UUID]) -> SidebarTopology {
        SidebarTopology(HierarchySnapshot(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true,
            workspaceMetadataAvailable: true, surfaceMetadataAvailable: true,
            workspacePathsAvailable: false,
            workspaces: [HierarchyWorkspace(
                id: workspace, title: .available("Work"), detail: .available(nil),
                isSelected: .available(true), isPinned: .available(false),
                unreadCount: .available(0), rootPath: .unavailable,
                projectRootPath: .unavailable,
                surfaces: .available(surfaces.map(surface))
            )],
            windowID: UUID()
        ))
    }

    private func surface(_ id: UUID) -> HierarchySurface {
        HierarchySurface(
            id: id, title: "Terminal", kind: .terminal, isFocused: false,
            isPinned: false, unreadCount: 0, workingDirectory: .unavailable
        )
    }
}
