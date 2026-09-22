import SwiftUI

@main
struct CMUXMaestroPreviewApp: App {
    var body: some Scene {
        #if !CMUX_VALIDATION
        WindowGroup {
            ContentView()
        }
        #endif
        // Validation keeps the same Settings entry point without opening setup windows.
        Settings {
            MaestroSettingsView()
        }
    }
}
