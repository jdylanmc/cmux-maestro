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
    enum ConfigurationError: Error { case invalidTailWindow }
    private struct Binding {
        let record: CopilotIdentityRecord
        let stamp: CopilotFileStamp
        let filename: String
    }
    private struct Tail: Sendable {
        let record: CopilotIdentityRecord
        var stamp: CopilotFileStamp?
        var readableStamp: CopilotFileStamp?
        var offset: Int64 = 0
        var partial = Data()
        var droppingOversizedLine = false
        var assetEnvelope: CopilotAssetEnvelope?
        var reducer: CopilotEventReducer
        var prefix = Data()
        var anchor = Data()
        var lastComplete: CopilotReducedState?
        var lastCompleteAt: Date?
        var target: Int64?
        var targetAt: Date?
        var historyIncomplete = false
        var discardingInitialLine = false
        var projectionInvalidated = false
    }

    private let roots: (@Sendable () throws -> (bindings: URL, sessions: URL))
    private let clock: @Sendable () -> Date
    private let verifier: CopilotIdentityVerifier
    private let limits: CopilotReaderLimits
    private let eventRead: @Sendable (Int32, Int64, Int) throws -> Data
    private var tails: [UUID: Tail] = [:]
    private var pendingHistory = false
    private var tailWindowBytes = CopilotTailWindow.defaultMiB * 1_048_576
    private var discovery: CopilotDirectoryStream?
    private var discoveryStamp: CopilotFileStamp?
    private var cycleChanged = false
    private var cycleOverflowed = false
    private var cycleIssues: [CopilotIssue] = []
    private var bindingsByID: [UUID: Binding] = [:]
    private var endedBindingsBySurface: [UUID: Binding] = [:]
    private var bindingOrder: [UUID] = []
    private var selectedSurfaces: Set<UUID> = []
    private var waitingBinding: Binding?
    private var publishedCohort: Set<UUID> = []
    private var lastDiscoveryCycle: CopilotFileStamp?
    private var fastDiscoveryCycle = true
    private var sessionNames = CopilotSessionNameCache()
    private var managedNames = CopilotSessionNameCache()
    // Bounded decoded routing metadata, not process/session evidence or grants.
    private var identityCache: [String: Binding] = [:]
    private var unseenIdentities: Set<String> = []
    private(set) var eventReadBytes = 0
    private(set) var eventFileOpens = 0
    private(set) var projectionBuilds = 0
    private(set) var identityReads = 0

    init() {
        roots = { (try CopilotPaths.bindingDirectory(), try CopilotPaths.sessionStateRoot()) }
        clock = { Date() }
        verifier = CopilotIdentityVerifier()
        limits = CopilotReaderLimits()
        eventRead = CopilotFileAccess.read
    }

    init(
        bindingDirectory: URL, sessionStateRoot: URL,
        uid: UInt32 = getuid(), clock: @escaping @Sendable () -> Date = { Date() },
        processLookup: @escaping @Sendable (Int32) -> CopilotProcessLookup = CopilotProcessProbe.read,
        limits: CopilotReaderLimits = CopilotReaderLimits(),
        eventRead: @escaping @Sendable (Int32, Int64, Int) throws -> Data = CopilotFileAccess.read
    ) {
        roots = { (bindingDirectory, sessionStateRoot) }
        self.clock = clock
        verifier = CopilotIdentityVerifier(uid: uid, lookup: processLookup)
        self.limits = limits
        self.eventRead = eventRead
    }

    func read(
        surfaceIDs: Set<UUID>, tailWindowMiB: Int = CopilotTailWindow.defaultMiB
    ) async throws -> CopilotSnapshot {
        guard let window = CopilotTailWindow(mebibytes: tailWindowMiB) else {
            throw ConfigurationError.invalidTailWindow
        }
        tailWindowBytes = window.bytes
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
            selectedSurfaces = surfaceIDs
            resetDiscovery()
        }
        guard !surfaceIDs.isEmpty else {
            resetDiscovery()
            return CopilotSnapshot(generatedAt: now, sessions: [], issues: [], isComplete: true)
        }
        let index: BindingIndex
        switch try openBindingIndex(now: now) {
        case .finished(let snapshot): return snapshot
        case .opened(let opened): index = opened
        }
        defer { close(index.descriptor) }
        var batch = Batch(now: now)
        if let failure = try beginDiscoveryCycle(index, batch: &batch) { return failure }
        try refreshCachedBindings(index, surfaceIDs: surfaceIDs)
        let admitted = try resumeWaitingBinding(index, surfaceIDs: surfaceIDs)
        let scanned = try scanBindings(index, surfaceIDs: surfaceIDs, admitted: admitted)
        let discoveryIncomplete = concludeDiscoveryScan(scanned: scanned, batch: &batch)
        let records = bindingOrder.compactMap { bindingsByID[$0] }
        let allowed = Set(records.map(\.record.sessionID))
        tails = tails.filter { allowed.contains($0.key) }
        sessionNames.retain(only: allowed)
        guard try directoryRemainsValid(index.descriptor, at: index.directories.bindings) else {
            resetDiscovery()
            return snapshot(now: now, observations: [], issues: [.identityChanged])
        }
        let root: SessionRoot?
        if records.isEmpty && endedBindingsBySurface.isEmpty {
            root = nil
        } else {
            do {
                root = SessionRoot(descriptor: try CopilotFileAccess.openDirectory(
                    index.directories.sessions, owner: verifier.uid
                ))
            } catch CopilotFileError.missing where records.isEmpty {
                root = SessionRoot(descriptor: nil)
            } catch {
                try Self.rethrowCancellation(error)
                batch.issues.append(Self.issue(error))
                return snapshot(now: now, observations: [], issues: batch.issues)
            }
        }
        defer { if let descriptor = root?.descriptor { close(descriptor) } }
        rotateBindingOrder()
        var byteBudget = limits.bytesPerRead
        if let descriptor = root?.descriptor {
            for entry in records {
                try Task.checkCancellation()
                let outcome = try readSession(entry, index: index, root: descriptor, budget: &byteBudget, now: now)
                absorb(outcome, for: entry.record, batch: &batch)
            }
        }
        try appendEndedObservations(index, root: root?.descriptor, batch: &batch)
        if records.isEmpty && !discoveryIncomplete && batch.observations.isEmpty {
            batch.issues.append(.noIdentityRecords)
        }
        try decorateObservations(index, batch: &batch)
        fenceObservations(index, batch: &batch)
        return try publish(index, sessionRoot: root, batch: batch)
    }

    // MARK: Batch phases

    private struct BindingIndex {
        let directories: (bindings: URL, sessions: URL)
        let descriptor: Int32
    }

    /// Nil descriptor records verified absence for an ended-only cohort, not an uninspected root.
    private struct SessionRoot {
        let descriptor: Int32?
    }

    private enum BindingIndexOpening {
        case opened(BindingIndex)
        case finished(CopilotSnapshot)
    }

    private struct Batch {
        let now: Date
        var issues: [CopilotIssue] = []
        var observations: [CopilotSessionObservation] = []
        var scopedIssues: [UUID: [CopilotIssue]] = [:]
        /// `workspace.yaml` of each session read live this cycle; decides current-worktree freshness.
        var workspaceSources: [UUID: CopilotWorktreeSource] = [:]
        var madeProgress = false
        var unreadHistory = false
    }

    private struct TailRead {
        var tail: Tail
        var issues: [CopilotIssue] = []
        var advanced = false
        var hasUnread = false
        var reachedBoundary = false
        var sessionName: String?
        var workspaceSource: CopilotWorktreeSource?
        var failure: CopilotIssue?
        let previouslyPublished: Bool
    }

    private enum SessionReadOutcome {
        // Routing changed: even an ambiguous row would publish the superseded
        // binding. It must be re-discovered under a current grant.
        case revoked
        // The routing grant remains valid but process/session evidence does
        // not, so only a content-free row is safe.
        case contentFree(CopilotLiveness, [CopilotIssue])
        case failed(CopilotIssue)
        case read(TailRead)
    }

    private func openBindingIndex(now: Date) throws -> BindingIndexOpening {
        let directories: (bindings: URL, sessions: URL)
        do {
            directories = try roots()
        } catch {
            resetDiscovery()
            return .finished(.init(generatedAt: now, sessions: [], issues: [.stateUnavailable], isComplete: false))
        }
        do {
            let descriptor = try CopilotFileAccess.openDirectory(directories.bindings, owner: verifier.uid)
            return .opened(BindingIndex(directories: directories, descriptor: descriptor))
        } catch {
            resetDiscovery()
            try Self.rethrowCancellation(error)
            return .finished(.init(
                generatedAt: now, sessions: [],
                issues: [Self.issue(error, missing: .integrationNotInstalled)], isComplete: false
            ))
        }
    }

    private func beginDiscoveryCycle(_ index: BindingIndex, batch: inout Batch) throws -> CopilotSnapshot? {
        do {
            let stamp = try CopilotFileAccess.statFile(index.descriptor)
            if let previous = discoveryStamp, !previous.sameFile(as: stamp) {
                resetDiscovery()
                batch.issues.append(.identityChanged)
            }
            if discovery == nil || (discovery?.finished == true && cohortFinished) {
                discovery = try CopilotDirectoryStream(at: index.descriptor)
                discoveryStamp = stamp
                cycleChanged = false
                cycleOverflowed = false
                cycleIssues.removeAll()
                unseenIdentities = Set(identityCache.keys)
                fastDiscoveryCycle = lastDiscoveryCycle != stamp
            } else if stamp != discoveryStamp {
                // Do not repeatedly restart a moving directory at its prefix.
                // Finish this pass, but only an unchanged cycle is complete.
                cycleChanged = true
            }
            return nil
        } catch {
            resetDiscovery()
            try Self.rethrowCancellation(error)
            return .init(generatedAt: batch.now, sessions: [], issues: [Self.issue(error)], isComplete: false)
        }
    }

    // Revalidate routing metadata before ANY process or transcript access.
    // A decoded cache entry is reusable only with an exact current file stamp.
    private func refreshCachedBindings(_ index: BindingIndex, surfaceIDs: Set<UUID>) throws {
        for id in bindingOrder {
            guard let cached = bindingsByID[id] else { continue }
            do {
                let (record, stamp) = try readIdentity(at: index.descriptor, filename: cached.filename)
                guard surfaceIDs.contains(record.surfaceID) else {
                    bindingsByID.removeValue(forKey: id)
                    recordCycleIssue(.identityChanged)
                    continue
                }
                guard record.schemaVersion == 1 else {
                    bindingsByID.removeValue(forKey: id)
                    recordCycleIssue(.identityChanged)
                    recordCycleIssue(.unsupportedFormat)
                    continue
                }
                if verifier.lookup(record.ownerPID) == .dead {
                    rememberEnded(Binding(record: record, stamp: stamp, filename: cached.filename))
                    bindingsByID.removeValue(forKey: id)
                    continue
                }
                cache(Binding(record: record, stamp: stamp, filename: cached.filename))
            } catch {
                try Self.rethrowCancellation(error)
                bindingsByID.removeValue(forKey: id)
                recordCycleIssue(error is DecodingError ? .ambiguousIdentity : Self.issue(error, missing: .identityChanged))
            }
        }
        bindingOrder.removeAll { bindingsByID[$0] == nil }
        publishedCohort.formIntersection(bindingsByID.keys)
    }

    // Returns the number of sessions admitted (zero or one).
    private func resumeWaitingBinding(_ index: BindingIndex, surfaceIDs: Set<UUID>) throws -> Int {
        guard let waiting = waitingBinding else { return 0 }
        do {
            let (record, stamp) = try readIdentity(at: index.descriptor, filename: waiting.filename)
            if !surfaceIDs.contains(record.surfaceID) {
                waitingBinding = nil
            } else if record.schemaVersion != 1 {
                recordCycleIssue(.unsupportedFormat)
                waitingBinding = nil
            } else if verifier.lookup(record.ownerPID) == .dead {
                rememberEnded(Binding(record: record, stamp: stamp, filename: waiting.filename))
                waitingBinding = nil
            } else {
                let entry = Binding(record: record, stamp: stamp, filename: waiting.filename)
                if admit(entry) {
                    waitingBinding = nil
                    return 1
                }
                waitingBinding = entry
            }
        } catch {
            try Self.rethrowCancellation(error)
            recordCycleIssue(Self.issue(error))
            waitingBinding = nil
        }
        return 0
    }

    // Returns the number of index entries scanned.
    private func scanBindings(_ index: BindingIndex, surfaceIDs: Set<UUID>, admitted initial: Int) throws -> Int {
        var scanned = 0
        var admitted = initial
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
                let (record, stamp) = try readIdentity(at: index.descriptor, filename: name)
                guard surfaceIDs.contains(record.surfaceID) else { continue }
                guard record.schemaVersion == 1 else { recordCycleIssue(.unsupportedFormat); continue }
                // Ended bindings can outlive their session directories. Only proven
                // owner death releases capacity; missing files or unknown probes do not.
                let entry = Binding(record: record, stamp: stamp, filename: name)
                if verifier.lookup(record.ownerPID) == .dead {
                    rememberEnded(entry)
                    continue
                }
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
        return scanned
    }

    // Returns whether this discovery pass is incomplete.
    private func concludeDiscoveryScan(scanned: Int, batch: inout Batch) -> Bool {
        batch.issues += cycleIssues
        let discoveryIncomplete = discovery?.finished != true || cycleChanged || cycleOverflowed
        if discoveryIncomplete { batch.issues.append(.readLimitReached) }
        // Continuation is productive only until EOF, not merely while a limit
        // warning exists (e.g. a changing directory or too many visible sessions).
        pendingHistory = fastDiscoveryCycle && scanned > 0 && discovery?.finished == false
            && waitingBinding == nil
        return discoveryIncomplete
    }

    // Move the first cached identity to the end after each batch so a large
    // transcript cannot monopolize the shared byte budget.
    private func rotateBindingOrder() {
        if let first = bindingOrder.first {
            bindingOrder.removeFirst()
            bindingOrder.append(first)
        }
    }

    private func readSession(
        _ entry: Binding, index: BindingIndex, root: Int32, budget: inout Int, now: Date
    ) throws -> SessionReadOutcome {
        do {
            return try readVerifiedSession(entry, index: index, root: root, budget: &budget, now: now)
        } catch {
            try Self.rethrowCancellation(error)
            return .failed(Self.issue(error))
        }
    }

    // Identity is verified before and after the tail read; a read is published
    // only when routing, process and session directory evidence are unchanged.
    private func readVerifiedSession(
        _ entry: Binding, index: BindingIndex, root: Int32, budget: inout Int, now: Date
    ) throws -> SessionReadOutcome {
        let record = entry.record
        guard try bindingRemainsValid(
            record, stamp: entry.stamp, filename: entry.filename, directory: index.descriptor
        ) else { return .revoked }
        let name = record.sessionID.uuidString.lowercased()
        let session = try CopilotFileAccess.openDirectory(at: root, name: name, owner: verifier.uid)
        defer { close(session) }
        let before = try verifier.inspect(record: record, sessionDirectory: session)
        guard before.status == .alive else {
            return .contentFree(Self.liveness(before.status), Self.issues(before.status))
        }
        var read = try advanceTail(currentTail(for: record), session: session, budget: &budget, now: now)
        // Published only with the stable identity verified below, under the exact session UUID.
        read.sessionName = sessionNames.name(for: record.sessionID, sessionDirectory: session, owner: verifier.uid)
        read.workspaceSource = (try? CopilotFileAccess.statEntry(at: session, name: CopilotSessionName.filename))
            .flatMap { $0.isRegular && $0.uid == verifier.uid ? CopilotWorktreeSource($0) : nil }
        let after = try verifier.verifyStable(before, record: record, sessionDirectory: session)
        guard try bindingRemainsValid(
            record, stamp: entry.stamp, filename: entry.filename, directory: index.descriptor
        ) else { return .revoked }
        guard after.status == .alive,
              (try CopilotFileAccess.statFile(session)).sameFile(
                as: try CopilotFileAccess.statEntry(at: root, name: name)
              ) else {
            return .contentFree(.ambiguous, after.status == .alive ? [.identityChanged] : Self.issues(after.status))
        }
        return .read(read)
    }

    private func currentTail(for record: CopilotIdentityRecord) -> Tail {
        if let tail = tails[record.sessionID], Self.sameBindingIdentity(tail.record, record) { return tail }
        return Tail(record: record, reducer: CopilotEventReducer(
            sessionID: record.sessionID, maximumRelationships: limits.maximumRelationships,
            maximumLifecycleEvents: limits.maximumLifecycleEvents,
            maximumReplayFilterWords: limits.maximumReplayFilterWords
        ))
    }

    private func advanceTail(_ tail: Tail, session: Int32, budget: inout Int, now: Date) throws -> TailRead {
        var read = TailRead(tail: tail, previouslyPublished: tail.lastComplete != nil)
        do {
            var advancing = tail
            let initialBudget = budget
            let result = try advance(&advancing, session: session, budget: &budget, now: now)
            read.issues = result.issues
            read.reachedBoundary = result.reachedBoundary
            read.tail = advancing
            read.advanced = budget < initialBudget
            read.hasUnread = (advancing.stamp?.size ?? 0) > advancing.offset
        } catch {
            try Self.rethrowCancellation(error)
            read.failure = Self.issue(error)
            read.issues.append(Self.issue(error))
            // A failed, explicitly unavailable observation must not pin
            // every later binding behind an unreadable transcript.
            read.reachedBoundary = true
        }
        return read
    }

    private func absorb(_ outcome: SessionReadOutcome, for record: CopilotIdentityRecord, batch: inout Batch) {
        let id = record.sessionID
        switch outcome {
        case .revoked:
            bindingsByID.removeValue(forKey: id)
            tails.removeValue(forKey: id)
            sessionNames.forget(id)
            publishedCohort.remove(id)
            batch.issues.append(.identityChanged)
        case .contentFree(let liveness, let issues):
            if liveness == .dead, let entry = bindingsByID.removeValue(forKey: id) {
                rememberEnded(entry)
                bindingOrder.removeAll { $0 == id }
                tails.removeValue(forKey: id)
                sessionNames.forget(id)
                publishedCohort.remove(id)
                return
            }
            // Private replay evidence survives uncertainty; no cached state is published.
            sessionNames.forget(id)
            publishedCohort.insert(id)
            recordIssues(issues, for: id, batch: &batch)
            batch.observations.append(observation(
                record, liveness: liveness, now: batch.now,
                includeBindingProcess: liveness == .unknown && issues == [.stateUnavailable]
                    && !retainedEvidenceProtectsUnknownRow(id)
            ))
        case .failed(let failure):
            publishedCohort.insert(id)
            recordIssues([failure], for: id, batch: &batch)
            let unsafe = [.identityChanged, .ambiguousIdentity, .permissionDenied].contains(failure)
            batch.observations.append(observation(record, liveness: unsafe ? .ambiguous : .unknown, now: batch.now))
        case .read(let read):
            tails[id] = read.tail
            if read.tail.historyIncomplete {
                batch.scopedIssues[id, default: []].append(.readLimitReached)
            }
            if read.reachedBoundary { publishedCohort.insert(id) }
            batch.madeProgress = batch.madeProgress
                || (read.advanced && (fastDiscoveryCycle || read.previouslyPublished))
            batch.unreadHistory = batch.unreadHistory || read.hasUnread
            // Only the tail operation failed; binding and custody fences still passed.
            let localIssues = read.issues.filter {
                $0 == .stateUnavailable || ($0.isSessionScoped && ($0 == read.failure
                    || (read.tail.projectionInvalidated && !read.tail.reducer.issues.contains($0))))
            }
            batch.scopedIssues[id, default: []] += localIssues
            batch.issues += read.issues.filter { !localIssues.contains($0) }
            let unsafeTail = localIssues.contains {
                [.identityChanged, .ambiguousIdentity, .permissionDenied].contains($0)
            }
            var result = observation(
                record, liveness: unsafeTail ? .ambiguous : .alive,
                now: unsafeTail ? batch.now : (read.tail.lastCompleteAt ?? batch.now),
                value: read.failure == nil ? (read.tail.lastComplete ?? CopilotReducedState()) : CopilotReducedState(),
                includeBindingProcess: !unsafeTail
            )
            if !unsafeTail {
                result.sessionName = read.sessionName
                batch.workspaceSources[id] = read.workspaceSource
            }
            batch.observations.append(result)
        }
        // Unavailability cannot downgrade retained source faults, even when a local
        // failure has the same issue value. Only rebuilding or retiring the tail clears them.
        batch.issues += tails[id]?.reducer.issues ?? []
    }

    private func recordIssues(_ issues: [CopilotIssue], for id: UUID, batch: inout Batch) {
        batch.scopedIssues[id, default: []] += issues.filter(\.isSessionScoped)
        batch.issues += issues.filter { !$0.isSessionScoped }
    }

    private func retainedEvidenceProtectsUnknownRow(_ id: UUID) -> Bool {
        guard let tail = tails[id] else { return false }
        guard let value = tail.lastComplete, tail.target == nil, tail.partial.isEmpty,
              !tail.historyIncomplete, !tail.droppingOversizedLine, !tail.discardingInitialLine,
              tail.stamp?.size == tail.offset, tail.reducer.issues.isEmpty else { return true }
        // Withhold correlation rather than republishing protected private history as current state.
        return [.failed, .blocked].contains(value.state) || !value.attention.isEmpty || !value.children.isEmpty
    }

    private func rememberEnded(_ entry: Binding) {
        let surface = entry.record.surfaceID
        if let previous = endedBindingsBySurface[surface] {
            let newer = entry.record.recordedAt > previous.record.recordedAt
                || (entry.record.recordedAt == previous.record.recordedAt
                    && entry.record.sessionID.uuidString > previous.record.sessionID.uuidString)
            guard newer || entry.record.sessionID == previous.record.sessionID else { return }
        } else if endedBindingsBySurface.count >= limits.maximumBindings {
            recordCycleIssue(.readLimitReached)
            return
        }
        endedBindingsBySurface[surface] = entry
    }

    private func appendEndedObservations(_ index: BindingIndex, root: Int32?, batch: inout Batch) throws {
        for (surface, cached) in endedBindingsBySurface {
            try Task.checkCancellation()
            let entry: Binding
            do {
                let (record, stamp) = try readIdentity(at: index.descriptor, filename: cached.filename)
                guard selectedSurfaces.contains(record.surfaceID),
                      Self.sameBindingIdentity(cached.record, record) else {
                    endedBindingsBySurface.removeValue(forKey: surface)
                    batch.issues.append(.identityChanged)
                    continue
                }
                guard bindingsByID[record.sessionID] == nil, verifier.lookup(record.ownerPID) == .dead else {
                    endedBindingsBySurface.removeValue(forKey: surface)
                    continue
                }
                entry = Binding(record: record, stamp: stamp, filename: cached.filename)
                endedBindingsBySurface[surface] = entry
            } catch {
                try Self.rethrowCancellation(error)
                endedBindingsBySurface.removeValue(forKey: surface)
                batch.issues.append(Self.issue(error, missing: .identityChanged))
                continue
            }
            let status: CopilotIdentityStatus
            do {
                status = try inspectEndedOwner(entry.record, root: root)
            } catch {
                try Self.rethrowCancellation(error)
                let issue = Self.issue(error)
                recordIssues([issue], for: entry.record.sessionID, batch: &batch)
                status = [.permissionDenied, .identityChanged, .ambiguousIdentity].contains(issue) ? .ambiguous : .unknown
            }
            recordIssues(status == .alive ? [.identityChanged] : Self.issues(status),
                         for: entry.record.sessionID, batch: &batch)
            batch.observations.append(observation(
                entry.record, liveness: status == .alive ? .ambiguous : Self.liveness(status), now: batch.now
            ))
        }
    }

    private func inspectEndedOwner(_ record: CopilotIdentityRecord, root: Int32?) throws -> CopilotIdentityStatus {
        guard let root else { return .dead }
        do {
            let session = try CopilotFileAccess.openDirectory(
                at: root, name: record.sessionID.uuidString.lowercased(), owner: verifier.uid
            )
            defer { close(session) }
            return try verifier.inspect(record: record, sessionDirectory: session).status
        } catch CopilotFileError.missing {
            // Owner death was proved independently; a removed directory cannot revive it.
            return .dead
        }
    }

    // A missing or invalid location only hides the branch row; it never degrades the session.
    private func decorateObservations(_ index: BindingIndex, batch: inout Batch) throws {
        let locations = try? CopilotFileAccess.openDirectory(
            index.directories.bindings.deletingLastPathComponent()
                .appendingPathComponent("locations", isDirectory: true),
            owner: verifier.uid
        )
        defer { if let locations { close(locations) } }
        var decorated: [CopilotSessionObservation] = []
        for observation in batch.observations {
            try Task.checkCancellation()
            var result = observation
            result.sessionIssues = batch.scopedIssues[observation.sessionID].flatMap { $0.isEmpty ? nil : $0 }
            if let locations {
                applyLocation(to: &result, locations: locations, source: batch.workspaceSources[observation.sessionID])
            }
            applyAppearance(to: &result, index: index, issues: &batch.issues)
            decorated.append(result)
        }
        batch.observations = decorated
    }

    /// A turn's touch wins over the selected-directory fallback. Changed bindings and non-live
    /// observations cannot revive a previous touch; the fallback retains its workspace-file fence.
    private func applyLocation(
        to observation: inout CopilotSessionObservation, locations: Int32, source: CopilotWorktreeSource?
    ) {
        guard let data = try? CopilotFileAccess.readStableRegular(
            at: locations, filename: observation.sessionID.uuidString.lowercased() + ".json",
            owner: verifier.uid, maximum: CopilotSessionLocation.maximumBytes, permissions: 0o600
        ), let record = CopilotSessionLocationRecord.decode(data, sessionID: observation.sessionID) else { return }
        if let location = record.location {
            observation.branch = location.branch
            observation.worktree = location.worktree
        }
        if let active = record.active {
            let bound = bindingsByID[observation.sessionID].map {
                CopilotActiveWorktree.bindingKey($0.record) == active.bindingKey
            } ?? false
            observation.currentWorktree = .init(
                evidence: .verified(active.identity),
                isCurrent: active.isCurrent && bound && observation.liveness == .alive
            )
        } else if let current = record.current {
            observation.currentWorktree = .init(
                evidence: current.evidence, isCurrent: current.source != nil && current.source == source
            )
        }
    }

    private func applyAppearance(
        to observation: inout CopilotSessionObservation, index: BindingIndex, issues: inout [CopilotIssue]
    ) {
        do {
            guard let appearance = try appearance(for: observation.sessionID, bindings: index.descriptor) else {
                return  // No explicit standalone icon has been chosen.
            }
            observation.iconId = appearance.iconId
            observation.iconColor = appearance.iconColor
            observation.petId = appearance.petId
        } catch {
            issues.append(.appearanceUnavailable)
        }
    }

    private func appearance(for sessionID: UUID, bindings: Int32) throws -> CopilotSessionAppearance? {
        let data: Data
        do {
            data = try CopilotFileAccess.readStableRegular(
                at: bindings, filename: "appearance-\(sessionID.uuidString.lowercased()).json",
                owner: verifier.uid, maximum: 4096, permissions: 0o600
            )
        } catch CopilotFileError.missing {
            return nil
        }
        let appearance = try JSONDecoder().decode(CopilotSessionAppearance.self, from: data)
        guard appearance.sessionID == sessionID, appearance.isValid else { throw CopilotFileError.changed }
        return appearance
    }

    /// Name and own appearance of sessions the Maestro controller enrolled, read by their exact
    /// session UUID from the controller's projection. Copilot defers a resumed session's
    /// `sessionStart` hook and its `inuse.<PID>.lock` until the first prompt, so the observer hook
    /// cannot bind it before then (#261). No transcript is read; a missing or refused file yields
    /// no detail. Bounded like observed sessions.
    func managedSessionDetails(_ ids: Set<UUID>) async -> [UUID: CopilotManagedSessionDetails] {
        let selected = ids.sorted { $0.uuidString < $1.uuidString }.prefix(limits.maximumSessions)
        managedNames.retain(only: Set(selected))
        guard !selected.isEmpty, let directories = try? roots(),
              let root = try? CopilotFileAccess.openDirectory(directories.sessions, owner: verifier.uid) else {
            return [:]
        }
        defer { close(root) }
        let bindings = try? CopilotFileAccess.openDirectory(directories.bindings, owner: verifier.uid)
        defer { if let bindings { close(bindings) } }
        let now = clock()
        var result: [UUID: CopilotManagedSessionDetails] = [:]
        for id in selected {
            guard !Task.isCancelled else { break }
            guard let session = try? CopilotFileAccess.openDirectory(
                at: root, name: id.uuidString.lowercased(), owner: verifier.uid
            ) else {
                managedNames.forget(id)
                continue
            }
            defer { close(session) }
            var details = CopilotManagedSessionDetails(
                sessionName: managedNames.name(for: id, sessionDirectory: session, owner: verifier.uid), readAt: now
            )
            if let bindings, let appearance = try? appearance(for: id, bindings: bindings) {
                details.iconId = appearance.iconId
                details.iconColor = appearance.iconColor
                details.petId = appearance.petId
            }
            result[id] = details
        }
        return result
    }

    // A later session's I/O can race an earlier binding, including revocation.
    // Validate the entire published set and the path to our anchored index.
    private func fenceObservations(_ index: BindingIndex, batch: inout Batch) {
        var fenced: [CopilotSessionObservation] = []
        for observation in batch.observations {
            let active = bindingsByID[observation.sessionID]
            let ended = endedBindingsBySurface[observation.surfaceID].flatMap {
                $0.record.sessionID == observation.sessionID ? $0 : nil
            }
            guard let entry = active ?? ended,
                  active != nil || verifier.lookup(entry.record.ownerPID) == .dead,
                  (try? bindingRemainsValid(
                    entry.record, stamp: entry.stamp, filename: entry.filename, directory: index.descriptor
                  )) == true else {
                tails.removeValue(forKey: observation.sessionID)
                bindingsByID.removeValue(forKey: observation.sessionID)
                publishedCohort.remove(observation.sessionID)
                if ended != nil { endedBindingsBySurface.removeValue(forKey: observation.surfaceID) }
                batch.issues.append(.identityChanged)
                continue
            }
            fenced.append(observation)
        }
        batch.observations = fenced
    }

    private func publish(_ index: BindingIndex, sessionRoot: SessionRoot?, batch: Batch) throws -> CopilotSnapshot {
        guard (try? directoryRemainsValid(index.descriptor, at: index.directories.bindings)) == true else {
            resetDiscovery()
            return snapshot(now: batch.now, observations: [], issues: [.identityChanged])
        }
        var issues = batch.issues + cycleIssues
        if (try CopilotFileAccess.statFile(index.descriptor)) != discoveryStamp {
            cycleChanged = true
            issues.append(.readLimitReached)
        }
        try Task.checkCancellation()
        if let sessionRoot,
           (try? directoryRemainsValid(sessionRoot.descriptor, at: index.directories.sessions)) != true {
            resetDiscovery()
            return snapshot(now: batch.now, observations: [], issues: [.identityChanged])
        }
        pendingHistory = pendingHistory || (batch.madeProgress && batch.unreadHistory)
        finishDiscoveryCycle()
        // Each frozen prefix ends after `batch.now`, so it can hold events stamped later.
        // Stamp the snapshot after every read; otherwise those events fail validation.
        return snapshot(now: max(batch.now, clock()), observations: batch.observations, issues: issues)
    }

    // Scheduling only: productive discovery and admitted-tail deltas, never capacity waits.
    func hasPendingHistory() -> Bool { pendingHistory }

    func retentionCounts() -> (bindings: Int, tails: Int, waiting: Int, published: Int) {
        (bindingsByID.count, tails.count, waitingBinding == nil ? 0 : 1, publishedCohort.count)
    }

    func identityCacheCount() -> Int { identityCache.count }
    func endedBindingCount() -> Int { endedBindingsBySurface.count }

    private func resetDiscovery() {
        discovery?.closeStream()
        discovery = nil
        discoveryStamp = nil
        identityCache.removeAll()
        unseenIdentities.removeAll()
        // Discovery is not an ownership change. Current grants are revalidated
        // before any retained session is read or published on the next pass.
        bindingsByID = bindingsByID.filter { selectedSurfaces.contains($0.value.record.surfaceID) }
        endedBindingsBySurface = endedBindingsBySurface.filter { selectedSurfaces.contains($0.key) }
        bindingOrder.removeAll { bindingsByID[$0] == nil }
        let retained = Set(bindingsByID.keys)
        tails = tails.filter { retained.contains($0.key) }
        sessionNames.retain(only: retained)
        pendingHistory = false
        cycleChanged = false
        cycleOverflowed = false
        cycleIssues.removeAll()
        waitingBinding = nil
        publishedCohort.formIntersection(retained)
        lastDiscoveryCycle = nil
        fastDiscoveryCycle = true
    }

    private var cohortFinished: Bool {
        waitingBinding == nil && bindingsByID.keys.allSatisfy { publishedCohort.contains($0) }
    }

    private func finishDiscoveryCycle() {
        if discovery?.finished == true && cohortFinished && !cycleChanged {
            lastDiscoveryCycle = discoveryStamp
            for filename in unseenIdentities { identityCache.removeValue(forKey: filename) }
            unseenIdentities.removeAll()
        }
    }

    private func admit(_ entry: Binding) -> Bool {
        if bindingsByID[entry.record.sessionID] == nil {
            if bindingOrder.count == limits.maximumSessions {
                cycleOverflowed = true
                return false
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
            recordCycleIssue(.identityChanged)
        }
        bindingsByID[id] = entry
    }

    private func recordCycleIssue(_ issue: CopilotIssue) {
        if !cycleIssues.contains(issue) { cycleIssues.append(issue) }
    }

    private func directoryRemainsValid(_ descriptor: Int32?, at url: URL) throws -> Bool {
        do {
            let current = try CopilotFileAccess.openDirectory(url, owner: verifier.uid)
            defer { close(current) }
            guard let descriptor else { return false }
            return try CopilotFileAccess.statFile(descriptor).sameFile(as: CopilotFileAccess.statFile(current))
        } catch CopilotFileError.missing where descriptor == nil {
            // Ended-only observations may use absence, but must revalidate it too.
            return true
        }
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
        let (refreshed, _) = try readIdentity(at: directory, filename: filename)
        return Self.sameBindingIdentity(record, refreshed)
    }

    private func readIdentity(
        at directory: Int32, filename: String
    ) throws -> (CopilotIdentityRecord, CopilotFileStamp) {
        do {
            try Task.checkCancellation()
            unseenIdentities.remove(filename)
            let current = try CopilotFileAccess.statEntry(at: directory, name: filename)
            if let cached = identityCache[filename], cached.stamp == current {
                return (cached.record, cached.stamp)
            }
            identityCache.removeValue(forKey: filename)
            identityReads += 1
            let (record, stamp) = try CopilotFileAccess.readIdentity(
                at: directory, filename: filename, owner: verifier.uid
            )
            if identityCache.count < limits.maximumBindings {
                identityCache[filename] = Binding(record: record, stamp: stamp, filename: filename)
            }
            return (record, stamp)
        } catch {
            identityCache.removeValue(forKey: filename)
            throw error
        }
    }

    private func advance(
        _ tail: inout Tail, session: Int32, budget: inout Int, now: Date
    ) throws -> (issues: [CopilotIssue], reachedBoundary: Bool) {
        let entry = try CopilotFileAccess.statEntry(at: session, name: "events.jsonl")
        // Reuse only an EOF whose full metadata still matches a successful read-open.
        // ctime, ownership, permissions and birth time participate, not just mtime/size.
        if tail.readableStamp == entry, tail.stamp == entry,
           tail.offset == entry.size, tail.target == nil {
            guard entry == (try CopilotFileAccess.statEntry(at: session, name: "events.jsonl")) else {
                throw CopilotFileError.changed
            }
            return refreshUnchangedTail(&tail, now: now)
        }
        eventFileOpens += 1
        let file = try CopilotFileAccess.openRegular(at: session, name: "events.jsonl", owner: verifier.uid)
        defer { close(file) }
        let before = try CopilotFileAccess.statFile(file)
        if tail.stamp == before, tail.offset == before.size, tail.target == nil {
            guard before == (try CopilotFileAccess.statFile(file)),
                  before == (try CopilotFileAccess.statEntry(at: session, name: "events.jsonl")) else {
                throw CopilotFileError.changed
            }
            tail.readableStamp = entry == before ? before : nil
            return refreshUnchangedTail(&tail, now: now)
        }
        var reset = false
        if let previous = tail.stamp {
            reset = !previous.sameFile(as: before) || before.size < previous.size || before.size < tail.offset
            if !reset && tail.offset > 0 {
                let prefix = try readEventBytes(file, offset: 0, count: tail.prefix.count)
                let anchor = try readEventBytes(
                    file, offset: tail.offset - Int64(tail.anchor.count), count: tail.anchor.count
                )
                reset = prefix != tail.prefix || anchor != tail.anchor
                    || (before.size == previous.size && before != previous)
            }
        }
        if reset {
            tail = Tail(record: tail.record, reducer: CopilotEventReducer(
                sessionID: tail.record.sessionID, maximumRelationships: limits.maximumRelationships,
                maximumLifecycleEvents: limits.maximumLifecycleEvents,
                maximumReplayFilterWords: limits.maximumReplayFilterWords
            ))
            tail.projectionInvalidated = true
        }
        if tail.target == nil && before.size - tail.offset > Int64(tailWindowBytes) {
            tail.offset = before.size - Int64(tailWindowBytes)
            tail.historyIncomplete = true
            tail.discardingInitialLine = true
            tail.partial.removeAll()
            tail.droppingOversizedLine = false
            tail.assetEnvelope = nil
            tail.lastComplete = nil
            tail.lastCompleteAt = nil
            tail.reducer.omitUnseenHistory()
            if tail.stamp == nil {
                // Validate source identity without importing historical work or model state.
                let header = try readEventBytes(file, offset: 0, count: 4096)
                if let newline = header.firstIndex(of: 10) {
                    tail.reducer.validateSourceHeader(Data(header[..<newline]))
                } else {
                    tail.reducer.markMalformed()
                }
            }
        }
        var remaining = min(budget, limits.bytesPerSession)
        var lines = 0
        if tail.target == nil {
            // Appends and preference edits cannot expand an admitted window.
            tail.target = before.size
            tail.targetAt = now
        }
        let targetSize = tail.target!
        while tail.offset < targetSize && remaining > 0 && lines < limits.linesPerSession {
            try Task.checkCancellation()
            let count = min(262_144, remaining, Int(min(Int64(Int.max), targetSize - tail.offset)))
            let chunk = try readEventBytes(file, offset: tail.offset, count: count)
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
                if tail.discardingInitialLine {
                    consumed = end
                    if newline != nil {
                        tail.discardingInitialLine = false
                        consumed += 1
                        lines += 1
                    }
                    continue
                }
                if !tail.droppingOversizedLine {
                    if end - consumed <= limits.maximumLineBytes - tail.partial.count {
                        tail.partial.append(chunk[consumed..<end])
                    } else {
                        var envelope = CopilotAssetEnvelope(maximumBytes: limits.maximumLineBytes)
                        envelope.consume(tail.partial)
                        envelope.consume(Data(chunk[consumed..<end]))
                        tail.assetEnvelope = envelope
                        tail.partial.removeAll(keepingCapacity: false)
                        tail.droppingOversizedLine = true
                    }
                } else {
                    tail.assetEnvelope?.consume(Data(chunk[consumed..<end]))
                }
                consumed = end
                if newline != nil {
                    if !tail.droppingOversizedLine {
                        if tail.partial.last == 13 { tail.partial.removeLast() }
                        tail.reducer.consume(tail.partial)
                    } else if let metadata = tail.assetEnvelope?.projectedEvent {
                        tail.reducer.consume(metadata)
                    } else {
                        tail.reducer.markMalformed()
                        tail.reducer.markLimited()
                    }
                    tail.partial.removeAll(keepingCapacity: true)
                    tail.droppingOversizedLine = false
                    tail.assetEnvelope = nil
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
        tail.prefix = try readEventBytes(file, offset: 0, count: Int(min(tail.offset, 128)))
        tail.anchor = try readEventBytes(
            file, offset: max(0, tail.offset - 128), count: Int(min(tail.offset, 128))
        )
        tail.stamp = after
        // Concurrent growth can carry a permission/ACL change; only the pre-read
        // stamp was authorized by openRegular. A different final stamp must reopen.
        tail.readableStamp = entry == before ? before : nil
        projectionBuilds += 1
        let value = tail.reducer.value()
        var issues = tail.reducer.issues
        let reachedBoundary = tail.offset >= targetSize
        if reachedBoundary {
            if tail.partial.isEmpty && !tail.droppingOversizedLine && !tail.discardingInitialLine
                && tail.reducer.canPublishProjection {
                // A verified boundary can publish conservative semantic limits,
                // but malformed data, invalid schemas and identity errors cannot.
                tail.lastComplete = value
                tail.projectionInvalidated = false
                // Verified current EOF is fresh; an older prefix with unread
                // appends must retain its captured age.
                tail.lastCompleteAt = tail.offset == after.size ? now : (tail.targetAt ?? now)
            }

            tail.target = nil
            tail.targetAt = nil
        }
        let incomplete = tail.offset < after.size || !tail.partial.isEmpty
            || tail.droppingOversizedLine || tail.discardingInitialLine
        if incomplete {
            issues.append(.loadingHistory)
            if tail.offset < after.size { issues.append(.readLimitReached) }
        }
        if tail.projectionInvalidated {
            issues.removeAll { $0 == .loadingHistory }
            issues.append(.identityChanged)
        }
        return (issues, reachedBoundary)
    }

    private func refreshUnchangedTail(
        _ tail: inout Tail, now: Date
    ) -> (issues: [CopilotIssue], reachedBoundary: Bool) {
        var issues = tail.reducer.issues
        if !tail.partial.isEmpty || tail.droppingOversizedLine || tail.discardingInitialLine {
            issues.append(.loadingHistory)
        } else if tail.reducer.canPublishProjection, tail.lastComplete != nil {
            tail.lastCompleteAt = now
        }
        if tail.projectionInvalidated {
            issues.removeAll { $0 == .loadingHistory }
            issues.append(.identityChanged)
        }
        return (issues, true)
    }

    private func readEventBytes(_ descriptor: Int32, offset: Int64, count: Int) throws -> Data {
        let bytes = try eventRead(descriptor, offset, count)
        eventReadBytes += bytes.count
        return bytes
    }

    private func observation(
        _ record: CopilotIdentityRecord, liveness: CopilotLiveness, now: Date,
        value: CopilotReducedState = CopilotReducedState(), includeBindingProcess: Bool = false
    ) -> CopilotSessionObservation {
        var result = CopilotSessionObservation(
            sessionID: record.sessionID, surfaceID: record.surfaceID,
            launchWorkspaceID: record.launchWorkspaceID, liveness: liveness,
            state: value.state, model: value.model, children: value.children, observedAt: now,
            attention: value.attention, activity: value.activity
        )
        if includeBindingProcess {
            result.bindingProcess = .init(
                pid: record.ownerPID, startSeconds: record.ownerStartSeconds,
                startMicroseconds: record.ownerStartMicroseconds
            )
        }
        return result
    }

    private func snapshot(
        now: Date, observations: [CopilotSessionObservation], issues: [CopilotIssue]
    ) -> CopilotSnapshot {
        let unique = Array(Set(issues.map(\.rawValue))).sorted().compactMap(CopilotIssue.init(rawValue:))
        let sessionsAreClean = observations.allSatisfy { ($0.sessionIssues ?? []).isEmpty }
        return .init(
            generatedAt: now,
            sessions: observations.sorted { $0.sessionID.uuidString < $1.sessionID.uuidString },
            issues: unique, isComplete: unique.allSatisfy(\.isCosmetic) && sessionsAreClean
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
