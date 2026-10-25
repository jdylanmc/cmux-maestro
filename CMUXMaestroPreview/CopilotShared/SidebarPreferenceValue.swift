import Foundation

nonisolated protocol SidebarPreferenceValue: Codable, Equatable, Sendable {
    init()
    static var maximumStoredBytes: Int { get }
    static var failOpen: Self { get }
    static var unreadableNotice: String { get }
    static var saveNotice: String { get }
    var isValid: Bool { get }
}
