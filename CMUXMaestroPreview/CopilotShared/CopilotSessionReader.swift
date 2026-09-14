import Darwin
import Foundation

nonisolated struct CopilotReaderLimits: Sendable {
    let maximumSessions: Int
    let maximumBindings: Int
    let bytesPerRead: Int
    let bytesPerSession: Int
    let linesPerSession: Int
    let maximumLineBytes: Int
    let maximumLifecycleEvents: Int
    let maximumReplayFilterWords: Int
    let maximumRelationships: Int

    init(
        maximumSessions: Int = 64, maximumBindings: Int = 1024,
        bytesPerRead: Int = 8_388_608, bytesPerSession: Int = 4_194_304,
        linesPerSession: Int = 2048, maximumLineBytes: Int = 1_048_576,
        maximumLifecycleEvents: Int = 65_536, maximumReplayFilterWords: Int = 16_384,
        maximumRelationships: Int = 4096
    ) {
        self.maximumSessions = max(1, maximumSessions)
        self.maximumBindings = max(1, maximumBindings)
        self.bytesPerRead = max(1, bytesPerRead)
        self.bytesPerSession = max(1, bytesPerSession)
        self.linesPerSession = max(1, linesPerSession)
        self.maximumLineBytes = max(1, maximumLineBytes)
        self.maximumLifecycleEvents = max(1, maximumLifecycleEvents)
        self.maximumReplayFilterWords = max(1, maximumReplayFilterWords)
        self.maximumRelationships = max(1, maximumRelationships)
    }
}

