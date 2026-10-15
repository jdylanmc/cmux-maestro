import CmuxExtensionKit
import SwiftUI

@main
final class CMUXMaestroSidebarExtension: @MainActor CmuxSidebarExtension {
    static let manifest = CmuxExtensionManifest(
        id: "com.jdylanmc.CMUXMaestroPreview.Extension",
        displayName: "Maestro Sidebar",
        readScopes: [
            .workspaceMetadata,
            .surfaceMetadata,
            .workspacePaths,
        ],
        actionScopes: [.selectWorkspace, .selectSurface, .createWorkspace, .createWorkspaceWithPath]
    )

    // Process-wide stores, owned here and injected so views never resolve live storage.
    // Window-scoped state lives in each view's SidebarWindowBinding (ADR 0023).
    private let preferences = SidebarPreferences()
    @MainActor private static let beats = SidebarBeatsController()
    @MainActor private static let pets = SidebarPetStore()

    required init() {}

    var body: some View {
        SidebarWindowView(preferences: preferences, beats: Self.beats, pets: Self.pets)
    }

    /// Process-wide and not window-scoped; each view reads its own `CmuxSidebarScene`.
    func update(context: CmuxSidebarContext) {}
}
