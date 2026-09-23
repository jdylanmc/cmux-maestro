import SwiftUI
import Darwin
import Dispatch

@main
enum CMUXMaestroEntryPoint {
    @MainActor
    static func main() {
        let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        guard arguments.contains(CopilotSetupCommandLine.installFlag) else {
            CMUXMaestroPreviewApp.main()
            return
        }
        Task { @MainActor in
            do {
                guard let selected = try CopilotSetupCommandLine.executable(arguments: arguments) else {
                    throw CopilotSetupCommandLine.Failure.usage
                }
                let result = await CopilotSetupCommandLine.install(selected: selected)
                let output = result == .installed ? FileHandle.standardOutput : FileHandle.standardError
                output.write(Data((result.message + "\n").utf8))
                exit(result == .installed ? 0 : 1)
            } catch {
                FileHandle.standardError.write(Data((CopilotSetupCommandLine.usage + "\n").utf8))
                exit(2)
            }
        }
        dispatchMain()
    }
}

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
