import Darwin
import Foundation
import LocalAuthentication
import Security
import SwiftUI

nonisolated enum NativeChildAuthorization {
    static let keyTag = Data("com.jdylanmc.CMUXMaestroPreview.native-child-policy.v1".utf8)
    static let policyDisclosure = "Authorize this actor only, in this coordinator run and workspace, to launch "
        + "future workers with different tasks and labels under this exact directory, "
        + "pinned account/model and requested tool-policy snapshot. Known denies remain; "
        + "full native parent policy is unknown and native restrictions remain authoritative. "
        + "Each launch needs its own one-time ticket. No existing worker is changed."
    enum Failure: Error { case unavailable, invalid }

    struct Request: Identifiable {
        let id: String
        let data: Data
        let display: String
    }

    static func validate(_ data: Data, id: String, at date: Date = Date()) throws -> Request {
        guard data.count <= 49_152, UUID(uuidString: id)?.uuidString.lowercased() == id,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == ["version", "requestId", "actor", "parentToolPolicy", "workerId",
                  "sessionId", "launchSettings", "toolPolicy", "mode", "parentPolicy", "cwd",
                  "name", "task", "createdAt", "expiresAt", "workerGeneration",
                  "approvalScope", "disclosure", "policyScope", "policyGrantId"],
              value["version"] as? Int == 2, value["requestId"] as? String == id,
              value["approvalScope"] as? String == "run-policy",
              value["disclosure"] as? String == policyDisclosure,
              value["policyGrantId"] is NSNull,
              value["mode"] as? String == "interactive-exact-tools",
              value["parentPolicy"] as? String == "unknown-human-fallback",
              value["workerGeneration"] as? Int == 1,
              let created = value["createdAt"] as? String,
              let expires = value["expiresAt"] as? String else { throw Failure.invalid }
        guard let scope = value["policyScope"] as? [String: Any],
              Set(scope.keys) == ["actor", "actorAuthority", "coordinator", "coordinatorAuthority",
                  "workspaceId", "cwd", "parentToolPolicy", "launchSettings", "toolPolicy", "setupId"],
              let actor = scope["actor"] as? [String: Any],
              let coordinator = scope["coordinator"] as? [String: Any],
              validIdentity(actor), validIdentity(coordinator),
              coordinator["sessionId"] is NSNull, coordinator["generation"] as? Int == 0,
              actor["runId"] as? String == coordinator["runId"] as? String,
              let cwd = scope["cwd"] as? String, cwd.hasPrefix("/"),
              let settings = value["launchSettings"] as? [String: Any],
              Set(settings.keys) == ["version", "copilotAccount", "model"],
              let decoded = try? JSONDecoder().decode(
                WorkerLaunchSettings.self, from: JSONSerialization.data(withJSONObject: settings)
              ), decoded.isValid, decoded.copilotAccount != nil, decoded.model != nil else { throw Failure.invalid }
        for field in ["actor", "parentToolPolicy", "launchSettings", "toolPolicy", "cwd"] {
            guard let signed = value[field] as? NSObject,
                  let scoped = scope[field] as? NSObject, signed == scoped else { throw Failure.invalid }
        }
        for field in ["actorAuthority", "coordinatorAuthority"] {
            guard let digest = scope[field] as? String,
                  digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw Failure.invalid }
        }
        for field in ["workspaceId", "setupId"] {
            guard validUUID(scope[field]) else { throw Failure.invalid }
        }
        for field in ["workerId", "sessionId"] {
            guard validUUID(value[field]) else { throw Failure.invalid }
        }
        for field in ["parentToolPolicy", "toolPolicy"] {
            guard let policy = value[field] as? [String: Any], Set(policy.keys) == ["allow", "deny"],
                  policy["allow"] is [String], policy["deny"] is [String] else { throw Failure.invalid }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let start = formatter.date(from: created) ?? plain.date(from: created),
              let end = formatter.date(from: expires) ?? plain.date(from: expires),
              start <= date, date < end, abs(end.timeIntervalSince(start) - 600) < 0.001,
              let display = String(data: data, encoding: .utf8) else { throw Failure.invalid }
        return Request(id: id, data: data, display: display)
    }

    private static func validUUID(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func validIdentity(_ value: [String: Any]) -> Bool {
        Set(value.keys) == ["nodeId", "sessionId", "generation", "runId"]
            && validUUID(value["nodeId"]) && validUUID(value["runId"])
            && (value["sessionId"] is NSNull || validUUID(value["sessionId"]))
            && (value["generation"] as? Int).map { $0 >= 0 } == true
    }

    static func requests(root: URL) throws -> [Request] {
        let directory = try CopilotFileAccess.openDirectory(
            root.appendingPathComponent("control", isDirectory: true), owner: getuid()
        )
        defer { close(directory) }
        let names = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("control").path
        ).filter { $0.hasPrefix("native-request-") && $0.hasSuffix(".json") }
        guard names.count <= 16 else { throw Failure.invalid }
        return try names.sorted().map { name in
            let id = String(name.dropFirst("native-request-".count).dropLast(5))
            let data = try CopilotFileAccess.readStableRegular(
                at: directory, filename: name, owner: getuid(), maximum: 49_152, permissions: 0o600
            )
            // Expired requests are still displayed for explicit dismissal, never signing.
            guard UUID(uuidString: id)?.uuidString.lowercased() == id,
                  let text = String(data: data, encoding: .utf8) else { throw Failure.invalid }
            return Request(id: id, data: data, display: (try? validate(data, id: id).display) ?? text)
        }
    }

    private static func key(create: Bool) throws -> SecKey {
        guard NativeSigningReadiness.current else { throw Failure.unavailable }
        let authentication = LAContext()
        authentication.interactionNotAllowed = !create
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnRef as String: true,
            kSecUseAuthenticationContext as String: authentication,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let result {
            let key = result as! SecKey
            guard let attributes = SecKeyCopyAttributes(key) as? [String: Any],
                  attributes[kSecAttrTokenID as String] as? String == kSecAttrTokenIDSecureEnclave as String
            else { throw Failure.unavailable }
            return key
        }
        guard create, status == errSecItemNotFound else { throw Failure.unavailable }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &error
        ), let key = SecKeyCreateRandomKey([
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain as String: true,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrAccessControl as String: access,
            ],
        ] as CFDictionary, &error) else { throw Failure.unavailable }
        return key
    }

    static func approve(_ displayed: Request, root: URL) throws {
        guard NativeSigningReadiness.current else { throw Failure.unavailable }
        let request = try validate(displayed.data, id: displayed.id)
        let directory = try HookFiles.privateDirectory(root.appendingPathComponent("control"))
        defer { close(directory) }
        let current = try CopilotFileAccess.readStableRegular(
            at: directory, filename: "native-request-\(request.id).json", owner: getuid(),
            maximum: 49_152, permissions: 0o600
        )
        guard current == displayed.data else { throw Failure.invalid }
        var error: Unmanaged<CFError>?
        // The non-exportable signing key requires OS-mediated user presence.
        // No command-line approval entry point and no software-key fallback exist.
        guard let signature = SecKeyCreateSignature(
            try key(create: true), .ecdsaSignatureMessageX962SHA256, request.data as CFData, &error
        ) as Data? else { throw Failure.unavailable }
        _ = try validate(request.data, id: request.id)
        let receipt = try JSONSerialization.data(withJSONObject: [
            "request": request.data.base64EncodedString(),
            "signature": signature.base64EncodedString(),
        ], options: [.sortedKeys])
        try HookFiles.atomicWrite(receipt, name: "native-approval-\(request.id).json", directory: directory)
    }

    static func verify(_ receipt: Data) -> Bool {
        guard NativeSigningReadiness.current, receipt.count <= 70_000,
              let value = try? JSONSerialization.jsonObject(with: receipt) as? [String: String],
              Set(value.keys) == ["request", "signature"],
              let data = Data(base64Encoded: value["request"] ?? ""),
              let signature = Data(base64Encoded: value["signature"] ?? ""),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["requestId"] as? String,
              (try? validate(data, id: id)) != nil,
              let privateKey = try? key(create: false),
              let publicKey = SecKeyCopyPublicKey(privateKey) else { return false }
        return SecKeyVerifySignature(
            publicKey, .ecdsaSignatureMessageX962SHA256, data as CFData, signature as CFData, nil
        )
    }

    static func dismiss(_ request: Request, root: URL) throws {
        guard UUID(uuidString: request.id)?.uuidString.lowercased() == request.id else { throw Failure.invalid }
        let directory = try HookFiles.privateDirectory(root.appendingPathComponent("control"))
        defer { close(directory) }
        for prefix in ["native-request-", "native-approval-"] {
            if unlinkat(directory, "\(prefix)\(request.id).json", 0) != 0 && errno != ENOENT {
                throw Failure.unavailable
            }
        }
    }
}

