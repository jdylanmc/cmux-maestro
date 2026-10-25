import Darwin
import Foundation

/// Vnode callbacks only yield to a thread-safe stream; the immutable lease owns cancellation.
nonisolated final class MaestroClickEvents: @unchecked Sendable {
    let events: AsyncStream<Void>
    private let source: any DispatchSourceFileSystemObject
    private let continuation: AsyncStream<Void>.Continuation

    init(directory: URL) throws {
        let descriptor = try CopilotFileAccess.openDirectory(directory, owner: getuid())
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // Directory vnode delivery has no async-native replacement.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .revoke],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { continuation.yield(()) }
        source.setCancelHandler { close(descriptor); continuation.finish() }
        self.events = events
        self.continuation = continuation
        self.source = source
        source.activate()
    }

    deinit {
        source.cancel()
        continuation.finish()
    }
}
