import AppKit
import UserNotifications

@MainActor
final class MaestroNotificationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard CopilotSetupAccess.currentAppAllowsChanges else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notification.request.content.sound == nil ? [.banner, .list] : [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let token = response.notification.request.content.userInfo["maestroClickToken"] as? String else { return }
        let name = response.notification.request.content.title
        await open(token: token, name: name)
    }

    private func open(token: String, name: String) async {
        guard CopilotSetupAccess.currentAppAllowsChanges else { return }
        do {
            try await MaestroNotificationController.installed().focus(token: token)
        } catch {
            let content = UNMutableNotificationContent()
            content.title = MaestroNotificationContent.text(name, limit: 100)
            content.subtitle = String(localized: "notifications.unavailable", defaultValue: "Unavailable")
            content.interruptionLevel = .passive
            do {
                try await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                )
            } catch {
                // Static diagnostic only; no content, target, token or OS error enters logs.
                fputs("Maestro notification target unavailable.\n", stderr)
            }
        }
    }
}
