import Foundation
import Testing

@MainActor
struct SidebarPreferencesTests {
    @Test
    func exposesExactlyTheTwoSidebarChoices() {
        #expect(SidebarMode.allCases.map(\.title) == ["Hierarchy", "Taskboard"])
    }

    @Test
    func defaultsToHierarchy() throws {
        try withIsolatedDefaults { defaults, file in
            #expect(SidebarPreferences(defaults: defaults, historyFile: file).selectedMode == .hierarchy)
        }
    }

    @Test
    func switchesImmediatelyWithoutChangingAnyConnectionState() throws {
        try withIsolatedDefaults { defaults, file in
            let preferences = SidebarPreferences(defaults: defaults, historyFile: file)
            let connection = SidebarConnectionModel()
            let states: [SidebarConnectionState] = [
                .waiting,
                .connected(workspaceCount: 2, surfaceCount: 3),
                .degraded(message: "Host unavailable"),
            ]

            for (index, state) in states.enumerated() {
                set(state, on: connection)
                preferences.selectedMode = index.isMultiple(of: 2) ? .taskboard : .hierarchy

                #expect(preferences.selectedMode == (index.isMultiple(of: 2) ? .taskboard : .hierarchy))
                #expect(connection.state == state)
            }
        }
    }

    @Test
    func persistsThroughReconstruction() throws {
        try withIsolatedDefaults { defaults, file in
            let original = SidebarPreferences(defaults: defaults, historyFile: file)
            original.selectedMode = .taskboard

            let reconstructed = SidebarPreferences(defaults: defaults, historyFile: file)

            #expect(reconstructed.selectedMode == .taskboard)
        }
    }

    @Test
    func invalidPersistedValueFallsBackToHierarchy() throws {
        try withIsolatedDefaults { defaults, file in
            defaults.set("unknown-mode", forKey: "sidebar.selectedMode")

            #expect(SidebarPreferences(defaults: defaults, historyFile: file).selectedMode == .hierarchy)
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults, URL) -> Void) throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        body(fixture.defaults, fixture.historyFile)
    }

    private func set(_ state: SidebarConnectionState, on connection: SidebarConnectionModel) {
        switch state {
        case .waiting:
            connection.showWaiting()
        case .connected(let workspaceCount, let surfaceCount):
            connection.showConnected(
                workspaceCount: workspaceCount,
                surfaceCount: surfaceCount
            )
        case .degraded(let message):
            connection.showDegraded(message: message)
        }
    }
}
