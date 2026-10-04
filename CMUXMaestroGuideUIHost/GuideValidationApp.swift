import SwiftUI

#if !CMUX_GUIDE_UI_VALIDATION
#error("The synthetic guide host requires its dedicated validation target.")
#endif

@main
struct GuideValidationApp: App {
    init() {
        let environment = ProcessInfo.processInfo.environment
        precondition(
            Bundle.main.bundleIdentifier == "com.jdylanmc.CMUXMaestroPreview.Validation.Tests.GuideHost"
                && environment["GITHUB_ACTIONS"] == "true"
                && environment["RUNNER_ENVIRONMENT"] == "github-hosted",
            "Synthetic guide presentation is restricted to isolated GitHub-hosted CI."
        )
    }

    var body: some Scene {
        Window("Synthetic CLI guide validation", id: "guide-validation-window") {
            GuideValidationContent()
        }
        .windowResizability(.contentSize)
    }
}
