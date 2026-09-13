import Darwin
import Foundation
import Testing
@testable import CMUXMaestroPreview

nonisolated struct CopilotReaderTests {
    @Test func readsOnlyGrantedSessionsAndKeepsSurfaceIdentityIndependentOfPlacement() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let other = try fixture.addSession(surface: UUID())
        try Data("PRIVATE_OTHER_SESSION_SENTINEL\n".utf8).write(to: other.appendingPathComponent("events.jsonl"))
        let reader = fixture.reader()
        let snapshot = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(snapshot.isComplete)
        #expect(snapshot.sessions.count == 1)
        #expect(snapshot.sessions[0].sessionID == fixture.sessionID)
        #expect(snapshot.sessions[0].surfaceID == fixture.surface)
        #expect(snapshot.sessions[0].launchWorkspaceID == fixture.workspace)
        #expect(snapshot.sessions[0].state == .idle)
        #expect(snapshot.sessions[0].liveness == .alive)
        let moved = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(moved.sessions[0].surfaceID == snapshot.sessions[0].surfaceID)
        #expect(moved.sessions[0].launchWorkspaceID == snapshot.sessions[0].launchWorkspaceID)
    }

    @Test func missingLogIsNotAnEmptyLog() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let reader = fixture.reader()
        let missing = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(!missing.isComplete)
        #expect(missing.issues.contains(.stateUnavailable))
        #expect(missing.sessions[0].state == .unknown)
        try fixture.writeEvents([])
        let empty = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(empty.isComplete)
        #expect(empty.sessions[0].children.isEmpty)
        #expect(empty.sessions[0].state == .unknown)
    }

    @Test func tornAppendRetainsLastCompleteEvidenceThenCatchesUp() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let reader = fixture.reader()
        let complete = try await reader.read(surfaceIDs: [fixture.surface])
        let row = try copilotTestEvent("assistant.turn_start", data: ["turnId": "1"])
        try fixture.append(row.prefix(row.count / 2))
        let torn = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(!torn.isComplete)
        #expect(torn.issues.contains(.loadingHistory))
        #expect(torn.sessions == complete.sessions)
        #expect(await reader.hasPendingHistory() == false)
        try fixture.append(row.suffix(row.count - row.count / 2) + Data([10]))
        let repaired = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(repaired.isComplete)
        #expect(repaired.sessions[0].state == .working)
    }

    @Test func malformedAndOversizedRowsDoNotFabricateCurrentState() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let reader = fixture.reader(limits: .init(maximumLineBytes: 512))
        let complete = try await reader.read(surfaceIDs: [fixture.surface])
        try fixture.append(Data("{bad}\n".utf8))
        try fixture.append(Data(repeating: 120, count: 1024) + Data([10]))
        try fixture.append(try copilotTestEvent("assistant.turn_start", data: ["turnId": "1"]) + Data([10]))
        let invalid = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(!invalid.isComplete)
        #expect(invalid.issues.contains(.malformedData))
        #expect(invalid.issues.contains(.readLimitReached))
        #expect(invalid.sessions == complete.sessions)
    }

    @Test func boundedIncrementalHistoryEventuallyCompletesAndDoesNotReplay() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        var rows: [Data] = []
        for i in 0..<8 { rows.append(try copilotTestEvent("skill.invoked", data: ["name": "skill-\(i)"])) }
        rows.append(try copilotTestEvent("session.idle"))
        try fixture.writeEvents(rows)
        let reader = fixture.reader(limits: .init(bytesPerRead: 200, bytesPerSession: 200, linesPerSession: 2))
        var snapshot = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(snapshot.issues.contains(.loadingHistory))
        #expect(await reader.hasPendingHistory())
        #expect(snapshot.sessions[0].children.isEmpty)
        for _ in 0..<40 where !snapshot.isComplete {
            snapshot = try await reader.read(surfaceIDs: [fixture.surface])
        }
        #expect(snapshot.isComplete)
        #expect(snapshot.sessions[0].children.count == 8)
        #expect(await reader.hasPendingHistory() == false)
        let unchanged = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(unchanged.sessions == snapshot.sessions)
    }

    @Test func rotationAndSameInodeTruncationRebuildInsteadOfCombiningHistories() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("skill.invoked", data: ["name": "old"])])
        let reader = fixture.reader()
        let first = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(first.sessions[0].children.count == 1)
        try fixture.writeEvents([copilotTestEvent("session.idle")], atomic: true)
        let rotated = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(rotated.isComplete)
        #expect(rotated.sessions[0].children.isEmpty)
        try fixture.writeEvents([copilotTestEvent("assistant.turn_start", data: ["turnId": "new-turn"])])
        let truncated = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(truncated.isComplete)
        #expect(truncated.sessions[0].state == .working)
    }

    @Test func deniesSymlinkedEventsAndSessionDirectories() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let sentinel = fixture.root.appendingPathComponent("sentinel")
        try Data("PRIVATE_SENTINEL".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: fixture.events, withDestinationURL: sentinel)
        let snapshot = try await fixture.reader().read(surfaceIDs: [fixture.surface])
        #expect(!snapshot.isComplete)
        #expect(snapshot.issues.contains(.ambiguousIdentity))
        try FileManager.default.removeItem(at: fixture.session)
        try FileManager.default.createSymbolicLink(at: fixture.session, withDestinationURL: fixture.root)
        let directory = try await fixture.reader().read(surfaceIDs: [fixture.surface])
        #expect(directory.issues.contains(.ambiguousIdentity))
    }

    @Test func integrationMissingAndEmptySelectionAreTyped() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.bindings)
        let missing = try await fixture.reader().read(surfaceIDs: [fixture.surface])
        #expect(missing.issues == [.integrationNotInstalled])
        let unselected = try await fixture.reader().read(surfaceIDs: [])
        #expect(unselected.isComplete)
        #expect(unselected.sessions.isEmpty)
    }

    @Test func cancellationPropagatesRatherThanBecomingAnIssue() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let reader = fixture.reader()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.read(surfaceIDs: [fixture.surface])
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled read returned a snapshot")
        } catch is CancellationError {
        }
    }

    @Test func oneMalformedSessionDoesNotHideAnotherVerifiedSession() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let other = try fixture.addSession(surface: fixture.surface)
        try Data("{malformed}\n".utf8).write(to: other.appendingPathComponent("events.jsonl"))
        try Data().write(to: other.appendingPathComponent("inuse.\(fixture.process.pid).lock"))
        let snapshot = try await fixture.reader().read(surfaceIDs: [fixture.surface])
        #expect(snapshot.sessions.count == 2)
        #expect(snapshot.sessions.first(where: { $0.sessionID == fixture.sessionID })?.state == .idle)
        #expect(snapshot.issues.contains(.malformedData))
        #expect(!snapshot.isComplete)
    }

    @Test func offSurfaceIndexRecordsNeverReachProcessValidationOrPublicSnapshot() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let otherSurface = UUID()
        let otherDirectory = try fixture.addSession(surface: otherSurface)
        let otherSession = try #require(UUID(uuidString: otherDirectory.lastPathComponent))
        try fixture.writeRecord(.init(
            sessionID: otherSession, surfaceID: otherSurface, launchWorkspaceID: UUID(),
            ownerPID: 7878, ownerStartSeconds: 1, ownerStartMicroseconds: 0,
            recordedAt: fixture.record.recordedAt
        ))
        try Data("PRIVATE_OFF_SURFACE_SENTINEL\n".utf8)
            .write(to: otherDirectory.appendingPathComponent("events.jsonl"))
        let audit = CopilotLookupAudit(owner: fixture.process)
        let snapshot = try await fixture.reader(lookup: { audit.read($0) })
            .read(surfaceIDs: [fixture.surface])
        #expect(snapshot.isComplete)
        #expect(snapshot.sessions.count == 1)
        #expect(!audit.queriedPIDs.contains(7878))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let publicJSON = String(decoding: try encoder.encode(snapshot), as: UTF8.self).lowercased()
        #expect(!publicJSON.contains(otherSession.uuidString.lowercased()))
        #expect(!publicJSON.contains(otherSurface.uuidString.lowercased()))
        #expect(!publicJSON.contains("private_off_surface_sentinel"))
    }

    @Test func timestampOnlyHookRefreshesDoNotRestartLargeHistoryCatchup() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        var rows = try (0..<24).map { _ in
            try copilotTestEvent("assistant.message", data: ["content": String(repeating: "x", count: 15_000)])
        }
        rows.append(try copilotTestEvent("session.idle"))
        try fixture.writeEvents(rows)
        let reader = fixture.reader(limits: .init(bytesPerSession: 262_144))
        var snapshot = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(snapshot.issues.contains(.loadingHistory))
        for refresh in 1...4 where !snapshot.isComplete {
            try fixture.writeRecord(refreshed(fixture.record, seconds: 1_000 + Double(refresh)), atomic: true)
            snapshot = try await reader.read(surfaceIDs: [fixture.surface])
        }
        #expect(snapshot.isComplete)
        #expect(snapshot.sessions[0].state == .idle)
        #expect(snapshot.sessions[0].children.isEmpty)
    }

    @Test func timestampOnlyAtomicBindingRefreshDuringReadIsRevalidated() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let refresh = refreshed(fixture.record, seconds: 1_001)
        let probe = CopilotHookRefreshProbe(owner: fixture.process) {
            try fixture.writeRecord(refresh, atomic: true)
        }
        let snapshot = try await fixture.reader(lookup: { probe.read($0) }).read(surfaceIDs: [fixture.surface])
        #expect(probe.refreshedSuccessfully)
        #expect(snapshot.isComplete)
        #expect(snapshot.sessions[0].liveness == .alive)
        #expect(snapshot.sessions[0].state == .idle)
    }

    @Test func routingChangeDuringAtomicBindingRefreshStillInvalidatesCandidate() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let record = fixture.record
        let rerouted = CopilotIdentityRecord(
            sessionID: record.sessionID, surfaceID: UUID(), launchWorkspaceID: record.launchWorkspaceID,
            ownerPID: record.ownerPID, ownerStartSeconds: record.ownerStartSeconds,
            ownerStartMicroseconds: record.ownerStartMicroseconds, recordedAt: record.recordedAt
        )
        let probe = CopilotHookRefreshProbe(owner: fixture.process) {
            try fixture.writeRecord(rerouted, atomic: true)
        }
        let snapshot = try await fixture.reader(lookup: { probe.read($0) }).read(surfaceIDs: [fixture.surface])
        #expect(probe.refreshedSuccessfully)
        #expect(snapshot.issues.contains(.identityChanged))
        #expect(snapshot.sessions[0].state == .unknown)
        #expect(snapshot.sessions[0].liveness == .ambiguous)
    }

    @Test func failedReadWithoutProgressDoesNotRequestImmediateCatchup() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([
            copilotTestEvent("assistant.message", data: ["content": String(repeating: "x", count: 1024)])
        ])
        let reader = fixture.reader(limits: .init(bytesPerSession: 200))
        _ = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(await reader.hasPendingHistory())
        try FileManager.default.removeItem(at: fixture.events)
        let missing = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(missing.issues.contains(.stateUnavailable))
        #expect(await reader.hasPendingHistory() == false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_MAESTRO_READER_BENCHMARK"] == "1"))
    func coldStartBenchmarkWith230MiBOfIgnoredSyntheticPayloads() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([])
        let row = try copilotTestEvent("tool.execution_partial_result", data: [
            "toolCallId": "ignored-payload", "partialOutput": String(repeating: "x", count: 524_288)
        ]) + Data([10])
        let handle = try FileHandle(forWritingTo: fixture.events)
        do {
            for _ in 0..<460 { try handle.write(contentsOf: row) }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        let tail = [
            try copilotTestEvent("tool.execution_start", data: ["toolCallId": "parent", "toolName": "task"]),
            try copilotTestEvent("subagent.started", agent: "parent", data: ["toolCallId": "parent", "agentDisplayName": "Worker"]),
            try copilotTestEvent("tool.execution_start", agent: "parent", data: ["toolCallId": "child", "toolName": "task"]),
            try copilotTestEvent("subagent.started", agent: "child", data: ["toolCallId": "child", "agentDisplayName": "Worker"]),
            try copilotTestEvent("subagent.completed", data: ["toolCallId": "child", "agentDisplayName": "Worker", "cancelled": true]),
            try copilotTestEvent("tool.execution_start", data: ["toolCallId": "sibling", "toolName": "task"]),
            try copilotTestEvent("subagent.started", agent: "sibling", data: ["toolCallId": "sibling", "agentDisplayName": "Worker"]),
            try copilotTestEvent("subagent.failed", data: ["toolCallId": "sibling", "agentDisplayName": "Worker", "error": "IGNORED"]),
            try copilotTestEvent("session.idle")
        ]
        for event in tail { try fixture.append(event + Data([10])) }
        let fileSize = try #require(FileManager.default.attributesOfItem(atPath: fixture.events.path)[.size] as? NSNumber)
        let reader = fixture.reader()
        let clock = ContinuousClock()
        let start = clock.now
        var batches = 1
        var snapshot = try await reader.read(surfaceIDs: [fixture.surface])
        var maximumBatch = start.duration(to: clock.now)
        #expect(snapshot.issues.contains(.loadingHistory))
        #expect(snapshot.sessions[0].children.isEmpty)
        while !snapshot.isComplete && batches < 128 {
            guard await reader.hasPendingHistory() else { break }
            try await Task.sleep(for: .milliseconds(10))
            let batchStart = clock.now
            snapshot = try await reader.read(surfaceIDs: [fixture.surface])
            maximumBatch = max(maximumBatch, batchStart.duration(to: clock.now))
            batches += 1
        }
        let duration = start.duration(to: clock.now).components
        let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        let maximumBatchMilliseconds = (
            Double(maximumBatch.components.seconds) + Double(maximumBatch.components.attoseconds) / 1e18
        ) * 1_000
        var usage = rusage()
        let measuredRSS = getrusage(RUSAGE_SELF, &usage) == 0 ? usage.ru_maxrss : -1
        print("COPILOT_READER_BENCHMARK bytes=\(fileSize.int64Value) batches=\(batches) seconds=\(seconds) maximumBatchMs=\(maximumBatchMilliseconds) processPeakRSSBytes=\(measuredRSS) continuationDelayMs=10")
        #expect(snapshot.isComplete)
        #expect(snapshot.sessions[0].state == .idle)
        #expect(snapshot.sessions[0].children.map(\.id) == ["parent", "child", "sibling"])
        #expect(snapshot.sessions[0].children.map(\.parentID) == [nil, "parent", nil])
        #expect(snapshot.sessions[0].children.map(\.state) == [.working, .cancelled, .failed])
        #expect(await reader.hasPendingHistory() == false)
    }

    private func refreshed(_ record: CopilotIdentityRecord, seconds: Double) -> CopilotIdentityRecord {
        .init(
            schemaVersion: record.schemaVersion, sessionID: record.sessionID,
            surfaceID: record.surfaceID, launchWorkspaceID: record.launchWorkspaceID,
            ownerPID: record.ownerPID, ownerStartSeconds: record.ownerStartSeconds,
            ownerStartMicroseconds: record.ownerStartMicroseconds,
            recordedAt: Date(timeIntervalSince1970: seconds)
        )
    }
}

