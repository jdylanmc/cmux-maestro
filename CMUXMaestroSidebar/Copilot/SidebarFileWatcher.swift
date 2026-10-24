import CoreServices
import Darwin
import Foundation
import OSLog

nonisolated protocol SidebarFileWatching: Sendable {
    var events: AsyncStream<Void> { get }
}

/// Immutable resource lease; only deinit tears down the stream. Callbacks touch only
/// the thread-safe continuation, never the lease or reader state.
nonisolated final class SidebarFileWatcher: SidebarFileWatching, @unchecked Sendable {
    enum Failure: Error { case noRoots, create, start }

    struct DirectoryEvents: Sendable {
        let continuation: AsyncStream<Void>.Continuation

        func receive(_ flags: DispatchSource.FileSystemEvent) {
            if !flags.intersection([.rename, .delete, .revoke]).isEmpty {
                // Termination wakes the reader after clearing the invalidated registration.
                continuation.finish()
            } else {
                continuation.yield(())
            }
        }
    }

    struct Scope: Equatable, Sendable {
        let recursive: [URL]
        let directories: [URL]

        static func copilot(sessions: Set<UUID>, bindings: URL, sessionRoot: URL) -> Self {
            .init(
                recursive: sessions.sorted { $0.uuidString < $1.uuidString }
                    .prefix(CopilotReaderLimits().maximumSessions)
                    .map { sessionRoot.appendingPathComponent($0.uuidString.lowercased(), isDirectory: true) },
                directories: [bindings]
            )
        }

        func existingRecursiveRoots(owner: UInt32) throws -> [URL] {
            var existing: [URL] = []
            for root in recursive {
                do {
                    let descriptor = try CopilotFileAccess.openDirectory(root, owner: owner)
                    close(descriptor)
                    existing.append(root)
                } catch CopilotFileError.missing {
                    continue
                }
            }
            return existing
        }
    }

    // FSEvents has no async-native API. Its C context owns this immutable stream sink.
    private final class Sink {
        let continuation: AsyncStream<Void>.Continuation
        init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
    }

    let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let source: FSEventStreamRef?
    private let directories: [any DispatchSourceFileSystemObject]

    convenience init(roots: [URL], owner: UInt32 = getuid()) throws {
        try self.init(scope: .init(recursive: roots, directories: []), owner: owner)
    }

    init(scope: Scope, owner: UInt32 = getuid()) throws {
        guard !scope.recursive.isEmpty || !scope.directories.isEmpty,
              scope.recursive.count <= CopilotReaderLimits().maximumSessions,
              scope.directories.count <= 1 else { throw Failure.noRoots }
        let roots = try scope.existingRecursiveRoots(owner: owner)
        guard !roots.isEmpty || !scope.directories.isEmpty else { throw CopilotFileError.missing }
        if roots.count != scope.recursive.count {
            Logger(subsystem: "com.jdylanmc.CMUXMaestroPreview", category: "file-notifications")
                .notice("Missing session directories use safety polling; keeping available file notifications.")
        }
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var directories: [any DispatchSourceFileSystemObject] = []
        var retained = false
        defer { if !retained { for directory in directories { directory.cancel() } } }
        for root in scope.directories {
            let descriptor = try CopilotFileAccess.openDirectory(root, owner: owner)
            // Directory vnode events are non-recursive; bindings use atomic replacement.
            let directory = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .revoke],
                queue: .global(qos: .utility)
            )
            let delivery = DirectoryEvents(continuation: continuation)
            directory.setEventHandler { [weak directory] in
                guard let directory else { return }
                delivery.receive(directory.data)
            }
            directory.setCancelHandler { close(descriptor) }
            directory.activate()
            directories.append(directory)
        }
        self.events = events
        self.continuation = continuation
        self.directories = directories
        guard !roots.isEmpty else {
            self.source = nil
            retained = true
            return
        }
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
                let invalidated = FSEventStreamEventFlags(
                    kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
                    | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount
                )
                if (0..<count).contains(where: { flags[$0] & invalidated != 0 }) {
                    sink.continuation.finish()
                } else {
                    sink.continuation.yield(())
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
        self.source = source
        retained = true
    }

    deinit {
        for directory in directories { directory.cancel() }
        if let source {
            FSEventStreamStop(source)
            FSEventStreamInvalidate(source)
            FSEventStreamRelease(source)
        }
        continuation.finish()
    }
}
