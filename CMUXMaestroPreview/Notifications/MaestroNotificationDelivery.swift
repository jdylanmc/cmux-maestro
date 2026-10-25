import UserNotifications

@MainActor
struct MaestroNotificationDelivery {
    let center: any MaestroNotificationCenter

    func submit(_ request: UNNotificationRequest, beforeSubmit: () async throws -> Void = {}) async throws {
        switch await center.authorization() {
        case .authorized, .provisional: break
        case .notDetermined:
            guard try await center.requestAuthorization() else { throw MaestroNotificationFailure.unauthorized }
        default: throw MaestroNotificationFailure.unauthorized
        }
        try await beforeSubmit()
        try await center.add(request)
    }
}
