import SwiftUI
import Darwin
import Dispatch

@main
enum CMUXMaestroEntryPoint {
    @MainActor
    static func main() {
        let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        guard arguments.contains(CopilotSetupCommandLine.installFlag)
            || arguments.contains(CopilotSetupCommandLine.bridgeFlag)
            || arguments.contains(MaestroAppLifecycleCommandLine.flag) else {
            CMUXMaestroPreviewApp.main()
            return
        }
        Task { @MainActor in
            do {
                if let request = try MaestroAppLifecycleCommandLine.request(arguments) {
                    let completion = await MaestroAppLifecycleCommandLine.perform(request)
                    let output = completion.useStandardOutput ? FileHandle.standardOutput : FileHandle.standardError
                    output.write(Data(completion.text.utf8))
                    exit(completion.exitCode)
                }
                if let request = try CopilotSetupCommandLine.bridge(arguments: arguments) {
                    let completion = await CopilotSetupCommandLine.coordinate(request)
                    let output = completion.useStandardOutput ? FileHandle.standardOutput : FileHandle.standardError
                    output.write(Data(completion.text.utf8))
                    exit(completion.exitCode)
                }
                guard let selected = try CopilotSetupCommandLine.executable(arguments: arguments) else {
                    throw CopilotSetupCommandLine.Failure.usage
                }
                let result = await CopilotSetupCommandLine.install(selected: selected)
                let completion = CopilotSetupCommandLine.completion(result)
                let output = completion.useStandardOutput ? FileHandle.standardOutput : FileHandle.standardError
                output.write(Data(completion.text.utf8))
                exit(completion.exitCode)
            } catch {
                let completion = CopilotSetupCommandLine.usageCompletion
                FileHandle.standardError.write(Data(completion.text.utf8))
                exit(completion.exitCode)
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
