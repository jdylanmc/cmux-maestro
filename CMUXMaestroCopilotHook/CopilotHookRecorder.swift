import CryptoKit
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

    /// Only Maestro's own switch. `CMUX_COPILOT_HOOKS_DISABLED` silences CMUX's restore hooks, and
    /// Maestro launches set it (ADR 0024); Maestro must still observe those sessions.
    static func isDisabled(_ environment: [String: String]) -> Bool {
        guard let value = environment["MAESTRO_NATIVE_DISABLED"]?.lowercased() else { return false }
        return !value.isEmpty && value != "0" && value != "false"
    }

    /// What a proven owner may do. Every intent shares one ownership proof.
    enum Intent: Sendable {
        /// Record (or refresh) this session's binding. The only intent that may create one.
        case bind
        /// Merge an explicit own-session appearance choice. Needs an existing binding.
        case setAppearance(CopilotSessionAppearance)
        /// Prove ownership for a caller that changes something else (for example Beats). No write.
        case prove

        fileprivate var requiresExistingBinding: Bool {
            if case .bind = self { return false }
            return true
        }
    }

    func bind(payload: Data, environment: [String: String]) -> HookOutcome {
        record(payload: payload, environment: environment, intent: .bind)
    }

    func setAppearance(
        _ appearance: CopilotSessionAppearance, payload: Data, environment: [String: String]
    ) -> HookOutcome {
        record(payload: payload, environment: environment, intent: .setAppearance(appearance))
    }

    func prove(payload: Data, environment: [String: String]) -> HookOutcome {
        record(payload: payload, environment: environment, intent: .prove)
    }

    private func record(payload: Data, environment: [String: String], intent: Intent) -> HookOutcome {
        guard !Self.isDisabled(environment) else { return .disabled }
        guard let request = HookRequest(payload: payload, environment: environment) else {
            return diagnose(.invalidInput)
        }
        if case .setAppearance(let appearance) = intent,
           !appearance.isValid || appearance.sessionID != request.session {
            return diagnose(.invalidInput)
        }
        do {
            return try withProvenOwnership(request, intent: intent) { ownership in
                switch intent {
                case .prove:
                    return .recorded
                case .setAppearance(let appearance):
                    return try commitAppearance(appearance, ownership: ownership)
                case .bind:
                    return try commitBinding(ownership)
                }
            }
        } catch {
            return diagnose(.unavailable)
        }
    }

    // MARK: Ownership proof

    private struct HookRequest {
        let object: [String: Any]
        let session: UUID
        let workspace: UUID
        let surface: UUID

        init?(payload: Data, environment: [String: String]) {
            guard payload.count <= 65_536,
                  let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let session = CopilotHookRecorder.canonicalUUID((object["sessionId"] ?? object["session_id"]) as? String),
                  object["sessionId"] == nil || object["session_id"] == nil
                    || CopilotHookRecorder.canonicalUUID(object["sessionId"] as? String)
                        == CopilotHookRecorder.canonicalUUID(object["session_id"] as? String),
                  let workspace = CopilotHookRecorder.canonicalUUID(environment["CMUX_WORKSPACE_ID"]),
                  let surface = CopilotHookRecorder.canonicalUUID(environment["CMUX_SURFACE_ID"])
            else { return nil }
            self.object = object
            self.session = session
            self.workspace = workspace
            self.surface = surface
        }

        var bindingName: String { session.uuidString.lowercased() + ".json" }
    }

    /// Evidence held open (and locked) for the duration of a commit.
    private struct Ownership {
        let request: HookRequest
        let own: HookProcess
        let ancestors: [HookProcess]
        let record: CopilotIdentityRecord
        let verifier: CopilotIdentityVerifier
        let proof: CopilotIdentityEvidence
        let sourceURL: URL
        let sourceMetadata: CopilotFileStamp
        let bindingURL: URL
        let bindings: Int32
        let bindingsMetadata: CopilotFileStamp
        let currentSource: Int32
    }

    private struct ProcessAncestry {
        let ancestors: [HookProcess]
        let owner: HookProcess?
    }

    private func withProvenOwnership(
        _ request: HookRequest, intent: Intent, _ commit: (Ownership) throws -> HookOutcome
    ) throws -> HookOutcome {
        guard case .found(let own) = process(processID), own.uid == getuid() else { return diagnose(.noOwner) }
        let sourceURL = sessionStateRoot.appendingPathComponent(request.session.uuidString.lowercased())
        let source = try CopilotFileAccess.openDirectory(sourceURL, owner: own.uid)
        defer { close(source) }
        let sourceMetadata = try CopilotFileAccess.statFile(source)
        let ancestry = findOwner(from: own, source: source)
        guard let owner = ancestry.owner else { return diagnose(.noOwner) }
        let record = CopilotIdentityRecord(sessionID: request.session, surfaceID: request.surface,
            launchWorkspaceID: request.workspace, ownerPID: owner.pid,
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
        let lockName = ".\(request.session.uuidString.lowercased()).lock"
        let lock = openat(bindings, lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { return diagnose(.unavailable) }
        defer { close(lock) }
        _ = try HookFiles.metadata(lock)
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return diagnose(.unavailable) }
        defer { flock(lock, LOCK_UN) }

        if let refusal = existingBindingRefusal(
            request, intent: intent, own: own, owner: owner, bindings: bindings
        ) { return diagnose(refusal) }

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
              ancestry.ancestors.allSatisfy({ process($0.pid) == .found($0) }) else { return diagnose(.noOwner) }

        return try commit(Ownership(
            request: request, own: own, ancestors: ancestry.ancestors, record: record, verifier: verifier,
            proof: proof, sourceURL: sourceURL, sourceMetadata: sourceMetadata, bindingURL: bindingURL,
            bindings: bindings, bindingsMetadata: bindingsMetadata, currentSource: currentSource
        ))
    }

    // The owner is the nearest same-user ancestor holding the session's in-use marker.
    private func findOwner(from own: HookProcess, source: Int32) -> ProcessAncestry {
        var ancestors: [HookProcess] = [own]
        var next = own.parentPID
        for _ in 0..<32 {
            guard next > 1, !ancestors.contains(where: { $0.pid == next }),
                  case .found(let candidate) = process(next), candidate.uid == own.uid else { break }
            ancestors.append(candidate)
            let name = "inuse.\(candidate.pid).lock"
            if (try? CopilotFileAccess.statEntry(at: source, name: name)) != nil {
                return ProcessAncestry(ancestors: ancestors, owner: candidate)
            }
            next = candidate.parentPID
        }
        return ProcessAncestry(ancestors: ancestors, owner: nil)
    }

    // A live, newer or foreign binding supersedes this one. Only `bind` may
    // proceed without a binding, and others must match it exactly.
    private func existingBindingRefusal(
        _ request: HookRequest, intent: Intent, own: HookProcess, owner: HookProcess, bindings: Int32
    ) -> HookOutcome? {
        let name = request.bindingName
        let existingFD = openat(bindings, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard existingFD >= 0 else {
            if intent.requiresExistingBinding { return .noOwner }
            return errno != ENOENT ? .unavailable : nil
        }
        close(existingFD)
        guard let (existing, _) = try? CopilotFileAccess.readIdentity(
            at: bindings, filename: name, owner: own.uid
        ) else { return .superseded }
        if intent.requiresExistingBinding {
            guard existing.sessionID == request.session, existing.surfaceID == request.surface,
                  existing.launchWorkspaceID == request.workspace, owner.owns(existing) else {
                return .noOwner
            }
        }
        switch process(existing.ownerPID) {
        case .found(let live):
            if live.uid != own.uid || (live.owns(existing)
                && (!owner.owns(existing) || existing.recordedAt > own.startDate)) {
                return .superseded
            }
        case .unavailable:
            return .superseded
        case .dead: break
        }
        return nil
    }

    // MARK: Commits

    private func commitBinding(_ ownership: Ownership) throws -> HookOutcome {
        try HookFiles.atomicWrite(
            CopilotIdentityJSON.encode(ownership.record), name: ownership.request.bindingName,
            directory: ownership.bindings
        )
        // Best effort: a location failure never changes the recording outcome.
        recordLocation(object: ownership.request.object, session: ownership.request.session,
                       sessionDirectory: ownership.currentSource)
        return .recorded
    }

    private func commitAppearance(_ appearance: CopilotSessionAppearance, ownership: Ownership) throws -> HookOutcome {
        let session = ownership.request.session
        let appearanceName = "appearance-\(session.uuidString.lowercased()).json"
        var selected = appearance
        do {
            let data = try CopilotFileAccess.readStableRegular(
                at: ownership.bindings, filename: appearanceName, owner: ownership.own.uid,
                maximum: 4096, permissions: 0o600
            )
            let previous = try JSONDecoder().decode(CopilotSessionAppearance.self, from: data)
            guard previous.sessionID == session, previous.isValid else { return diagnose(.unavailable) }
            selected.iconId = appearance.iconId ?? previous.iconId
            selected.iconColor = appearance.iconColor ?? previous.iconColor
            selected.petId = appearance.petId ?? previous.petId
        } catch CopilotFileError.missing {
            // The first own-session choice has no previous appearance.
        }
        let finalBindings = try CopilotFileAccess.openDirectory(ownership.bindingURL, owner: ownership.own.uid)
        defer { close(finalBindings) }
        let finalSource = try CopilotFileAccess.openDirectory(ownership.sourceURL, owner: ownership.own.uid)
        defer { close(finalSource) }
        guard ownership.bindingsMetadata.sameFile(as: try CopilotFileAccess.statFile(finalBindings)),
              ownership.sourceMetadata.sameFile(as: try CopilotFileAccess.statFile(finalSource)) else {
            return diagnose(.noOwner)
        }
        guard try ownership.verifier.verifyStable(
            ownership.proof, record: ownership.record, sessionDirectory: ownership.currentSource
        ).status == .alive,
              ownership.ancestors.allSatisfy({ process($0.pid) == .found($0) }) else { return diagnose(.noOwner) }
        try HookFiles.atomicWrite(
            JSONEncoder().encode(selected), name: appearanceName, directory: ownership.bindings
        )
        return .recorded
    }

    /// `sessionDirectory` is the exact session's state directory this hook just proved it owns.
    func recordLocation(object: [String: Any], session: UUID, sessionDirectory: Int32) {
        let home = (try? CopilotPaths.realUserHome().path) ?? "/"
        let location = CopilotLocationResolver.resolve(payload: object, home: home)
        let current = CopilotWorktreeResolver.observe(sessionDirectory: sessionDirectory, owner: getuid())
        guard let directory = try? HookFiles.privateDirectory(
            integrationRoot.appendingPathComponent("locations", isDirectory: true)
        ) else { return }
        defer { close(directory) }
        let name = session.uuidString.lowercased() + ".json"
        let existing = try? CopilotFileAccess.readStableRegular(
            at: directory, filename: name, owner: getuid(), maximum: CopilotSessionLocation.maximumBytes, permissions: 0o600
        )
        if let existing, CopilotSessionLocationRecord.decode(existing, sessionID: session)
            == CopilotSessionLocationRecord(location: location, current: current) { return }
        guard let data = try? CopilotSessionLocation.encode(
            sessionID: session, location: location, current: current, recordedAt: Date()
        ) else { return }
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

/// The worktree a session's own selected directory is in (ADR 0026). Reads `workspace.yaml`
/// `cwd:` from the session's state directory, then only Git's plain files under that directory:
/// no `git` process, no environment, bounded depth and size. Any surprise is `unknown`, never
/// `nonRepository`.
nonisolated enum CopilotWorktreeResolver {
    static let maximumDepth = 64

    static func observe(sessionDirectory: Int32, owner: UInt32) -> CopilotSessionWorktree {
        guard let stamp = try? CopilotFileAccess.statEntry(at: sessionDirectory, name: CopilotSessionName.filename),
              stamp.isRegular, stamp.uid == owner, stamp.size > 0,
              stamp.size <= Int64(CopilotSessionName.maximumFileBytes),
              let data = try? CopilotFileAccess.readStableRegular(
                at: sessionDirectory, filename: CopilotSessionName.filename, owner: owner,
                maximum: CopilotSessionName.maximumFileBytes
              ),
              let after = try? CopilotFileAccess.statEntry(at: sessionDirectory, name: CopilotSessionName.filename),
              after.sameFile(as: stamp), after.size == stamp.size,
              after.modifiedSeconds == stamp.modifiedSeconds,
              after.modifiedNanoseconds == stamp.modifiedNanoseconds
        else { return .init(evidence: .unknown, source: nil) }
        let source = CopilotWorktreeSource(stamp)
        guard let cwd = CopilotSessionName.scalar(forKey: "cwd", in: data) else {
            return .init(evidence: .unknown, source: source)
        }
        return .init(evidence: resolve(directory: cwd), source: source)
    }

    static func resolve(directory: String) -> CopilotWorktreeEvidence {
        guard directory.hasPrefix("/"), directory.utf8.count <= 4096, !directory.utf8.contains(0),
              let start = canonical(directory), isDirectory(start) else { return .unknown }
        var current = start
        for _ in 0..<maximumDepth {
            var entry = stat()
            if lstat(join(current, ".git"), &entry) == 0 {
                switch entry.st_mode & S_IFMT {
                case S_IFDIR: return verified(gitDirectory: join(current, ".git"), root: current)
                case S_IFREG: return linked(file: join(current, ".git"), root: current)
                default: return .unknown
                }
            }
            // Only "not there" continues upward; denied or failed reads prove nothing.
            guard errno == ENOENT else { return .unknown }
            // Inside a bare repository or a Git administrative directory: unsupported, not "no repository".
            if looksLikeGitDirectory(current) || current.split(separator: "/").contains(".git") { return .unknown }
            if current == "/" { return .nonRepository }
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { return .unknown }
        }
        return .unknown
    }

    private static func linked(file: String, root: String) -> CopilotWorktreeEvidence {
        guard let text = readSmallFile(file), text.hasPrefix("gitdir:") else { return .unknown }
        let line = text.dropFirst(7).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.utf8.contains(0),
              let gitDirectory = canonical(trimmed.hasPrefix("/") ? trimmed : join(root, trimmed)),
              isDirectory(gitDirectory) else { return .unknown }
        return verified(gitDirectory: gitDirectory, root: root)
    }

    private static func verified(gitDirectory path: String, root: String) -> CopilotWorktreeEvidence {
        guard let gitDirectory = canonical(path), let head = readSmallFile(join(gitDirectory, "HEAD")),
              let parsedHead = parseHead(head) else { return .unknown }
        // A linked worktree's Git directory names the shared one in `commondir`.
        var common = gitDirectory
        var isLinked = false
        var entry = stat()
        if lstat(join(gitDirectory, "commondir"), &entry) == 0 {
            guard let text = readSmallFile(join(gitDirectory, "commondir")),
                  let line = text.split(whereSeparator: \.isNewline).first.map(String.init),
                  !line.isEmpty,
                  let resolved = canonical(line.hasPrefix("/") ? line : join(gitDirectory, line)),
                  isDirectory(resolved) else { return .unknown }
            common = resolved
            isLinked = true
        } else if errno != ENOENT {
            return .unknown
        }
        let commonName = (common as NSString).lastPathComponent
        let repositoryPath = commonName == ".git" ? (common as NSString).deletingLastPathComponent
            : isLinked ? common : root
        var repository = (repositoryPath as NSString).lastPathComponent
        if repository.hasSuffix(".git"), repository.count > 4 { repository.removeLast(4) }
        guard let label = CopilotDisplayText.sanitize(repository, limit: 100),
              CopilotWorktreeIdentity.validLabel(label) else { return .unknown }
        return .verified(.init(key: key(gitDirectory), repository: label, head: parsedHead, linked: isLinked))
    }

    static func key(_ gitDirectory: String) -> String {
        let digest = SHA256.hash(data: Data(("cmux-maestro-worktree-v1\u{0}" + gitDirectory).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func parseHead(_ text: String) -> CopilotWorktreeHead? {
        let line = (text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("ref: refs/heads/") {
            let name = String(line.dropFirst(16))
            return CopilotSessionLocation.validBranch(name) ? .branch(name) : nil
        }
        guard [40, 64].contains(line.utf8.count),
              line.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return .detached(String(line.prefix(7)))
    }

    private static func looksLikeGitDirectory(_ path: String) -> Bool {
        var head = stat(), objects = stat(), refs = stat()
        return lstat(join(path, "HEAD"), &head) == 0 && head.st_mode & S_IFMT == S_IFREG
            && lstat(join(path, "objects"), &objects) == 0 && objects.st_mode & S_IFMT == S_IFDIR
            && lstat(join(path, "refs"), &refs) == 0 && refs.st_mode & S_IFMT == S_IFDIR
    }

    private static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(validatingCString: resolved)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var entry = stat()
        return stat(path, &entry) == 0 && entry.st_mode & S_IFMT == S_IFDIR
    }

    private static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    /// Regular file only (never a symlink), at most 4 KiB, valid UTF-8.
    private static func readSmallFile(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var entry = stat()
        guard fstat(fd, &entry) == 0, entry.st_mode & S_IFMT == S_IFREG,
              entry.st_size > 0, entry.st_size <= 4096 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4097)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0, count <= 4096, !buffer.prefix(count).contains(0) else { return nil }
        return String(bytes: buffer.prefix(count), encoding: .utf8)
    }
}
