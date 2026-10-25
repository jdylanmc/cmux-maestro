nonisolated enum MaestroNotificationFailure: String, Error {
    case unavailable = "notification-unavailable"
    case invalidInput = "notification-input-invalid"
    case unauthorized = "notifications-not-authorized"
    case identity = "notification-identity-unverified"
    case muted
    case rateLimited = "rate-limited"
    case settings = "notification-settings-unavailable"
    case capacity = "notification-capacity-unavailable"
}
