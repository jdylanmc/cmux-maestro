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

    private let model = SidebarConnectionModel()
    private let preferences = SidebarPreferences()
    // Process-wide stores, owned here and injected so views never resolve live storage.
    @MainActor private static let beats = SidebarBeatsController()
    @MainActor private static let pets = SidebarPetStore()

    required init() {}

    var body: some View {
        SidebarView(model: model, preferences: preferences, beats: Self.beats, pets: Self.pets)
    }

    func update(context: CmuxSidebarContext) {
        model.update(context: context)
    }

    func connectionStatusDidChange(_ status: CmuxSidebarConnectionStatus) {
        model.connectionStatusDidChange(status)
    }
}
