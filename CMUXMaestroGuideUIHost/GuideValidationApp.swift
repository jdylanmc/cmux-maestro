import SwiftUI

#if !CMUX_GUIDE_UI_VALIDATION
#error("The synthetic guide host requires its dedicated validation target.")
#endif

@main
struct GuideValidationApp {
    @MainActor static func main() {
        let environment = ProcessInfo.processInfo.environment
        precondition(
            Bundle.main.bundleIdentifier == "com.jdylanmc.CMUXMaestroPreview.Validation.Tests.GuideHost"
                && environment["GITHUB_ACTIONS"] == "true"
                && environment["RUNNER_ENVIRONMENT"] == "github-hosted",
            "Synthetic guide presentation is restricted to isolated GitHub-hosted CI."
        )
        if environment["CMUX_GUIDE_ACCEPTANCE_CASE"] != nil {
            GuideAcceptanceApplication.main()
        } else {
            GuideReadinessApplication.main()
        }
    }
}

struct GuideReadinessApplication: App {
    var body: some Scene {
        Window("Synthetic CLI guide validation", id: "guide-validation-window") {
            GuideValidationContent()
        }
        .windowResizability(.contentSize)
    }
}

struct GuideAcceptanceApplication: App {
    @NSApplicationDelegateAdaptor(GuideValidationDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class GuideValidationDelegate: NSObject, NSApplicationDelegate {
    private var fixture: GuideAcceptanceFixture?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CMUX_GUIDE_ACCEPTANCE_CASE"] != nil else { return }
        do {
            let fixture = try GuideAcceptanceFixture(environment: environment)
            self.fixture = fixture
            fixture.start()
        } catch {
            // A malformed launch must never open the ordinary readiness window as a fallback.
            fatalError("Invalid acceptance fixture launch: \(error)")
        }
    }
}
