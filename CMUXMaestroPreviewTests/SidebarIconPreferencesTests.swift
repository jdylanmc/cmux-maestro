import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct SidebarIconPreferencesTests {
    private let standard = SidebarIconChoice(glyph: "md-robot", color: .theme)
    private let agent = SidebarIconChoice(glyph: "md-duck", color: .teal)
    private let human = SidebarIconChoice(glyph: "md-bird", color: .purple)

    @Test func humanHexColorDecodesAndWritesCanonicalOpaqueSRGB() throws {
        let color = try JSONDecoder().decode(SidebarAvatarColor.self, from: Data("\"#a1b2c3\"".utf8))
        #expect(color.rawValue == "#A1B2C3")
        #expect(String(data: try JSONEncoder().encode(color), encoding: .utf8) == "\"#A1B2C3\"")
        for value in ["#ABC", "#11223344", "112233", "#GG0000", " #112233", "#１２３４５６"] {
            let data = try JSONEncoder().encode(value)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(SidebarAvatarColor.self, from: data) }
        }
        #expect(try JSONDecoder().decode(SidebarAvatarColor.self, from: Data(#""teal""#.utf8)) == .teal)
    }

    @Test func legacyIconsUpgradeOnlyOnWriteAndCustomColorsSurviveBothResets() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let target = SidebarIconTarget.session(UUID())
        let file = fixture.root.appendingPathComponent("sidebar-icons.json")
        let legacy = Data("""
        {"version":1,"overrides":{"\(target.key)":{"custom":{"_0":{"glyph":"md-duck","color":"teal"}}}}}
        """.utf8)
        try legacy.write(to: file)
        let preferences = fixture.preferences()
        #expect(preferences.iconNotice == nil)
        #expect(preferences.icons.resolve(target: target, standard: standard, agent: nil).choice == agent)
        #expect(try Data(contentsOf: file) == legacy)
        let color = try #require(SidebarAvatarColor(rawValue: "#fedcba"))
        let custom = SidebarIconChoice(glyph: "md-bird", color: color)
        preferences.setIcon(custom, for: target)
        let stored = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(stored["version"] as? Int == 2)
        #expect(fixture.preferences().icons.resolve(target: target, standard: standard, agent: agent).choice == custom)
        preferences.resetIconToDefault(for: target)
        #expect(fixture.preferences().icons.resolve(target: target, standard: standard, agent: agent).choice == standard)
        preferences.setIcon(custom, for: target)
        preferences.resetIconToAgentSelection(for: target)
        #expect(fixture.preferences().icons.resolve(target: target, standard: standard, agent: agent).choice == agent)
    }

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
        let key = SidebarIconTarget.session(UUID()).key
        let invalidColor = Data("""
        {"version":2,"overrides":{"\(key)":{"custom":{"_0":{"glyph":"md-duck","color":"#ABC"}}}}}
        """.utf8)
        let unversionedCustom = Data("""
        {"version":1,"overrides":{"\(key)":{"custom":{"_0":{"glyph":"md-duck","color":"#112233"}}}}}
        """.utf8)
        for data in [Data("broken".utf8), Data(#"{"version":999,"overrides":{}}"#.utf8), invalidColor, unversionedCustom] {
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
