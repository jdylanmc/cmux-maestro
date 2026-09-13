import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct SidebarPreferencesTests {
    @Test
    func exposesExactlyTheTwoSidebarChoices() {
        #expect(SidebarMode.allCases.map(\.title) == ["Hierarchy", "Taskboard"])
    }

    @Test
    func defaultsToHierarchy() throws {
        try withIsolatedDefaults { defaults, file, attentionFile, layoutStore in
            #expect(SidebarPreferences(defaults: defaults, historyFile: file, attentionFile: attentionFile, layoutStore: layoutStore).selectedMode == .hierarchy)
        }
    }

    @Test
    func switchesImmediatelyWithoutChangingAnyConnectionState() throws {
        try withIsolatedDefaults { defaults, file, attentionFile, layoutStore in
            let preferences = SidebarPreferences(defaults: defaults, historyFile: file, attentionFile: attentionFile, layoutStore: layoutStore)
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
        try withIsolatedDefaults { defaults, file, attentionFile, layoutStore in
            let original = SidebarPreferences(defaults: defaults, historyFile: file, attentionFile: attentionFile, layoutStore: layoutStore)
            original.selectedMode = .taskboard

            let reconstructed = SidebarPreferences(defaults: defaults, historyFile: file, attentionFile: attentionFile, layoutStore: layoutStore)

            #expect(reconstructed.selectedMode == .taskboard)
        }
    }

    @Test
    func invalidPersistedValueFallsBackToHierarchy() throws {
        try withIsolatedDefaults { defaults, file, attentionFile, layoutStore in
            defaults.set("unknown-mode", forKey: "sidebar.selectedMode")

            #expect(SidebarPreferences(defaults: defaults, historyFile: file, attentionFile: attentionFile, layoutStore: layoutStore).selectedMode == .hierarchy)
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults, URL, URL, SidebarLayoutStore) -> Void) throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        body(fixture.defaults, fixture.historyFile, fixture.attentionFile, .init(file: .init(url: fixture.layoutFile)))
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
