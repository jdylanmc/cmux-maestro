import Foundation
import Testing
@testable import CMUXMaestroPreview

@MainActor
struct SidebarOrchestrationTests {
    @Test func projectionKeepsExplicitAncestryAndRejectsOffWindowSurfaces() async throws {
        let workspace = UUID()
        let coordinatorSurface = UUID()
        let workerSurface = UUID()
        let offWindowSurface = UUID()
        let root = node(
            role: "coordinator", parent: nil, workspace: workspace, surface: coordinatorSurface
        )
        let child = node(
            role: "worker", parent: root.id, workspace: workspace, surface: workerSurface
        )
        let omitted = node(
            role: "worker", parent: root.id, workspace: workspace, surface: offWindowSurface
        )
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date(), complete: true, omittedCount: 0,
            nodes: [root, child, omitted]
        )
        let poll = SidebarOrchestrationPolling(
            read: { snapshot },
            pause: { try await Task.sleep(for: .seconds(60)) }
        )
        let hierarchy = HierarchySnapshot(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true,
            workspaceMetadataAvailable: true, surfaceMetadataAvailable: true,
            workspacePathsAvailable: false,
            workspaces: [HierarchyWorkspace(
                id: workspace, title: .available("Work"), detail: .available(nil),
                isSelected: .available(true), isPinned: .available(false),
                unreadCount: .available(0), rootPath: .unavailable, projectRootPath: .unavailable,
                surfaces: .available([
                    surface(coordinatorSurface), surface(workerSurface),
                ])
            )],
            windowID: UUID()
        )
        poll.update(topology: SidebarTopology(hierarchy), connected: true)
        poll.setVisible(true)
        for _ in 0..<100 where poll.snapshot.nodes.isEmpty { await Task.yield() }

        #expect(poll.availability == .partial)
        #expect(poll.snapshot.nodes.map(\.id) == [root.id, child.id])
        #expect(poll.snapshot.omittedCount == 1)
        #expect(poll.roots.map(\.id) == [root.id])
        #expect(poll.children(of: root.id).map(\.id) == [child.id])
        poll.setVisible(false)
    }

    private func node(
        role: String, parent: UUID?, workspace: UUID, surface: UUID
    ) -> SidebarOrchestrationNode {
        SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: parent, role: role,
            label: role == "worker" ? "Implementation" : "Coordinator",
            workspaceId: workspace, surfaceId: surface, generation: role == "worker" ? 1 : 0,
            phase: role == "worker" ? "process-running" : "registered",
            availability: role == "worker" ? "busy" : "active",
            createdAt: Date(), updatedAt: Date()
        )
    }

    private func surface(_ id: UUID) -> HierarchySurface {
        HierarchySurface(
            id: id, title: "Terminal", kind: .terminal, isFocused: false,
            isPinned: false, unreadCount: 0, workingDirectory: .unavailable
        )
    }
}
