import Darwin
import Foundation

typealias HookProcess = CopilotProcessIdentity

extension CopilotProcessIdentity {
    nonisolated static func current(_ pid: Int32) -> HookProcess? {
        guard case .found(let process) = CopilotProcessProbe.read(pid) else { return nil }
        return process
    }

    nonisolated var startDate: Date {
        Date(timeIntervalSince1970: Double(startSeconds) + Double(startMicroseconds) / 1_000_000)
    }

    nonisolated func owns(_ record: CopilotIdentityRecord) -> Bool {
        pid == record.ownerPID && startSeconds == record.ownerStartSeconds
            && startMicroseconds == record.ownerStartMicroseconds
    }
}

nonisolated enum HookOutcome: String, Sendable {
    case recorded, disabled, invalidInput, noOwner, unavailable, superseded
}

/// All path traversal is descriptor-relative. The helper never follows a source
/// symlink or reads a transcript, process arguments, or another process's environment.
nonisolated enum HookFiles {
    enum Failure: Error { case unavailable }

    static func directory(_ url: URL, create: Bool = false) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw Failure.unavailable }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unavailable }
        do {
            for component in url.pathComponents.dropFirst() {
                guard component != ".", component != "..", !component.contains("/") else {
                    throw Failure.unavailable
                }
                if create && mkdirat(descriptor, component, 0o700) != 0 && errno != EEXIST {
                    throw Failure.unavailable
                }
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Failure.unavailable }
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func metadata(_ fd: Int32, directory: Bool = false) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_uid == getuid(), value.st_mode & 0o022 == 0,
              value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              directory || value.st_nlink == 1 else { throw Failure.unavailable }
        return value
    }

    static func privateDirectory(_ url: URL) throws -> Int32 {
        let fd = try directory(url, create: true)
        do {
            _ = try metadata(fd, directory: true)
            guard fchmod(fd, 0o700) == 0 else { throw Failure.unavailable }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    static func atomicWrite(_ data: Data, name: String, directory: Int32) throws {
        let pending = ".pending-\(UUID().uuidString)"
        let fd = openat(directory, pending, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        defer {
            close(fd)
            unlinkat(directory, pending, 0)
        }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count, fsync(fd) == 0,
              renameat(directory, pending, directory, name) == 0 else { throw Failure.unavailable }
    }
}

nonisolated struct CopilotHookRecorder {
    let integrationRoot: URL
    let sessionStateRoot: URL
    let processID: Int32
    let process: @Sendable (Int32) -> CopilotProcessLookup

    static func canonicalUUID(_ value: String?) -> UUID? {
        guard let value, value.count == 36, let id = UUID(uuidString: value),
              id.uuidString.lowercased() == value.lowercased() else { return nil }
        return id
    }

    static func isDisabled(_ environment: [String: String]) -> Bool {
        ["CMUX_COPILOT_HOOKS_DISABLED", "MAESTRO_NATIVE_DISABLED"].contains {
            guard let value = environment[$0]?.lowercased() else { return false }
            return !value.isEmpty && value != "0" && value != "false"
        }
    }

    func record(payload: Data, environment: [String: String]) -> HookOutcome {
        guard !Self.isDisabled(environment) else { return .disabled }
        guard payload.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let session = Self.canonicalUUID((object["sessionId"] ?? object["session_id"]) as? String),
              object["sessionId"] == nil || object["session_id"] == nil
                || Self.canonicalUUID(object["sessionId"] as? String) == Self.canonicalUUID(object["session_id"] as? String),
              let workspace = Self.canonicalUUID(environment["CMUX_WORKSPACE_ID"]),
              let surface = Self.canonicalUUID(environment["CMUX_SURFACE_ID"])
        else { return diagnose(.invalidInput) }

        do {
            guard case .found(let own) = process(processID), own.uid == getuid() else { return diagnose(.noOwner) }
            let sourceURL = sessionStateRoot.appendingPathComponent(session.uuidString.lowercased())
            let source = try CopilotFileAccess.openDirectory(sourceURL, owner: own.uid)
            defer { close(source) }
            let sourceMetadata = try CopilotFileAccess.statFile(source)
            var ancestors: [HookProcess] = [own]
            var next = own.parentPID
            var owner: HookProcess?
            for _ in 0..<32 {
                guard next > 1, !ancestors.contains(where: { $0.pid == next }),
                      case .found(let candidate) = process(next), candidate.uid == own.uid else { break }
                ancestors.append(candidate)
                let name = "inuse.\(candidate.pid).lock"
                if (try? CopilotFileAccess.statEntry(at: source, name: name)) != nil {
                    owner = candidate
                    break
                }
                next = candidate.parentPID
            }
            guard let owner else { return diagnose(.noOwner) }
            let record = CopilotIdentityRecord(sessionID: session, surfaceID: surface,
                launchWorkspaceID: workspace, ownerPID: owner.pid,
                ownerStartSeconds: owner.startSeconds, ownerStartMicroseconds: owner.startMicroseconds,
                recordedAt: own.startDate)
            let verifier = CopilotIdentityVerifier(uid: own.uid, lookup: process)
            let proof = try verifier.inspect(record: record, sessionDirectory: source)
            guard proof.status == .alive else { return diagnose(.noOwner) }
            let root = try HookFiles.privateDirectory(integrationRoot)
            defer { close(root) }
            let bindingURL = integrationRoot.appendingPathComponent("bindings")
            let bindings = try HookFiles.privateDirectory(bindingURL)
            defer { close(bindings) }
            let lockName = ".\(session.uuidString.lowercased()).lock"
            let lock = openat(bindings, lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard lock >= 0 else { return diagnose(.unavailable) }
            defer { close(lock) }
            _ = try HookFiles.metadata(lock)
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return diagnose(.unavailable) }
            defer { flock(lock, LOCK_UN) }

            let name = session.uuidString.lowercased() + ".json"
            let existingFD = openat(bindings, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if existingFD >= 0 {
                close(existingFD)
                guard let (existing, _) = try? CopilotFileAccess.readIdentity(
                    at: bindings, filename: name, owner: own.uid
                ) else { return diagnose(.superseded) }
                switch process(existing.ownerPID) {
                case .found(let live):
                    if live.uid != own.uid || (live.owns(existing)
                        && (!owner.owns(existing) || existing.recordedAt > own.startDate)) {
                        return diagnose(.superseded)
                    }
                case .unavailable:
                    return diagnose(.superseded)
                case .dead: break
                }
            } else if errno != ENOENT {
                return diagnose(.unavailable)
            }

            // Reopen the named source and marker immediately before committing:
            // a renamed directory, replaced lock, dead owner or reused PID fails closed.
            let currentSource = try CopilotFileAccess.openDirectory(sourceURL, owner: own.uid)
            defer { close(currentSource) }
            let currentBindings = try CopilotFileAccess.openDirectory(bindingURL, owner: own.uid)
            defer { close(currentBindings) }
            let bindingsMetadata = CopilotFileStamp(try HookFiles.metadata(bindings, directory: true))
            let currentBindingsMetadata = CopilotFileStamp(try HookFiles.metadata(currentBindings, directory: true))
            guard sourceMetadata.sameFile(as: try CopilotFileAccess.statFile(currentSource)),
                  bindingsMetadata.sameFile(as: currentBindingsMetadata),
                  try verifier.verifyStable(proof, record: record, sessionDirectory: currentSource).status == .alive,
                  ancestors.allSatisfy({ process($0.pid) == .found($0) }) else { return diagnose(.noOwner) }

            try HookFiles.atomicWrite(CopilotIdentityJSON.encode(record), name: name, directory: bindings)
            return .recorded
        } catch {
            return diagnose(.unavailable)
        }
    }

    @discardableResult
    func diagnose(_ outcome: HookOutcome) -> HookOutcome {
        // One bounded generic status, not a log of hook payloads, paths or CLI output.
        if let directory = try? HookFiles.privateDirectory(integrationRoot) {
            defer { close(directory) }
            try? HookFiles.atomicWrite(Data("{\"status\":\"\(outcome.rawValue)\"}\n".utf8),
                                       name: "hook-status.json", directory: directory)
        }
        return outcome
    }
}
