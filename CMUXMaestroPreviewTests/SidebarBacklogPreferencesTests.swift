import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct SidebarBacklogPreferencesTests {
    @Test func exactIdentitiesPersistThroughFreshReadersAndReplacementStartsUnconfigured() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let a = UUID(), b = UUID(), replacement = UUID()
        let preferences = fixture.preferences()
        let history = preferences.history, attention = preferences.attention, layout = preferences.layout
        let file = fixture.root.appendingPathComponent("sidebar-backlog.json")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        preferences.setBacklogURL(" https://example.com/a?filter=open#work ", for: a)
        preferences.setBacklogURL("https://example.org/b", for: b)
        let fresh = fixture.preferences()
        #expect(fresh.backlog.urlText(for: a) == "https://example.com/a?filter=open#work")
        #expect(fresh.backlog.urlText(for: b) == "https://example.org/b")
        #expect(fresh.backlog.urlText(for: replacement) == nil)
        #expect(fresh.history == history && fresh.attention == attention && fresh.layout == layout)
        let persisted = try JSONDecoder().decode(SidebarBacklogSettings.self, from: Data(contentsOf: file))
        #expect(persisted.urls.count == 2)
        #expect(persisted.urlText(for: a) == "https://example.com/a?filter=open#work")
    }

    @Test func twoWindowsMergeChangesAndRemovalAffectsOnlyExactWorkspace() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let a = UUID(), b = UUID()
        let first = fixture.preferences(), second = fixture.preferences()
        first.setBacklogURL("https://example.com/a", for: a)
        second.setBacklogURL("https://example.org/b", for: b)
        #expect(first.backlog == second.backlog)
        #expect(first.backlog.urls.count == 2)
        first.setBacklogURL("", for: a)
        #expect(second.backlog.urlText(for: a) == nil)
        #expect(second.backlog.urlText(for: b) == "https://example.org/b")
        #expect(fixture.preferences().backlog == second.backlog)
    }

    @Test(arguments: ["garbage", #"{"version":999,"urls":{}}"#,
                      #"{"version":1,"urls":{"friendly-name":"https://example.com"}}"#])
    func unreadableFilesArePreservedUntilExplicitReset(contents: String) throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let file = fixture.root.appendingPathComponent("sidebar-backlog.json")
        let bytes = Data(contents.utf8)
        try bytes.write(to: file)
        let preferences = fixture.preferences()
        #expect(preferences.backlogNotice != nil)
        preferences.setBacklogURL("https://example.com/valid", for: UUID())
        #expect(preferences.backlogNotice != nil)
        #expect(try Data(contentsOf: file) == bytes)
        preferences.resetBacklogs()
        #expect(preferences.backlogNotice == nil)
        #expect(fixture.preferences().backlog.urls.isEmpty)
    }

    @Test func invalidInputAndFailedSavePreserveSavedBindings() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let id = UUID()
        let preferences = fixture.preferences()
        preferences.setBacklogURL("https://example.com/saved", for: id)
        let file = fixture.root.appendingPathComponent("sidebar-backlog.json")
        let bytes = try Data(contentsOf: file)
        preferences.setBacklogURL("not a URL", for: id)
        #expect(preferences.backlogNotice == SidebarBacklogSettings.invalidNotice)
        #expect(preferences.backlog.urlText(for: id) == "https://example.com/saved")
        #expect(try Data(contentsOf: file) == bytes)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.root.path) }
        preferences.setBacklogURL("https://example.com/replacement", for: id)
        #expect(preferences.backlogNotice == SidebarBacklogSettings.saveNotice)
        #expect(preferences.backlog.urlText(for: id) == "https://example.com/saved")
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func storageBoundsNeverEvictOtherWorkspaceURLs() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        var settings = SidebarBacklogSettings()
        for _ in 0..<SidebarBacklogSettings.maximumEntries {
            try settings.setURL("https://example.com", for: UUID())
        }
        let file = fixture.root.appendingPathComponent("sidebar-backlog.json")
        try JSONEncoder().encode(settings).write(to: file)
        let preferences = fixture.preferences()
        preferences.setBacklogURL("https://example.org", for: UUID())
        #expect(preferences.backlogNotice != nil)
        #expect(preferences.backlog == settings)
        #expect(fixture.preferences().backlog == settings)
    }
}
