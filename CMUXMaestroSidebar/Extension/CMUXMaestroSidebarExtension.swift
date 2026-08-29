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
        ],
        actionScopes: []
    )

    private let model = SidebarConnectionModel()

    required init() {}

    var body: some View {
        SidebarView(model: model)
    }

    func update(context: CmuxSidebarContext) {
        model.update(context: context)
    }

    func connectionStatusDidChange(_ status: CmuxSidebarConnectionStatus) {
        model.connectionStatusDidChange(status)
    }
}
