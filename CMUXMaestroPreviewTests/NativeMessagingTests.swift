import Foundation
import LocalAuthentication
import Security
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
        let id = UUID().uuidString.lowercased()
        let data = try request(id: id)
        let displayed = NativeChildAuthorization.Request(id: id, data: data, display: String(decoding: data, as: UTF8.self))
        // Readiness must fail before touching even this nonexistent, checkout-local fixture path.
        #expect(throws: NativeChildAuthorization.failure(NativeChildAuthorization.Failure.unavailable, stage: .readiness)) {
            try NativeChildAuthorization.approve(displayed, root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/setup-tests/never-created-approval-root"))
        }
    }

    @Test func reviewStatesUseSigningValidationWithoutPromotingReuseOrLegacy() throws {
        let id = UUID().uuidString.lowercased()
        let now = ISO8601DateFormatter().date(from: "2026-09-20T00:05:00Z")!
        let original = try JSONSerialization.jsonObject(with: request(id: id)) as! [String: Any]
        func displayed(_ value: [String: Any]) throws -> NativeChildAuthorization.Request {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            return .init(id: id, data: data, display: String(decoding: data, as: UTF8.self))
        }
        var pending = try displayed(original)
        #expect(pending.status(at: now) == .pending)
        #expect(pending.status(at: now.addingTimeInterval(300)) == .expired)
        #expect(pending.status(at: now.addingTimeInterval(-301)) == .notYetValid)
        pending.receiptState = .matching
        #expect(pending.status(at: now) == .receiptPresent)
        #expect(pending.status(at: now.addingTimeInterval(300)) == .expired)
        pending.receiptState = .problem
        #expect(pending.status(at: now) == .receiptProblem)
        var reuse = original
        reuse["policyGrantId"] = UUID().uuidString.lowercased()
        let ticket = try displayed(reuse)
        #expect(ticket.status(at: now) == .reuseReady)
        #expect(ticket.status(at: now.addingTimeInterval(300)) == .expired)
        #expect(throws: (any Error).self) { try NativeChildAuthorization.validate(ticket.data, id: id, at: now) }
        reuse["cwd"] = "/different"
        #expect(try displayed(reuse).status(at: now) == .unsupported)
        for (key, value): (String, Any) in [
            ("version", 1), ("approvalScope", "once"), ("disclosure", "untrusted instructions"),
            ("policyGrantId", "not-a-uuid"), ("mode", "allow-all"),
            ("expiresAt", "2026-09-20T00:20:00Z"), ("cwd", "/different"),
        ] {
            var changed = original
            changed[key] = value
            let candidate = try displayed(changed)
            #expect(candidate.status(at: now) == (key == "version" ? .legacy : .unsupported))
            #expect(throws: (any Error).self) { try NativeChildAuthorization.validate(candidate.data, id: id, at: now) }
        }
    }

    @Test func labelsAreBoundedMetadataAndPolicySummaryRetainsExactScope() throws {
        let id = UUID().uuidString.lowercased()
        let data = try request(id: id)
        let displayed = NativeChildAuthorization.Request(id: id, data: data, display: String(decoding: data, as: UTF8.self))
        #expect(displayed.label == "Worker")
        let summary = Dictionary(uniqueKeysWithValues: NativeChildAuthorization.policySummary(displayed).map { ($0.title, $0.value) })
        #expect(summary["Directory"] == "/explicit/target")
        #expect(summary["Pinned account / model"] == "example-user / example-model")
        #expect(summary["Requested allows"] == "\"read\"")
        #expect(summary["Requested denies"] == "\"web\"")
        #expect(summary["Known parent denies"] == "\"web\"")
        #expect(summary["Actor only"]?.contains(id) == true)
        #expect(summary["Coordinator"]?.contains("Session none · generation 0") == true)
        #expect(summary["Run"] == id)
        #expect(summary["Workspace"] == id)
        #expect(displayed.data == data)
        #expect(displayed.display.data(using: .utf8) == data)
        #expect(NativeChildAuthorization.labelText(" \u{202E}Worker\n\u{0} ") == "Worker")
        #expect(NativeChildAuthorization.labelText(String(repeating: "x", count: 101)) == String(repeating: "x", count: 100) + "…")
        #expect(NativeChildAuthorization.visibleText("a\n\u{202E}b") == #"a\u{a}\u{202e}b"#)
        #expect(NativeChildAuthorization.visibleText(#"\u{a}"#) != NativeChildAuthorization.visibleText("\n"))
        var value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        value["name"] = "\n"
        value["task"] = "Task label"
        let fallback = try JSONSerialization.data(withJSONObject: value)
        #expect(NativeChildAuthorization.Request(id: id, data: fallback, display: "").label == "Task label")
        var scope = value["policyScope"] as! [String: Any]
        scope["toolPolicy"] = ["allow": [], "deny": ["shell(a,b)", "read\nwrite"]]
        value["policyScope"] = scope
        let unusual = try JSONSerialization.data(withJSONObject: value)
        let fields = NativeChildAuthorization.policySummary(.init(id: id, data: unusual, display: ""))
        #expect(fields.first { $0.title == "Requested allows" }?.value == "None explicitly listed")
        #expect(fields.first { $0.title == "Requested denies" }?.value == "\"shell(a,b)\"\n\"read\\\\u{a}write\"")
    }

    @Test func receiptPresenceIsNotSignatureVerificationOrApprovalSuccess() throws {
        let id = UUID().uuidString.lowercased()
        let data = try request(id: id)
        let displayed = NativeChildAuthorization.Request(id: id, data: data, display: "")
        let receipt = try JSONSerialization.data(withJSONObject: [
            "request": data.base64EncodedString(), "signature": Data("synthetic-not-a-signature".utf8).base64EncodedString(),
        ])
        #expect(NativeChildAuthorization.receiptMatches(receipt, request: displayed))
        #expect(!NativeChildAuthorization.verify(receipt))
        #expect(!NativeChildAuthorization.receiptMatches(receipt, request: .init(id: id, data: Data("changed".utf8), display: "")))
        #expect(!NativeChildAuthorization.receiptMatches(Data(#"{"request":"","signature":""}"#.utf8), request: displayed))
        #expect(!NativeChildAuthorization.receiptMatches(Data(repeating: 0, count: 70_001), request: displayed))
    }

    @Test func requestDiscoveryRetainsFixturesAndRejectsUnsafeReceiptReadback() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/setup-tests/approval-fixtures-\(UUID().uuidString)")
        let control = root.appendingPathComponent("control")
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ data: Data, name: String) throws {
            let url = control.appendingPathComponent(name)
            try data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let id = UUID().uuidString.lowercased()
        let data = try request(id: id)
        try write(data, name: "native-request-\(id).json")
        var found = try NativeChildAuthorization.requests(root: root)
        #expect(found.count == 1)
        #expect(found[0].receiptState == .absent)
        let receiptName = "native-approval-\(id).json"
        let receipt = try JSONSerialization.data(withJSONObject: [
            "request": data.base64EncodedString(), "signature": Data("synthetic-not-a-signature".utf8).base64EncodedString(),
        ])
        try write(receipt, name: receiptName)
        found = try NativeChildAuthorization.requests(root: root)
        #expect(found[0].receiptState == .matching)
        #expect(found[0].data == data)
        let receiptURL = control.appendingPathComponent(receiptName)
        try FileManager.default.removeItem(at: receiptURL)
        try FileManager.default.createSymbolicLink(atPath: receiptURL.path,
                                                  withDestinationPath: "native-request-\(id).json")
        found = try NativeChildAuthorization.requests(root: root)
        #expect(found[0].receiptState == .problem)
        #expect(try FileManager.default.contentsOfDirectory(atPath: control.path).count == 2)
        #expect(try Data(contentsOf: control.appendingPathComponent("native-request-\(id).json")) == data)
        try NativeChildAuthorization.dismiss(found[0], root: root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: control.path).isEmpty)
    }

    @Test func approvalOutcomeRequiresExactReceiptReadbackAndPreservesFailureStage() throws {
        let receipt = Data("synthetic receipt; no key or disk access".utf8)
        var written: Data?
        let outcome = try NativeChildAuthorization.persistReceipt(receipt, write: { written = $0 }, read: {
            #expect(written == receipt)
            return receipt
        })
        #expect(outcome == .approved)
        #expect(outcome.message.contains("ready for launch"))
        #expect(outcome.message.contains("No worker was launched"))
        #expect(!NativeChildAuthorization.Outcome.removed.message.contains("approved"))
        #expect(NativeChildAuthorization.Outcome.removed.message.contains("not revoked"))
        var readCalled = false
        #expect(throws: NativeChildAuthorization.failure(CopilotFileError.permissionDenied, stage: .receiptWrite)) {
            try NativeChildAuthorization.persistReceipt(receipt, write: { _ in throw CopilotFileError.permissionDenied }, read: {
                readCalled = true
                return receipt
            })
        }
        #expect(!readCalled)
        #expect(throws: NativeChildAuthorization.failure(CopilotFileError.unsafePath, stage: .receiptReadback)) {
            try NativeChildAuthorization.persistReceipt(receipt, write: { _ in }, read: { throw CopilotFileError.unsafePath })
        }
        #expect(throws: NativeChildAuthorization.failure(NativeChildAuthorization.Failure.invalid, stage: .receiptReadback)) {
            try NativeChildAuthorization.persistReceipt(receipt, write: { _ in }, read: { Data("different receipt".utf8) })
        }
    }

    @Test func approvalErrorsExposeSafeStageCodesNotBackendDetails() {
        let cancelled = NativeChildAuthorization.systemFailure(stage: .signing, domain: NSOSStatusErrorDomain, code: Int(errSecUserCanceled))
        #expect(cancelled.cancelled)
        #expect(cancelled.message.contains("cancelled"))
        #expect(cancelled.message.contains("[signing/osstatus:"))
        #expect(!cancelled.message.contains("ready for launch"))
        #expect(NativeChildAuthorization.failure(cancelled, stage: .validation) == cancelled)
        for code in [LAError.userCancel.rawValue, LAError.systemCancel.rawValue, LAError.appCancel.rawValue] {
            #expect(NativeChildAuthorization.systemFailure(stage: .keyAccess, domain: LAError.errorDomain, code: code).cancelled)
        }
        let denied = NativeChildAuthorization.systemFailure(stage: .keyAccess, domain: NSOSStatusErrorDomain, code: Int(errSecAuthFailed))
        #expect(!denied.cancelled)
        #expect(denied.message.contains("protected signing key"))
        let unknown = NativeChildAuthorization.systemFailure(stage: .signing, domain: "private-backend-dump", code: -2)
        #expect(!unknown.cancelled)
        #expect(unknown.code == "system:-2")
        #expect(!unknown.message.contains("private-backend-dump"))
        let backend = NSError(domain: "secret-domain", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-key-material"])
        #expect(!NativeChildAuthorization.failure(backend, stage: .receiptWrite).message.contains("private-key-material"))
        let messages: [NativeChildAuthorization.Stage: String] = [
            .readiness: "Signing is unavailable", .validation: "invalid, unsupported or changed",
            .requestRead: "read safely", .keyAccess: "protected signing key", .signing: "did not complete signing",
            .receiptWrite: "could not be saved", .receiptReadback: "A receipt may exist", .removal: "Some files may remain",
        ]
        for (stage, text) in messages {
            let failure = NativeChildAuthorization.failure(NativeChildAuthorization.Failure.unavailable, stage: stage)
            #expect(failure.message.contains(text))
            #expect(failure.message.contains("[\(stage.rawValue)/"))
            #expect(!failure.message.contains("ready for launch"))
        }
        #expect(NativeChildAuthorization.failure(NativeChildAuthorization.Failure.expired, stage: .validation).message.contains("Prepare a fresh request"))
    }

    @Test func routineSetupAndApprovalHaveStableAccessibilityTargets() throws {
        // Source contract only; installed-app AX exposure still needs live verification.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let approval = try String(contentsOf: root.appendingPathComponent("CMUXMaestroPreview/Integration/NativeChildAuthorization.swift"), encoding: .utf8)
        let setup = try String(contentsOf: root.appendingPathComponent("CMUXMaestroPreview/ContentView.swift"), encoding: .utf8)
        for identifier in ["native-authorization-refresh", "native-authorization-result",
                           "native-authorization-status", "native-authorization-details",
                           "native-authorization-error", "native-authorization-approve",
                           "native-authorization-remove", "native-authorization-back"] {
            #expect(approval.components(separatedBy: ".accessibilityIdentifier(\"\(identifier)\")").count == 2)
        }
        #expect(approval.contains(#".accessibilityIdentifier("native-authorization-review-\(request.id)")"#))
        #expect(approval.contains(#".accessibilityValue("\(status.rawValue). Request \(request.id)")"#))
        for label in ["Refresh native authorization requests", "Full run-policy request details",
                      "Authorize this actor's run policy", "Remove request and receipt",
                      "Back to requests without approving"] {
            #expect(approval.contains(".accessibilityLabel(\"\(label)\")"))
        }
        for identifier in ["copilot-setup-choose-executable", "copilot-setup-enable", "copilot-setup-uninstall",
                           "copilot-setup-cancel-running", "native-setup-enable", "native-setup-disable",
                           "native-setup-result", "agent-launch-settings", "copilot-setup-confirm-install",
                           "copilot-setup-confirm-uninstall", "copilot-setup-cancel-confirmation",
                           "native-setup-confirm-enable", "native-setup-confirm-disable", "native-setup-cancel-confirmation"] {
            #expect(setup.components(separatedBy: "\"\(identifier)\"").count == 2)
        }
        #expect(setup.contains(#".accessibilityLabel(action == .install ? "Confirm installation of Native Plugin" : "Confirm removal of Native Plugin")"#))
        #expect(setup.contains(#".accessibilityLabel(nativeSetup == true ? "Confirm enabling Native Messaging" : "Confirm disabling Native Messaging")"#))
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
