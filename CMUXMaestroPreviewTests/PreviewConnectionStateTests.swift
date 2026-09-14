import AppKit
import Testing
@testable import CMUXMaestroPreview

struct PreviewConnectionStateTests {
    @MainActor
    @Test
    func validationHostCannotOfferInstallationOrOpenASetupWindow() {
        #expect(!CopilotSetupAccess.currentAppAllowsChanges)
        #expect(NSApplication.shared.windows.filter(\.isVisible).isEmpty)
    }

    @Test
    func exposesAllVisibleBootstrapStates() {
        #expect(PreviewConnectionState.allCases.map(\.title) == [
            "Waiting",
            "Connected",
            "Degraded",
        ])
    }

    @Test
    func everyStateHasDistinctPresentation() {
        let states = PreviewConnectionState.allCases

        #expect(Set(states.map(\.detail)).count == states.count)
        #expect(Set(states.map(\.symbolName)).count == states.count)
    }
}
