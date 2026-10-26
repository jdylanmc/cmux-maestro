import Foundation
import UserNotifications

nonisolated struct MaestroNotificationContent: Sendable {
    let message: String
    let urgent: Bool

    static func text(_ input: String, limit: Int) -> String {
        let clean = String(input.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > limit ? String(clean.prefix(limit - 1)) + "…" : clean
    }

    func request(admission: MaestroNotificationAdmission) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.body = Self.text(message, limit: 140)
        content.threadIdentifier = admission.target.sessionId.uuidString.lowercased()
        content.interruptionLevel = .active
        content.sound = urgent ? .default : nil
        content.userInfo = ["maestroClickToken": admission.clickToken]
        return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    }
}
