import Foundation
import Testing
@testable import CMUXMaestroPreview

@Suite struct NativeMessagingTests {
    private func request(id: String, mode: String = "interactive-exact-tools") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": 1, "requestId": id, "actor": [:], "parentToolPolicy": [:],
            "workerId": id, "sessionId": id, "launchSettings": [:], "toolPolicy": [:],
            "workerGeneration": 1,
            "mode": mode, "parentPolicy": "unknown-human-fallback",
            "cwd": "/explicit/target", "name": "Worker", "task": "Bounded task",
            "createdAt": "2026-09-20T00:00:00+00:00",
            "expiresAt": "2026-09-20T00:10:00+00:00",
        ], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    @Test func approvalBindsExactDisplayedBytesAndExpiry() throws {
        let id = UUID().uuidString.lowercased()
        let data = try request(id: id)
        let now = ISO8601DateFormatter().date(from: "2026-09-20T00:05:00Z")!
        let parsed = try NativeChildAuthorization.validate(data, id: id, at: now)
        #expect(parsed.data == data)
        #expect(parsed.display.data(using: .utf8) == data)
        #expect(parsed.display.contains("/explicit/target"))
        #expect(throws: (any Error).self) {
            try NativeChildAuthorization.validate(data, id: UUID().uuidString.lowercased(), at: now)
        }
        #expect(throws: (any Error).self) {
            try NativeChildAuthorization.validate(data, id: id, at: now.addingTimeInterval(301))
        }
        #expect(throws: (any Error).self) {
            try NativeChildAuthorization.validate(request(id: id, mode: "allow-all"), id: id, at: now)
        }
    }

    @Test func validationCopyCannotApproveOrVerify() throws {
        #expect(!NativeChildAuthorization.verify(Data(#"{"request":"","signature":""}"#.utf8)))
        #expect(throws: (any Error).self) {
            try NativeMessagingSetup.setEnabled(true)
        }
    }
}
