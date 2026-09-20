import Darwin
import Foundation
import LocalAuthentication
import Security
import SwiftUI

nonisolated enum NativeChildAuthorization {
    static let keyTag = Data("com.jdylanmc.CMUXMaestroPreview.native-child-policy.v1".utf8)
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
                  "name", "task", "createdAt", "expiresAt", "workerGeneration"],
              value["version"] as? Int == 1, value["requestId"] as? String == id,
              value["mode"] as? String == "interactive-exact-tools",
              value["parentPolicy"] as? String == "unknown-human-fallback",
              value["workerGeneration"] as? Int == 1,
              let created = value["createdAt"] as? String,
              let expires = value["expiresAt"] as? String else { throw Failure.invalid }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let start = formatter.date(from: created) ?? plain.date(from: created),
              let end = formatter.date(from: expires) ?? plain.date(from: expires),
              start <= date, date < end, abs(end.timeIntervalSince(start) - 600) < 0.001,
              let display = String(data: data, encoding: .utf8) else { throw Failure.invalid }
        return Request(id: id, data: data, display: display)
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
        let authentication = LAContext()
        authentication.interactionNotAllowed = !create
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
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
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrAccessControl as String: access,
            ],
        ] as CFDictionary, &error) else { throw Failure.unavailable }
        return key
    }

    static func approve(_ displayed: Request, root: URL) throws {
        guard CopilotSetupAccess.currentAppAllowsChanges else { throw Failure.unavailable }
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
        guard CopilotSetupAccess.currentAppAllowsChanges, receipt.count <= 70_000,
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
            Text("Full parent policy is unavailable. Authorize only this displayed child policy and exact target. Known denies remain; native managed restrictions still apply. Future parent changes affect future launches only. No allow-all, path or URL emulation.")
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
                Text("Authorize this exact launch?").font(.headline)
                ScrollView { Text(request.display).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                Text("Signing requires macOS user presence. This expires in ten minutes and can launch once. Signing is not a task-completion or permission-approval callback.")
                    .font(.caption)
                HStack {
                    Button("Authorize once…") {
                        perform { try NativeChildAuthorization.approve(request, root: $0) }
                    }
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
        do {
            requests = try NativeChildAuthorization.requests(root: CopilotPaths.orchestrationRoot())
            notice = requests.isEmpty ? "No pending requests." : nil
        } catch {
            notice = "Requests could not be read safely."
        }
    }
}
