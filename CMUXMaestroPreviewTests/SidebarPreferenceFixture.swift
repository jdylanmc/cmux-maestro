import Foundation

struct SidebarPreferenceFixture {
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    var historyFile: URL { root.appendingPathComponent("history.json") }

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
