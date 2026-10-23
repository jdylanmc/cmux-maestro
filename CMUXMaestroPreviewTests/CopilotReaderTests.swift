import Darwin
import Foundation
import Testing
@testable import CMUXMaestroPreview

// These disk-heavy scenarios share the test executor with short process-readiness checks.
@Suite(.serialized)
nonisolated struct CopilotReaderTests {
    @Test func componentValidationRejectsSeparatorsAndAllowsUnicodeNames() throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let directory = try CopilotFileAccess.openDirectory(fixture.bindings)
        defer { close(directory) }
        for name in ["", ".", "..", "nested/file", "bad\u{0}name", "/\u{0301}"] {
            #expect(throws: CopilotFileError.unsafePath) {
                try CopilotFileAccess.statEntry(at: directory, name: name)
            }
        }
        for name in ["synthetic.json", "cafe\u{0301}.json"] {
            try Data().write(to: fixture.bindings.appendingPathComponent(name))
            #expect(try CopilotFileAccess.statEntry(at: directory, name: name).isRegular)
        }
    }

    @Test func unchangedBindingIndexDoesNotReopenOrDecodeIdentities() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        for _ in 0..<20 { _ = try fixture.addSession(surface: UUID()) }
        let reader = fixture.reader()
        let first = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(first.sessions.count == 1)
        let reads = await reader.identityReads
        let builds = await reader.projectionBuilds
        #expect(reads >= 21)
        let unchanged = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(unchanged.sessions.first?.state == .idle)
        #expect(await reader.identityReads == reads)
        #expect(await reader.projectionBuilds == builds)

        try fixture.writeRecord(fixture.record, atomic: true)
        let refreshed = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(refreshed.sessions.first?.state == .idle)
        #expect(await reader.identityReads == reads + 1)
    }

    @Test func inPlaceOffSurfaceRerouteWithRestoredModificationTimeIsRediscovered() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let record = fixture.record
        try fixture.writeRecord(.init(
            sessionID: record.sessionID, surfaceID: UUID(), launchWorkspaceID: record.launchWorkspaceID,
            ownerPID: record.ownerPID, ownerStartSeconds: record.ownerStartSeconds,
            ownerStartMicroseconds: record.ownerStartMicroseconds, recordedAt: record.recordedAt
        ))
        let reader = fixture.reader()
        #expect(try await reader.read(surfaceIDs: [fixture.surface]).sessions.isEmpty)
        let reads = await reader.identityReads
        #expect(await reader.identityCacheCount() == 1)
        let directory = try CopilotFileAccess.openDirectory(fixture.bindings)
        defer { close(directory) }
        let filename = record.sessionID.uuidString.lowercased() + ".json"
        let beforeDirectory = try CopilotFileAccess.statFile(directory)
        let before = try CopilotFileAccess.statEntry(at: directory, name: filename)
        let file = try FileHandle(forWritingTo: fixture.bindings.appendingPathComponent(filename))
        try file.write(contentsOf: CopilotIdentityJSON.encode(record))
        try file.close()
        let modified = timespec(tv_sec: Int(before.modifiedSeconds), tv_nsec: Int(before.modifiedNanoseconds))
        #expect(utimensat(directory, filename, [modified, modified], 0) == 0)
        let after = try CopilotFileAccess.statEntry(at: directory, name: filename)
        #expect(before.sameFile(as: after) && before.size == after.size)
        #expect(before.modifiedSeconds == after.modifiedSeconds && before.modifiedNanoseconds == after.modifiedNanoseconds)
        #expect(try CopilotFileAccess.statFile(directory) == beforeDirectory)
        let rerouted = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(rerouted.sessions.first?.state == .idle)
        #expect(await reader.identityReads == reads + 1)
    }

    @Test(arguments: ["permissions", "symlink", "malformed"])
    func cachedIdentityNeverSurvivesUnsafeFileChange(_ change: String) async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let reader = fixture.reader()
        #expect(try await reader.read(surfaceIDs: [fixture.surface]).sessions.count == 1)
        let reads = await reader.identityReads
        let url = fixture.bindings.appendingPathComponent(fixture.sessionID.uuidString.lowercased() + ".json")
        switch change {
        case "permissions":
            #expect(chmod(url.path, 0o644) == 0)
        case "symlink":
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: fixture.events)
        default:
            try Data("{}".utf8).write(to: url)
        }
        let rejected = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(rejected.sessions.isEmpty)
        #expect(!rejected.issues.isEmpty)
        #expect(await reader.identityReads > reads)
        #expect(await reader.identityCacheCount() == 0)
        try FileManager.default.removeItem(at: url)
        try fixture.writeRecord(fixture.record)
        #expect(try await reader.read(surfaceIDs: [fixture.surface]).sessions.first?.state == .idle)
    }

    @Test func decodedIdentityCacheIsBoundedAndPrunesRemovedFiles() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        var files: [URL] = []
        for _ in 0..<5 {
            let session = try fixture.addSession(surface: UUID())
            files.append(fixture.bindings.appendingPathComponent(session.lastPathComponent + ".json"))
        }
        let reader = fixture.reader(limits: .init(maximumBindings: 2))
        for _ in 0..<8 {
            _ = try await reader.read(surfaceIDs: [fixture.surface])
            #expect(await reader.identityCacheCount() <= 2)
        }
        for file in files { try FileManager.default.removeItem(at: file) }
        for _ in 0..<8 { _ = try await reader.read(surfaceIDs: [fixture.surface]) }
        #expect(await reader.identityCacheCount() == 1)
        let reads = await reader.identityReads
        #expect(try await reader.read(surfaceIDs: [fixture.surface]).sessions.first?.state == .idle)
        #expect(await reader.identityReads == reads)
        _ = try await reader.read(surfaceIDs: [])
        #expect(await reader.identityCacheCount() == 0)
    }

    @Test func unchangedEventFileDoesNotReadBytesOrRebuildProjection() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let clock = CopilotReaderTestClock()
        let reader = fixture.reader(clock: { clock.now() })
        let first = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(first.isComplete && first.sessions.first?.state == .idle)
        let bytes = await reader.eventReadBytes
        let builds = await reader.projectionBuilds
        clock.advance(by: 600)
        let unchanged = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(unchanged.isComplete && unchanged.sessions.first?.state == .idle)
        #expect(unchanged.sessions.first?.observedAt == clock.now())
        #expect(await reader.eventReadBytes == bytes)
        #expect(await reader.projectionBuilds == builds)
        #expect(await reader.hasPendingHistory() == false)

        let appended = try copilotTestEvent("assistant.turn_start", data: ["turnId": "new"]) + Data([10])
        try fixture.append(appended)
        let changed = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(changed.isComplete && changed.sessions.first?.state == .working)
        #expect(await reader.projectionBuilds == builds + 1)
        #expect(await reader.eventReadBytes <= bytes + appended.count + 512)
    }

    @MainActor
    @Test func twentyOpenBackgroundChatsRefreshIdleAndReportFailureWithoutChangingBounds() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let surfaces = [fixture.surface] + (1..<20).map { _ in UUID() }
        var directories = [fixture.session]
        for surface in surfaces.dropFirst() { directories.append(try fixture.addSession(surface: surface)) }
        for directory in directories {
            try Data().write(to: directory.appendingPathComponent("inuse.\(fixture.process.pid).lock"))
            try (copilotTestEvent("session.idle") + Data([10])).write(to: directory.appendingPathComponent("events.jsonl"))
        }
        let topology = SidebarTopology(.init(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true,
            workspaceMetadataAvailable: true, surfaceMetadataAvailable: true, workspacePathsAvailable: false,
            workspaces: [.init(
                id: fixture.workspace, title: .available("Synthetic twenty-chat workload"), detail: .available(nil),
                isSelected: .available(false), isPinned: .available(false), unreadCount: .available(0),
                rootPath: .unavailable, projectRootPath: .unavailable,
                surfaces: .available(surfaces.map {
                    .init(id: $0, title: "Synthetic background tab", kind: .terminal, isFocused: false,
                          isPinned: false, unreadCount: 0, workingDirectory: .unavailable)
                })
            )], windowID: UUID()
        ))
        let clock = CopilotReaderTestClock()
        let reader = fixture.reader(clock: { clock.now() })
        let measured = ContinuousClock()
        let coldStart = measured.now
        let cold = try await reader.read(surfaceIDs: Set(surfaces))
        let coldTree = SidebarCopilotTree.project(cold, onto: topology, now: clock.now())
        let coldElapsed = coldStart.duration(to: measured.now)
        #expect(coldTree.sessions.count == 20)
        #expect(coldTree.sessions.allSatisfy { $0.state == .idle })
        clock.advance(by: 600)
        let idle = try await reader.read(surfaceIDs: Set(surfaces))
        #expect(idle.sessions.count == 20)
        #expect(idle.sessions.allSatisfy { $0.state == .idle && $0.observedAt == clock.now() })
        for directory in directories {
            let file = try FileHandle(forWritingTo: directory.appendingPathComponent("events.jsonl"))
            try file.seekToEnd()
            try file.write(contentsOf: copilotTestEvent("assistant.turn_start", data: ["turnId": "new"]) + Data([10]))
            try file.close()
        }
        clock.advance(by: 2)
        let updateStart = measured.now
        let updated = try await reader.read(surfaceIDs: Set(surfaces))
        let tree = SidebarCopilotTree.project(updated, onto: topology, now: clock.now())
        let updateElapsed = updateStart.duration(to: measured.now)
        #expect(tree.sessions.count == 20 && tree.sessions.allSatisfy { $0.state == .working })
        try FileManager.default.removeItem(at: fixture.events)
        clock.advance(by: 10)
        let failureStart = measured.now
        let failed = try await reader.read(surfaceIDs: Set(surfaces))
        let failedTree = SidebarCopilotTree.project(failed, onto: topology, now: clock.now())
        let failureElapsed = failureStart.duration(to: measured.now)
        #expect(failed.sessions.first { $0.sessionID == fixture.sessionID }?.sessionIssues == [.stateUnavailable])
        #expect(!failed.issues.contains(.stateUnavailable))
        #expect(failedTree.sessions.count == 19)
        #expect(failedTree.sessions.allSatisfy { $0.state == .working })
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        clock.advance(by: 2)
        let recovered = try await reader.read(surfaceIDs: Set(surfaces))
        #expect(recovered.sessions.count == 20)
        #expect(recovered.sessions.first { $0.sessionID == fixture.sessionID }?.state == .idle)
        let counts = await reader.retentionCounts()
        #expect(counts.bindings == 20 && counts.tails == 20)
        print("S119 synthetic 20-tab reader+projection: cold=\(coldElapsed), update=\(updateElapsed), failure=\(failureElapsed); default poll pause=2s (not included); no host/render latency measured")
    }

    @Test(arguments: ["removed", "replaced", "unsupported"])
    func knownBindingChangeIsExplicitRatherThanTemporaryObservationLoss(_ change: String) async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let reader = fixture.reader()
        #expect(try await reader.read(surfaceIDs: [fixture.surface]).sessions.count == 1)
        if change == "removed" {
            try FileManager.default.removeItem(at: fixture.bindings.appendingPathComponent(fixture.sessionID.uuidString.lowercased() + ".json"))
        } else {
            try fixture.writeRecord(.init(
                schemaVersion: change == "unsupported" ? 2 : 1,
                sessionID: fixture.sessionID, surfaceID: fixture.surface, launchWorkspaceID: fixture.workspace,
                ownerPID: fixture.process.pid,
                ownerStartSeconds: fixture.process.startSeconds + (change == "replaced" ? 1 : 0),
                ownerStartMicroseconds: fixture.process.startMicroseconds, recordedAt: fixture.record.recordedAt
            ), atomic: true)
        }
        let changed = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(changed.issues.contains(.identityChanged))
        if change == "unsupported" { #expect(changed.issues.contains(.unsupportedFormat)) }
        #expect(!changed.sessions.contains { $0.liveness == .alive })
    }

    @MainActor
    @Test func unchangedOverflowKeepsAdmittedTreeFreshOnNormalCadence() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let other = try fixture.addSession(surface: fixture.surface)
        let directories = [fixture.session, other]
        let rows = try (0..<6).map { _ in try copilotTestEvent("assistant.message", data: ["content": "ignored"]) }
            + [copilotTestEvent("session.shutdown", data: ["shutdownType": "routine"])]
        var bytes = Data()
        for row in rows { bytes.append(row); bytes.append(10) }
        for directory in directories {
            try Data().write(to: directory.appendingPathComponent("inuse.\(fixture.process.pid).lock"))
            try bytes.write(to: directory.appendingPathComponent("events.jsonl"))
        }
        let clock = CopilotReaderTestClock()
        let reader = fixture.reader(limits: .init(maximumSessions: 1, linesPerSession: 1), clock: { clock.now() })
        let initial = try await reader.read(surfaceIDs: [fixture.surface])
        let expected = Set(initial.sessions.map(\.sessionID))
        #expect(expected.count == 1)
        let topology = SidebarTopology(HierarchySnapshot(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true,
            workspaceMetadataAvailable: true, surfaceMetadataAvailable: true, workspacePathsAvailable: false,
            workspaces: [
                .init(id: fixture.workspace, title: .available("Synthetic"), detail: .available(nil),
                      isSelected: .available(true), isPinned: .available(false), unreadCount: .available(0),
                      rootPath: .unavailable, projectRootPath: .unavailable, surfaces: .available([
                        .init(id: fixture.surface, title: "Synthetic", kind: .terminal, isFocused: true,
                              isPinned: false, unreadCount: 0, workingDirectory: .unavailable)
                      ]))
            ], windowID: UUID()
        ))
        var normalPolls = 0
        for sweep in 0..<2 {
            var visible: Set<UUID> = []
            for _ in 0..<48 {
                let snapshot = try await reader.read(surfaceIDs: [fixture.surface])
                let tree = SidebarCopilotTree.project(snapshot, onto: topology, now: clock.now())
                visible.formUnion(tree.sessions.filter { $0.state == .completed }.map(\.id))
                let pending = await reader.hasPendingHistory()
                if sweep == 1 { #expect(!pending) }
                if !pending { normalPolls += 1 }
                clock.advance(by: pending ? 0.01 : 2)
                if visible == expected && !pending { break }
            }
            #expect(visible == expected)
        }
        #expect(normalPolls >= 2)
    }

    @Test(arguments: [1, 2, 64], [false, true])
    func boundedCohortsFinishAdmittedTranscriptsWithoutEvictionOrFastRetry(capacity: Int, byteLimited: Bool) async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        var directories = [fixture.session]
        for _ in 0..<capacity { directories.append(try fixture.addSession(surface: fixture.surface)) }
        let rows = try (0..<6).map { _ in try copilotTestEvent("assistant.message", data: ["content": "ignored"]) }
            + [copilotTestEvent("session.shutdown", data: ["shutdownType": "routine"])]
        var bytes = Data()
        for row in rows { bytes.append(row); bytes.append(10) }
        for directory in directories {
            try Data().write(to: directory.appendingPathComponent("inuse.\(fixture.process.pid).lock"))
            try bytes.write(to: directory.appendingPathComponent("events.jsonl"))
        }
        let expected = Set(try directories.map { try #require(UUID(uuidString: $0.lastPathComponent)) })
        let reader = fixture.reader(limits: .init(
            maximumSessions: capacity, bytesPerSession: byteLimited ? max(1, bytes.count / rows.count) : 4_194_304,
            linesPerSession: byteLimited ? 2048 : 1
        ))
        var published: Set<UUID> = []
        var admitted: Set<UUID> = []
        var stopped = false
        // A bounded number of line/byte batches, not a wall-clock timeout.
        let cohorts = (directories.count + capacity - 1) / capacity
        for _ in 0..<((cohorts + 1) * (rows.count + 3)) {
            let snapshot = try await reader.read(surfaceIDs: [fixture.surface])
            #expect(snapshot.sessions.count <= capacity)
            #expect(snapshot.sessions.allSatisfy { expected.contains($0.sessionID) })
            if admitted.isEmpty { admitted = Set(snapshot.sessions.map(\.sessionID)) }
            #expect(Set(snapshot.sessions.map(\.sessionID)) == admitted)
            let counts = await reader.retentionCounts()
            #expect(counts.bindings <= capacity && counts.tails <= capacity && counts.waiting <= 1)
            published.formUnion(snapshot.sessions.filter { $0.state == .completed }.map(\.sessionID))
            let pending = await reader.hasPendingHistory()
            if published == admitted && !pending {
                stopped = true
                break
            }
        }
        #expect(published == admitted && admitted.count == capacity)
        #expect(stopped)
        // Capacity waits never restart fast retries or replace the admitted cohort.
        for _ in 0..<((cohorts + 1) * (rows.count + 3)) {
            _ = try await reader.read(surfaceIDs: [fixture.surface])
            #expect(await reader.hasPendingHistory() == false)
        }
    }

    @Test func growingFirstTranscriptCannotExtendOtherAdmittedCatchupWindow() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let other = try fixture.addSession(surface: fixture.surface)
        var rows = try (0..<6).map { _ in try copilotTestEvent("assistant.message", data: ["content": "ignored"]) }
        rows.append(try copilotTestEvent("session.shutdown", data: ["shutdownType": "routine"]))
        var bytes = Data()
        for row in rows { bytes.append(row); bytes.append(10) }
        for directory in [fixture.session, other] {
            try Data().write(to: directory.appendingPathComponent("inuse.\(fixture.process.pid).lock"))
            try bytes.write(to: directory.appendingPathComponent("events.jsonl"))
        }
        let clock = CopilotReaderTestClock()
        let reader = fixture.reader(limits: .init(maximumSessions: 2, linesPerSession: 1), clock: { clock.now() })
        let capturedAt = clock.now()
        let initial = try await reader.read(surfaceIDs: [fixture.surface])
        let firstID = try #require(initial.sessions.first?.sessionID)
        let all = Set(try [fixture.session, other].map { try #require(UUID(uuidString: $0.lastPathComponent)) })
        let laterID = try #require(all.first(where: { $0 != firstID }))
        let growing = fixture.sessions.appendingPathComponent(firstID.uuidString.lowercased()).appendingPathComponent("events.jsonl")
        var sawCapturedBoundary = false
        var sawLater = false
        for _ in 0..<(rows.count * 2 + 4) {
            clock.advance(by: 2)
            do {
                let handle = try FileHandle(forWritingTo: growing)
                defer { try? handle.close() }
                try handle.seekToEnd()
                for _ in 0..<4 {
                    try handle.write(contentsOf: copilotTestEvent("assistant.message", data: ["content": "more"]) + Data([10]))
                }
            }
            let snapshot = try await reader.read(surfaceIDs: [fixture.surface])
            if snapshot.sessions.contains(where: { $0.sessionID == firstID && $0.state == .completed }) {
                sawCapturedBoundary = true
                #expect(snapshot.sessions.first(where: { $0.sessionID == firstID })?.observedAt == capturedAt)
                #expect(snapshot.issues.contains(.loadingHistory))
                #expect(!snapshot.isComplete)
            }
            if snapshot.sessions.contains(where: { $0.sessionID == laterID && $0.state == .completed }) {
                sawLater = true
                break
            }
            let counts = await reader.retentionCounts()
            #expect(counts.tails <= 2 && counts.bindings <= 2 && counts.waiting == 0)
        }
        #expect(sawCapturedBoundary)
        #expect(sawLater)
    }

    @Test(arguments: ["active-revoked", "waiting-revoked", "waiting-removed", "directory-replaced", "grant-revoked", "cancelled"])
    func waitingCatchupSlotRevalidatesIdentityAndUnwindsSafely(change: String) async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let other = try fixture.addSession(surface: fixture.surface)
        var rows = try (0..<6).map { _ in try copilotTestEvent("assistant.message", data: ["content": "ignored"]) }
        rows.append(try copilotTestEvent("session.shutdown", data: ["shutdownType": "routine"]))
        var bytes = Data()
        for row in rows { bytes.append(row); bytes.append(10) }
        for directory in [fixture.session, other] {
            try Data().write(to: directory.appendingPathComponent("inuse.\(fixture.process.pid).lock"))
            try bytes.write(to: directory.appendingPathComponent("events.jsonl"))
        }
        let all = Set(try [fixture.session, other].map { try #require(UUID(uuidString: $0.lastPathComponent)) })
        let audit = CopilotLookupAudit(owner: fixture.process)
        let reader = fixture.reader(
            limits: .init(maximumSessions: 1, linesPerSession: 1), lookup: { audit.read($0) }
        )
        let first = try await reader.read(surfaceIDs: [fixture.surface])
        let activeID = try #require(first.sessions.first?.sessionID)
        let waitingID = try #require(all.first(where: { $0 != activeID }))
        _ = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(await reader.retentionCounts().waiting == 1)
        var expected: Set<UUID> = [activeID]
        switch change {
        case "active-revoked", "waiting-revoked":
            let revoked = change == "active-revoked" ? activeID : waitingID
            if change == "active-revoked" { expected = [waitingID] }
            try fixture.writeRecord(.init(
                sessionID: revoked, surfaceID: UUID(), launchWorkspaceID: fixture.workspace,
                ownerPID: 7878, ownerStartSeconds: 1, ownerStartMicroseconds: 0,
                recordedAt: fixture.record.recordedAt
            ), atomic: true)
        case "waiting-removed":
            expected.remove(waitingID)
            try FileManager.default.removeItem(
                at: fixture.bindings.appendingPathComponent(waitingID.uuidString.lowercased() + ".json")
            )
        case "directory-replaced":
            expected = [waitingID]
            try FileManager.default.moveItem(
                at: fixture.bindings, to: fixture.root.appendingPathComponent("old-bindings")
            )
            try FileManager.default.createDirectory(at: fixture.bindings, withIntermediateDirectories: true)
            try fixture.writeRecord(.init(
                sessionID: waitingID, surfaceID: fixture.surface, launchWorkspaceID: fixture.workspace,
                ownerPID: fixture.process.pid, ownerStartSeconds: 1, ownerStartMicroseconds: 0,
                recordedAt: fixture.record.recordedAt
            ))
        case "grant-revoked":
            expected = all
            let revoked = try await reader.read(surfaceIDs: [])
            #expect(revoked.sessions.isEmpty)
            #expect(await reader.retentionCounts().tails == 0)
            #expect(await reader.retentionCounts().waiting == 0)
            #expect(await reader.hasPendingHistory() == false)
        default:
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await reader.read(surfaceIDs: [fixture.surface])
            }
            do {
                _ = try await cancelled.value
                Issue.record("Cancelled catchup published a snapshot")
            } catch is CancellationError {}
            #expect(await reader.retentionCounts().tails == 1)
            #expect(await reader.retentionCounts().waiting == 0)
            #expect(await reader.hasPendingHistory() == false)
        }
        var published: Set<UUID> = []
        for _ in 0..<((rows.count + 3) * (expected.count + 1)) {
            let snapshot = try await reader.read(surfaceIDs: [fixture.surface])
            #expect(snapshot.sessions.allSatisfy { expected.contains($0.sessionID) })
            published.formUnion(snapshot.sessions.filter { $0.state == .completed }.map(\.sessionID))
            let counts = await reader.retentionCounts()
            #expect(counts.bindings <= 1 && counts.tails <= 1 && counts.waiting <= 1)
            if published.count == 1 { break }
        }
        #expect(published.count == 1 && published.isSubset(of: expected))
        #expect(!audit.queriedPIDs.contains(7878))
    }

    @Test func routingDiscoveryProgressesBeyondFirst1024HistoricalEntries() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        for index in 0..<1100 {
            try Data().write(to: fixture.bindings.appendingPathComponent("historical-\(index).lock"))
            let offSurfaceID = UUID()
            try fixture.writeRecord(.init(
                sessionID: offSurfaceID, surfaceID: UUID(), launchWorkspaceID: fixture.workspace,
                ownerPID: 7878, ownerStartSeconds: 1, ownerStartMicroseconds: 0,
                recordedAt: fixture.record.recordedAt
            ))
            let directory = fixture.sessions.appendingPathComponent(offSurfaceID.uuidString.lowercased())
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("OFF_SURFACE_TRANSCRIPT_MUST_NOT_BE_READ\n".utf8)
                .write(to: directory.appendingPathComponent("events.jsonl"))
        }
        let directory = try CopilotFileAccess.openDirectory(fixture.bindings)
        defer { close(directory) }
        let prefix = try CopilotFileAccess.names(at: directory, limit: 1024)
        #expect(prefix.limited)
        let all = try CopilotFileAccess.names(at: directory, limit: 4096)
        let filename = try #require(all.names.first {
            $0.hasSuffix(".json") && !prefix.names.contains($0)
                && $0 != fixture.sessionID.uuidString.lowercased() + ".json"
        })
        let targetID = try #require(UUID(uuidString: String(filename.dropLast(5))))
        try FileManager.default.removeItem(
            at: fixture.bindings.appendingPathComponent(fixture.sessionID.uuidString.lowercased() + ".json")
        )
        try fixture.writeRecord(.init(
            sessionID: targetID, surfaceID: fixture.surface, launchWorkspaceID: fixture.workspace,
            ownerPID: fixture.process.pid, ownerStartSeconds: 1, ownerStartMicroseconds: 0,
            recordedAt: fixture.record.recordedAt
        ))
        let target = fixture.sessions.appendingPathComponent(targetID.uuidString.lowercased())
        try Data().write(to: target.appendingPathComponent("inuse.\(fixture.process.pid).lock"))
        try (copilotTestEvent("session.idle") + Data([10])).write(to: target.appendingPathComponent("events.jsonl"))
        let audit = CopilotLookupAudit(owner: fixture.process)
        let reader = fixture.reader(lookup: { audit.read($0) })
        var snapshot = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(!snapshot.isComplete)
        for _ in 0..<8 where !snapshot.isComplete {
            snapshot = try await reader.read(surfaceIDs: [fixture.surface])
        }
        #expect(snapshot.isComplete)
        #expect(snapshot.sessions.map(\.sessionID) == [targetID])
        #expect(snapshot.sessions.first?.state == .idle)
        #expect(!audit.queriedPIDs.contains(7878))
        #expect(await reader.hasPendingHistory() == false)
    }

    @Test func longTranscriptRetirementPublishesFreshBlockedWorkAndSurvivesRebuild() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        var rows: [Data] = []
        for index in 0..<4300 {
            rows.append(try copilotTestEvent("tool.execution_start", data: [
                "toolCallId": "shell-\(index)", "toolName": "bash"
            ]))
            rows.append(try copilotTestEvent("tool.execution_complete", data: [
                "toolCallId": "shell-\(index)", "success": true
            ]))
        }
        rows.append(try copilotTestEvent("tool.execution_start", data: ["toolCallId": "fresh", "toolName": "task"]))
        rows.append(try copilotTestEvent("subagent.started", agent: "fresh", data: [
            "toolCallId": "fresh", "agentDisplayName": "Fresh"
        ]))
        rows.append(try copilotTestEvent("permission.requested", agent: "fresh", data: ["requestId": "approval"]))
        try fixture.writeEvents(rows)
        let reader = fixture.reader()
        var snapshot = try await reader.read(surfaceIDs: [fixture.surface])
        for _ in 0..<12 where !snapshot.isComplete {
            #expect(await reader.hasPendingHistory())
            snapshot = try await reader.read(surfaceIDs: [fixture.surface])
        }
        #expect(snapshot.isComplete)
        #expect(snapshot.sessions.first?.children.last?.id == "fresh")
        #expect(snapshot.sessions.first?.children.last?.state == .blocked)
        #expect(snapshot.sessions.first?.children.count == 256)
        try fixture.writeEvents(rows, atomic: true)
        var rebuilt = try await reader.read(surfaceIDs: [fixture.surface])
        for _ in 0..<12 where !rebuilt.isComplete {
            rebuilt = try await reader.read(surfaceIDs: [fixture.surface])
        }
        #expect(rebuilt.isComplete)
        #expect(snapshot.sessions == rebuilt.sessions)
    }

    @Test func cachedBindingsAreRevalidatedForChangeRemovalAndSurfaceRevocation() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let audit = CopilotLookupAudit(owner: fixture.process)
        let reader = fixture.reader(limits: .init(maximumBindings: 2), lookup: { audit.read($0) })
        let initial = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(initial.isComplete)
        for index in 0..<8 {
            try Data().write(to: fixture.bindings.appendingPathComponent("old-\(index).lock"))
        }
        let pending = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(pending.sessions.first?.state == .idle)
        #expect(await reader.hasPendingHistory())
        let otherSurface = UUID()
        try fixture.writeRecord(.init(
            sessionID: fixture.sessionID, surfaceID: otherSurface, launchWorkspaceID: fixture.workspace,
            ownerPID: 7878, ownerStartSeconds: 1, ownerStartMicroseconds: 0,
            recordedAt: fixture.record.recordedAt
        ), atomic: true)
        let changed = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(changed.sessions.isEmpty)
        try fixture.writeRecord(fixture.record, atomic: true)
        var restored = try await reader.read(surfaceIDs: [fixture.surface])
        for _ in 0..<20 where restored.sessions.isEmpty {
            restored = try await reader.read(surfaceIDs: [fixture.surface])
        }
        #expect(restored.sessions.first?.state == .idle)
        let revoked = try await reader.read(surfaceIDs: [otherSurface])
        #expect(revoked.sessions.isEmpty)
        _ = try await reader.read(surfaceIDs: [fixture.surface])
        try FileManager.default.removeItem(
            at: fixture.bindings.appendingPathComponent(fixture.sessionID.uuidString.lowercased() + ".json")
        )
        let removed = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(removed.sessions.isEmpty)
        let empty = try await reader.read(surfaceIDs: [])
        #expect(empty.isComplete && empty.sessions.isEmpty)
        #expect(await reader.hasPendingHistory() == false)
        #expect(!audit.queriedPIDs.contains(7878))
    }

    @Test func replacedOrSymlinkedIndexNeverPublishesOldCachedBinding() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let reader = fixture.reader(limits: .init(maximumBindings: 2))
        _ = try await reader.read(surfaceIDs: [fixture.surface])
        for index in 0..<8 {
            try Data().write(to: fixture.bindings.appendingPathComponent("old-\(index).lock"))
        }
        _ = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(await reader.hasPendingHistory())
        let parked = fixture.root.appendingPathComponent("old-bindings")
        try FileManager.default.moveItem(at: fixture.bindings, to: parked)
        try FileManager.default.createDirectory(at: fixture.bindings, withIntermediateDirectories: true)
        let replaced = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(replaced.sessions.isEmpty)
        #expect(replaced.issues == [.identityChanged, .noIdentityRecords])
        #expect(await reader.hasPendingHistory() == false)
        try FileManager.default.removeItem(at: fixture.bindings)
        try FileManager.default.createSymbolicLink(at: fixture.bindings, withDestinationURL: parked)
        let symlink = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(symlink.sessions.isEmpty)
        #expect(symlink.issues == [.ambiguousIdentity])
    }

    @Test func directoryReplacementDuringProcessValidationSuppressesPublication() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let probe = CopilotHookRefreshProbe(owner: fixture.process) {
            try FileManager.default.moveItem(
                at: fixture.bindings, to: fixture.root.appendingPathComponent("replaced-bindings")
            )
            try FileManager.default.createDirectory(at: fixture.bindings, withIntermediateDirectories: true)
        }
        let reader = fixture.reader(lookup: { probe.read($0) })
        let snapshot = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(probe.refreshedSuccessfully)
        #expect(snapshot.sessions.isEmpty)
        #expect(snapshot.issues == [.identityChanged])
        #expect(await reader.hasPendingHistory() == false)
        let next = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(next.sessions.isEmpty)
        #expect(Set(next.issues) == [.identityChanged, .noIdentityRecords])
        let settled = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(settled.sessions.isEmpty && settled.issues == [.noIdentityRecords])
    }

    @Test func cappedVisibleDiscoveryRetainsCohortWithoutClaimingCompleteOrSpinning() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        var expected: Set<UUID> = [fixture.sessionID]
        for _ in 0..<7 {
            let directory = try fixture.addSession(surface: fixture.surface)
            expected.insert(try #require(UUID(uuidString: directory.lastPathComponent)))
            try Data().write(to: directory.appendingPathComponent("inuse.\(fixture.process.pid).lock"))
            try (copilotTestEvent("session.idle") + Data([10]))
                .write(to: directory.appendingPathComponent("events.jsonl"))
        }
        let reader = fixture.reader(limits: .init(maximumSessions: 2, maximumBindings: 3))
        var observed: Set<UUID> = []
        var reachedEOF = false
        for _ in 0..<8 {
            let snapshot = try await reader.read(surfaceIDs: [fixture.surface])
            #expect(snapshot.sessions.count <= 2)
            #expect(!snapshot.isComplete)
            #expect(snapshot.issues.contains(.readLimitReached))
            observed.formUnion(snapshot.sessions.map(\.sessionID))
            if await reader.hasPendingHistory() == false { reachedEOF = true }
        }
        #expect(observed.count == 2 && observed.isSubset(of: expected))
        #expect(reachedEOF)
    }

    @Test func cancellationClosesDiscoveryAndRestartsWithoutCachedPublication() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        for index in 0..<8 {
            try Data().write(to: fixture.bindings.appendingPathComponent("old-\(index).lock"))
        }
        let reader = fixture.reader(limits: .init(maximumBindings: 2))
        _ = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(await reader.hasPendingHistory())
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.read(surfaceIDs: [fixture.surface])
        }
        do {
            _ = try await cancelled.value
            Issue.record("Cancelled discovery published a snapshot")
        } catch is CancellationError {}
        #expect(await reader.hasPendingHistory() == false)
        let empty = try await reader.read(surfaceIDs: [])
        #expect(empty.isComplete && empty.sessions.isEmpty)
        var restarted = try await reader.read(surfaceIDs: [fixture.surface])
        for _ in 0..<8 where !restarted.isComplete {
            restarted = try await reader.read(surfaceIDs: [fixture.surface])
        }
        #expect(restarted.isComplete)
        #expect(restarted.sessions.first?.state == .idle)
    }

    @Test func cancellationDuringIdentityVerificationDiscardsCandidateAndStream() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let probe = CopilotHookRefreshProbe(owner: fixture.process) {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let reader = fixture.reader(lookup: { probe.read($0) })
        let task = Task { try await reader.read(surfaceIDs: [fixture.surface]) }
        do {
            _ = try await task.value
            Issue.record("In-flight cancellation published a candidate")
        } catch is CancellationError {}
        #expect(probe.refreshedSuccessfully)
        #expect(await reader.hasPendingHistory() == false)
        let recovered = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(recovered.isComplete)
        #expect(recovered.sessions.first?.state == .idle)
    }

    @Test func malformedEarlierIndexPagePreventsFalseCompleteAtEOF() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        var names: [String] = []
        for _ in 0..<6 {
            let id = UUID()
            let name = id.uuidString.lowercased() + ".json"
            names.append(name)
            try fixture.writeRecord(.init(
                sessionID: id, surfaceID: UUID(), launchWorkspaceID: fixture.workspace,
                ownerPID: 7878, ownerStartSeconds: 1, ownerStartMicroseconds: 0,
                recordedAt: fixture.record.recordedAt
            ))
        }
        let directory = try CopilotFileAccess.openDirectory(fixture.bindings)
        defer { close(directory) }
        let firstPage = try CopilotFileAccess.names(at: directory, limit: 2)
        let badName = try #require(firstPage.names.first { names.contains($0) })
        try Data("{malformed}\n".utf8).write(to: fixture.bindings.appendingPathComponent(badName))
        let reader = fixture.reader(limits: .init(maximumBindings: 2))
        var snapshot = try await reader.read(surfaceIDs: [fixture.surface])
        for _ in 0..<8 {
            if await reader.hasPendingHistory() == false { break }
            snapshot = try await reader.read(surfaceIDs: [fixture.surface])
        }
        #expect(!snapshot.isComplete)
        #expect(snapshot.issues.contains(.malformedData))
        #expect(await reader.hasPendingHistory() == false)
        for name in names { try FileManager.default.removeItem(at: fixture.bindings.appendingPathComponent(name)) }
        let repaired = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(repaired.isComplete)
        #expect(repaired.sessions.first?.state == .idle)
    }

    @Test func cancelledDirectoryStreamClosesAndCannotResumeOldCursor() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let directory = try CopilotFileAccess.openDirectory(fixture.bindings)
        defer { close(directory) }
        let stream = try CopilotDirectoryStream(at: directory)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try stream.next()
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled directory stream advanced")
        } catch is CancellationError {}
        #expect(stream.finished)
        #expect(try stream.next() == nil)
    }

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
        #expect(missing.sessions[0].sessionIssues == [.stateUnavailable])
        #expect(!missing.issues.contains(.stateUnavailable))
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

    @Test func standaloneAppearanceDoesNotChangeLifecycleAndMalformedAppearanceDoesNotPoisonIt() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("assistant.turn_start", data: ["turnId": "current"])])
        let file = fixture.bindings.appendingPathComponent("appearance-\(fixture.sessionID.uuidString.lowercased()).json")
        let choice = CopilotSessionAppearance(sessionID: fixture.sessionID, iconId: "md-duck", iconColor: "blue")
        try JSONEncoder().encode(choice).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let reader = fixture.reader()
        let chosen = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(chosen.sessions.first?.iconId == "md-duck")
        #expect(chosen.sessions.first?.iconColor == "blue")
        #expect(chosen.sessions.first?.state == .working)
        try Data("malformed".utf8).write(to: file)
        let invalid = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(invalid.issues.contains(.appearanceUnavailable))
        #expect(invalid.issues.allSatisfy { $0.isCosmetic })
        #expect(invalid.isComplete)
        #expect(invalid.sessions.first?.state == .working)
        #expect(invalid.sessions.first?.iconId == nil)
    }

    /// #261: a resumed session has no observer binding and no inuse lock before its first prompt.
    /// The controller's exact session UUID still yields its name and own appearance, never state.
    @Test func managedSessionDetailsNameAnUnboundSessionByItsExactUUID() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let resumed = fixture.sessions.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let id = try #require(UUID(uuidString: resumed.lastPathComponent))
        try FileManager.default.createDirectory(at: resumed, withIntermediateDirectories: true)
        let yaml = resumed.appendingPathComponent(CopilotSessionName.filename)
        try Data("name: Synthetic refactor\n".utf8).write(to: yaml)
        let file = fixture.bindings.appendingPathComponent("appearance-\(id.uuidString.lowercased()).json")
        try JSONEncoder().encode(CopilotSessionAppearance(sessionID: id, petId: "synthetic-pet")).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let reader = fixture.reader()
        let observed = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(!observed.sessions.contains { $0.sessionID == id })
        let details = await reader.managedSessionDetails([id, UUID()])
        #expect(details.count == 1)
        #expect(details[id]?.sessionName == "Synthetic refactor")
        #expect(details[id]?.petId == "synthetic-pet")
        #expect(details[id]?.readAt == Date(timeIntervalSince1970: 2_000))
        #expect(await reader.managedSessionDetails([]).isEmpty)
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
        #expect(directory.sessions.first?.sessionIssues?.contains(.ambiguousIdentity) == true)
        #expect(!directory.isComplete)
    }

    @Test func oneAmbiguousSessionDoesNotBlankOrPoisonHealthySessions() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("assistant.turn_start", data: ["turnId": "current"])])
        let badSurface = UUID()
        let bad = try fixture.addSession(surface: badSurface)
        try FileManager.default.removeItem(at: bad)
        try FileManager.default.createSymbolicLink(at: bad, withDestinationURL: fixture.root)
        let snapshot = try await fixture.reader().read(surfaceIDs: [fixture.surface, badSurface])
        let healthy = snapshot.sessions.first { $0.sessionID == fixture.sessionID }
        #expect(healthy?.state == .working)
        #expect(healthy?.sessionIssues == nil)
        let broken = snapshot.sessions.first { $0.surfaceID == badSurface }
        #expect(broken?.sessionIssues == [.ambiguousIdentity])
        #expect(!snapshot.issues.contains(.ambiguousIdentity))
        #expect(!snapshot.isComplete)
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
        let reader = fixture.reader(lookup: { probe.read($0) })
        let snapshot = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(probe.refreshedSuccessfully)
        // Atomic replacement changes the index during this cycle. The verified
        // row is usable, but discovery must run one stable cycle before complete.
        #expect(snapshot.issues == [.readLimitReached])
        let refreshedSession = try #require(snapshot.sessions.first)
        #expect(refreshedSession.liveness == .alive)
        #expect(refreshedSession.state == .idle)
        let stable = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(stable.isComplete)
        #expect(try #require(stable.sessions.first).sessionID == fixture.sessionID)
    }

    @Test func routingChangeDuringAtomicBindingRefreshStillInvalidatesCandidate() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let peerDirectory = try fixture.addSession(surface: fixture.surface)
        let peerID = try #require(UUID(uuidString: peerDirectory.lastPathComponent))
        try Data().write(to: peerDirectory.appendingPathComponent("inuse.\(fixture.process.pid).lock"))
        try (copilotTestEvent("session.idle") + Data([10]))
            .write(to: peerDirectory.appendingPathComponent("events.jsonl"))
        let record = fixture.record
        let rerouted = CopilotIdentityRecord(
            sessionID: record.sessionID, surfaceID: UUID(), launchWorkspaceID: record.launchWorkspaceID,
            ownerPID: record.ownerPID, ownerStartSeconds: record.ownerStartSeconds,
            ownerStartMicroseconds: record.ownerStartMicroseconds, recordedAt: record.recordedAt
        )
        let probe = CopilotHookRefreshProbe(owner: fixture.process) {
            try fixture.writeRecord(rerouted, atomic: true)
        }
        let reader = fixture.reader(lookup: { probe.read($0) })
        let snapshot = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(probe.refreshedSuccessfully)
        #expect(snapshot.issues.contains(.identityChanged))
        #expect(!snapshot.isComplete)
        // A revoked routing identity must not escape even as an ambiguous row.
        // Unrelated granted evidence must still be visible in the same batch.
        #expect(snapshot.sessions.map(\.sessionID) == [peerID])
        let peer = try #require(snapshot.sessions.first(where: { $0.sessionID == peerID }))
        #expect(peer.liveness == .alive)
        #expect(peer.state == .idle)
        let publicJSON = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).lowercased()
        #expect(!publicJSON.contains(record.sessionID.uuidString.lowercased()))
        #expect(!publicJSON.contains(rerouted.surfaceID.uuidString.lowercased()))

        let originalGrant = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(originalGrant.isComplete)
        #expect(originalGrant.sessions.map(\.sessionID) == [peerID])
        let newGrant = try await reader.read(surfaceIDs: [rerouted.surfaceID])
        #expect(newGrant.isComplete)
        let moved = try #require(newGrant.sessions.first(where: { $0.sessionID == record.sessionID }))
        #expect(moved.surfaceID == rerouted.surfaceID)
        #expect(moved.liveness == .alive)
        #expect(moved.state == .idle)
    }

    @Test func reroutingWithinGrantedSurfacesDefersStaleCandidateThenRebuilds() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let record = fixture.record
        let newSurface = UUID()
        let rerouted = CopilotIdentityRecord(
            sessionID: record.sessionID, surfaceID: newSurface, launchWorkspaceID: record.launchWorkspaceID,
            ownerPID: record.ownerPID, ownerStartSeconds: record.ownerStartSeconds,
            ownerStartMicroseconds: record.ownerStartMicroseconds, recordedAt: record.recordedAt
        )
        let probe = CopilotHookRefreshProbe(owner: fixture.process) {
            try fixture.writeRecord(rerouted, atomic: true)
            try fixture.writeEvents([copilotTestEvent("assistant.turn_start", data: ["turnId": "new-route"])], atomic: true)
        }
        let reader = fixture.reader(lookup: { probe.read($0) })
        let grants: Set<UUID> = [fixture.surface, newSurface]
        let changed = try await reader.read(surfaceIDs: grants)
        #expect(probe.refreshedSuccessfully)
        #expect(changed.issues.contains(.identityChanged))
        #expect(!changed.isComplete)
        #expect(changed.sessions.isEmpty)
        let recovered = try await reader.read(surfaceIDs: grants)
        #expect(recovered.isComplete)
        let moved = try #require(recovered.sessions.first)
        #expect(moved.sessionID == record.sessionID)
        #expect(moved.surfaceID == newSurface)
        #expect(moved.launchWorkspaceID == record.launchWorkspaceID)
        #expect(moved.liveness == .alive)
        #expect(moved.state == .working)
    }

    @Test func unstableProcessEvidenceWithUnchangedBindingStillReturnsAmbiguousRow() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let probe = CopilotHookRefreshProbe(owner: fixture.process) {
            try Data("replaced-marker".utf8).write(
                to: fixture.session.appendingPathComponent("inuse.\(fixture.process.pid).lock"), options: .atomic
            )
        }
        let reader = fixture.reader(lookup: { probe.read($0) })
        let snapshot = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(probe.refreshedSuccessfully)
        #expect(!snapshot.issues.contains(.identityChanged))
        #expect(!snapshot.isComplete)
        let ambiguous = try #require(snapshot.sessions.first)
        #expect(ambiguous.sessionIssues == [.identityChanged])
        #expect(ambiguous.sessionID == fixture.sessionID)
        #expect(ambiguous.surfaceID == fixture.surface)
        #expect(ambiguous.liveness == .ambiguous)
        #expect(ambiguous.state == .unknown)
        #expect(ambiguous.children.isEmpty)
        let recovered = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(recovered.isComplete)
        #expect(try #require(recovered.sessions.first).state == .idle)
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
        #expect(missing.sessions.first { $0.sessionID == fixture.sessionID }?.sessionIssues == [.stateUnavailable])
        #expect(!missing.issues.contains(.stateUnavailable))
        #expect(await reader.hasPendingHistory() == false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_MAESTRO_READER_BENCHMARK"] == "1"))
    func coldStartBenchmarkWith230MiBOfIgnoredSyntheticPayloads() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.start", data: [
            "sessionId": fixture.sessionID.uuidString, "version": 1
        ])])
        let row = try copilotTestEvent("tool.execution_partial_result", data: [
            "toolCallId": "ignored-payload", "partialOutput": String(repeating: "x", count: 524_288)
        ]) + Data([10])
        let handle = try FileHandle(forWritingTo: fixture.events)
        do {
            try handle.seekToEnd()
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
        let snapshot = try await reader.read(surfaceIDs: [fixture.surface])
        let duration = start.duration(to: clock.now).components
        let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        var usage = rusage()
        let measuredRSS = getrusage(RUSAGE_SELF, &usage) == 0 ? usage.ru_maxrss : -1
        let readBytes = await reader.eventReadBytes
        print("COPILOT_READER_BENCHMARK bytes=\(fileSize.int64Value) readBytes=\(readBytes) batches=1 seconds=\(seconds) processPeakRSSBytes=\(measuredRSS)")
        #expect(!snapshot.isComplete)
        #expect(snapshot.sessions[0].sessionIssues == [.readLimitReached])
        #expect(!snapshot.issues.contains(.loadingHistory))
        #expect(snapshot.sessions[0].state == .idle)
        #expect(snapshot.sessions[0].children.map(\.id) == ["parent", "child", "sibling"])
        #expect(snapshot.sessions[0].children.map(\.parentID) == [nil, "parent", nil])
        #expect(snapshot.sessions[0].children.map(\.state) == [.working, .cancelled, .failed])
        #expect(await reader.hasPendingHistory() == false)
        _ = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(await reader.eventReadBytes == readBytes)
    }

    @Test func largeLogColdStartReadsCurrentTailWithoutHistoricalCatchup() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.start", data: [
            "sessionId": fixture.sessionID.uuidString, "version": 1
        ])])
        let file = try FileHandle(forWritingTo: fixture.events)
        try file.seekToEnd()
        try file.write(contentsOf: Data("""
        {"id":"10000000-0000-0000-0000-000000000001","type":"assistant.message","data":{"content":"
        """.utf8))
        let opaque = Data(repeating: 120, count: 1_048_576)
        for _ in 0..<320 { try file.write(contentsOf: opaque) }
        try file.write(contentsOf: Data("\"}}\n".utf8))
        try file.close()
        try fixture.append(copilotTestEvent("assistant.turn_start", data: [
            "turnId": "current", "model": "Synthetic model"
        ]) + Data([10]))
        let reader = fixture.reader()
        let initial = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(initial.sessions.first?.state == .working)
        #expect(initial.sessions.first?.model == "Synthetic model")
        #expect(initial.sessions.first?.sessionIssues == [.readLimitReached])
        #expect(!initial.issues.contains(.readLimitReached))
        #expect(!initial.isComplete)
        #expect(await reader.hasPendingHistory() == false)
        let firstBytes = await reader.eventReadBytes
        #expect(firstBytes <= 4_194_304 + 4096 + 256)
        let unchanged = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(unchanged.sessions.first?.state == .working)
        #expect(await reader.eventReadBytes == firstBytes)
        let appended = try copilotTestEvent("assistant.turn_end", data: ["turnId": "current"]) + Data([10])
        try fixture.append(appended)
        let updated = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(updated.sessions.first?.state == .idle)
        #expect(await reader.eventReadBytes - firstBytes <= appended.count + 512)
        #expect(await reader.hasPendingHistory() == false)
        let restarted = fixture.reader()
        let afterRestart = try await restarted.read(surfaceIDs: [fixture.surface])
        #expect(afterRestart.sessions.first?.state == .idle)
        #expect(await restarted.eventReadBytes <= 4_194_304 + 4096 + 256)
        #expect(await restarted.hasPendingHistory() == false)
    }

    @Test func largerTailWindowKeepsPerReadBudgetAndFinishesOnlyItsFrozenWindow() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([
            copilotTestEvent("session.start", data: ["sessionId": fixture.sessionID.uuidString, "version": 1]),
            copilotTestEvent("assistant.message", data: ["content": String(repeating: "x", count: 10 * 1_048_576)]),
            copilotTestEvent("assistant.turn_start", data: ["turnId": "current"])
        ])
        let reader = fixture.reader()
        let first = try await reader.read(surfaceIDs: [fixture.surface], tailWindowMiB: 8)
        #expect(first.sessions.first?.state == .unknown)
        #expect(await reader.hasPendingHistory())
        let firstBytes = await reader.eventReadBytes
        #expect(firstBytes <= 4_194_304 + 4096 + 256)
        // A preference change does not restart or expand an admitted window.
        let second = try await reader.read(surfaceIDs: [fixture.surface], tailWindowMiB: 64)
        #expect(second.sessions.first?.state == .working)
        #expect(second.sessions.first?.sessionIssues == [.readLimitReached])
        #expect(await reader.eventReadBytes - firstBytes <= 4_194_304 + 512)
        #expect(await reader.hasPendingHistory() == false)
        let caughtUp = await reader.eventReadBytes
        _ = try await reader.read(surfaceIDs: [fixture.surface], tailWindowMiB: 1)
        #expect(await reader.eventReadBytes == caughtUp)
    }

    @Test func missingTailBoundaryRemainsUnknownUntilNewCompleteEvidence() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.start", data: [
            "sessionId": fixture.sessionID.uuidString, "version": 1
        ])])
        try fixture.append(Data("""
        {"id":"10000000-0000-0000-0000-000000000001","type":"assistant.message","data":{"content":"
        """.utf8) + Data(repeating: 120, count: 2 * 1_048_576))
        let reader = fixture.reader()
        let partial = try await reader.read(surfaceIDs: [fixture.surface], tailWindowMiB: 1)
        #expect(partial.sessions.first?.state == .unknown)
        #expect(partial.sessions.first?.sessionIssues == [.readLimitReached])
        #expect(await reader.hasPendingHistory() == false)
        let bytes = await reader.eventReadBytes
        _ = try await reader.read(surfaceIDs: [fixture.surface], tailWindowMiB: 4)
        #expect(await reader.eventReadBytes == bytes)
        try fixture.append(Data("\"}}\n".utf8) + copilotTestEvent("assistant.turn_start", data: [
            "turnId": "new-evidence"
        ]) + Data([10]))
        let updated = try await reader.read(surfaceIDs: [fixture.surface], tailWindowMiB: 4)
        #expect(updated.sessions.first?.state == .working)
        #expect(!updated.issues.contains(.malformedData))
        #expect(updated.sessions.first?.sessionIssues == [.readLimitReached])
    }

    @Test(arguments: ["foreign", "unsupported"])
    func boundedTailStillValidatesSourceHeader(_ failure: String) async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([
            copilotTestEvent("session.start", data: [
                "sessionId": failure == "foreign" ? UUID().uuidString : fixture.sessionID.uuidString,
                "version": failure == "unsupported" ? 0 : 1
            ]),
            copilotTestEvent("assistant.message", data: ["content": String(repeating: "x", count: 2 * 1_048_576)]),
            copilotTestEvent("assistant.turn_start", data: ["turnId": "untrusted"])
        ])
        let value = try await fixture.reader().read(surfaceIDs: [fixture.surface], tailWindowMiB: 1)
        #expect(value.sessions.first?.state == .unknown)
        #expect(value.issues.contains(failure == "foreign" ? .identityChanged : .unsupportedFormat))
    }

    @Test(arguments: [0, 65, Int.max])
    func invalidTailWindowIsRejectedBeforeReading(_ value: Int) async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let reader = fixture.reader()
        await #expect(throws: CopilotSessionReader.ConfigurationError.self) {
            _ = try await reader.read(surfaceIDs: [fixture.surface], tailWindowMiB: value)
        }
        #expect(await reader.eventReadBytes == 0)
    }

    @Test(arguments: ["surface-added", "bindings-unavailable", "marker-unavailable"])
    func retainedSessionKeepsObservedReplayAcrossDiscoveryRecovery(_ change: String) async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let start = try copilotTestEvent("assistant.turn_start", data: ["turnId": "observed"])
        try fixture.writeEvents([
            copilotTestEvent("session.start", data: ["sessionId": fixture.sessionID.uuidString, "version": 1]),
            start, copilotTestEvent("assistant.turn_end", data: ["turnId": "observed"])
        ])
        let reader = fixture.reader()
        _ = try await reader.read(surfaceIDs: [fixture.surface], tailWindowMiB: 1)
        for _ in 0..<3 {
            try fixture.append(copilotTestEvent("assistant.message", data: [
                "content": String(repeating: "x", count: 750_000)
            ]) + Data([10]))
            let advanced = try await reader.read(surfaceIDs: [fixture.surface], tailWindowMiB: 1)
            #expect(advanced.sessions.first?.state == .idle)
        }
        let observedBytes = await reader.eventReadBytes
        var surfaces: Set<UUID> = [fixture.surface]
        if change == "surface-added" {
            surfaces.insert(UUID())
        } else if change == "bindings-unavailable" {
            let moved = fixture.root.appendingPathComponent("temporarily-unavailable-bindings")
            try FileManager.default.moveItem(at: fixture.bindings, to: moved)
            let unavailable = try await reader.read(surfaceIDs: surfaces, tailWindowMiB: 1)
            #expect(unavailable.sessions.isEmpty && !unavailable.isComplete)
            try FileManager.default.moveItem(at: moved, to: fixture.bindings)
        } else {
            let marker = fixture.session.appendingPathComponent("inuse.\(fixture.process.pid).lock")
            try FileManager.default.removeItem(at: marker)
            let unavailable = try await reader.read(surfaceIDs: surfaces, tailWindowMiB: 1)
            #expect(unavailable.sessions.first?.liveness == .unknown)
            try Data().write(to: marker)
        }
        let recovered = try await reader.read(surfaceIDs: surfaces, tailWindowMiB: 1)
        #expect(recovered.sessions.first?.state == .idle)
        #expect(await reader.eventReadBytes == observedBytes)
        _ = try await reader.read(surfaceIDs: [fixture.surface], tailWindowMiB: 1)
        #expect(await reader.eventReadBytes == observedBytes)
        try fixture.append(start + Data([10]))
        let replayed = try await reader.read(surfaceIDs: [fixture.surface], tailWindowMiB: 1)
        #expect(replayed.sessions.first?.state == .idle)
    }

    @Test func boundedTailRequiresAnExactStartHeaderBeforeSkippedHistory() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([
            copilotTestEvent("session.resume"),
            copilotTestEvent("session.start", data: ["sessionId": UUID().uuidString, "version": 1]),
            copilotTestEvent("assistant.message", data: ["content": String(repeating: "x", count: 2 * 1_048_576)]),
            copilotTestEvent("assistant.turn_start", data: ["turnId": "untrusted"])
        ])
        let snapshot = try await fixture.reader().read(surfaceIDs: [fixture.surface], tailWindowMiB: 1)
        #expect(snapshot.sessions.first?.state == .unknown)
        #expect(snapshot.issues.contains(.unsupportedFormat))
    }

    @Test(arguments: [false, true])
    func unseenAppendGapReseatsBoundedTailWithoutForgettingObservedReplay(hasRecentStart: Bool) async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let oldStart = try copilotTestEvent("assistant.turn_start", data: ["turnId": "old"])
        try fixture.writeEvents([
            copilotTestEvent("session.start", data: ["sessionId": fixture.sessionID.uuidString, "version": 1]),
            oldStart, copilotTestEvent("assistant.turn_end", data: ["turnId": "old"]),
            copilotTestEvent("assistant.turn_start", data: ["turnId": "unfinished-before-gap"])
        ])
        let reader = fixture.reader()
        _ = try await reader.read(surfaceIDs: [fixture.surface], tailWindowMiB: 1)
        let initialBytes = await reader.eventReadBytes
        let gap = try copilotTestEvent("assistant.message", data: [
            "content": String(repeating: "x", count: 2 * 1_048_576)
        ]) + Data([10])
        do {
            let handle = try FileHandle(forWritingTo: fixture.session.appendingPathComponent("events.jsonl"))
            defer { try? handle.close() }
            try handle.seekToEnd()
            for _ in 0..<(hasRecentStart ? 160 : 1) { try handle.write(contentsOf: gap) }
        }
        if hasRecentStart {
            try fixture.append(copilotTestEvent("assistant.turn_start", data: ["turnId": "recent"]) + Data([10]))
        }
        let resumed = try await reader.read(surfaceIDs: [fixture.surface], tailWindowMiB: 1)
        #expect(await reader.eventReadBytes - initialBytes <= 1_048_576 + 512)
        #expect(resumed.sessions.first?.state == (hasRecentStart ? .working : .unknown))
        #expect(resumed.sessions.first?.sessionIssues == [.readLimitReached])
        #expect(await reader.hasPendingHistory() == false)
        try fixture.append(oldStart + Data([10]))
        if hasRecentStart {
            try fixture.append(copilotTestEvent("assistant.turn_end", data: ["turnId": "recent"]) + Data([10]))
        }
        let afterReplay = try await reader.read(surfaceIDs: [fixture.surface], tailWindowMiB: 1)
        #expect(afterReplay.sessions.first?.state == (hasRecentStart ? .idle : .unknown))
    }

    @Test func fullSelectedCohortNeverEvictsObservedReplayToAdmitAnotherSession() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let reader = fixture.reader(limits: .init(maximumSessions: 1))
        _ = try await reader.read(surfaceIDs: [fixture.surface])
        let otherSurface = UUID()
        let other = try fixture.addSession(surface: otherSurface)
        let otherID = try #require(UUID(uuidString: other.lastPathComponent))
        try Data().write(to: other.appendingPathComponent("inuse.\(fixture.process.pid).lock"))
        try (copilotTestEvent("session.idle") + Data([10])).write(to: other.appendingPathComponent("events.jsonl"))
        for _ in 0..<4 {
            let capped = try await reader.read(surfaceIDs: [fixture.surface, otherSurface])
            #expect(capped.sessions.map(\.sessionID) == [fixture.sessionID])
            #expect(!capped.isComplete && capped.issues.contains(.readLimitReached))
            #expect(await reader.hasPendingHistory() == false)
            #expect(await reader.retentionCounts().tails == 1)
        }
        let released = try await reader.read(surfaceIDs: [otherSurface])
        #expect(released.sessions.map(\.sessionID) == [otherID])
        #expect(released.sessions.first?.state == .idle)
    }

    @Test func skippedGapRetiresObservedInteractionAndRequestIdentities() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([
            copilotTestEvent("session.start", data: ["sessionId": fixture.sessionID.uuidString, "version": 1]),
            interactionEvent("assistant.turn_start", turn: "0", interaction: "root-A"),
            interactionEvent("assistant.turn_start", owner: "child", turn: "0", interaction: "child-A"),
            interactionEvent("permission.requested", data: ["requestId": "observed-request"])
        ])
        let reader = fixture.reader()
        let initial = try await reader.read(surfaceIDs: [fixture.surface], tailWindowMiB: 1)
        #expect(initial.sessions.first?.state == .blocked)
        for event in try [
            copilotTestEvent("assistant.message", data: ["content": String(repeating: "x", count: 2 * 1_048_576)]),
            interactionEvent("assistant.turn_start", turn: "0", interaction: "root-B"),
            interactionEvent("assistant.turn_start", owner: "child", turn: "0", interaction: "child-B")
        ] { try fixture.append(event + Data([10])) }
        let recent = try await reader.read(surfaceIDs: [fixture.surface], tailWindowMiB: 1)
        #expect(recent.sessions.first?.state == .working)
        for event in try [
            interactionEvent("assistant.turn_start", turn: "unseen", interaction: "root-A"),
            interactionEvent("assistant.turn_start", owner: "child", turn: "unseen", interaction: "child-A"),
            interactionEvent("permission.requested", data: ["requestId": "observed-request"]),
            interactionEvent("assistant.turn_end", turn: "0", interaction: "root-B"),
            interactionEvent("assistant.turn_end", owner: "child", turn: "0", interaction: "child-B")
        ] { try fixture.append(event + Data([10])) }
        let completed = try await reader.read(surfaceIDs: [fixture.surface], tailWindowMiB: 1)
        let session = try #require(completed.sessions.first)
        #expect(session.state == .idle)
        #expect(session.children.first?.state == .idle)
        #expect(session.attention?.contains { $0.kind.isBlocking } == false)
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

nonisolated final class CopilotReaderTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ instant: Date = Date(timeIntervalSince1970: 2_000)) {
        self.instant = instant
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        instant.addTimeInterval(seconds)
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
        lookup: (@Sendable (Int32) -> CopilotProcessLookup)? = nil,
        clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 2_000) }
    ) -> CopilotSessionReader {
        let owner = process
        return CopilotSessionReader(
            bindingDirectory: bindings, sessionStateRoot: sessions,
            clock: clock,
            processLookup: lookup ?? { $0 == owner.pid ? .found(owner) : .dead },
            limits: limits
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