struct NativeChildAuthorizationView: View {
    @State private var requests: [NativeChildAuthorization.Request] = []
    @State private var selected: NativeChildAuthorization.Request?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading) {
            Text("Native messaging child authorization").font(.headline)
            Text("Full parent policy is unavailable. Human authorization is an actor-specific run-policy snapshot, not live policy synchronization. Known denies and native managed restrictions remain. No allow-all, path or URL emulation.")
                .font(.caption)
            HStack {
                Button("Refresh requests", action: refresh)
                if let notice { Text(notice).font(.caption) }
            }
            ForEach(requests) { request in
                Button("Review \(request.id)") { selected = request }
            }
        }
        .sheet(item: $selected) { request in
            VStack(alignment: .leading, spacing: 12) {
                Text("Authorize this actor’s run-policy snapshot?").font(.headline)
                Text(NativeChildAuthorization.policyDisclosure).font(.caption)
                ScrollView { Text(request.display).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                Text("Signing requires macOS user presence. This pending request expires in ten minutes; its first launch activates reusable consent for this exact actor, run and policy. Future matching tasks and labels need no further authentication, but each launch consumes a fresh one-time ticket. New runs or changed scopes require fresh consent. Disable setup, archive or recover to invalidate reuse. Signing is not task completion or a native permission callback.")
                    .font(.caption)
                HStack {
                    Button("Authorize run policy…") {
                        perform { try NativeChildAuthorization.approve(request, root: $0) }
                    }.disabled(!NativeSigningReadiness.current || (try? NativeChildAuthorization.validate(request.data, id: request.id)) == nil)
                    Button("Dismiss request", role: .destructive) {
                        perform { try NativeChildAuthorization.dismiss(request, root: $0) }
                    }
                    Button("Cancel") { selected = nil }
                }
            }.padding().frame(width: 680, height: 580)
        }
    }

    private func perform(_ operation: (URL) throws -> Void) {
        do {
            try operation(CopilotPaths.orchestrationRoot())
            selected = nil
            refresh()
            notice = "Request updated. No session was launched."
        } catch {
            notice = "Authorization unavailable, expired, changed or cancelled. Nothing was launched."
        }
    }

    private func refresh() {
        guard NativeSigningReadiness.current else {
            requests = []
            notice = NativeSigningReadiness.unsupported
            return
        }
        do {
            requests = try NativeChildAuthorization.requests(root: CopilotPaths.orchestrationRoot())
            notice = requests.isEmpty ? "No pending requests." : nil
        } catch {
            notice = "Requests could not be read safely."
        }
    }
}
