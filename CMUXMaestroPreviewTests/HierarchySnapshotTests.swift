import Foundation
import Testing
@_spi(CmuxHostTransport) import CmuxExtensionKit

@MainActor
struct HierarchySnapshotTests {
    @Test
    func mapsEverySurfaceKindWithoutFilteringOrProviderData() throws {
        let workspaceID = id("10000000-0000-0000-0000-000000000001")
        let kinds = CmuxSidebarSurfaceKind.allCases
        let surfaces = kinds.enumerated().map { index, kind in
            CmuxSidebarSurface(
                id: id("20000000-0000-0000-0000-\(String(format: "%012d", index + 1))"),
                title: "Surface \(index + 1)",
                kind: kind,
                isFocused: index == 1,
                isPinned: index == 2,
                unreadCount: index,
                workingDirectory: "/workspace/surface-\(index + 1)"
            )
        }
        let snapshot = CmuxSidebarSnapshot(
            sequence: 10,
            selectedWorkspaceID: workspaceID,
            grantedReadScopes: allHierarchyScopes,
            workspaces: [
                CmuxSidebarWorkspace(
                    id: workspaceID,
                    title: "Primary",
                    detail: "Shared workspace",
                    isPinned: true,
                    rootPath: "/workspace",
                    projectRootPath: "/workspace/project",
                    unreadCount: 7,
                    surfaces: surfaces
                ),
            ]
        )
        let model = SidebarConnectionModel()

        model.update(context: context(snapshot))

        let workspace = try #require(model.hierarchy.workspaces.first)
        let mappedSurfaces = try #require(available(workspace.surfaces))
        #expect(model.state == .connected(workspaceCount: 1, surfaceCount: kinds.count))
        #expect(mappedSurfaces.map(\.id) == surfaces.map(\.id))
        #expect(mappedSurfaces.map(\.kind) == [
            .terminal,
            .browser,
            .markdown,
            .filePreview,
            .rightSidebarTool,
            .agentSession,
            .project,
            .unknown,
        ])
        #expect(mappedSurfaces.map(\.title) == surfaces.map(\.title))
        #expect(mappedSurfaces[1].isFocused)
        #expect(mappedSurfaces[2].isPinned)
        #expect(mappedSurfaces[3].unreadCount == 3)
        #expect(available(mappedSurfaces[3].workingDirectory) == "/workspace/surface-4")
        #expect(available(workspace.title) == "Primary")
        #expect(available(workspace.detail) == "Shared workspace")
        #expect(available(workspace.isSelected) == true)
        #expect(available(workspace.isPinned) == true)
        #expect(available(workspace.unreadCount) == 7)
        #expect(available(workspace.rootPath) == "/workspace")
        #expect(available(workspace.projectRootPath) == "/workspace/project")
    }

    @Test
    func eachSnapshotAuthoritativelyReplacesPlacementAndOrderWhileIDsRemainStable() {
        let firstID = id("30000000-0000-0000-0000-000000000001")
        let secondID = id("30000000-0000-0000-0000-000000000002")
        let stableSurfaceID = id("40000000-0000-0000-0000-000000000001")
        let removedSurfaceID = id("40000000-0000-0000-0000-000000000002")
        let model = SidebarConnectionModel()

        model.update(context: context(CmuxSidebarSnapshot(
            sequence: 20,
            selectedWorkspaceID: firstID,
            grantedReadScopes: allHierarchyScopes,
            workspaces: [
                workspace(firstID, title: "First", surfaces: [
                    surface(stableSurfaceID, title: "Stable"),
                    surface(removedSurfaceID, title: "Removed"),
                ]),
                workspace(secondID, title: "Second"),
            ]
        )))

        model.update(context: context(CmuxSidebarSnapshot(
            sequence: 21,
            selectedWorkspaceID: secondID,
            grantedReadScopes: allHierarchyScopes,
            workspaces: [
                workspace(secondID, title: "Second updated"),
                workspace(firstID, title: "First updated", surfaces: [
                    surface(stableSurfaceID, title: "Stable updated"),
                ]),
            ]
        )))

        #expect(model.hierarchy.sequence == 21)
        #expect(model.hierarchy.workspaces.map(\.id) == [secondID, firstID])
        #expect(model.state == .connected(workspaceCount: 2, surfaceCount: 1))

        guard case .available(let surfaces) = model.hierarchy.workspaces[1].surfaces else {
            Issue.record("Expected surface metadata")
            return
        }
        #expect(surfaces.map(\.id) == [stableSurfaceID])
        #expect(surfaces.first?.title == "Stable updated")
    }

    @Test
    func representsPermissionDenialAndMissingPathDataHonestly() throws {
        let workspaceID = id("50000000-0000-0000-0000-000000000001")
        let model = SidebarConnectionModel()

        #expect(!model.hierarchy.receivedSnapshot)

        model.update(context: context(CmuxSidebarSnapshot(
            sequence: 30,
            selectedWorkspaceID: nil,
            grantedReadScopes: [],
            workspaces: []
        )))

        #expect(!model.hierarchy.workspaceListAvailable)
        #expect(model.hierarchy.receivedSnapshot)
        #expect(!model.hierarchy.workspaceMetadataAvailable)
        #expect(!model.hierarchy.surfaceMetadataAvailable)
        #expect(!model.hierarchy.workspacePathsAvailable)
        #expect(model.hierarchy.workspaces.isEmpty)

        model.update(context: context(CmuxSidebarSnapshot(
            sequence: 31,
            selectedWorkspaceID: nil,
            grantedReadScopes: [.workspaceList],
            workspaces: [CmuxSidebarWorkspace(id: workspaceID, title: "")]
        )))

        let redactedWorkspace = try #require(model.hierarchy.workspaces.first)
        #expect(model.hierarchy.workspaceListAvailable)
        #expect(redactedWorkspace.title == .unavailable)
        #expect(redactedWorkspace.isSelected == .unavailable)
        #expect(redactedWorkspace.surfaces == .unavailable)
        #expect(redactedWorkspace.rootPath == .unavailable)

        model.update(context: context(CmuxSidebarSnapshot(
            sequence: 32,
            selectedWorkspaceID: workspaceID,
            grantedReadScopes: [.workspaceMetadata],
            workspaces: [
                CmuxSidebarWorkspace(
                    id: workspaceID,
                    title: "Metadata-authorized",
                    rootPath: "/not-granted",
                    surfaces: [
                        CmuxSidebarSurface(
                            id: id("60000000-0000-0000-0000-000000000001"),
                            title: "Not granted",
                            kind: .terminal,
                            workingDirectory: "/not-granted"
                        ),
                    ]
                ),
            ]
        )))

        #expect(model.hierarchy.workspaceListAvailable)
        #expect(available(model.hierarchy.workspaces[0].title) == "Metadata-authorized")
        #expect(model.hierarchy.workspaces[0].surfaces == .unavailable)
        #expect(model.hierarchy.workspaces[0].rootPath == .unavailable)

        model.update(context: context(CmuxSidebarSnapshot(
            sequence: 33,
            selectedWorkspaceID: workspaceID,
            grantedReadScopes: [.workspaceMetadata, .surfaceMetadata],
            workspaces: [
                CmuxSidebarWorkspace(
                    id: workspaceID,
                    title: "Surface metadata",
                    surfaces: [
                        CmuxSidebarSurface(
                            id: id("60000000-0000-0000-0000-000000000002"),
                            title: "Visible surface",
                            kind: .browser,
                            workingDirectory: "/not-granted"
                        ),
                    ]
                ),
            ]
        )))

        let noPathWorkspace = try #require(model.hierarchy.workspaces.first)
        let noPathSurface = try #require(available(noPathWorkspace.surfaces)?.first)
        #expect(noPathSurface.title == "Visible surface")
        #expect(noPathSurface.workingDirectory == .unavailable)

        model.update(context: context(CmuxSidebarSnapshot(
            sequence: 34,
            selectedWorkspaceID: workspaceID,
            grantedReadScopes: allHierarchyScopes,
            workspaces: [
                CmuxSidebarWorkspace(
                    id: workspaceID,
                    title: "Pathless",
                    rootPath: nil,
                    projectRootPath: nil,
                    surfaces: [
                        CmuxSidebarSurface(
                            id: id("60000000-0000-0000-0000-000000000001"),
                            title: "Terminal",
                            kind: .terminal,
                            workingDirectory: nil
                        ),
                    ]
                ),
            ]
        )))

        let pathlessWorkspace = try #require(model.hierarchy.workspaces.first)
        #expect(pathlessWorkspace.rootPath == .available(nil))
        #expect(pathlessWorkspace.projectRootPath == .available(nil))
        let pathlessSurface = try #require(available(pathlessWorkspace.surfaces)?.first)
        #expect(pathlessSurface.workingDirectory == .available(nil))
    }

    @Test
    func workspacePathsRemainUnavailableWithoutWorkspaceMetadata() throws {
        let firstWorkspaceID = id("65000000-0000-0000-0000-000000000001")
        let secondWorkspaceID = id("65000000-0000-0000-0000-000000000002")
        let model = SidebarConnectionModel()

        model.update(context: context(CmuxSidebarSnapshot(
            sequence: 35,
            selectedWorkspaceID: firstWorkspaceID,
            grantedReadScopes: [.workspaceList, .workspacePaths],
            workspaces: [
                CmuxSidebarWorkspace(
                    id: firstWorkspaceID,
                    title: "First",
                    rootPath: "/first",
                    projectRootPath: "/first/project"
                ),
                CmuxSidebarWorkspace(
                    id: secondWorkspaceID,
                    title: "Second",
                    rootPath: "/second",
                    projectRootPath: "/second/project"
                ),
            ]
        )))

        #expect(!model.hierarchy.workspacePathsAvailable)
        #expect(model.hierarchy.workspaces.count == 2)
        for workspace in model.hierarchy.workspaces {
            #expect(workspace.rootPath == .unavailable)
            #expect(workspace.projectRootPath == .unavailable)
        }
    }

    @Test
    func connectionStatusChangesDoNotDiscardTheLatestHierarchy() {
        let workspaceID = id("70000000-0000-0000-0000-000000000001")
        let model = SidebarConnectionModel()
        model.update(context: context(CmuxSidebarSnapshot(
            sequence: 40,
            selectedWorkspaceID: workspaceID,
            grantedReadScopes: allHierarchyScopes,
            workspaces: [workspace(workspaceID, title: "Retained")]
        )))
        let hierarchy = model.hierarchy

        model.connectionStatusDidChange(.error("Disconnected"))
        #expect(model.state == .degraded(message: "Disconnected"))
        #expect(model.hierarchy == hierarchy)

        model.connectionStatusDidChange(.waitingForHost)
        #expect(model.state == .waiting)
        #expect(model.hierarchy == hierarchy)
    }

    @Test
    func syntheticSurfaceKindsHaveDistinctLabelsAndSymbols() {
        #expect(HierarchySurfaceKind.allCases.map(\.title) == [
            "Terminal",
            "Browser",
            "Agent Session",
            "Markdown",
            "File Preview",
            "Project",
            "Right Sidebar Tool",
            "Unknown",
        ])
        #expect(Set(HierarchySurfaceKind.allCases.map(\.symbolName)).count == HierarchySurfaceKind.allCases.count)
    }

    private var allHierarchyScopes: Set<CmuxExtensionScope> {
        [.workspaceList, .workspaceMetadata, .surfaceMetadata, .workspacePaths]
    }

    private func context(_ snapshot: CmuxSidebarSnapshot) -> CmuxSidebarContext {
        CmuxSidebarContext(
            snapshot: snapshot,
            host: CmuxSidebarHost(performAction: { _, _ in })
        )
    }

    private func workspace(
        _ id: UUID,
        title: String,
        surfaces: [CmuxSidebarSurface] = []
    ) -> CmuxSidebarWorkspace {
        CmuxSidebarWorkspace(id: id, title: title, surfaces: surfaces)
    }

    private func surface(_ id: UUID, title: String) -> CmuxSidebarSurface {
        CmuxSidebarSurface(id: id, title: title, kind: .terminal)
    }

    private func id(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }

    private func available<Value>(_ value: HierarchyAvailability<Value>) -> Value? {
        guard case .available(let value) = value else { return nil }
        return value
    }
}
