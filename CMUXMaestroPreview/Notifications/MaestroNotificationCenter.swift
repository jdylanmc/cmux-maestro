import Foundation
import UserNotifications

@MainActor
protocol MaestroNotificationCenter {
    func authorization() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}