nonisolated final class CopilotHookRefreshProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let owner: CopilotProcessIdentity
    private let refresh: @Sendable () throws -> Void
    private var count = 0
    private var succeeded = false

    init(owner: CopilotProcessIdentity, refresh: @escaping @Sendable () throws -> Void) {
        self.owner = owner
        self.refresh = refresh
    }

    var refreshedSuccessfully: Bool {
        lock.lock()
        defer { lock.unlock() }
        return succeeded
    }

    func read(_ pid: Int32) -> CopilotProcessLookup {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        if count == 3 {
            do {
                try refresh()
                succeeded = true
            } catch {
                succeeded = false
            }
        }
        return pid == owner.pid ? .found(owner) : .unavailable
    }
}

nonisolated final class CopilotLookupAudit: @unchecked Sendable {
    private let lock = NSLock()
    private let owner: CopilotProcessIdentity
    private var pids: [Int32] = []

    init(owner: CopilotProcessIdentity) { self.owner = owner }

    var queriedPIDs: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return pids
    }

    func read(_ pid: Int32) -> CopilotProcessLookup {
        lock.lock()
        defer { lock.unlock() }
        pids.append(pid)
        return pid == owner.pid ? .found(owner) : .unavailable
    }
}

nonisolated struct CopilotReaderFixture: Sendable {
    let root: URL
    let bindings: URL
    let sessions: URL
    let session: URL
    let sessionID = UUID()
    let surface = UUID()
    let workspace = UUID()
    let process = CopilotProcessIdentity(
        pid: 4242, parentPID: 1, uid: getuid(), startSeconds: 1, startMicroseconds: 0
    )
    var events: URL { session.appendingPathComponent("events.jsonl") }
    var record: CopilotIdentityRecord {
        .init(
            sessionID: sessionID, surfaceID: surface, launchWorkspaceID: workspace,
            ownerPID: process.pid, ownerStartSeconds: process.startSeconds,
            ownerStartMicroseconds: process.startMicroseconds,
            recordedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    init() throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/copilot-reader-fixtures/\(UUID().uuidString)", isDirectory: true)
        bindings = root.appendingPathComponent("bindings", isDirectory: true)
        sessions = root.appendingPathComponent("session-state", isDirectory: true)
        session = sessions.appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: bindings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try writeRecord(record)
        try Data().write(to: session.appendingPathComponent("inuse.\(process.pid).lock"))
    }

    func writeRecord(_ record: CopilotIdentityRecord, filename: String? = nil, atomic: Bool = false) throws {
        let url = bindings.appendingPathComponent(filename ?? record.sessionID.uuidString.lowercased() + ".json")
        try CopilotIdentityJSON.encode(record).write(to: url, options: atomic ? [.atomic] : [])
        guard chmod(url.path, 0o600) == 0 else { throw CopilotFileError.io }
    }

    func addSession(surface: UUID) throws -> URL {
        let id = UUID()
        let directory = sessions.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeRecord(.init(
            sessionID: id, surfaceID: surface, launchWorkspaceID: workspace,
            ownerPID: process.pid, ownerStartSeconds: process.startSeconds,
            ownerStartMicroseconds: process.startMicroseconds, recordedAt: record.recordedAt
        ))
        return directory
    }

    func writeEvents(_ rows: [Data], atomic: Bool = false) throws {
        var data = Data()
        for row in rows { data.append(row); data.append(10) }
        try data.write(to: events, options: atomic ? [.atomic] : [])
    }

    func append(_ data: Data) throws {
        let handle = try FileHandle(forWritingTo: events)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func reader(
        limits: CopilotReaderLimits = CopilotReaderLimits(),
        lookup: (@Sendable (Int32) -> CopilotProcessLookup)? = nil
    ) -> CopilotSessionReader {
        let owner = process
        return CopilotSessionReader(
            bindingDirectory: bindings, sessionStateRoot: sessions,
            clock: { Date(timeIntervalSince1970: 2_000) },
            processLookup: lookup ?? { $0 == owner.pid ? .found(owner) : .dead },
            limits: limits
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
