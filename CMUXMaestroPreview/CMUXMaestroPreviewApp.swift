import SwiftUI

@main
struct CMUXMaestroPreviewApp: App {
    init() {
        if CommandLine.arguments.dropFirst() == ["--maestro-verify-native-authorization"] {
            let input = FileHandle.standardInput.readData(ofLength: 70_001)
            let valid = NativeChildAuthorization.verify(input)
            print(valid ? #"{"valid":true}"# : #"{"valid":false}"#)
            exit(valid ? 0 : 2)
        }
    }

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
