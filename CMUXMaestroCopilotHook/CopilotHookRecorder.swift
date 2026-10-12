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

    func record(
        payload: Data, environment: [String: String], appearance: CopilotSessionAppearance? = nil,
        verifyOnly: Bool = false
    ) -> HookOutcome {
        guard !Self.isDisabled(environment) else { return .disabled }
        guard payload.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let session = Self.canonicalUUID((object["sessionId"] ?? object["session_id"]) as? String),
              object["sessionId"] == nil || object["session_id"] == nil
                || Self.canonicalUUID(object["sessionId"] as? String) == Self.canonicalUUID(object["session_id"] as? String),
              let workspace = Self.canonicalUUID(environment["CMUX_WORKSPACE_ID"]),
              let surface = Self.canonicalUUID(environment["CMUX_SURFACE_ID"])
        else { return diagnose(.invalidInput) }
        if let appearance, (!appearance.isValid || appearance.sessionID != session) {
            return diagnose(.invalidInput)
        }

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
                if appearance != nil || verifyOnly {
                    guard existing.sessionID == session, existing.surfaceID == surface,
                          existing.launchWorkspaceID == workspace, owner.owns(existing) else {
                        return diagnose(.noOwner)
                    }
                }
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
            } else {
                if appearance != nil || verifyOnly { return diagnose(.noOwner) }
                if errno != ENOENT { return diagnose(.unavailable) }
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

            // Ownership proof for callers that change something else (for example Beats): no write.
            if verifyOnly { return .recorded }
            if let appearance {
                let appearanceName = "appearance-\(session.uuidString.lowercased()).json"
                var selected = appearance
                do {
                    let data = try CopilotFileAccess.readStableRegular(
                        at: bindings, filename: appearanceName, owner: own.uid, maximum: 4096, permissions: 0o600
                    )
                    let previous = try JSONDecoder().decode(CopilotSessionAppearance.self, from: data)
                    guard previous.sessionID == session, previous.isValid else { return diagnose(.unavailable) }
                    selected.iconId = appearance.iconId ?? previous.iconId
                    selected.iconColor = appearance.iconColor ?? previous.iconColor
                    selected.petId = appearance.petId ?? previous.petId
                } catch CopilotFileError.missing {
                    // The first own-session choice has no previous appearance.
                }
                let finalBindings = try CopilotFileAccess.openDirectory(bindingURL, owner: own.uid)
                defer { close(finalBindings) }
                let finalSource = try CopilotFileAccess.openDirectory(sourceURL, owner: own.uid)
                defer { close(finalSource) }
                guard bindingsMetadata.sameFile(as: try CopilotFileAccess.statFile(finalBindings)),
                      sourceMetadata.sameFile(as: try CopilotFileAccess.statFile(finalSource)) else {
                    return diagnose(.noOwner)
                }
                guard try verifier.verifyStable(proof, record: record, sessionDirectory: currentSource).status == .alive,
                      ancestors.allSatisfy({ process($0.pid) == .found($0) }) else { return diagnose(.noOwner) }
                try HookFiles.atomicWrite(
                    JSONEncoder().encode(selected), name: appearanceName, directory: bindings
                )
            } else {
                try HookFiles.atomicWrite(CopilotIdentityJSON.encode(record), name: name, directory: bindings)
                // Best effort: a location failure never changes the recording outcome.
                recordLocation(object: object, session: session)
            }
            return .recorded
        } catch {
            return diagnose(.unavailable)
        }
    }

    func recordLocation(object: [String: Any], session: UUID) {
        let home = (try? CopilotPaths.realUserHome().path) ?? "/"
        let location = CopilotLocationResolver.resolve(payload: object, home: home)
        guard let directory = try? HookFiles.privateDirectory(
            integrationRoot.appendingPathComponent("locations", isDirectory: true)
        ) else { return }
        defer { close(directory) }
        let name = session.uuidString.lowercased() + ".json"
        guard let location else {
            unlinkat(directory, name, 0)
            return
        }
        let existing = try? CopilotFileAccess.readStableRegular(
            at: directory, filename: name, owner: getuid(), maximum: CopilotSessionLocation.maximumBytes, permissions: 0o600
        )
        if let existing, CopilotSessionLocation.decode(existing, sessionID: session) == location { return }
        guard let data = try? CopilotSessionLocation.encode(sessionID: session, location: location, recordedAt: Date())
        else { return }
        try? HookFiles.atomicWrite(data, name: name, directory: directory)
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

/// Finds the branch an agent is working in by reading plain files only: no
/// `git` process, no network, bounded depth and size. Any surprise is "no location".
nonisolated enum CopilotLocationResolver {
    static let maximumDepth = 40
    static let maximumReadBytes = 4096
    private static let shellTools: Set<String> = ["bash", "powershell", "shell", "sh", "zsh"]
    private static let pathKeys = ["path", "file_path", "filePath"]

    static func resolve(payload: [String: Any], home: String) -> CopilotSessionLocation? {
        candidates(payload: payload, home: home).first.flatMap(location(at:))
    }

    /// Most specific tool path first; payload cwd is the fallback when none is usable.
    static func candidates(payload: [String: Any], home: String) -> [String] {
        var result: [String] = []
        if let tool = payload["toolName"] as? String ?? payload["tool_name"] as? String,
           let arguments = toolArguments(payload) {
            if shellTools.contains(tool.lowercased()) {
                if let command = arguments["command"] as? String,
                   let path = lastLeadingChange(command, home: home) { result.append(path) }
            } else if let path = pathKeys.lazy.compactMap({ arguments[$0] as? String })
                .compactMap({ absolute($0, home: home) }).first {
                result.append(path)
            }
        }
        if let cwd = payload["cwd"] as? String, let path = absolute(cwd, home: home) { result.append(path) }
        return result
    }

    static func toolArguments(_ payload: [String: Any]) -> [String: Any]? {
        let raw = payload["toolArgs"] ?? payload["tool_args"] ?? payload["toolInput"] ?? payload["tool_input"]
        if let object = raw as? [String: Any] { return object }
        guard let text = raw as? String, text.utf8.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return nil }
        return object
    }

    static func absolute(_ value: String, home: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 4096, !value.utf8.contains(0) else { return nil }
        var path = value
        if path == "~" { path = home } else if path.hasPrefix("~/") { path = home + path.dropFirst() }
        guard path.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Target of the last `cd` in the leading `cd … && cd … && command` chain.
    static func lastLeadingChange(_ command: String, home: String) -> String? {
        guard command.utf8.count <= 16_384 else { return nil }
        var found: String?
        var rest = Substring(command)
        while true {
            rest = rest.drop { $0 == " " || $0 == "\t" || $0 == "\n" }
            guard rest.hasPrefix("cd"), rest.dropFirst(2).first.map({ $0 == " " || $0 == "\t" }) == true else { break }
            rest = rest.dropFirst(2).drop { $0 == " " || $0 == "\t" }
            while rest.hasPrefix("-") && !rest.hasPrefix("--") {
                let flag = rest.prefix { $0 != " " && $0 != "\t" }
                guard ["-P", "-L", "-e", "-@"].contains(String(flag)) else { return found }
                rest = rest.dropFirst(flag.count).drop { $0 == " " || $0 == "\t" }
            }
            var target = ""
            if let quote = rest.first, quote == "\"" || quote == "'" {
                let body = rest.dropFirst()
                guard let end = body.firstIndex(of: quote) else { return found }
                target = String(body[..<end])
                rest = body[body.index(after: end)...]
            } else {
                let token = rest.prefix { !" \t\n;&|<>()".contains($0) }
                target = String(token)
                rest = rest.dropFirst(token.count)
            }
            guard !target.isEmpty, !target.contains(where: { "$`*?[\\".contains($0) }),
                  let path = absolute(target, home: home) else { return found }
            found = path
            rest = rest.drop { $0 == " " || $0 == "\t" }
            if rest.hasPrefix("&&") { rest = rest.dropFirst(2) }
            else if rest.hasPrefix(";") || rest.hasPrefix("\n") { rest = rest.dropFirst() }
            else { break }
        }
        return found
    }

    static func location(at path: String) -> CopilotSessionLocation? {
        guard var directory = existingDirectory(path) else { return nil }
        for _ in 0..<maximumDepth {
            var entry = stat()
            if lstat(directory + "/.git", &entry) == 0 {
                switch entry.st_mode & S_IFMT {
                case S_IFDIR:
                    return branch(head: directory + "/.git/HEAD").map { .init(branch: $0, worktree: false) }
                case S_IFREG:
                    return linkedWorktree(file: directory + "/.git", base: directory)
                default:
                    return nil
                }
            }
            guard errno == ENOENT || errno == ENOTDIR, directory != "/" else { return nil }
            directory = (directory as NSString).deletingLastPathComponent
            if directory.isEmpty { return nil }
        }
        return nil
    }

    private static func existingDirectory(_ path: String) -> String? {
        var current = path
        for _ in 0..<64 {
            var entry = stat()
            if stat(current, &entry) == 0, entry.st_mode & S_IFMT == S_IFDIR { return current }
            guard current != "/" else { return nil }
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { return nil }
        }
        return nil
    }

    private static func linkedWorktree(file: String, base: String) -> CopilotSessionLocation? {
        guard let text = readSmallFile(file), text.hasPrefix("gitdir:") else { return nil }
        let line = text.dropFirst(7).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.utf8.contains(0) else { return nil }
        let gitDirectory = trimmed.hasPrefix("/") ? trimmed : base + "/" + trimmed
        var entry = stat()
        guard let normalized = absolute(gitDirectory, home: "/"),
              (normalized as NSString).deletingLastPathComponent.split(separator: "/").last == "worktrees",
              lstat(normalized, &entry) == 0, entry.st_mode & S_IFMT == S_IFDIR
        else { return nil }
        return branch(head: normalized + "/HEAD").map { .init(branch: $0, worktree: true) }
    }

    private static func branch(head path: String) -> String? {
        guard let text = readSmallFile(path), text.hasPrefix("ref: refs/heads/") else { return nil }
        let name = String(text.dropFirst(16).split(whereSeparator: \.isNewline).first ?? "")
            .trimmingCharacters(in: .whitespaces)
        return CopilotSessionLocation.validBranch(name) ? name : nil
    }

    /// Regular file only (never a symlink), at most 4 KiB, valid UTF-8.
    private static func readSmallFile(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var entry = stat()
        guard fstat(fd, &entry) == 0, entry.st_mode & S_IFMT == S_IFREG,
              entry.st_size > 0, entry.st_size <= maximumReadBytes else { return nil }
        var buffer = [UInt8](repeating: 0, count: maximumReadBytes + 1)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0, count <= maximumReadBytes, !buffer.prefix(count).contains(0) else { return nil }
        return String(bytes: buffer.prefix(count), encoding: .utf8)
    }
}
