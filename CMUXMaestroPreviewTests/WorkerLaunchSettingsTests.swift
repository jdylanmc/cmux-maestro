import Foundation
import Testing
@testable import CMUXMaestroPreview

struct WorkerLaunchSettingsTests {
    @Test func defaultsAreUnpinnedAndStoredPreferencesContainNoCredential() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/worker-launch-tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try WorkerLaunchSettings.load(from: root) == .init())
        let chosen = WorkerLaunchSettings(copilotAccount: "work-user", model: "example-large-model")
        try chosen.save(to: root)
        #expect(try WorkerLaunchSettings.load(from: root) == chosen)
        let file = root.appendingPathComponent("worker-settings.json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(Set(object.keys) == ["version", "copilotAccount", "model"])
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func invalidPreferencesCannotReplacePreviousSelection() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/worker-launch-tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = WorkerLaunchSettings(copilotAccount: "work-user", model: nil)
        try original.save(to: root)
        #expect(throws: (any Error).self) {
            try WorkerLaunchSettings(copilotAccount: "--show-token", model: nil).save(to: root)
        }
        #expect(try WorkerLaunchSettings.load(from: root) == original)
        try Data(#"{"version":1,"token":"not-a-supported-setting"}"#.utf8)
            .write(to: root.appendingPathComponent("worker-settings.json"))
        #expect(throws: (any Error).self) { try WorkerLaunchSettings.load(from: root) }
    }
}
