import Darwin
import Foundation

nonisolated enum CopilotFileError: Error, Equatable {
    case missing, permissionDenied, unsafePath, tooLarge, changed, io

    static func current() -> Self {
        switch errno {
        case ENOENT: .missing
        case EACCES, EPERM: .permissionDenied
        case ELOOP, ENOTDIR: .unsafePath
        default: .io
        }
    }
}

nonisolated struct CopilotFileStamp: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let uid: UInt32
    let mode: UInt16
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let birthSeconds: Int64
    let birthNanoseconds: Int64

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        uid = value.st_uid
        mode = value.st_mode
        size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        birthSeconds = Int64(value.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(value.st_birthtimespec.tv_nsec)
    }

    var isRegular: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFREG) }
    var isDirectory: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
    var permissions: UInt16 { mode & 0o7777 }

    func sameFile(as other: Self) -> Bool {
        device == other.device && inode == other.inode
            && birthSeconds == other.birthSeconds && birthNanoseconds == other.birthNanoseconds
    }
}

// Exclusively owned by one reader actor (or a synchronous helper call). Holding
// DIR, rather than a pathname or a prefix, preserves readdir's opaque position.
nonisolated final class CopilotDirectoryStream: @unchecked Sendable {
    private var stream: UnsafeMutablePointer<DIR>?
    private(set) var finished = false

    init(at directory: Int32) throws {
        let copy = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard copy >= 0 else { throw CopilotFileError.current() }
        guard let opened = fdopendir(copy) else {
            close(copy)
            throw CopilotFileError.current()
        }
        stream = opened
    }

    deinit { if let stream { closedir(stream) } }

    func closeStream() {
        if let stream { closedir(stream) }
        stream = nil
        finished = true
    }

    func next() throws -> String? {
        do {
            try Task.checkCancellation()
            guard let stream else { return nil }
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { throw CopilotFileError.current() }
                    closeStream()
                    return nil
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                        String(cString: $0)
                    }
                }
                if name != "." && name != ".." { return name }
            }
        } catch {
            closeStream()
            throw error
        }
    }
}

// File descriptors anchor each traversal. No resolve-then-open symlink window,
// and no path from a transcript is ever passed into these helpers.
nonisolated enum CopilotFileAccess {
    static func openDirectory(_ url: URL, owner: UInt32? = nil) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw CopilotFileError.unsafePath }
        let components = url.path.split(separator: "/").map(String.init)
        var descriptor = Darwin.open(
            "/", (components.isEmpty ? O_RDONLY : O_SEARCH) | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw CopilotFileError.current() }
        do {
            for (index, part) in components.enumerated() {
                guard validComponent(part) else { throw CopilotFileError.unsafePath }
                // Ancestor traversal needs search permission, not directory contents.
                // The authorized final directory still requires normal read access.
                let access = index == components.count - 1 ? O_RDONLY : O_SEARCH
                let next = openat(descriptor, part, access | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard next >= 0 else { throw CopilotFileError.current() }
                close(descriptor)
                descriptor = next
            }
            let stamp = try statFile(descriptor)
            guard stamp.isDirectory, owner == nil || stamp.uid == owner else {
                throw CopilotFileError.unsafePath
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func openDirectory(at parent: Int32, name: String, owner: UInt32) throws -> Int32 {
        guard validComponent(name) else { throw CopilotFileError.unsafePath }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CopilotFileError.current() }
        do {
            let stamp = try statFile(descriptor)
            guard stamp.isDirectory, stamp.uid == owner else { throw CopilotFileError.unsafePath }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func openRegular(
        at directory: Int32, name: String, owner: UInt32, permissions: UInt16? = nil
    ) throws -> Int32 {
        guard validComponent(name) else { throw CopilotFileError.unsafePath }
        let descriptor = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CopilotFileError.current() }
        do {
            let stamp = try statFile(descriptor)
            guard stamp.isRegular, stamp.uid == owner,
                  permissions == nil || stamp.permissions == permissions else {
                throw CopilotFileError.unsafePath
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func statFile(_ descriptor: Int32) throws -> CopilotFileStamp {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw CopilotFileError.current() }
        return CopilotFileStamp(value)
    }

    static func statEntry(at directory: Int32, name: String) throws -> CopilotFileStamp {
        guard validComponent(name) else { throw CopilotFileError.unsafePath }
        var value = stat()
        guard fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw CopilotFileError.current()
        }
        return CopilotFileStamp(value)
    }

    static func names(at directory: Int32, limit: Int) throws -> (names: [String], limited: Bool) {
        let stream = try CopilotDirectoryStream(at: directory)
        defer { stream.closeStream() }
        var names: [String] = []
        while let name = try stream.next() {
            guard names.count < limit else { return (names.sorted(), true) }
            names.append(name)
        }
        return (names.sorted(), false)
    }

    static func read(_ descriptor: Int32, offset: Int64, count: Int) throws -> Data {
        guard count >= 0, offset >= 0 else { throw CopilotFileError.io }
        var bytes = Data(count: count)
        let size = bytes.withUnsafeMutableBytes {
            pread(descriptor, $0.baseAddress, count, off_t(offset))
        }
        guard size >= 0 else { throw CopilotFileError.current() }
        bytes.count = size
        return bytes
    }

    static func readIdentity(
        at directory: Int32, filename: String, owner: UInt32
    ) throws -> (CopilotIdentityRecord, CopilotFileStamp) {
        let descriptor = try openRegular(at: directory, name: filename, owner: owner, permissions: 0o600)
        defer { close(descriptor) }
        let before = try statFile(descriptor)
        guard before.size > 0, before.size <= 16_384 else { throw CopilotFileError.tooLarge }
        let bytes = try read(descriptor, offset: 0, count: 16_385)
        let record = try CopilotIdentityJSON.decode(bytes)
        guard before == (try statFile(descriptor)),
              before == (try statEntry(at: directory, name: filename)) else {
            throw CopilotFileError.changed
        }
        guard filename == record.sessionID.uuidString.lowercased() + ".json",
              record.ownerPID > 0, record.ownerStartSeconds > 0,
              record.ownerStartMicroseconds < 1_000_000,
              record.recordedAt.timeIntervalSince1970.isFinite else {
            throw CopilotFileError.unsafePath
        }
        return (record, before)
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
            && !value.utf8.contains(0)
    }
}
