import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Qualification only: never creates a key or asks for authentication.
nonisolated enum NativeSigningReadiness {
    static let appID = "com.jdylanmc.CMUXMaestroPreview"
    static let unsupported = "Native messaging unsupported: requires a properly signed, provisioned app with its private keychain group, Secure Enclave and macOS user authentication. Ad-hoc builds remain supported for ordinary orchestration."

    struct Metadata {
        let identifier: String
        let team: String
        let signed: Bool
        let adHoc: Bool
        let entitlements: [String: Any]
        let profile: [String: Any]
        let certificate: Data
    }

    // Pure qualification of already authenticated metadata; not an authority/configuration input.
    static func eligible(_ value: Metadata, identifier: String, keychain: Bool,
                         at now: Date = Date()) -> Bool {
        let e = value.entitlements
        let p = value.profile
        guard value.signed, !value.adHoc, value.identifier == identifier,
              value.team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil,
              let grants = p["Entitlements"] as? [String: Any],
              p["TeamIdentifier"] as? [String] == [value.team],
              let prefixes = p["ApplicationIdentifierPrefix"] as? [String], prefixes.count == 1,
              let prefix = prefixes.first,
              prefix.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil,
              let start = p["CreationDate"] as? Date, let end = p["ExpirationDate"] as? Date,
              start <= now, now < end,
              let certificates = p["DeveloperCertificates"] as? [Data],
              certificates.contains(value.certificate),
              e["com.apple.developer.team-identifier"] as? String == value.team,
              grants["com.apple.developer.team-identifier"] as? String == value.team,
              e["com.apple.application-identifier"] as? String == "\(prefix).\(identifier)",
              grants["com.apple.application-identifier"] as? String == "\(prefix).\(identifier)"
        else { return false }
        if keychain {
            let group = "\(prefix).\(appID)"
            guard e["keychain-access-groups"] as? [String] == [group],
                  let groups = grants["keychain-access-groups"] as? [String],
                  groups.contains(group) || groups.contains("\(prefix).*")
            else { return false }
        } else {
            guard e["com.apple.security.app-sandbox"] as? Bool == true,
                  e["keychain-access-groups"] == nil else { return false }
        }
        return true
    }

    private static func metadata(_ url: URL, identifier: String) -> Metadata? {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        // Apple-issued signing identity, exact namespace; never trust a plist bundle ID alone.
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(
                "anchor apple generic and identifier \"\(identifier)\"" as CFString,
                [], &requirement
              ) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                                         requirement) == errSecSuccess
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let info = information as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              let signedID = info[kSecCodeInfoIdentifier as String] as? String,
              let flags = info[kSecCodeInfoFlags as String] as? UInt32,
              let e = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let chain = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = chain.first,
              let profile = authenticatedProfile(url.appendingPathComponent("Contents/embedded.provisionprofile"))
        else { return nil }
        return Metadata(identifier: signedID, team: team, signed: true, adHoc: flags & 2 != 0,
                        entitlements: e, profile: profile, certificate: SecCertificateCopyData(leaf) as Data)
    }

    private static func authenticatedProfile(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= 1_048_576 else { return nil }
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return nil }
        let status = data.withUnsafeBytes {
            CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count)
        }
        var signer = CMSSignerStatus(rawValue: 0)!
        var trust: SecTrust?
        var result: OSStatus = errSecSuccess
        var count = 0
        var content: CFData?
        guard status == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess,
              CMSDecoderGetNumSigners(decoder, &count) == errSecSuccess, count == 1,
              CMSDecoderCopySignerStatus(decoder, 0, SecPolicyCreateBasicX509(), true,
                                        &signer, &trust, &result) == errSecSuccess,
              signer == .valid, result == errSecSuccess,
              CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content
        else { return nil }
        // The running process's restricted entitlements are also validated by macOS
        // against its embedded provisioning profile, not just the CMS payload.
        return (try? PropertyListSerialization.propertyList(from: content as Data, format: nil)) as? [String: Any]
    }

    static var current: Bool {
        guard CopilotSetupAccess.currentAppAllowsChanges, SecureEnclave.isAvailable else { return false }
        var process: SecCode?
        guard SecCodeCopySelf([], &process) == errSecSuccess, let process,
              SecCodeCheckValidity(process, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
              let app = metadata(Bundle.main.bundleURL, identifier: appID),
              eligible(app, identifier: appID, keychain: true),
              let sidebar = metadata(Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Extensions/CMUX Maestro Preview Extension.appex"), identifier: appID + ".Extension"),
              sidebar.team == app.team,
              eligible(sidebar, identifier: appID + ".Extension", keychain: false)
        else { return false }
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }
}
