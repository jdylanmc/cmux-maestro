import Darwin
import Foundation

nonisolated struct CopilotReaderLimits: Sendable {
    let maximumSessions: Int
    let maximumBindings: Int
    let bytesPerRead: Int
    let bytesPerSession: Int
    let linesPerSession: Int
    let maximumLineBytes: Int

    init(
        maximumSessions: Int = 64, maximumBindings: Int = 1024,
        bytesPerRead: Int = 8_388_608, bytesPerSession: Int = 4_194_304,
        linesPerSession: Int = 2048, maximumLineBytes: Int = 1_048_576
    ) {
        self.maximumSessions = max(1, maximumSessions)
        self.maximumBindings = max(1, maximumBindings)
        self.bytesPerRead = max(1, bytesPerRead)
        self.bytesPerSession = max(1, bytesPerSession)
        self.linesPerSession = max(1, linesPerSession)
        self.maximumLineBytes = max(1, maximumLineBytes)
    }
}

actor CopilotSessionReader {
    private struct Tail: Sendable {
        let record: CopilotIdentityRecord
        var stamp: CopilotFileStamp?
        var offset: Int64 = 0
        var partial = Data()
        var droppingOversizedLine = false
        var reducer: CopilotEventReducer
        var prefix = Data()
        var anchor = Data()
        var lastComplete: CopilotReducedState?
        var lastCompleteAt: Date?
    }

    private let roots: (@Sendable () throws -> (bindings: URL, sessions: URL))
    private let clock: @Sendable () -> Date
    private let verifier: CopilotIdentityVerifier
    private let limits: CopilotReaderLimits
    private var tails: [UUID: Tail] = [:]
    private var sessionCursor = 0
    private var pendingHistory = false

    init() {
        roots = { (try CopilotPaths.bindingDirectory(), try CopilotPaths.sessionStateRoot()) }
        clock = { Date() }
        verifier = CopilotIdentityVerifier()
        limits = CopilotReaderLimits()
    }

    init(
        bindingDirectory: URL, sessionStateRoot: URL,
        uid: UInt32 = getuid(), clock: @escaping @Sendable () -> Date = { Date() },
        processLookup: @escaping @Sendable (Int32) -> CopilotProcessLookup = CopilotProcessProbe.read,
        limits: CopilotReaderLimits = CopilotReaderLimits()
    ) {
        roots = { (bindingDirectory, sessionStateRoot) }
        self.clock = clock
        verifier = CopilotIdentityVerifier(uid: uid, lookup: processLookup)
        self.limits = limits
    }

    func read(surfaceIDs: Set<UUID>) async throws -> CopilotSnapshot {
        try Task.checkCancellation()
        pendingHistory = false
        let now = clock()
        guard !surfaceIDs.isEmpty else {
            tails.removeAll()
            return CopilotSnapshot(generatedAt: now, sessions: [], issues: [], isComplete: true)
        }
        var issues: [CopilotIssue] = []
        var observations: [CopilotSessionObservation] = []
        let directories: (bindings: URL, sessions: URL)
        do {
            directories = try roots()
        } catch {
            return .init(generatedAt: now, sessions: [], issues: [.stateUnavailable], isComplete: false)
        }
        let bindings: Int32
        do {
            bindings = try CopilotFileAccess.openDirectory(directories.bindings, owner: verifier.uid)
        } catch {
            try Self.rethrowCancellation(error)
            return .init(
                generatedAt: now, sessions: [],
                issues: [Self.issue(error, missing: .integrationNotInstalled)], isComplete: false
            )
        }
        defer { close(bindings) }
        let entries: (names: [String], limited: Bool)
        do {
            entries = try CopilotFileAccess.names(at: bindings, limit: limits.maximumBindings)
        } catch {
            try Self.rethrowCancellation(error)
            return .init(generatedAt: now, sessions: [], issues: [Self.issue(error)], isComplete: false)
        }
        if entries.limited { issues.append(.readLimitReached) }
        var records: [(record: CopilotIdentityRecord, stamp: CopilotFileStamp, filename: String)] = []
        for name in entries.names {
            try Task.checkCancellation()
            guard name.hasSuffix(".json"),
                  let id = UUID(uuidString: String(name.dropLast(5))),
                  name == id.uuidString.lowercased() + ".json" else { continue }
            do {
                // Discovery scans only Maestro's bounded, sanitized routing index.
                // Off-surface records never reach process validation or transcript reads,
                // and their identifiers/counts are not included in the snapshot.
                let (record, stamp) = try CopilotFileAccess.readIdentity(at: bindings, filename: name, owner: verifier.uid)
                guard surfaceIDs.contains(record.surfaceID) else { continue }
                guard record.schemaVersion == 1 else { issues.append(.unsupportedFormat); continue }
                records.append((record, stamp, name))
            } catch {
                try Self.rethrowCancellation(error)
                issues.append(Self.issue(error))
            }
        }
        let allowed = Set(records.map(\.record.sessionID))
        tails = tails.filter { allowed.contains($0.key) }
        if records.isEmpty {
            issues.append(.noIdentityRecords)
            return snapshot(now: now, observations: [], issues: issues)
        }
        let root: Int32
        do {
            root = try CopilotFileAccess.openDirectory(directories.sessions, owner: verifier.uid)
        } catch {
            try Self.rethrowCancellation(error)
            issues.append(Self.issue(error))
            return snapshot(now: now, observations: [], issues: issues)
        }
        defer { close(root) }

        // Rotate bounded work so a large first transcript cannot starve later surfaces.
        let start = sessionCursor % records.count
        records = Array(records[start...] + records[..<start])
        let selected = Array(records.prefix(limits.maximumSessions))
        sessionCursor = (start + 1) % records.count
        if selected.count < records.count { issues.append(.readLimitReached) }
        var byteBudget = limits.bytesPerRead
        var madeProgress = false
        var unreadHistory = false
        for entry in selected {
            try Task.checkCancellation()
            let record = entry.record
            do {
                let session = try CopilotFileAccess.openDirectory(
                    at: root, name: record.sessionID.uuidString.lowercased(), owner: verifier.uid
                )
                defer { close(session) }
                let before = try verifier.inspect(record: record, sessionDirectory: session)
                guard before.status == .alive else {
                    tails.removeValue(forKey: record.sessionID)
                    issues += Self.issues(before.status)
                    observations.append(observation(record, liveness: Self.liveness(before.status), now: now))
                    continue
                }
                var tail = tails[record.sessionID]
                if tail.map({ Self.sameBindingIdentity($0.record, record) }) != true {
                    tail = Tail(record: record, reducer: CopilotEventReducer(sessionID: record.sessionID))
                }
                var candidate = tail!
                var sessionIssues: [CopilotIssue] = []
                var advanced = false
                var hasUnread = false
                do {
                    var advancing = candidate
                    let initialBudget = byteBudget
                    sessionIssues = try advance(&advancing, session: session, budget: &byteBudget, now: now)
                    candidate = advancing
                    advanced = byteBudget < initialBudget
                    hasUnread = (candidate.stamp?.size ?? 0) > candidate.offset
                } catch {
                    try Self.rethrowCancellation(error)
                    sessionIssues.append(Self.issue(error))
                }
                let after = try verifier.verifyStable(before, record: record, sessionDirectory: session)
                guard after.status == .alive,
                      try bindingRemainsValid(record, stamp: entry.stamp, filename: entry.filename, directory: bindings),
                      (try CopilotFileAccess.statFile(session)).sameFile(
                        as: try CopilotFileAccess.statEntry(at: root, name: record.sessionID.uuidString.lowercased())
                      ) else {
                    tails.removeValue(forKey: record.sessionID)
                    issues += after.status == .alive ? [.identityChanged] : Self.issues(after.status)
                    observations.append(observation(record, liveness: .ambiguous, now: now))
                    continue
                }
                tails[record.sessionID] = candidate
                madeProgress = madeProgress || advanced
                unreadHistory = unreadHistory || hasUnread
                issues += sessionIssues
                observations.append(observation(
                    record, liveness: .alive, now: candidate.lastCompleteAt ?? now,
                    value: candidate.lastComplete ?? CopilotReducedState()
                ))
            } catch {
                try Self.rethrowCancellation(error)
                issues.append(Self.issue(error))
                observations.append(observation(record, liveness: .unknown, now: now))
            }
        }
        pendingHistory = madeProgress && unreadHistory
        return snapshot(now: now, observations: observations, issues: issues)
    }

    // Scheduling only: loadingHistory can also mean a torn line at EOF. A fast
    // retry is useful only when this batch progressed and bytes remain unread.
    func hasPendingHistory() -> Bool { pendingHistory }

    private static func sameBindingIdentity(_ lhs: CopilotIdentityRecord, _ rhs: CopilotIdentityRecord) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion && lhs.sessionID == rhs.sessionID
            && lhs.surfaceID == rhs.surfaceID && lhs.launchWorkspaceID == rhs.launchWorkspaceID
            && lhs.ownerPID == rhs.ownerPID && lhs.ownerStartSeconds == rhs.ownerStartSeconds
            && lhs.ownerStartMicroseconds == rhs.ownerStartMicroseconds
    }

    private func bindingRemainsValid(
        _ record: CopilotIdentityRecord, stamp: CopilotFileStamp, filename: String, directory: Int32
    ) throws -> Bool {
        if stamp == (try CopilotFileAccess.statEntry(at: directory, name: filename)) { return true }
        // Hooks atomically refresh recordedAt without changing ownership. Re-read
        // the secure record rather than treating every inode change as a new owner.
        let (refreshed, _) = try CopilotFileAccess.readIdentity(
            at: directory, filename: filename, owner: verifier.uid
        )
        return Self.sameBindingIdentity(record, refreshed)
    }

    private func advance(
        _ tail: inout Tail, session: Int32, budget: inout Int, now: Date
    ) throws -> [CopilotIssue] {
        let file = try CopilotFileAccess.openRegular(at: session, name: "events.jsonl", owner: verifier.uid)
        defer { close(file) }
        let before = try CopilotFileAccess.statFile(file)
        var reset = false
        if let previous = tail.stamp {
            reset = !previous.sameFile(as: before) || before.size < tail.offset
            if !reset && tail.offset > 0 {
                let prefix = try CopilotFileAccess.read(file, offset: 0, count: tail.prefix.count)
                let anchor = try CopilotFileAccess.read(
                    file, offset: tail.offset - Int64(tail.anchor.count), count: tail.anchor.count
                )
                reset = prefix != tail.prefix || anchor != tail.anchor
                    || (before.size == previous.size && before != previous)
            }
        }
        if reset {
            let saved = tail.lastComplete
            let savedAt = tail.lastCompleteAt
            tail = Tail(record: tail.record, reducer: CopilotEventReducer(sessionID: tail.record.sessionID))
            tail.lastComplete = saved
            tail.lastCompleteAt = savedAt
        }
        var remaining = min(budget, limits.bytesPerSession)
        var lines = 0
        let targetSize = before.size
        while tail.offset < targetSize && remaining > 0 && lines < limits.linesPerSession {
            try Task.checkCancellation()
            let count = min(262_144, remaining, Int(min(Int64(Int.max), targetSize - tail.offset)))
            let chunk = try CopilotFileAccess.read(file, offset: tail.offset, count: count)
            guard !chunk.isEmpty else { throw CopilotFileError.changed }
            var consumed = 0
            while consumed < chunk.count && lines < limits.linesPerSession {
                try Task.checkCancellation()
                let newline: Int? = chunk.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress,
                          let match = memchr(base.advanced(by: consumed), 10, bytes.count - consumed) else {
                        return nil
                    }
                    return base.distance(to: UnsafeRawPointer(match))
                }
                let end = newline ?? chunk.count
                if !tail.droppingOversizedLine {
                    if end - consumed <= limits.maximumLineBytes - tail.partial.count {
                        tail.partial.append(chunk[consumed..<end])
                    } else {
                        tail.partial.removeAll(keepingCapacity: false)
                        tail.droppingOversizedLine = true
                        tail.reducer.markMalformed()
                        tail.reducer.markLimited()
                    }
                }
                consumed = end
                if newline != nil {
                    if !tail.droppingOversizedLine {
                        if tail.partial.last == 13 { tail.partial.removeLast() }
                        tail.reducer.consume(tail.partial)
                    }
                    tail.partial.removeAll(keepingCapacity: true)
                    tail.droppingOversizedLine = false
                    lines += 1
                    consumed += 1
                }
            }
            tail.offset += Int64(consumed)
            remaining -= chunk.count
            budget -= chunk.count
        }
        let after = try CopilotFileAccess.statFile(file)
        guard before.sameFile(as: after), after.size >= targetSize,
              after.size != before.size || after == before,
              after.sameFile(as: try CopilotFileAccess.statEntry(at: session, name: "events.jsonl")) else {
            throw CopilotFileError.changed
        }
        tail.prefix = try CopilotFileAccess.read(file, offset: 0, count: Int(min(tail.offset, 128)))
        tail.anchor = try CopilotFileAccess.read(
            file, offset: max(0, tail.offset - 128), count: Int(min(tail.offset, 128))
        )
        tail.stamp = after
        let value = tail.reducer.value()
        var issues = tail.reducer.issues
        let incomplete = tail.offset < after.size || !tail.partial.isEmpty || tail.droppingOversizedLine
        if incomplete {
            issues.append(.loadingHistory)
            if tail.offset < after.size { issues.append(.readLimitReached) }
        } else if issues.isEmpty {
            tail.lastComplete = value
            tail.lastCompleteAt = now
        }
        return issues
    }

    private func observation(
        _ record: CopilotIdentityRecord, liveness: CopilotLiveness, now: Date,
        value: CopilotReducedState = CopilotReducedState()
    ) -> CopilotSessionObservation {
        .init(
            sessionID: record.sessionID, surfaceID: record.surfaceID,
            launchWorkspaceID: record.launchWorkspaceID, liveness: liveness,
            state: value.state, model: value.model, children: value.children, observedAt: now
        )
    }

    private func snapshot(
        now: Date, observations: [CopilotSessionObservation], issues: [CopilotIssue]
    ) -> CopilotSnapshot {
        let unique = Array(Set(issues.map(\.rawValue))).sorted().compactMap(CopilotIssue.init(rawValue:))
        return .init(
            generatedAt: now,
            sessions: observations.sorted { $0.sessionID.uuidString < $1.sessionID.uuidString },
            issues: unique, isComplete: unique.isEmpty
        )
    }

    private static func rethrowCancellation(_ error: any Error) throws {
        if error is CancellationError { throw error }
    }

    private static func issue(_ error: any Error, missing: CopilotIssue = .stateUnavailable) -> CopilotIssue {
        guard let error = error as? CopilotFileError else {
            return error is DecodingError ? .malformedData : .stateUnavailable
        }
        return switch error {
        case .missing: missing
        case .permissionDenied: .permissionDenied
        case .unsafePath: .ambiguousIdentity
        case .tooLarge: .readLimitReached
        case .changed: .identityChanged
        case .io: .stateUnavailable
        }
    }

    private static func issues(_ status: CopilotIdentityStatus) -> [CopilotIssue] {
        switch status {
        case .alive, .dead: []
        case .unknown: [.stateUnavailable]
        case .ambiguous: [.ambiguousIdentity]
        case .changed: [.identityChanged]
        case .unsupported: [.unsupportedFormat]
        }
    }

    private static func liveness(_ status: CopilotIdentityStatus) -> CopilotLiveness {
        switch status {
        case .alive: .alive
        case .dead: .dead
        case .ambiguous, .changed: .ambiguous
        case .unknown, .unsupported: .unknown
        }
    }
}
