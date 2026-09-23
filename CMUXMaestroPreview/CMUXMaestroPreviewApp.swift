import SwiftUI
import Darwin

@main
struct CMUXMaestroPreviewApp: App {
    private let setupRequested: Bool

    init() {
        let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        setupRequested = arguments.contains(CopilotSetupCommandLine.installFlag)
        guard setupRequested else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task {
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
    }

    var body: some Scene {
        #if !CMUX_VALIDATION
        if !setupRequested {
            WindowGroup {
                ContentView()
            }
        }
        #endif
        // Validation keeps the same Settings entry point without opening setup windows.
        Settings {
            MaestroSettingsView()
        }
    }
}
