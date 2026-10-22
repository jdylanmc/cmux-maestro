import CoreServices
import Darwin
import Foundation

/// Immutable resource lease; only deinit tears down the stream. Callbacks touch only
/// the thread-safe continuation, never the lease or reader state.
nonisolated final class SidebarFileWatcher: @unchecked Sendable {
    enum Failure: Error { case noRoots, create, start }

    // FSEvents has no async-native API. Its C context owns this immutable stream sink.
    private final class Sink {
        let continuation: AsyncStream<Void>.Continuation
        init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
    }

    let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let source: FSEventStreamRef

    init(roots: [URL], owner: UInt32 = getuid()) throws {
        guard !roots.isEmpty, roots.count <= 3 else { throw Failure.noRoots }
        for root in roots {
            let descriptor = try CopilotFileAccess.openDirectory(root, owner: owner)
            close(descriptor)
        }
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let sink = Sink(continuation)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { value in
                guard let value else { return nil }
                _ = Unmanaged<Sink>.fromOpaque(value).retain()
                return value
            },
            release: { value in
                if let value { Unmanaged<Sink>.fromOpaque(value).release() }
            },
            copyDescription: nil
        )
        // Paths are never read. Loss/root flags end the lease so its owner revalidates the roots.
        guard let source = FSEventStreamCreate(
            nil, { _, context, count, _, flags, _ in
                guard let context else { return }
                let sink = Unmanaged<Sink>.fromOpaque(context).takeUnretainedValue()
                sink.continuation.yield(())
                let invalidated = FSEventStreamEventFlags(
                    kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
                    | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount
                )
                if (0..<count).contains(where: { flags[$0] & invalidated != 0 }) {
                    sink.continuation.finish()
                }
            },
            &context, roots.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        ) else { throw Failure.create }
        FSEventStreamSetDispatchQueue(source, DispatchQueue.global(qos: .utility))
        guard FSEventStreamStart(source) else {
            FSEventStreamInvalidate(source)
            FSEventStreamRelease(source)
            throw Failure.start
        }
        self.events = events
        self.continuation = continuation
        self.source = source
    }

    deinit {
        FSEventStreamStop(source)
        FSEventStreamInvalidate(source)
        FSEventStreamRelease(source)
        continuation.finish()
    }
}
