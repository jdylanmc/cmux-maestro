import Testing
@testable import CMUXMaestroPreview

struct PreviewConnectionStateTests {
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
