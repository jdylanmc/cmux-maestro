import Foundation

nonisolated struct MaestroNotificationTarget: Codable, Equatable, Sendable {
    let nodeId: UUID
    let sessionId: UUID
    let workspaceId: UUID
    let surfaceId: UUID
    let generation: Int
}
