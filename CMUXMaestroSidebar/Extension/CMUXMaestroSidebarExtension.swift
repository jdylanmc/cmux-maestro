import CmuxExtensionKit
import SwiftUI

@main
final class CMUXMaestroSidebarExtension: @MainActor CmuxSidebarExtension {
    static let manifest = CmuxExtensionManifest(
        id: "com.jdylanmc.CMUXMaestroPreview.Extension",
        displayName: "CMUX Maestro Preview",
        readScopes: [
            .workspaceList,
            .workspaceMetadata,
            .surfaceMetadata,
            .workspacePaths,
        ],
        actionScopes: []
    )

    private let model = SidebarConnectionModel()
    private let preferences = SidebarPreferences()

    required init() {}

    var body: some View {
        SidebarView(model: model, preferences: preferences)
    }

    func update(context: CmuxSidebarContext) {
        model.update(context: context)
    }

    func connectionStatusDidChange(_ status: CmuxSidebarConnectionStatus) {
        model.connectionStatusDidChange(status)
    }
}
