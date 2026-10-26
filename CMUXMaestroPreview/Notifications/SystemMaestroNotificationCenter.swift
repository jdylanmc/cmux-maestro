import UserNotifications

@MainActor
struct SystemMaestroNotificationCenter: MaestroNotificationCenter {
    let center: UNUserNotificationCenter
    func authorization() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }
    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
}
