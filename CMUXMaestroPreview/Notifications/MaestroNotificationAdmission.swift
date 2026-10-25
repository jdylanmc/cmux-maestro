import Foundation

nonisolated struct MaestroNotificationAdmission: Decodable, Sendable {
    let target: MaestroNotificationTarget
    let clickToken: String
    let name: String
}
