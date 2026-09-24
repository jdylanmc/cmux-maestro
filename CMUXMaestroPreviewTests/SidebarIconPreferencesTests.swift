import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct SidebarIconPreferencesTests {
    private let standard = SidebarIconChoice(glyph: "md-robot", color: .theme)
    private let agent = SidebarIconChoice(glyph: "md-duck", color: .teal)
    private let human = SidebarIconChoice(glyph: "md-bird", color: .purple)

    @Test func humanOverrideAndBothResetsHaveDistinctPrecedence() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let target = SidebarIconTarget.session(UUID())
        #expect(preferences.icons.resolve(target: target, standard: standard, agent: agent).choice == agent)
        preferences.setIcon(human, for: target)
        let updatedAgent = SidebarIconChoice(glyph: "fa-ship", color: .red)
        #expect(preferences.icons.resolve(target: target, standard: standard, agent: updatedAgent).choice == human)
        #expect(preferences.icons.resolve(target: target, standard: standard, agent: updatedAgent).source == "Your choice")
        preferences.resetIconToDefault(for: target)
        #expect(preferences.icons.resolve(target: target, standard: standard, agent: updatedAgent).choice == standard)
        #expect(preferences.icons.resolve(target: target, standard: standard, agent: updatedAgent).source == "Default")
        preferences.resetIconToAgentSelection(for: target)
        #expect(preferences.icons.resolve(target: target, standard: standard, agent: updatedAgent).choice == updatedAgent)
        #expect(preferences.icons.resolve(target: target, standard: standard, agent: nil).choice == standard)
    }

    @Test func stableTypedIdentitiesPersistWithoutAffectingOtherPreferencesOrReplacementSessions() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let id = UUID(), replacement = UUID()
        let session = SidebarIconTarget.session(id), surface = SidebarIconTarget.surface(id)
        let history = preferences.history, attention = preferences.attention, layout = preferences.layout
        let mode = preferences.selectedMode
        preferences.setIcon(human, for: session)
        preferences.setIcon(agent, for: surface)
        let reconstructed = fixture.preferences()
        #expect(reconstructed.icons.resolve(target: session, standard: standard, agent: nil).choice == human)
        #expect(reconstructed.icons.resolve(target: surface, standard: standard, agent: nil).choice == agent)
        #expect(reconstructed.icons.resolve(target: .session(replacement), standard: standard, agent: nil).choice == standard)
        #expect(preferences.history == history && preferences.attention == attention && preferences.layout == layout)
        #expect(preferences.selectedMode == mode)
        preferences.resetIconToDefault(for: surface)
        #expect(preferences.icons.overrides[surface.key] == nil)
        #expect(preferences.icons.overrides[session.key] == .custom(human))
    }

    @Test func separateWindowsMergeChoicesAndConvergeWithoutStaleSnapshotWrites() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let first = fixture.preferences(), second = fixture.preferences()
        let a = SidebarIconTarget.session(UUID()), b = SidebarIconTarget.surface(UUID())
        first.setIcon(human, for: a)
        second.setIcon(agent, for: b)
        #expect(first.icons == second.icons)
        #expect(first.icons.overrides.count == 2)
        first.resetIconToDefault(for: a)
        #expect(second.icons.overrides[a.key] == .standard)
        #expect(second.icons.overrides[b.key] == .custom(agent))
        second.resetIconToAgentSelection(for: a)
        #expect(first.icons.overrides[a.key] == nil)
        #expect(first.icons.overrides[b.key] == .custom(agent))
    }

    @Test func iconStorageIsReadOnlyUntilAnExplicitAction() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let file = fixture.root.appendingPathComponent("sidebar-icons.json")
        let preferences = fixture.preferences()
        _ = preferences.icons
        preferences.refreshIcons()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        preferences.setIcon(human, for: .session(UUID()))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func unreadableOrFuturePreferencesArePreservedUntilGlobalExplicitReset() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let file = fixture.root.appendingPathComponent("sidebar-icons.json")
        for data in [Data("broken".utf8), Data(#"{"version":999,"overrides":{}}"#.utf8)] {
            try data.write(to: file)
            let preferences = fixture.preferences()
            #expect(preferences.iconNotice != nil)
            let target = SidebarIconTarget.session(UUID())
            preferences.setIcon(human, for: target)
            preferences.resetIconToDefault(for: target)
            #expect(try Data(contentsOf: file) == data)
            #expect(preferences.iconNotice != nil)
            preferences.resetIcons()
            #expect(preferences.iconNotice == nil)
            #expect(preferences.icons.overrides.isEmpty)
        }
    }

    @Test func writeFailuresAndInvalidInputsAreVisible() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let blocked = fixture.root.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: blocked)
        let preferences = SidebarPreferences(
            defaults: fixture.defaults, historyFile: fixture.historyFile, attentionFile: fixture.attentionFile,
            layoutStore: .init(file: .init(url: fixture.layoutFile)),
            iconFile: blocked.appendingPathComponent("icons.json")
        )
        preferences.setIcon(human, for: .session(UUID()))
        #expect(preferences.iconNotice == SidebarIconSettings.saveNotice)
        #expect(try Data(contentsOf: blocked) == Data("keep".utf8))
        let normal = fixture.preferences()
        normal.setIcon(.init(glyph: "../../bad", color: .theme), for: .session(UUID()))
        #expect(normal.iconNotice != nil)
        #expect(normal.icons.overrides.isEmpty)
        normal.resetIconToAgentSelection(for: .surface(UUID()))
        #expect(normal.iconNotice != nil)
    }

    @Test func storageBoundsAndKeyValidationAreEnforced() throws {
        var settings = SidebarIconSettings()
        for _ in 0..<SidebarIconSettings.maximumEntries {
            settings.overrides[SidebarIconTarget.session(UUID()).key] = .custom(human)
        }

        #expect(settings.isValid)
        #expect(try JSONEncoder().encode(settings).count < SidebarIconSettings.maximumStoredBytes)
        settings.overrides[SidebarIconTarget.session(UUID()).key] = .standard
        #expect(!settings.isValid)
        settings = .init()
        for key in ["pane:0", "session:Friendly name", "surface:../../bad", "session:\(UUID()):extra"] {
            settings.overrides = [key: .standard]
            #expect(!settings.isValid)
        }
    }

    @Test func failedSavePreservesExistingHumanChoicesInEveryWindowAndOnDisk() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let first = fixture.preferences(), second = fixture.preferences()
        let custom = SidebarIconTarget.session(UUID()), standardTarget = SidebarIconTarget.session(UUID())
        let another = SidebarIconTarget.surface(UUID())
        first.setIcon(human, for: custom)
        first.resetIconToDefault(for: standardTarget)
        let previous = first.icons
        let file = fixture.root.appendingPathComponent("sidebar-icons.json")
        let previousData = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.root.path) }
        second.setIcon(agent, for: another)
        #expect(second.iconNotice == SidebarIconSettings.saveNotice)
        #expect(first.iconNotice == SidebarIconSettings.saveNotice)
        #expect(first.icons == previous && second.icons == previous)
        #expect(first.icons.resolve(target: custom, standard: standard, agent: agent).choice == human)
        #expect(first.icons.resolve(target: standardTarget, standard: standard, agent: agent).choice == standard)
        #expect(try Data(contentsOf: file) == previousData)
        first.resetIcons()
        #expect(first.icons == previous && second.icons == previous)
        #expect(first.iconNotice == SidebarIconSettings.saveNotice)
        #expect(try Data(contentsOf: file) == previousData)
    }

    @Test func managedIdentityUsesExactSessionAndNeverNodeOrPaneFallback() {
        let sessionID = UUID()
        let node = SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: nil, role: "worker", label: "Same label",
            workspaceId: UUID(), surfaceId: UUID(), generation: 3, phase: "turn-running",
            availability: "busy", copilotSessionId: sessionID, createdAt: Date(), updatedAt: Date()
        )
        let empty = SidebarCopilotTree(availability: .unavailable, sessions: [], issues: [], generatedAt: nil)
        #expect(SidebarPresentation.managedIconTarget(node, tree: empty, now: Date()) == .session(sessionID))
        let unknown = SidebarOrchestrationNode(
            id: node.id, runId: node.runId, parentId: nil, role: "worker", label: node.label,
            workspaceId: node.workspaceId, surfaceId: node.surfaceId, generation: 4,
            phase: "launching", availability: "busy", createdAt: Date(), updatedAt: Date()
        )
        #expect(SidebarPresentation.managedIconTarget(unknown, tree: empty, now: Date()) == nil)
    }
}
