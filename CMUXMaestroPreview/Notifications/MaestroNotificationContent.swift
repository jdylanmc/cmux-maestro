import Foundation
import UserNotifications

nonisolated struct MaestroNotificationContent: Sendable {
    let name: String
    let state: CopilotWorkState
    let message: String
    let urgent: Bool

    static func text(_ input: String, limit: Int) -> String {
        let clean = String(input.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > limit ? String(clean.prefix(limit - 1)) + "…" : clean
    }

    var subtitle: String {
        switch state {
        case .working: "🟢 " + String(localized: "notifications.working", defaultValue: "Working")
        case .blocked: "⏸️ " + String(localized: "notifications.input", defaultValue: "Needs input")
        case .failed: "🔴 " + String(localized: "notifications.failed", defaultValue: "Failed")
        case .completed: "✅ " + String(localized: "notifications.finished", defaultValue: "Turn finished")
        case .cancelled: "⏹️ " + String(localized: "notifications.cancelled", defaultValue: "Cancelled")
        case .idle: "⚪ " + String(localized: "notifications.idle", defaultValue: "Idle")
        case .unknown: "❔ " + String(localized: "notifications.unknown", defaultValue: "Unknown")
        }
    }

    func request(admission: MaestroNotificationAdmission, attachment: UNNotificationAttachment) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = Self.text(name, limit: 100)
        content.subtitle = urgent ? String(localized: "notifications.urgent", defaultValue: "Urgent") + " · \(subtitle)" : subtitle
        content.body = Self.text(message, limit: 140)
        content.threadIdentifier = admission.target.sessionId.uuidString.lowercased()
        content.interruptionLevel = .active
        content.sound = urgent ? .default : nil
        content.attachments = [attachment]
        content.userInfo = ["maestroClickToken": admission.clickToken]
        return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    }
}