actor CopilotSessionReader {
    private struct Binding {
        let record: CopilotIdentityRecord
        let stamp: CopilotFileStamp
        let filename: String
    }
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
        var target: Int64?
        var targetAt: Date?
    }

    private let roots: (@Sendable () throws -> (bindings: URL, sessions: URL))
    private let clock: @Sendable () -> Date
    private let verifier: CopilotIdentityVerifier
    private let limits: CopilotReaderLimits
    private var tails: [UUID: Tail] = [:]
    private var pendingHistory = false
    private var discovery: CopilotDirectoryStream?
    private var discoveryStamp: CopilotFileStamp?
    private var cycleChanged = false
    private var cycleOverflowed = false
    private var cycleIssues: [CopilotIssue] = []
    private var bindingsByID: [UUID: Binding] = [:]
    private var bindingOrder: [UUID] = []
    private var selectedSurfaces: Set<UUID> = []
    private var waitingBinding: Binding?
    private var publishedCohort: Set<UUID> = []
    private var lastDiscoveryCycle: CopilotFileStamp?
    private var fastDiscoveryCycle = true

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
        do {
            return try readBatch(surfaceIDs: surfaceIDs)
        } catch {
            resetDiscovery()
            try Self.rethrowCancellation(error)
            return .init(generatedAt: clock(), sessions: [], issues: [Self.issue(error)], isComplete: false)
        }
    }

    private func readBatch(surfaceIDs: Set<UUID>) throws -> CopilotSnapshot {
        pendingHistory = false
        try Task.checkCancellation()
        let now = clock()
        if selectedSurfaces != surfaceIDs {
            resetDiscovery()
            selectedSurfaces = surfaceIDs
        }
        guard !surfaceIDs.isEmpty else {
            resetDiscovery()
            return CopilotSnapshot(generatedAt: now, sessions: [], issues: [], isComplete: true)
        }
        var issues: [CopilotIssue] = []
        var observations: [CopilotSessionObservation] = []
        let directories: (bindings: URL, sessions: URL)
        do {
            directories = try roots()
        } catch {
            resetDiscovery()
            return .init(generatedAt: now, sessions: [], issues: [.stateUnavailable], isComplete: false)
        }
        let bindings: Int32
        do {
            bindings = try CopilotFileAccess.openDirectory(directories.bindings, owner: verifier.uid)
        } catch {
            resetDiscovery()
            try Self.rethrowCancellation(error)
            return .init(
                generatedAt: now, sessions: [],
                issues: [Self.issue(error, missing: .integrationNotInstalled)], isComplete: false
            )
        }
        defer { close(bindings) }
        do {
            let stamp = try CopilotFileAccess.statFile(bindings)
            if let previous = discoveryStamp, !previous.sameFile(as: stamp) {
                resetDiscovery()
            }
            if discovery == nil || (discovery?.finished == true && cohortFinished) {
                discovery = try CopilotDirectoryStream(at: bindings)
                discoveryStamp = stamp
                cycleChanged = false
                cycleOverflowed = false
                cycleIssues.removeAll()
                fastDiscoveryCycle = lastDiscoveryCycle != stamp
            } else if stamp != discoveryStamp {
                // Do not repeatedly restart a moving directory at its prefix.
                // Finish this pass, but only an unchanged cycle is complete.
                cycleChanged = true
            }
        } catch {
            resetDiscovery()
            try Self.rethrowCancellation(error)
            return .init(generatedAt: now, sessions: [], issues: [Self.issue(error)], isComplete: false)
        }

        // The cache contains only granted identities and is re-read before ANY
        // process or transcript access. A cached routing decision is not a grant.
        for id in bindingOrder {
            guard let cached = bindingsByID[id] else { continue }
            do {
                let (record, stamp) = try CopilotFileAccess.readIdentity(
                    at: bindings, filename: cached.filename, owner: verifier.uid
                )
                guard surfaceIDs.contains(record.surfaceID) else {
                    bindingsByID.removeValue(forKey: id)
                    continue
                }
                guard record.schemaVersion == 1 else {
                    bindingsByID.removeValue(forKey: id)
                    recordCycleIssue(.unsupportedFormat)
                    continue
                }
                cache(Binding(record: record, stamp: stamp, filename: cached.filename))
            } catch {
                try Self.rethrowCancellation(error)
                bindingsByID.removeValue(forKey: id)
                recordCycleIssue(Self.issue(error))
            }
        }
        bindingOrder.removeAll { bindingsByID[$0] == nil }
        publishedCohort.formIntersection(bindingsByID.keys)
        var scanned = 0
        var admitted = 0
        if let waiting = waitingBinding {
            do {
                let (record, stamp) = try CopilotFileAccess.readIdentity(
                    at: bindings, filename: waiting.filename, owner: verifier.uid
                )
                if !surfaceIDs.contains(record.surfaceID) {
                    waitingBinding = nil
                } else if record.schemaVersion != 1 {
                    recordCycleIssue(.unsupportedFormat)
                    waitingBinding = nil
                } else {
                    let entry = Binding(record: record, stamp: stamp, filename: waiting.filename)
                    if admit(entry) {
                        waitingBinding = nil
                        admitted += 1
                    } else {
                        waitingBinding = entry
                    }
                }
            } catch {
                try Self.rethrowCancellation(error)
                recordCycleIssue(Self.issue(error))
                waitingBinding = nil
            }
        }
        while waitingBinding == nil && scanned < limits.maximumBindings && admitted < limits.maximumSessions,
              let name = try discovery?.next() {
            scanned += 1
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
                guard record.schemaVersion == 1 else { recordCycleIssue(.unsupportedFormat); continue }
                let entry = Binding(record: record, stamp: stamp, filename: name)
                if bindingsByID[record.sessionID] == nil {
                    guard admit(entry) else {
                        waitingBinding = entry
                        break
                    }
                    admitted += 1
                } else {
                    cache(entry)
                }
            } catch {
                try Self.rethrowCancellation(error)
                recordCycleIssue(Self.issue(error))
            }
        }
        issues += cycleIssues
        let discoveryIncomplete = discovery?.finished != true || cycleChanged || cycleOverflowed
        if discoveryIncomplete { issues.append(.readLimitReached) }
        // Continuation is productive only until EOF, not merely while a limit
        // warning exists (e.g. a changing directory or too many visible sessions).
        pendingHistory = fastDiscoveryCycle && scanned > 0 && discovery?.finished == false
        let records = bindingOrder.compactMap { bindingsByID[$0] }
        let allowed = Set(records.map(\.record.sessionID))
        tails = tails.filter { allowed.contains($0.key) }
        guard try directoryRemainsValid(bindings, at: directories.bindings) else {
            resetDiscovery()
            return snapshot(now: now, observations: [], issues: [.identityChanged])
        }
        if records.isEmpty {
            if !discoveryIncomplete { issues.append(.noIdentityRecords) }
            if (try CopilotFileAccess.statFile(bindings)) != discoveryStamp {
                cycleChanged = true
                issues.append(.readLimitReached)
            }
            finishDiscoveryCycle()
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

        // Move the first cached identity to the end after each batch so a large
        // transcript cannot monopolize the shared byte budget.
        if let first = bindingOrder.first {
            bindingOrder.removeFirst()
            bindingOrder.append(first)
        }
        var byteBudget = limits.bytesPerRead
        var madeProgress = false
        var unreadHistory = false
        for entry in records {
            try Task.checkCancellation()
            let record = entry.record
            do {
                guard try bindingRemainsValid(
                    record, stamp: entry.stamp, filename: entry.filename, directory: bindings
                ) else {
                    bindingsByID.removeValue(forKey: record.sessionID)
                    tails.removeValue(forKey: record.sessionID)
                    publishedCohort.remove(record.sessionID)
                    issues.append(.identityChanged)
                    continue
                }
                let session = try CopilotFileAccess.openDirectory(
                    at: root, name: record.sessionID.uuidString.lowercased(), owner: verifier.uid
                )
                defer { close(session) }
                let before = try verifier.inspect(record: record, sessionDirectory: session)
                guard before.status == .alive else {
                    tails.removeValue(forKey: record.sessionID)
                    publishedCohort.insert(record.sessionID)
                    issues += Self.issues(before.status)
                    observations.append(observation(record, liveness: Self.liveness(before.status), now: now))
                    continue
                }
                var tail = tails[record.sessionID]
                if tail.map({ Self.sameBindingIdentity($0.record, record) }) != true {
                    tail = Tail(record: record, reducer: CopilotEventReducer(
                        sessionID: record.sessionID, maximumRelationships: limits.maximumRelationships,
                        maximumLifecycleEvents: limits.maximumLifecycleEvents,
                        maximumReplayFilterWords: limits.maximumReplayFilterWords
                    ))
                }
                var candidate = tail!
                var sessionIssues: [CopilotIssue] = []
                var advanced = false
                var hasUnread = false
                var reachedBoundary = false
                let previouslyPublished = candidate.lastComplete != nil
                do {
                    var advancing = candidate
                    let initialBudget = byteBudget
                    let result = try advance(&advancing, session: session, budget: &byteBudget, now: now)
                    sessionIssues = result.issues
                    reachedBoundary = result.reachedBoundary
                    candidate = advancing
                    advanced = byteBudget < initialBudget
                    hasUnread = (candidate.stamp?.size ?? 0) > candidate.offset
                } catch {
                    try Self.rethrowCancellation(error)
                    sessionIssues.append(Self.issue(error))
                    // A failed, explicitly unavailable observation must not pin
                    // every later binding behind an unreadable transcript.
                    reachedBoundary = true
                }
                let after = try verifier.verifyStable(before, record: record, sessionDirectory: session)
                guard try bindingRemainsValid(record, stamp: entry.stamp, filename: entry.filename, directory: bindings)
                else {
                    // Routing changed: even an ambiguous row would publish the
                    // superseded binding. Re-discover it under a current grant.
                    tails.removeValue(forKey: record.sessionID)
                    publishedCohort.remove(record.sessionID)
                    bindingsByID.removeValue(forKey: record.sessionID)
                    issues.append(.identityChanged)
                    continue
                }
                guard after.status == .alive,
                      (try CopilotFileAccess.statFile(session)).sameFile(
                        as: try CopilotFileAccess.statEntry(at: root, name: record.sessionID.uuidString.lowercased())
                      ) else {
                    // The routing grant remains valid; only process/session
                    // evidence is uncertain, so a content-free row is safe.
                    tails.removeValue(forKey: record.sessionID)
                    publishedCohort.insert(record.sessionID)
                    issues += after.status == .alive ? [.identityChanged] : Self.issues(after.status)
                    observations.append(observation(record, liveness: .ambiguous, now: now))
                    continue
                }
                tails[record.sessionID] = candidate
                if reachedBoundary { publishedCohort.insert(record.sessionID) }
                madeProgress = madeProgress || (advanced && (fastDiscoveryCycle || previouslyPublished))
                unreadHistory = unreadHistory || hasUnread
                issues += sessionIssues
                observations.append(observation(
                    record, liveness: .alive, now: candidate.lastCompleteAt ?? now,
                    value: candidate.lastComplete ?? CopilotReducedState()
                ))
            } catch {
                try Self.rethrowCancellation(error)
                publishedCohort.insert(record.sessionID)
                issues.append(Self.issue(error))
                observations.append(observation(record, liveness: .unknown, now: now))
            }
        }
        // A later session's I/O can race an earlier binding, including revocation.
        // Validate the entire published set and the path to our anchored index.
        observations = observations.filter { observation in
            guard let entry = bindingsByID[observation.sessionID],
                  (try? bindingRemainsValid(
                    entry.record, stamp: entry.stamp, filename: entry.filename, directory: bindings
                  )) == true else {
                tails.removeValue(forKey: observation.sessionID)
                bindingsByID.removeValue(forKey: observation.sessionID)
                publishedCohort.remove(observation.sessionID)
                issues.append(.identityChanged)
                return false
            }
            return true
        }
        guard (try? directoryRemainsValid(bindings, at: directories.bindings)) == true else {
            resetDiscovery()
            return snapshot(now: now, observations: [], issues: [.identityChanged])
        }
        if (try CopilotFileAccess.statFile(bindings)) != discoveryStamp {
            cycleChanged = true
            issues.append(.readLimitReached)
        }
        try Task.checkCancellation()
        pendingHistory = pendingHistory || (madeProgress && unreadHistory)
            || (fastDiscoveryCycle && waitingBinding != nil && !publishedCohort.isEmpty)
        // An overflow warning is not work. Finish this finite sweep before
        // polling another one; stationary evicted prefixes must not spin fast.
        if discovery?.finished == true && cohortFinished && cycleOverflowed { pendingHistory = false }
        finishDiscoveryCycle()
        return snapshot(now: now, observations: observations, issues: issues)
    }

    // Scheduling only: initial/changed index sweeps and retained-tail deltas.
    // Rebuilding evicted prefixes of an unchanged overflow uses normal polling.
    func hasPendingHistory() -> Bool { pendingHistory }

    func retentionCounts() -> (bindings: Int, tails: Int, waiting: Int, published: Int) {
        (bindingsByID.count, tails.count, waitingBinding == nil ? 0 : 1, publishedCohort.count)
    }

    private func resetDiscovery() {
        discovery?.closeStream()
        discovery = nil
        discoveryStamp = nil
        bindingsByID.removeAll()
        bindingOrder.removeAll()
        tails.removeAll()
        pendingHistory = false
        cycleChanged = false
        cycleOverflowed = false
        cycleIssues.removeAll()
        waitingBinding = nil
        publishedCohort.removeAll()
        lastDiscoveryCycle = nil
        fastDiscoveryCycle = true
    }

    private var cohortFinished: Bool {
        waitingBinding == nil && bindingsByID.keys.allSatisfy { publishedCohort.contains($0) }
    }

    private func finishDiscoveryCycle() {
        if discovery?.finished == true && cohortFinished && !cycleChanged {
            lastDiscoveryCycle = discoveryStamp
        }
    }

    private func admit(_ entry: Binding) -> Bool {
        if bindingsByID[entry.record.sessionID] == nil {
            if bindingOrder.count == limits.maximumSessions {
                guard let index = bindingOrder.firstIndex(where: { publishedCohort.contains($0) }) else {
                    return false
                }
                let retired = bindingOrder.remove(at: index)
                bindingsByID.removeValue(forKey: retired)
                tails.removeValue(forKey: retired)
                publishedCohort.remove(retired)
                cycleOverflowed = true
            }
            bindingOrder.append(entry.record.sessionID)
        }
        cache(entry)
        return true
    }

    private func cache(_ entry: Binding) {
        let id = entry.record.sessionID
        if let previous = bindingsByID[id], !Self.sameBindingIdentity(previous.record, entry.record) {
            tails.removeValue(forKey: id)
            publishedCohort.remove(id)
        }
        bindingsByID[id] = entry
    }

    private func recordCycleIssue(_ issue: CopilotIssue) {
        if !cycleIssues.contains(issue) { cycleIssues.append(issue) }
    }

    private func directoryRemainsValid(_ descriptor: Int32, at url: URL) throws -> Bool {
        let current = try CopilotFileAccess.openDirectory(url, owner: verifier.uid)
        defer { close(current) }
        return try CopilotFileAccess.statFile(descriptor).sameFile(as: CopilotFileAccess.statFile(current))
    }

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
    ) throws -> (issues: [CopilotIssue], reachedBoundary: Bool) {
        let file = try CopilotFileAccess.openRegular(at: session, name: "events.jsonl", owner: verifier.uid)
        defer { close(file) }
        let before = try CopilotFileAccess.statFile(file)
        var reset = false
        if let previous = tail.stamp {
            reset = !previous.sameFile(as: before) || before.size < previous.size || before.size < tail.offset
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
            tail = Tail(record: tail.record, reducer: CopilotEventReducer(
                sessionID: tail.record.sessionID, maximumRelationships: limits.maximumRelationships,
                maximumLifecycleEvents: limits.maximumLifecycleEvents,
                maximumReplayFilterWords: limits.maximumReplayFilterWords
            ))
            tail.lastComplete = saved
            tail.lastCompleteAt = savedAt
        }
        var remaining = min(budget, limits.bytesPerSession)
        var lines = 0
        if tail.target == nil {
            // Freeze a finite prefix. Appends cannot indefinitely extend the
            // initial catch-up lease and prevent another binding's admission.
            tail.target = before.size
            tail.targetAt = now
        }
        let targetSize = tail.target!
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
                        tail.reducer.consume(tail.partial, observedAt: now)
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
        let reachedBoundary = tail.offset >= targetSize
        if reachedBoundary {
            if tail.partial.isEmpty && !tail.droppingOversizedLine && tail.reducer.canPublishProjection {
                // A verified boundary can publish conservative semantic limits,
                // but malformed data, invalid schemas and identity errors cannot.
                tail.lastComplete = value
                // Verified current EOF is fresh; an older prefix with unread
                // appends must retain its captured age.
                tail.lastCompleteAt = tail.offset == after.size ? now : (tail.targetAt ?? now)
            }
            tail.target = nil
            tail.targetAt = nil
        }
        let incomplete = tail.offset < after.size || !tail.partial.isEmpty || tail.droppingOversizedLine
        if incomplete {
            issues.append(.loadingHistory)
            if tail.offset < after.size { issues.append(.readLimitReached) }
        }
        return (issues, reachedBoundary)
    }

    private func observation(
        _ record: CopilotIdentityRecord, liveness: CopilotLiveness, now: Date,
        value: CopilotReducedState = CopilotReducedState()
    ) -> CopilotSessionObservation {
        .init(
            sessionID: record.sessionID, surfaceID: record.surfaceID,
            launchWorkspaceID: record.launchWorkspaceID, liveness: liveness,
            state: value.state, model: value.model, children: value.children, observedAt: now,
            attention: value.attention, activity: value.activity
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
