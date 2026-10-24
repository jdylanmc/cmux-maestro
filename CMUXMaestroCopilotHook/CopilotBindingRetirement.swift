import CryptoKit
import Darwin
import Foundation

/// Opportunistic storage maintenance, never a reader or lifecycle authority.
nonisolated struct CopilotBindingRetirement {
    static let maximumEntries = 4096
    static let maximumCandidates = 64

    let integrationRoot: URL
    let sessionStateRoot: URL
    let process: @Sendable (Int32) -> CopilotProcessLookup

    private struct Candidate {
        let name: String
        let record: CopilotIdentityRecord
        let stamp: CopilotFileStamp
    }

    private struct Surface: Hashable {
        let workspace: UUID
        let surface: UUID
    }

    private struct Report: Encodable {
        var status = "complete"
        var examined = 0
        var retired = 0
    }

    private enum Failure: Error { case busy, changed }

    func run() {
        var report = Report()
        do {
            let root = try HookFiles.privateDirectory(integrationRoot)
            defer { close(root) }
            do {
                try pass(root: root, report: &report)
            } catch Failure.busy {
                report.status = "busy"
            } catch {
                report.status = "unavailable"
            }
            try HookFiles.atomicWrite(
                JSONEncoder().encode(report), name: "binding-retirement-status.json", directory: root)
        } catch {
            // Match hook diagnostics: only a bounded generic status, never paths or errors.
            let recorder = CopilotHookRecorder(
                integrationRoot: integrationRoot, sessionStateRoot: sessionStateRoot,
                processID: getpid(), process: process)
            recorder.diagnose(.unavailable)
        }
    }

    private func pass(root: Int32, report: inout Report) throws {
        let lease = try lock(at: root, name: ".binding-retirement.lock")
        defer { close(lease) }
        let bindings = try CopilotFileAccess.openDirectory(at: root, name: "bindings", owner: getuid())
        defer { close(bindings) }
        _ = try HookFiles.metadata(bindings, directory: true)
        let entries = try CopilotFileAccess.names(at: bindings, limit: Self.maximumEntries)
        guard !entries.limited else { report.status = "limited"; return }
        let names = entries.names.filter {
            $0.hasSuffix(".json") && CopilotHookRecorder.canonicalUUID(String($0.dropLast(5))) != nil
        }
        let cursor: String
        do {
            let data = try CopilotFileAccess.readStableRegular(
                at: root, filename: "binding-retirement-cursor", owner: getuid(), maximum: 41, permissions: 0o600)
            guard let value = String(data: data, encoding: .utf8), value.hasSuffix(".json"),
                  CopilotHookRecorder.canonicalUUID(String(value.dropLast(5))) != nil else {
                throw Failure.changed
            }
            cursor = value
        } catch CopilotFileError.missing {
            cursor = ""
        }
        let remaining = names.filter { $0 > cursor }
        let selected = Array((remaining.isEmpty ? names : remaining).prefix(Self.maximumCandidates))
        var candidates: [Candidate] = []
        for name in selected {
            report.examined += 1
            do {
                let candidate = try readCandidate(name, bindings: bindings)
                if try isDead(candidate) { candidates.append(candidate) }
            } catch {
                report.status = "partial"
            }
        }
        let groups = Dictionary(grouping: candidates) {
            Surface(workspace: $0.record.launchWorkspaceID, surface: $0.record.surfaceID)
        }
        for group in groups.values {
            guard let survivor = group.max(by: { $0.record.recordedAt < $1.record.recordedAt }) else { continue }
            for candidate in group where candidate.record.recordedAt < survivor.record.recordedAt {
                do {
                    if try retire(candidate, keeping: survivor, root: root, bindings: bindings) {
                        report.retired += 1
                    } else {
                        report.status = "partial"
                    }
                } catch {
                    report.status = "partial"
                }
            }
        }
        if let last = selected.last {
            try HookFiles.atomicWrite(Data(last.utf8), name: "binding-retirement-cursor", directory: root)
        }
    }

    private func isDead(_ candidate: Candidate) throws -> Bool {
        let record = candidate.record
        guard record.schemaVersion == 1, process(record.ownerPID) == .dead else { return false }
        let source = try CopilotFileAccess.openDirectory(
            sessionStateRoot.appendingPathComponent(record.sessionID.uuidString.lowercased()), owner: getuid())
        defer { close(source) }
        return try CopilotIdentityVerifier(uid: getuid(), lookup: process)
            .inspect(record: record, sessionDirectory: source).status == .dead
    }

    private func unchanged(_ candidate: Candidate, bindings: Int32) throws -> Bool {
        let current = try readCandidate(candidate.name, bindings: bindings)
        return current.record == candidate.record && current.stamp == candidate.stamp
    }

    private func readCandidate(_ name: String, bindings: Int32) throws -> Candidate {
        let fd = try CopilotFileAccess.openRegular(at: bindings, name: name, owner: getuid(), permissions: 0o600)
        defer { close(fd) }
        let stamp = CopilotFileStamp(try HookFiles.metadata(fd))
        let (record, current) = try CopilotFileAccess.readIdentity(at: bindings, filename: name, owner: getuid())
        guard stamp == current else { throw Failure.changed }
        return Candidate(name: name, record: record, stamp: stamp)
    }

    private func retire(
        _ candidate: Candidate, keeping survivor: Candidate, root: Int32, bindings: Int32
    ) throws -> Bool {
        // flock coordinates separate hook processes, including already-installed older writers.
        let candidateLock = try lock(at: bindings, name: ".\(candidate.record.sessionID.uuidString.lowercased()).lock")
        defer { close(candidateLock) }
        let survivorLock = try lock(at: bindings, name: ".\(survivor.record.sessionID.uuidString.lowercased()).lock")
        defer { close(survivorLock) }
        guard try unchanged(candidate, bindings: bindings), try unchanged(survivor, bindings: bindings),
              try isDead(candidate), try isDead(survivor) else { return false }
        let archive = try HookFiles.privateDirectory(integrationRoot.appendingPathComponent("retired-bindings"))
        defer { close(archive) }
        try preserve(candidate.record, archive: archive)

        let currentRoot = try CopilotFileAccess.openDirectory(integrationRoot, owner: getuid())
        defer { close(currentRoot) }
        let currentBindings = try CopilotFileAccess.openDirectory(at: currentRoot, name: "bindings", owner: getuid())
        defer { close(currentBindings) }
        let currentArchive = try CopilotFileAccess.openDirectory(at: currentRoot, name: "retired-bindings", owner: getuid())
        defer { close(currentArchive) }
        guard try CopilotFileAccess.statFile(root).sameFile(as: CopilotFileAccess.statFile(currentRoot)),
              try CopilotFileAccess.statFile(bindings).sameFile(as: CopilotFileAccess.statFile(currentBindings)),
              try CopilotFileAccess.statFile(archive).sameFile(as: CopilotFileAccess.statFile(currentArchive)),
              try isDead(candidate), try isDead(survivor),
              try unchanged(candidate, bindings: bindings), try unchanged(survivor, bindings: bindings) else { return false }
        guard unlinkat(bindings, candidate.name, 0) == 0, fsync(bindings) == 0 else {
            throw HookFiles.Failure.unavailable
        }
        return true
    }

    private func preserve(_ record: CopilotIdentityRecord, archive: Int32) throws {
        let data = try CopilotIdentityJSON.encode(record)
        let name = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".json"
        let fd = openat(archive, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 {
            guard errno == EEXIST else { throw HookFiles.Failure.unavailable }
            let existingFD = try CopilotFileAccess.openRegular(
                at: archive, name: name, owner: getuid(), permissions: 0o600)
            defer { close(existingFD) }
            let stamp = CopilotFileStamp(try HookFiles.metadata(existingFD))
            let existing = try CopilotFileAccess.readStableRegular(
                at: archive, filename: name, owner: getuid(), maximum: 16_384, permissions: 0o600)
            guard existing == data,
                  try stamp == CopilotFileAccess.statEntry(at: archive, name: name),
                  fsync(existingFD) == 0, fsync(archive) == 0 else { throw Failure.changed }
            return
        }
        defer { close(fd) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count, fsync(fd) == 0, fsync(archive) == 0 else {
            throw HookFiles.Failure.unavailable
        }
    }

    private func lock(at directory: Int32, name: String) throws -> Int32 {
        let fd = openat(directory, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HookFiles.Failure.unavailable }
        do {
            let metadata = try HookFiles.metadata(fd)
            guard metadata.st_mode & 0o7777 == 0o600 else { throw HookFiles.Failure.unavailable }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
            guard try CopilotFileAccess.statFile(fd) == CopilotFileAccess.statEntry(at: directory, name: name) else {
                throw Failure.changed
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }
}
