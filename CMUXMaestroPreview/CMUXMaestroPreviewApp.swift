import SwiftUI

@main
struct CMUXMaestroPreviewApp: App {
    var body: some Scene {
        #if CMUX_VALIDATION
        // A settings-only scene keeps test hosts alive without opening setup windows.
        Settings {
            ContentView()
        }
        #else
        WindowGroup {
            ContentView()
        }
        Settings {
            WorkerLaunchSettingsView()
        }
        #endif
    }
}
