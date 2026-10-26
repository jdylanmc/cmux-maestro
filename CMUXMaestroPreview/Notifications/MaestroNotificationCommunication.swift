import Foundation
import Intents
import Security
import UserNotifications

@MainActor
struct MaestroNotificationCommunication {
    static let entitlement = "com.apple.developer.usernotifications.communication"

    static func requireEntitlement() throws {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              entitlements[entitlement] as? Bool == true else {
            throw MaestroNotificationFailure.unavailable
        }
    }

    func interaction(admission: MaestroNotificationAdmission, message: String, avatar: Data, id: String) -> INInteraction {
        let session = admission.target.sessionId.uuidString.lowercased()
        let sender = INPerson(
            personHandle: INPersonHandle(value: "maestro-agent:\(session)", type: .unknown),
            nameComponents: nil,
            displayName: String(localized: "notifications.sender", defaultValue: "Maestro agent"),
            image: INImage(imageData: avatar), contactIdentifier: nil,
            customIdentifier: "maestro-agent:\(session)", isMe: false, suggestionType: .none
        )
        let intent = INSendMessageIntent(
            recipients: nil, outgoingMessageType: .outgoingMessageText,
            content: MaestroNotificationContent.text(message, limit: 140),
            speakableGroupName: nil, conversationIdentifier: "maestro-session:\(session)",
            serviceName: nil, sender: sender, attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.identifier = id
        interaction.groupIdentifier = "maestro-session:\(session)"
        interaction.direction = .incoming
        return interaction
    }

    func prepare(_ request: UNNotificationRequest, interaction: INInteraction) async throws -> UNNotificationRequest {
        try Self.requireEntitlement()
        guard let intent = interaction.intent as? INSendMessageIntent else {
            throw MaestroNotificationFailure.unavailable
        }
        try await interaction.donate()
        let content = try request.content.updating(from: intent)
        return UNNotificationRequest(identifier: request.identifier, content: content, trigger: request.trigger)
    }
}
