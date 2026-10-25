import Foundation

nonisolated struct MaestroNotificationClick: Sendable {
    let root: URL
    var now: @Sendable () -> Date = { Date() }
    var timeout: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(15)) }

    func focus(_ target: MaestroNotificationTarget) async throws {
        let (window, lease) = try MaestroClickChannel.destination(root: root, workspace: target.workspaceId)
        let channel = try MaestroClickChannel(root: root, window: window, serving: false)
        let events = try MaestroClickEvents(directory: root)
        guard try MaestroClickChannel.liveLease(root: root, window: window) == lease else {
            throw MaestroNotificationFailure.unavailable
        }
        let request = MaestroClickChannel.Request(id: UUID(), nonce: lease.nonce, target: target, createdAt: now())
        try channel.remove(slot: "result")
        try channel.write(request, slot: "request")
        defer {
            do { try channel.remove(slot: "request"); try channel.remove(slot: "result") }
            catch { fputs("Maestro notification click cleanup unavailable.\n", stderr) }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in events.events {
                    try Task.checkCancellation()
                    guard let response = try channel.read(MaestroClickChannel.Response.self, slot: "result"),
                          response.id == request.id else { continue }
                    guard response.focused else { throw MaestroNotificationFailure.unavailable }
                    return
                }
                throw MaestroNotificationFailure.unavailable
            }
            group.addTask {
                try await timeout()
                throw MaestroNotificationFailure.unavailable
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}
