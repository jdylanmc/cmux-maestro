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
    enum Failure: Error { case unavailable, invalid, expired, notYetValid }

    enum Stage: String {
        case readiness, validation, requestRead = "request-read", keyAccess = "key-access"
        case signing, receiptWrite = "receipt-write", receiptReadback = "receipt-readback", removal
    }

    struct ApprovalFailure: Error, Equatable {
        let stage: Stage
        let code: String
        let cancelled: Bool

        var message: String {
            let explanation: String
            if cancelled {
                explanation = "macOS authentication was cancelled. No new approval was saved. Try again when ready."
            } else {
                switch stage {
                case .readiness:
                    explanation = "Signing is unavailable in this app or device. Use the qualified installed app and check Native Messaging setup."
                case .validation:
                    switch code {
                    case "expired": explanation = "This request expired. Prepare a fresh request, then refresh."
                    case "not-yet-valid": explanation = "This request is not yet valid. Check its dates and refresh."
                    default: explanation = "This request is invalid, unsupported or changed. Prepare a fresh request, then refresh."
                    }
                case .requestRead:
                    explanation = "The pending request could not be read safely. Refresh before retrying."
                case .keyAccess:
                    explanation = "macOS could not access or create the protected signing key. Check device authentication and try again."
                case .signing:
                    explanation = "macOS did not complete signing. No new approval was saved. Try again when ready."
                case .receiptWrite:
                    explanation = "Approval could not be saved. Check access to the control directory, then refresh before retrying."
                case .receiptReadback:
                    explanation = "Approval persistence could not be confirmed. A receipt may exist; refresh before retrying. Do not assume approval succeeded."
                case .removal:
                    explanation = "Removal could not be completed. Some files may remain; refresh to check."
                }
            }
            return "\(explanation) [\(stage.rawValue)/\(code)]"
        }
    }

    static func failure(_ error: any Error, stage: Stage) -> ApprovalFailure {
        if let failure = error as? ApprovalFailure { return failure }
        let code: String
        switch error {
        case Failure.expired: code = "expired"
        case Failure.notYetValid: code = "not-yet-valid"
        case Failure.invalid: code = "invalid-or-changed"
        case Failure.unavailable: code = "unavailable"
        case let error as CopilotFileError:
            switch error {
            case .missing: code = "missing"
            case .permissionDenied: code = "permission-denied"
            case .unsafePath: code = "unsafe-path"
            case .tooLarge: code = "too-large"
            case .changed: code = "changed"
            case .io: code = "io"
            }
        default: code = "unavailable"
        }
        return ApprovalFailure(stage: stage, code: code, cancelled: false)
    }

    // Report only allowlisted domains and numeric status, never backend descriptions/userInfo.
    static func systemFailure(stage: Stage, domain: String, code: Int) -> ApprovalFailure {
        let security = domain == NSOSStatusErrorDomain
        let authentication = domain == LAError.errorDomain
        let cancelled = (security && code == Int(errSecUserCanceled))
            || (authentication && [LAError.userCancel.rawValue, LAError.systemCancel.rawValue,
                                   LAError.appCancel.rawValue].contains(code))
        return ApprovalFailure(stage: stage,
                               code: "\(security ? "osstatus" : authentication ? "la" : "system"):\(code)",
                               cancelled: cancelled)
    }

    private static func systemFailure(stage: Stage, error: Unmanaged<CFError>?) -> ApprovalFailure {
        guard let error = error?.takeRetainedValue() else {
            return failure(Failure.unavailable, stage: stage)
        }
        return systemFailure(stage: stage, domain: CFErrorGetDomain(error) as String,
                             code: CFErrorGetCode(error))
    }

    private static func atStage<T>(_ stage: Stage, _ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch { throw failure(error, stage: stage) }
    }

    enum RequestStatus: String {
        case pending = "Needs run-policy approval"
        case expired = "Expired — prepare a fresh request"
        case notYetValid = "Not yet valid"
        case legacy = "Legacy v1 — cannot approve"
        case unsupported = "Unsupported or invalid — cannot approve"
        case reuseReady = "Reuse-ready ticket — no signing needed"
        case receiptPresent = "Receipt present — controller checks required"
        case receiptProblem = "Receipt unreadable or mismatched — refresh or prepare anew"
    }

    enum ReceiptState { case absent, matching, problem }

    struct Request: Identifiable {
        let id: String
        let data: Data
        let display: String
        var receiptState: ReceiptState = .absent

        var label: String {
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            for key in ["name", "task"] {
                if let text = value?[key] as? String {
                    let cleaned = NativeChildAuthorization.labelText(text)
                    if !cleaned.isEmpty { return cleaned }
                }
            }
            return "Worker request"
        }

        func status(at date: Date = Date()) -> RequestStatus {
            do {
                _ = try NativeChildAuthorization.validatePayload(data, id: id, at: date, allowReuse: true)
                let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if value?["policyGrantId"] is String { return .reuseReady }
                switch receiptState {
                case .absent: return .pending
                case .matching: return .receiptPresent
                case .problem: return .receiptProblem
                }
            } catch Failure.expired { return .expired }
            catch Failure.notYetValid { return .notYetValid }
            catch {
                let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                return value?["version"] as? Int == 1 ? .legacy : .unsupported
            }
        }
    }

    // Same bounded control/bidi filtering as sidebar metadata; labels are not authority.
    static func labelText(_ value: String) -> String {
        let cleaned = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}").contains($0)
        }
        let text = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces)
        return String(text.prefix(100)) + (text.count > 100 ? "…" : "")
    }

    static func validate(_ data: Data, id: String, at date: Date = Date()) throws -> Request {
        try validatePayload(data, id: id, at: date, allowReuse: false)
    }

    private static func validatePayload(_ data: Data, id: String, at date: Date,
                                        allowReuse: Bool) throws -> Request {
        guard data.count <= 49_152, UUID(uuidString: id)?.uuidString.lowercased() == id,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == ["version", "requestId", "actor", "parentToolPolicy", "workerId",
                  "sessionId", "launchSettings", "toolPolicy", "mode", "parentPolicy", "cwd",
                  "name", "task", "createdAt", "expiresAt", "workerGeneration",
                  "approvalScope", "disclosure", "policyScope", "policyGrantId"],
              value["version"] as? Int == 2, value["requestId"] as? String == id,
              value["approvalScope"] as? String == "run-policy",
              value["disclosure"] as? String == policyDisclosure,
              value["policyGrantId"] is NSNull || (allowReuse && validUUID(value["policyGrantId"])),
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
              abs(end.timeIntervalSince(start) - 600) < 0.001,
              let display = String(data: data, encoding: .utf8) else { throw Failure.invalid }
        guard date < end else { throw Failure.expired }
        guard start <= date else { throw Failure.notYetValid }
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

    struct SummaryField: Identifiable {
        let title: String
        let value: String
        var id: String { title }
    }

    static func policySummary(_ request: Request) -> [SummaryField] {
        guard let value = (try? JSONSerialization.jsonObject(with: request.data)) as? [String: Any],
              let scope = value["policyScope"] as? [String: Any],
              let settings = scope["launchSettings"] as? [String: Any],
              let policy = scope["toolPolicy"] as? [String: Any],
              let parent = scope["parentToolPolicy"] as? [String: Any],
              let actor = scope["actor"] as? [String: Any],
              let coordinator = scope["coordinator"] as? [String: Any] else { return [] }
        func text(_ item: Any?) -> String {
            guard let string = item as? String else { return "Unavailable" }
            return visibleText(string)
        }
        func tools(_ item: Any?) -> String {
            guard let values = item as? [String] else { return "Unavailable" }
            // Quote each literal tool selector so commas, whitespace and newlines cannot hide scope.
            return values.isEmpty ? "None explicitly listed" : values.map {
                String(reflecting: visibleText($0))
            }.joined(separator: "\n")
        }
        func identity(_ item: [String: Any]) -> String {
            let session = item["sessionId"] is NSNull ? "none" : text(item["sessionId"])
            let generation = (item["generation"] as? Int).map(String.init) ?? "Unavailable"
            return "Node \(text(item["nodeId"]))\nSession \(session) · generation \(generation)"
        }
        return [
            .init(title: "Directory", value: text(scope["cwd"])),
            .init(title: "Pinned account / model", value: "\(text(settings["copilotAccount"])) / \(text(settings["model"]))"),
            .init(title: "Requested allows", value: tools(policy["allow"])),
            .init(title: "Requested denies", value: tools(policy["deny"])),
            .init(title: "Known parent allows", value: tools(parent["allow"])),
            .init(title: "Known parent denies", value: tools(parent["deny"])),
            .init(title: "Actor only", value: identity(actor)),
            .init(title: "Coordinator", value: identity(coordinator)),
            .init(title: "Run", value: text(actor["runId"])),
            .init(title: "Workspace", value: text(scope["workspaceId"])),
            .init(title: "Request expires", value: text(value["expiresAt"])),
        ]
    }

    // Unlike short labels, exact details never silently omit control/bidi characters or truncate.
    static func visibleText(_ value: String) -> String {
        value.unicodeScalars.map {
            if $0 == "\\" { return "\\\\" }
            if CharacterSet.controlCharacters.contains($0)
                || CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}").contains($0) {
                return "\\u{\(String($0.value, radix: 16))}"
            }
            return String($0)
        }.joined()
    }

    static func receiptMatches(_ receipt: Data, request: Request) -> Bool {
        guard receipt.count <= 70_000,
              let value = (try? JSONSerialization.jsonObject(with: receipt)) as? [String: String],
              Set(value.keys) == ["request", "signature"],
              let data = Data(base64Encoded: value["request"] ?? ""),
              let signature = Data(base64Encoded: value["signature"] ?? ""),
              !signature.isEmpty else { return false }
        return data == request.data
    }

    private static func receiptState(for request: Request, directory: Int32) -> ReceiptState {
        do {
            let receipt = try CopilotFileAccess.readStableRegular(
                at: directory, filename: "native-approval-\(request.id).json", owner: getuid(),
                maximum: 70_000, permissions: 0o600
            )
            // Presence/exact binding only, not signature validity or controller admission.
            return receiptMatches(receipt, request: request) ? .matching : .problem
        } catch CopilotFileError.missing { return .absent }
        catch { return .problem }
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
            // Retain stale and handled requests for explicit review/removal, never automatic pruning.
            guard UUID(uuidString: id)?.uuidString.lowercased() == id,
                  let text = String(data: data, encoding: .utf8) else { throw Failure.invalid }
            var request = Request(id: id, data: data, display: text)
            request.receiptState = receiptState(for: request, directory: directory)
            return request
        }
    }

    private static func key(create: Bool) throws -> SecKey {
        guard NativeSigningReadiness.current else { throw failure(Failure.unavailable, stage: .readiness) }
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
            else { throw failure(Failure.unavailable, stage: .keyAccess) }
            return key
        }
        guard create, status == errSecItemNotFound else {
            throw systemFailure(stage: .keyAccess, domain: NSOSStatusErrorDomain, code: Int(status))
        }
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
        ] as CFDictionary, &error) else { throw systemFailure(stage: .keyAccess, error: error) }
        return key
    }

    enum Outcome {
        case approved, removed

        var message: String {
            switch self {
            case .approved: "Run policy approved — ready for launch. Approval saved and read back exactly. No worker was launched; controller checks still apply."
            case .removed: "Request and any receipt removed. No worker was launched. Active run-policy grants were not revoked."
            }
        }
    }

    // The UI receives success only after an exact, bounded, descriptor-relative read-back.
    static func persistReceipt(_ receipt: Data, write: (Data) throws -> Void,
                               read: () throws -> Data) throws -> Outcome {
        try atStage(.receiptWrite) { try write(receipt) }
        try atStage(.receiptReadback) {
            guard try read() == receipt else { throw Failure.invalid }
        }
        return .approved
    }

    static func approve(_ displayed: Request, root: URL) throws -> Outcome {
        guard NativeSigningReadiness.current else { throw failure(Failure.unavailable, stage: .readiness) }
        let request = try atStage(.validation) { try validate(displayed.data, id: displayed.id) }
        let directory = try atStage(.requestRead) { try HookFiles.privateDirectory(root.appendingPathComponent("control")) }
        defer { close(directory) }
        func checkCurrent() throws {
            let current = try atStage(.requestRead) {
                try CopilotFileAccess.readStableRegular(
                    at: directory, filename: "native-request-\(request.id).json", owner: getuid(),
                    maximum: 49_152, permissions: 0o600
                )
            }
            guard current == displayed.data else { throw failure(Failure.invalid, stage: .validation) }
        }
        try checkCurrent()
        var error: Unmanaged<CFError>?
        // The non-exportable signing key requires OS-mediated user presence.
        // No command-line approval entry point and no software-key fallback exist.
        guard let signature = SecKeyCreateSignature(
            try key(create: true), .ecdsaSignatureMessageX962SHA256, request.data as CFData, &error
        ) as Data? else { throw systemFailure(stage: .signing, error: error) }
        _ = try atStage(.validation) { try validate(request.data, id: request.id) }
        try checkCurrent()
        let receipt = try atStage(.receiptWrite) {
            try JSONSerialization.data(withJSONObject: [
                "request": request.data.base64EncodedString(),
                "signature": signature.base64EncodedString(),
            ], options: [.sortedKeys])
        }
        let name = "native-approval-\(request.id).json"
        return try persistReceipt(receipt) {
            try HookFiles.atomicWrite($0, name: name, directory: directory)
        } read: {
            try CopilotFileAccess.readStableRegular(
                at: directory, filename: name, owner: getuid(), maximum: 70_000, permissions: 0o600
            )
        }
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
    @State private var sheetFailure: NativeChildAuthorization.ApprovalFailure?
    @State private var signingReady = false

    var body: some View {
        VStack(alignment: .leading) {
            Text("Native messaging child authorization").font(.headline)
            Text("Full parent policy is unavailable. Human authorization is an actor-specific run-policy snapshot, not live policy synchronization. Known denies and native managed restrictions remain. No allow-all, path or URL emulation.")
                .font(.caption)
            HStack {
                Button("Refresh requests", action: refresh)
                    .accessibilityLabel("Refresh native authorization requests")
                    .accessibilityIdentifier("native-authorization-refresh")
                if let notice {
                    Text(notice).font(.caption)
                        .accessibilityIdentifier("native-authorization-result")
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let sorted = requests.sorted {
                    let left = $0.status(at: context.date) == .pending
                    let right = $1.status(at: context.date) == .pending
                    return left != right ? left : $0.id < $1.id
                }
                ForEach(sorted) { request in
                    let status = request.status(at: context.date)
                    Button {
                        notice = nil
                        sheetFailure = nil
                        selected = request
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: "Initial worker: \(request.label)")
                                .fontWeight(status == .pending ? .semibold : .regular)
                            Text(status.rawValue).font(.caption)
                            Text(verbatim: "Review · \(request.id.prefix(8))").font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .accessibilityLabel("Review run policy for initial worker: \(request.label)")
                    .accessibilityValue("\(status.rawValue). Request \(request.id)")
                    .accessibilityIdentifier("native-authorization-review-\(request.id)")
                }
            }
        }
        .onAppear(perform: refresh)
        .sheet(item: $selected) { request in
            review(request)
        }
    }

    private func review(_ request: NativeChildAuthorization.Request) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let status = request.status(at: context.date)
            VStack(alignment: .leading, spacing: 12) {
                Text("Review run-policy approval").font(.headline)
                Text(verbatim: "Initial worker: \(request.label)")
                Text(status.rawValue).font(.subheadline).fontWeight(.semibold)
                    .accessibilityIdentifier("native-authorization-status")
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Worker/task labels are request metadata, not instructions or proof of authority.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(NativeChildAuthorization.policyDisclosure)
                        Text("These are explicit CLI tool flags, not an OS sandbox or a full export of effective native permissions. Known denies win; native restrictions remain authoritative.")
                            .font(.caption)
                        let summary = NativeChildAuthorization.policySummary(request)
                        if summary.isEmpty {
                            Text("No supported run-policy summary. This request cannot be approved.")
                        }
                        ForEach(summary) { field in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(field.title).fontWeight(.semibold)
                                Text(verbatim: field.value).textSelection(.enabled)
                            }
                        }
                        DisclosureGroup("Full request details · \(request.id.prefix(8))") {
                            Text("Source JSON; backslash, control and direction characters shown as escapes. Display formatting never changes signed bytes.")
                                .font(.caption)
                            Text(verbatim: NativeChildAuthorization.visibleText(request.display))
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        .accessibilityLabel("Full run-policy request details")
                        .accessibilityIdentifier("native-authorization-details")
                        Text("Signing requires macOS user presence. The first launch activates reuse for this exact actor, run and policy. Future matching tasks and labels need no further authentication; each launch still consumes a fresh one-time ticket. New runs or changed scopes require fresh consent. Disable setup, archive or recover to invalidate reuse.")
                            .font(.caption)
                        if status == .reuseReady || status == .receiptPresent {
                            Text("No signing action here. The controller still checks signature/grant, scope, expiry and ticket consumption at launch. This row does not confirm a launch or current admission.")
                                .font(.caption)
                        }
                    }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let sheetFailure {
                    Label {
                        Text(verbatim: sheetFailure.message).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                    }
                    .font(.callout).foregroundStyle(.red)
                    .accessibilityLabel("Request action failed. \(sheetFailure.message)")
                    .accessibilityIdentifier("native-authorization-error")
                }
                if !signingReady {
                    Text(NativeSigningReadiness.unsupported).font(.caption)
                }
                Text("Remove deletes this request and any receipt, not active run-policy grants. Nothing here launches a worker.")
                    .font(.caption)
                HStack {
                    Button("Authorize run policy…") {
                        perform(stage: .requestRead) { try NativeChildAuthorization.approve(request, root: $0) }
                    }.disabled(!signingReady || status != .pending)
                        .accessibilityLabel("Authorize this actor's run policy")
                        .accessibilityIdentifier("native-authorization-approve")
                    Button("Remove request and receipt", role: .destructive) {
                        perform(stage: .removal) {
                            try NativeChildAuthorization.dismiss(request, root: $0)
                            return .removed
                        }
                    }
                    .accessibilityLabel("Remove request and receipt")
                    .accessibilityIdentifier("native-authorization-remove")
                    Spacer()
                    Button("Back to requests") { selected = nil }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Back to requests without approving")
                        .accessibilityIdentifier("native-authorization-back")
                }
            }.padding().frame(width: 720, height: 680)
        }
    }

    private func perform(stage: NativeChildAuthorization.Stage,
                         _ operation: (URL) throws -> NativeChildAuthorization.Outcome) {
        sheetFailure = nil
        do {
            let outcome = try operation(CopilotPaths.orchestrationRoot())
            selected = nil
            refresh()
            notice = [outcome.message, notice].compactMap { $0 }.joined(separator: " ")
        } catch {
            sheetFailure = NativeChildAuthorization.failure(error, stage: stage)
        }
    }

    private func refresh() {
        signingReady = NativeSigningReadiness.current
        do {
            requests = try NativeChildAuthorization.requests(root: CopilotPaths.orchestrationRoot())
            notice = requests.isEmpty ? "No requests." : nil
        } catch {
            requests = []
            notice = "Requests could not be read safely."
        }
    }
}
