import Darwin
import Foundation

// Per-session cache keyed only by exact session UUID. A file is re-read only
// when its identity, size or modification time changes.
nonisolated struct CopilotSessionNameCache: Sendable {
    private struct Entry: Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let name: String?

        func matches(_ stamp: CopilotFileStamp) -> Bool {
            device == stamp.device && inode == stamp.inode && size == stamp.size
                && modifiedSeconds == stamp.modifiedSeconds && modifiedNanoseconds == stamp.modifiedNanoseconds
        }
    }

    typealias Read = @Sendable (_ directory: Int32, _ filename: String, _ owner: UInt32, _ maximum: Int) throws -> Data

    private var entries: [UUID: Entry] = [:]
    private let read: Read
    private(set) var reads = 0

    var count: Int { entries.count }

    init(read: @escaping Read = { try CopilotFileAccess.readStableRegular(
        at: $0, filename: $1, owner: $2, maximum: $3
    ) }) {
        self.read = read
    }

    /// A missing or refused file (symlink, other owner, not regular, empty, oversized, malformed)
    /// drops the entry. A brief failure (the file changed mid-read, or I/O) keeps the previous
    /// name so the row does not flicker; the next poll re-reads.
    mutating func name(for sessionID: UUID, sessionDirectory: Int32, owner: UInt32) -> String? {
        let stamp: CopilotFileStamp
        do {
            stamp = try CopilotFileAccess.statEntry(at: sessionDirectory, name: CopilotSessionName.filename)
        } catch CopilotFileError.io {
            return entries[sessionID]?.name
        } catch {
            entries.removeValue(forKey: sessionID)
            return nil
        }
        guard stamp.isRegular, stamp.uid == owner,
              stamp.size > 0, stamp.size <= Int64(CopilotSessionName.maximumFileBytes) else {
            entries.removeValue(forKey: sessionID)
            return nil
        }
        if let cached = entries[sessionID], cached.matches(stamp) { return cached.name }
        reads += 1
        let data: Data
        do {
            data = try read(sessionDirectory, CopilotSessionName.filename, owner, CopilotSessionName.maximumFileBytes)
        } catch CopilotFileError.changed, CopilotFileError.io {
            return entries[sessionID]?.name
        } catch {
            entries.removeValue(forKey: sessionID)
            return nil
        }
        // Malformed content replaces the previous name with "unavailable" for this exact file
        // version, so it is not re-read every poll.
        let name = CopilotSessionName.parse(data)
        entries[sessionID] = .init(
            device: stamp.device, inode: stamp.inode, size: stamp.size,
            modifiedSeconds: stamp.modifiedSeconds, modifiedNanoseconds: stamp.modifiedNanoseconds, name: name
        )
        return name
    }

    mutating func forget(_ sessionID: UUID) { entries.removeValue(forKey: sessionID) }

    mutating func retain(only sessionIDs: Set<UUID>) {
        entries = entries.filter { sessionIDs.contains($0.key) }
    }

    mutating func removeAll() { entries.removeAll() }
}
