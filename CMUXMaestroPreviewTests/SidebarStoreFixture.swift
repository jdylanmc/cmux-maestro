import Foundation

/// Isolated Beats and pet stores, so synthetic renders never read the user's real stores.
@MainActor
struct SidebarStoreFixture {
    let root: URL
    let suiteName: String
    let beats: SidebarBeatsController
    let pets: SidebarPetStore

    init() {
        suiteName = "SidebarStoreFixture.\(UUID().uuidString)"
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/sidebar-store-fixtures/\(suiteName)", isDirectory: true)
        beats = SidebarBeatsController(file: SidebarBeatsFile(root: root.appendingPathComponent("Beats", isDirectory: true)))
        pets = SidebarPetStore(
            defaults: UserDefaults(suiteName: suiteName)!,
            uploadDirectory: root.appendingPathComponent("Pets", isDirectory: true),
            sessionDirectory: root.appendingPathComponent("PetSessions", isDirectory: true)
        )
    }

    func cleanup() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

extension SidebarView {
    /// Synthetic renders inject isolated stores; production injects its own from the extension root.
    @MainActor
    init(model: SidebarConnectionModel, preferences: SidebarPreferences, stores: SidebarStoreFixture? = nil,
         actionNow: @escaping () -> Date = { Date() }) {
        let stores = stores ?? SidebarStoreFixture()
        self.init(model: model, preferences: preferences, beats: stores.beats, pets: stores.pets, actionNow: actionNow)
    }
}
