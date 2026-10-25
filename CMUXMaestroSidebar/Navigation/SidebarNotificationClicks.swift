import Foundation

@MainActor
final class SidebarNotificationClicks {
    private let root: URL
    private let verify: @MainActor (MaestroNotificationTarget) throws -> Void
    private let now: @Sendable () -> Date
    private var channel: MaestroClickChannel?
    private var lease: MaestroClickChannel.Lease?
    private var events: MaestroClickEvents?
    private var task: Task<Void, Never>?
    private var navigation: SidebarNavigation?
    private var topology: SidebarTopology?
    private var consumed: [UUID: Date] = [:]

    init(
        root: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        verify: @escaping @MainActor (MaestroNotificationTarget) throws -> Void = {
            try SidebarNotificationTargetVerifier().verify($0)
        }
    ) {
        self.root = root
        self.now = now
        self.verify = verify
    }

    deinit { task?.cancel() }

    func update(topology: SidebarTopology, navigation: SidebarNavigation) {
        guard let window = topology.windowID, !topology.workspaceIDs.isEmpty else { stop(); return }
        self.navigation = navigation
        self.topology = topology
        do {
            if channel?.window != window {
                stop()
                self.navigation = navigation
                self.topology = topology
                try FileManager.default.createDirectory(
                    at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
                )
                let channel = try MaestroClickChannel(root: root, window: window, serving: true)
                // A new connection never consumes a predecessor's pending click.
                try channel.remove(slot: "request")
                try channel.remove(slot: "result")
                let events = try MaestroClickEvents(directory: root)
                self.channel = channel
                self.events = events
                let lease = MaestroClickChannel.Lease(nonce: UUID(), workspaces: Array(topology.workspaceIDs))
                try channel.publish(lease)
                self.lease = lease
                task = Task { [weak self, events] in
                    for await _ in events.events {
                        guard !Task.isCancelled else { return }
                        self?.consume()
                    }
                }
            } else if let channel, let lease, Set(lease.workspaces) != topology.workspaceIDs {
                let updated = MaestroClickChannel.Lease(nonce: lease.nonce, workspaces: Array(topology.workspaceIDs))
                try channel.publish(updated)
                self.lease = updated
            }
        } catch {
            stop()
            fputs("Maestro notification click connection unavailable.\n", stderr)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        events = nil
        lease = nil
        channel = nil
        navigation = nil
        topology = nil
        consumed.removeAll()
    }

    func consume() {
        guard let channel, let lease, let topology, let navigation else { return }
        do {
            guard let request = try channel.read(MaestroClickChannel.Request.self, slot: "request") else { return }
            try channel.remove(slot: "request")
            let date = now()
            consumed = consumed.filter { date.timeIntervalSince($0.value) < 5 }
            guard request.isCurrent(nonce: lease.nonce, now: date), consumed[request.id] == nil,
                  consumed.count < 64,
                  topology.workspaceBySurface[request.target.surfaceId] == request.target.workspaceId else {
                try channel.write(MaestroClickChannel.Response(id: request.id, focused: false), slot: "result")
                return
            }
            consumed[request.id] = request.createdAt
            do { try verify(request.target) }
            catch {
                try channel.write(MaestroClickChannel.Response(id: request.id, focused: false), slot: "result")
                return
            }
            navigation.select(.surface(workspaceID: request.target.workspaceId, surfaceID: request.target.surfaceId),
                              onFinish: { [weak self] status in
                guard let channel = self?.channel, self?.lease?.nonce == lease.nonce else { return }
                do {
                    try channel.write(MaestroClickChannel.Response(id: request.id, focused: status == .selected), slot: "result")
                } catch { fputs("Maestro notification click result unavailable.\n", stderr) }
            }, validate: { [weak self] in
                guard let self, self.lease?.nonce == lease.nonce,
                      request.isCurrent(nonce: lease.nonce, now: self.now()) else {
                    throw CopilotFileError.changed
                }
                try self.verify(request.target)
            })
        } catch {
            // Malformed data is never deferred until a later connection or silently accepted.
            do { try channel.remove(slot: "request") }
            catch { fputs("Maestro notification click removal unavailable.\n", stderr) }
            fputs("Maestro notification click request unavailable.\n", stderr)
        }
    }
}
