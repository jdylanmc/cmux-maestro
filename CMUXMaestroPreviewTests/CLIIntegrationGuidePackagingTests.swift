import CryptoKit
import Foundation
import Testing
@testable import CMUXMaestroPreview

struct CLIIntegrationGuidePackagingTests {
    @Test func appBundleContainsCurrentDigestsButNotGuideBodies() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let baseline = try CLIIntegrationGuideChecker.bundledBaseline()
        let object = try #require(JSONSerialization.jsonObject(with: baseline) as? [String: Any])
        #expect(Set(object.keys) == ["version", "files"])
        #expect(object["version"] as? Int == 1)
        let files = try #require(object["files"] as? [String: String])
        #expect(Set(files.keys) == ["SKILL.md", "intent.md"])
        for name in ["SKILL.md", "intent.md"] {
            let canonical = try Data(contentsOf: root.appendingPathComponent("skills/maestro/\(name)"))
            let expected = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
            #expect(files[name] == expected)
            #expect(!String(decoding: baseline, as: UTF8.self).contains(String(decoding: canonical, as: UTF8.self)))
        }
        #expect(baseline.count < 1024)
        let resources = try #require(Bundle.main.resourceURL)
        #expect(!FileManager.default.fileExists(atPath: resources.appendingPathComponent("maestro/SKILL.md").path))
        #expect(!FileManager.default.fileExists(atPath: resources.appendingPathComponent("intent.md").path))
        let bundledLifecycle = try Data(contentsOf: resources.appendingPathComponent("SKILL.md"))
        let guide = try Data(contentsOf: root.appendingPathComponent("skills/maestro/SKILL.md"))
        #expect(bundledLifecycle != guide)
    }
}
