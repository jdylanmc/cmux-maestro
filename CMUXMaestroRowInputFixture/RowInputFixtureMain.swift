import AppKit
import Darwin

/// This executable has no setup, saved-state, preference, or production-app entry point.
@main
enum RowInputFixtureMain {
    @MainActor
    static func main() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true",
              environment["RUNNER_ENVIRONMENT"] == "github-hosted",
              Bundle.main.bundleIdentifier == "com.jdylanmc.CMUXMaestroPreview.Validation.RowInputFixture",
              let value = environment["CMUX_ROW_INPUT_CASE"], let caseID = UUID(uuidString: value) else {
            FileHandle.standardError.write(Data("Row input fixture requires the isolated hosted UI-test venue.\n".utf8))
            exit(78)
        }
        let application = NSApplication.shared
        let fixture = RowInputFixture(caseID: caseID)
        application.delegate = fixture
        withExtendedLifetime(fixture) { application.run() }
    }
}
