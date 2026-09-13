import CmuxExtensionKit

extension SidebarConnectionModel {
    func update(context: CmuxSidebarContext) {
        let snapshot = context.snapshot
        let workspaces = snapshot.workspaces
        let scopes = context.grantedReadScopes
        guard acceptSnapshot(sequence: snapshot.sequence) else { return }

        replaceHierarchy(with: HierarchySnapshot(
            sequence: snapshot.sequence,
            receivedSnapshot: true,
            workspaceListAvailable: scopes.contains(.workspaceList) || scopes.contains(.workspaceMetadata),
            workspaceMetadataAvailable: scopes.contains(.workspaceMetadata),
            surfaceMetadataAvailable: scopes.contains(.surfaceMetadata),
            workspacePathsAvailable: scopes.contains(.workspaceMetadata) && scopes.contains(.workspacePaths),
            workspaces: workspaces.map { workspace in
                map(
                    workspace: workspace,
                    selectedWorkspaceID: snapshot.selectedWorkspaceID,
                    grantedReadScopes: scopes
                )
            },
            windowID: snapshot.windowID
        ))
        showConnected(
            workspaceCount: workspaces.count,
            surfaceCount: workspaces.reduce(0) { $0 + $1.surfaces.count }
        )
        let topology = SidebarTopology(hierarchy)
        copilot.update(topology: topology, connected: true)
        navigation.update(
            topology: topology,
            connected: true,
            workspaceAllowed: context.grantedActionScopes.contains(.selectWorkspace),
            surfaceAllowed: context.grantedActionScopes.contains(.selectSurface),
            perform: { target in
                do {
                    switch target {
                    case .workspace(let id):
                        try await context.host.selectWorkspace(id)
                    case .surface(let workspaceID, let surfaceID):
                        try await context.host.selectSurface(workspaceID: workspaceID, surfaceID: surfaceID)
                    }
                } catch CmuxSidebarActionError.cancelled {
                    throw SidebarNavigationError.cancelled
                } catch {
                    throw SidebarNavigationError.rejected
                }
            }
        )
    }

    func connectionStatusDidChange(_ status: CmuxSidebarConnectionStatus) {
        switch status {
        case .connected:
            if case .degraded = state {
                showWaiting()
            }
        case .waitingForHost:
            resetSnapshotOrderingForDisconnectedHost()
            showWaiting()
        case .error(let message):
            showDegraded(message: message)
        }
    }

    private func map(
        workspace: CmuxSidebarWorkspace,
        selectedWorkspaceID: UUID?,
        grantedReadScopes scopes: Set<CmuxExtensionScope>
    ) -> HierarchyWorkspace {
        let hasWorkspaceMetadata = scopes.contains(.workspaceMetadata)
        let hasSurfaceMetadata = hasWorkspaceMetadata && scopes.contains(.surfaceMetadata)
        let hasWorkspacePaths = hasWorkspaceMetadata && scopes.contains(.workspacePaths)

        return HierarchyWorkspace(
            id: workspace.id,
            title: hasWorkspaceMetadata ? .available(workspace.title) : .unavailable,
            detail: hasWorkspaceMetadata ? .available(workspace.detail) : .unavailable,
            isSelected: hasWorkspaceMetadata
                ? .available(workspace.id == selectedWorkspaceID)
                : .unavailable,
            isPinned: hasWorkspaceMetadata ? .available(workspace.isPinned) : .unavailable,
            unreadCount: hasWorkspaceMetadata ? .available(workspace.unreadCount) : .unavailable,
            rootPath: hasWorkspacePaths ? .available(workspace.rootPath) : .unavailable,
            projectRootPath: hasWorkspacePaths ? .available(workspace.projectRootPath) : .unavailable,
            surfaces: hasSurfaceMetadata
                ? .available(workspace.surfaces.map { map(surface: $0, hasWorkspacePaths: hasWorkspacePaths) })
                : .unavailable
        )
    }

    private func map(
        surface: CmuxSidebarSurface,
        hasWorkspacePaths: Bool
    ) -> HierarchySurface {
        HierarchySurface(
            id: surface.id,
            title: surface.title,
            kind: HierarchySurfaceKind(surface.kind),
            isFocused: surface.isFocused,
            isPinned: surface.isPinned,
            unreadCount: surface.unreadCount,
            workingDirectory: hasWorkspacePaths
                ? .available(surface.workingDirectory)
                : .unavailable
        )
    }
}

private extension HierarchySurfaceKind {
    init(_ kind: CmuxSidebarSurfaceKind) {
        switch kind {
        case .terminal:
            self = .terminal
        case .browser:
            self = .browser
        case .agentSession:
            self = .agentSession
        case .markdown:
            self = .markdown
        case .filePreview:
            self = .filePreview
        case .project:
            self = .project
        case .rightSidebarTool:
            self = .rightSidebarTool
        case .unknown:
            self = .unknown
        }
    }
}
