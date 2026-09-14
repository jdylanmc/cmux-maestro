import Foundation

struct SidebarPreferenceFixture {
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    var historyFile: URL { root.appendingPathComponent("history.json") }
    var attentionFile: URL { root.appendingPathComponent("attention.json") }
    var layoutFile: URL { root.appendingPathComponent("layout.json") }

    @MainActor
    func preferences(historyFile: URL? = nil, attentionFile: URL? = nil, layoutFile: URL? = nil) -> SidebarPreferences {
        SidebarPreferences(
            defaults: defaults, historyFile: historyFile ?? self.historyFile,
            attentionFile: attentionFile ?? self.attentionFile,
            layoutStore: .init(file: .init(url: layoutFile ?? self.layoutFile))
        )
    }

    init() throws {
        suiteName = "SidebarPreferenceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/preference-coordination/fixtures/\(suiteName)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
