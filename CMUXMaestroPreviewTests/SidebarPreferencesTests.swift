import Foundation
import Testing

@MainActor
struct SidebarPreferencesTests {
    @Test
    func exposesExactlyTheTwoSidebarChoices() {
        #expect(SidebarMode.allCases.map(\.title) == ["Hierarchy", "Taskboard"])
    }

    @Test
    func defaultsToHierarchy() {
        withIsolatedDefaults { defaults in
            #expect(SidebarPreferences(defaults: defaults).selectedMode == .hierarchy)
        }
    }

    @Test
    func switchesImmediatelyWithoutChangingAnyConnectionState() {
        withIsolatedDefaults { defaults in
            let preferences = SidebarPreferences(defaults: defaults)
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
    func persistsThroughReconstruction() {
        withIsolatedDefaults { defaults in
            let original = SidebarPreferences(defaults: defaults)
            original.selectedMode = .taskboard

            let reconstructed = SidebarPreferences(defaults: defaults)

            #expect(reconstructed.selectedMode == .taskboard)
        }
    }

    @Test
    func invalidPersistedValueFallsBackToHierarchy() {
        withIsolatedDefaults { defaults in
            defaults.set("unknown-mode", forKey: "sidebar.selectedMode")

            #expect(SidebarPreferences(defaults: defaults).selectedMode == .hierarchy)
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "SidebarPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
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
