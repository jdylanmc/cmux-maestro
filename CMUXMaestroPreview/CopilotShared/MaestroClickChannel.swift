import Darwin
import Foundation

/// One bounded click slot per connected CMUX window. Locks fence processes, not Swift state.
/// Each instance is used by one actor; immutable descriptors are closed only at deinit.
nonisolated final class MaestroClickChannel: @unchecked Sendable {
    struct Lease: Codable, Equatable, Sendable {
        let nonce: UUID
        let workspaces: [UUID]
    }
    struct Request: Codable, Sendable {
        let id: UUID
        let nonce: UUID
        let target: MaestroNotificationTarget
        let createdAt: Date

        func isCurrent(nonce: UUID, now: Date) -> Bool {
            self.nonce == nonce && target.generation > 0
                && (0..<5).contains(now.timeIntervalSince(createdAt))
        }
    }
    struct Response: Codable, Sendable {
        let id: UUID
        let focused: Bool
    }

    let root: URL
    let window: UUID
    private let directory: Int32
    private let lock: Int32
    private let lockName: String

    init(root: URL, window: UUID, serving: Bool) throws {
        self.root = root
        self.window = window
        lockName = window.uuidString.lowercased() + (serving ? ".lease" : ".busy")
        directory = try CopilotFileAccess.openDirectory(root, owner: getuid())
        do {
            guard try CopilotFileAccess.statFile(directory).permissions == 0o700 else {
                throw CopilotFileError.unsafePath
            }
            let directory = directory, name = lockName
            lock = try Self.withRegistry(at: directory) {
                try Self.reclaimRetired(at: directory)
                return try Self.acquire(at: directory, name: name, create: true)
            }
        } catch {
            close(directory)
            throw error
        }
    }

    deinit {
        defer { close(lock); close(directory) }
        do {
            try Self.withRegistry(at: directory) {
                try Self.reclaim(window: window, at: directory, owned: (lockName, lock))
            }
        } catch {
            // Contention leaves an unlocked retired file for the next bounded sweep.
            fputs("Maestro retired notification channel cleanup unavailable.\n", stderr)
        }
    }

    /// This permanent inode serializes lock-name creation and removal across processes.
    private static func withRegistry<T>(at directory: Int32, _ operation: () throws -> T) throws -> T {
        let descriptor = try acquire(at: directory, name: ".registry", create: true)
        defer { close(descriptor) }
        return try operation()
    }

    private static func acquire(at directory: Int32, name: String, create: Bool) throws -> Int32 {
        let descriptor = openat(
            directory, name, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (create ? O_CREAT : 0), 0o600
        )
        guard descriptor >= 0 else { throw CopilotFileError.current() }
        do {
            let stamp = try CopilotFileAccess.statFile(descriptor)
            guard stamp.isRegular, stamp.uid == getuid(), stamp.permissions == 0o600 else {
                throw CopilotFileError.unsafePath
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK { throw CopilotFileError.changed }
                throw CopilotFileError.current()
            }
            guard stamp.sameFile(as: try CopilotFileAccess.statEntry(at: directory, name: name)) else {
                throw CopilotFileError.changed
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func reclaimRetired(at directory: Int32) throws {
        let entries = try CopilotFileAccess.names(at: directory, limit: 256)
        var windows: Set<UUID> = []
        for name in entries.names {
            let parts = name.split(separator: ".", maxSplits: 1)
            guard parts.count == 2, let window = UUID(uuidString: String(parts[0])),
                  window.uuidString.lowercased() == parts[0],
                  ["lease", "busy", "request", "result", "request.staging", "result.staging"].contains(String(parts[1])) else { continue }
            windows.insert(window)
        }
        for window in windows { try reclaim(window: window, at: directory) }
    }

    private static func reclaim(window: UUID, at directory: Int32, owned: (String, Int32)? = nil) throws {
        let prefix = window.uuidString.lowercased() + "."
        var descriptors: [(String, Int32)] = []
        defer { for (_, descriptor) in descriptors { close(descriptor) } }
        for suffix in ["lease", "busy"] {
            let name = prefix + suffix
            if owned?.0 == name { continue }
            do { descriptors.append((name, try acquire(at: directory, name: name, create: false))) }
            catch CopilotFileError.missing { continue }
            catch CopilotFileError.changed { return }
        }
        // No live lease or sender remains. The registry fences all new openers.
        for suffix in ["request", "result", "request.staging", "result.staging"] {
            let name = prefix + suffix
            do {
                let stamp = try CopilotFileAccess.statEntry(at: directory, name: name)
                guard stamp.isRegular, stamp.uid == getuid(), stamp.permissions == 0o600 else {
                    throw CopilotFileError.unsafePath
                }
                guard unlinkat(directory, name, 0) == 0 else { throw CopilotFileError.current() }
            } catch CopilotFileError.missing { continue }
        }
        for (name, descriptor) in descriptors + (owned.map { [$0] } ?? []) {
            let stamp = try CopilotFileAccess.statFile(descriptor)
            guard stamp.sameFile(as: try CopilotFileAccess.statEntry(at: directory, name: name)),
                  unlinkat(directory, name, 0) == 0 else { throw CopilotFileError.changed }
        }
    }

    func publish(_ lease: Lease) throws {
        guard !lease.workspaces.isEmpty, lease.workspaces.count <= 512,
              Set(lease.workspaces).count == lease.workspaces.count else { throw CopilotFileError.tooLarge }
        let data = try JSONEncoder().encode(lease)
        guard ftruncate(lock, 0) == 0 else { throw CopilotFileError.current() }
        let written = data.withUnsafeBytes { pwrite(lock, $0.baseAddress, $0.count, 0) }
        guard written == data.count else { throw CopilotFileError.io }
    }

    static func liveLease(root: URL, window: UUID) throws -> Lease? {
        let directory = try CopilotFileAccess.openDirectory(root, owner: getuid())
        defer { close(directory) }
        let name = window.uuidString.lowercased() + ".lease"
        let descriptor = try CopilotFileAccess.openRegular(at: directory, name: name, owner: getuid(), permissions: 0o600)
        defer { close(descriptor) }
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 { return nil }
        guard errno == EWOULDBLOCK else { throw CopilotFileError.current() }
        let data = try CopilotFileAccess.readStableRegular(
            at: directory, filename: name, owner: getuid(), maximum: 32_768, permissions: 0o600
        )
        let lease = try JSONDecoder().decode(Lease.self, from: data)
        guard !lease.workspaces.isEmpty, lease.workspaces.count <= 512,
              Set(lease.workspaces).count == lease.workspaces.count else { throw CopilotFileError.unsafePath }
        return lease
    }

    static func destination(root: URL, workspace: UUID) throws -> (UUID, Lease) {
        let directory = try CopilotFileAccess.openDirectory(root, owner: getuid())
        defer { close(directory) }
        guard try CopilotFileAccess.statFile(directory).permissions == 0o700 else { throw CopilotFileError.unsafePath }
        return try withRegistry(at: directory) {
            try reclaimRetired(at: directory)
            let entries = try CopilotFileAccess.names(at: directory, limit: 256)
            guard !entries.limited else { throw CopilotFileError.tooLarge }
            var matches: [(UUID, Lease)] = []
            for name in entries.names where name.hasSuffix(".lease") {
                guard let window = UUID(uuidString: String(name.dropLast(6))) else { throw CopilotFileError.unsafePath }
                if let lease = try liveLease(root: root, window: window), lease.workspaces.contains(workspace) {
                    matches.append((window, lease))
                }
            }
            guard matches.count == 1, let match = matches.first else { throw CopilotFileError.missing }
            return match
        }
    }

    func write<T: Encodable>(_ value: T, slot: String) throws {
        guard ["request", "result"].contains(slot) else { throw CopilotFileError.unsafePath }
        let name = window.uuidString.lowercased() + "." + slot
        let staging = name + ".staging"
        let bytes = try JSONEncoder().encode(value)
        guard bytes.count <= 4096 else { throw CopilotFileError.tooLarge }
        let descriptor = openat(directory, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CopilotFileError.current() }
        defer { close(descriptor); unlinkat(directory, staging, 0) }
        let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard count == bytes.count, renameat(directory, staging, directory, name) == 0 else {
            throw CopilotFileError.io
        }
    }

    func read<T: Decodable>(_ type: T.Type, slot: String) throws -> T? {
        guard ["request", "result"].contains(slot) else { throw CopilotFileError.unsafePath }
        do {
            let data = try CopilotFileAccess.readStableRegular(
                at: directory, filename: window.uuidString.lowercased() + "." + slot,
                owner: getuid(), maximum: 4096, permissions: 0o600
            )
            return try JSONDecoder().decode(type, from: data)
        } catch CopilotFileError.missing { return nil }
    }

    func remove(slot: String) throws {
        guard ["request", "result"].contains(slot) else { throw CopilotFileError.unsafePath }
        if unlinkat(directory, window.uuidString.lowercased() + "." + slot, 0) != 0, errno != ENOENT {
            throw CopilotFileError.current()
        }
    }
}
