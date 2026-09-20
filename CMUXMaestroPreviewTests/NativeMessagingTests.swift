import Foundation
import Testing
@testable import CMUXMaestroPreview

@Suite struct NativeMessagingTests {
    private func request(id: String, mode: String = "interactive-exact-tools") throws -> Data {
        let actor: [String: Any] = ["nodeId": id, "runId": id, "sessionId": NSNull(), "generation": 0]
        let settings: [String: Any] = ["version": 1, "copilotAccount": "example-user", "model": "example-model"]
        let policy = ["allow": ["read"], "deny": ["web"]]
        let scope: [String: Any] = [
            "actor": actor, "coordinator": actor,
            "actorAuthority": String(repeating: "a", count: 64),
            "coordinatorAuthority": String(repeating: "a", count: 64),
            "workspaceId": id, "setupId": id, "cwd": "/explicit/target",
            "launchSettings": settings, "parentToolPolicy": policy, "toolPolicy": policy,
        ]
        return try JSONSerialization.data(withJSONObject: [
            "version": 2, "requestId": id, "actor": actor, "parentToolPolicy": policy,
            "approvalScope": "run-policy", "disclosure": NativeChildAuthorization.policyDisclosure,
            "policyScope": scope, "policyGrantId": NSNull(),
            "workerId": id, "sessionId": id, "launchSettings": settings, "toolPolicy": policy,
            "workerGeneration": 1,
            "mode": mode, "parentPolicy": "unknown-human-fallback",
            "cwd": "/explicit/target", "name": "Worker", "task": "Bounded task",
            "createdAt": "2026-09-20T00:00:00+00:00",
            "expiresAt": "2026-09-20T00:10:00+00:00",
        ], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    @Test func reusableScopeRequiresExplicitDisclosureAndMatchingSnapshot() throws {
        let id = UUID().uuidString.lowercased()
        let now = ISO8601DateFormatter().date(from: "2026-09-20T00:05:00Z")!
        let original = try JSONSerialization.jsonObject(with: request(id: id)) as! [String: Any]
        for (key, value): (String, Any) in [
            ("version", 1), ("approvalScope", "once"), ("disclosure", "This child only"),
            ("policyGrantId", id), ("cwd", "/changed"),
            ("launchSettings", ["version": 1, "copilotAccount": "changed", "model": "changed"]),
            ("toolPolicy", ["allow": ["write"], "deny": []]),
        ] {
            var changed = original
            changed[key] = value
            #expect(throws: (any Error).self) {
                try NativeChildAuthorization.validate(
                    JSONSerialization.data(withJSONObject: changed), id: id, at: now
                )
            }
        }
        #expect(NativeChildAuthorization.policyDisclosure.contains("future workers with different tasks and labels"))
        #expect(NativeChildAuthorization.policyDisclosure.contains("this actor only"))
        #expect(NativeChildAuthorization.policyDisclosure.contains("No existing worker is changed"))
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
        #expect(!NativeSigningReadiness.current)
        #expect(!NativeChildAuthorization.verify(Data(#"{"request":"","signature":""}"#.utf8)))
        #expect(throws: (any Error).self) {
            try NativeMessagingSetup.setEnabled(true)
        }
    }

    @Test func signingQualificationRequiresAuthenticatedMatchingMetadata() {
        let team = "SYNTHETIC1"
        let id = NativeSigningReadiness.appID
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let certificate = Data("synthetic certificate, not credentials".utf8)
        let entitlements: [String: Any] = [
            "com.apple.application-identifier": "\(team).\(id)",
            "com.apple.developer.team-identifier": team,
            "keychain-access-groups": ["\(team).\(id)"],
        ]
        let profile: [String: Any] = [
            "TeamIdentifier": [team], "ApplicationIdentifierPrefix": [team],
            "CreationDate": now.addingTimeInterval(-60), "ExpirationDate": now.addingTimeInterval(60),
            "DeveloperCertificates": [certificate], "Entitlements": entitlements,
        ]
        func qualifies(signed: Bool = true, adHoc: Bool = false, signedID: String? = nil,
                       signedTeam: String = team, e: [String: Any]? = nil, p: [String: Any]? = nil,
                       cert: Data = certificate) -> Bool {
            NativeSigningReadiness.eligible(.init(
                identifier: signedID ?? id, team: signedTeam, signed: signed, adHoc: adHoc,
                entitlements: e ?? entitlements, profile: p ?? profile, certificate: cert
            ), identifier: id, keychain: true, at: now)
        }
        #expect(qualifies())
        #expect(!qualifies(signed: false))
        #expect(!qualifies(adHoc: true))
        #expect(!qualifies(e: [:]))
        #expect(!qualifies(p: [:]))
        #expect(!qualifies(signedID: id + ".Validation.Tests"))
        #expect(!qualifies(signedTeam: "OTHERTEAM1"))
        #expect(!qualifies(cert: Data("wrong certificate".utf8)))
        var changed = profile
        changed["ExpirationDate"] = now
        #expect(!qualifies(p: changed))
        changed = profile
        changed["TeamIdentifier"] = ["OTHERTEAM1"]
        #expect(!qualifies(p: changed))
        changed = profile
        changed["Entitlements"] = [
            "com.apple.application-identifier": "\(team).\(id).Extension",
            "com.apple.developer.team-identifier": team,
            "keychain-access-groups": ["\(team).*"],
        ]
        #expect(!qualifies(p: changed))
        var wrongGroup = entitlements
        wrongGroup["keychain-access-groups"] = ["\(team).*"]
        #expect(!qualifies(e: wrongGroup))
        wrongGroup["keychain-access-groups"] = ["\(team).unrelated"]
        #expect(!qualifies(e: wrongGroup))

        var sidebar = entitlements
        sidebar["com.apple.application-identifier"] = "\(team).\(id).Extension"
        sidebar.removeValue(forKey: "keychain-access-groups")
        sidebar["com.apple.security.app-sandbox"] = true
        changed = profile
        changed["Entitlements"] = sidebar
        #expect(NativeSigningReadiness.eligible(.init(
            identifier: id + ".Extension", team: team, signed: true, adHoc: false,
            entitlements: sidebar, profile: changed, certificate: certificate
        ), identifier: id + ".Extension", keychain: false, at: now))
    }
}
