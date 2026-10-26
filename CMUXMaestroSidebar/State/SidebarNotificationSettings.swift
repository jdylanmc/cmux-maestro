import Foundation

nonisolated struct SidebarNotificationSettings: SidebarPreferenceValue {
    var version = 1
    var muted = false
    static let maximumStoredBytes = 1024
    static var failOpen: Self { .init(muted: true) }
    static var unreadableNotice: String {
        String(localized: "notifications.unavailable", defaultValue: "Unavailable")
    }
    static var saveNotice: String { unreadableNotice }
    var isValid: Bool { version == 1 }
}
