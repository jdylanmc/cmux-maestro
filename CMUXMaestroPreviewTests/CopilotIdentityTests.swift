import Darwin
import Foundation
import Testing
@testable import CMUXMaestroPreview

nonisolated struct CopilotIdentityTests {
    @Test(.enabled(if: getuid() != 0))
    func searchOnlyAncestorsDoNotRequireDirectoryReadAccess() throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let ancestor = fixture.root.appendingPathComponent("search-only", isDirectory: true)
        let leaf = ancestor.appendingPathComponent("leaf", isDirectory: true)
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        #expect(chmod(ancestor.path, 0o111) == 0)
        defer { _ = chmod(ancestor.path, 0o700) }

        let descriptor = try CopilotFileAccess.openDirectory(leaf, owner: getuid())
        #expect(try CopilotFileAccess.statFile(descriptor).isDirectory)
        close(descriptor)

        #expect(chmod(leaf.path, 0o111) == 0)
        defer { _ = chmod(leaf.path, 0o700) }
        #expect(throws: CopilotFileError.permissionDenied) {
            let denied = try CopilotFileAccess.openDirectory(leaf, owner: getuid())
            close(denied)
        }
    }

    @Test func recordRoundTripsMillisecondsAndFileContract() throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let descriptor = try CopilotFileAccess.openDirectory(fixture.bindings, owner: getuid())
        defer { close(descriptor) }
        let (record, stamp) = try CopilotFileAccess.readIdentity(
            at: descriptor, filename: fixture.sessionID.uuidString.lowercased() + ".json", owner: getuid()
        )
        #expect(record == fixture.record)
        #expect(stamp.permissions == 0o600)
        let json = try #require(JSONSerialization.jsonObject(with: CopilotIdentityJSON.encode(record)) as? [String: Any])
        #expect(json["recordedAt"] as? Double == 1_000_000)
    }

    @Test func wrongFilenamePermissionAndSymlinkAreRejected() throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let descriptor = try CopilotFileAccess.openDirectory(fixture.bindings, owner: getuid())
        defer { close(descriptor) }
        let name = UUID().uuidString.lowercased() + ".json"
        try fixture.writeRecord(fixture.record, filename: name)
        #expect(throws: CopilotFileError.unsafePath) {
            try CopilotFileAccess.readIdentity(at: descriptor, filename: name, owner: getuid())
        }
        let correct = fixture.sessionID.uuidString.lowercased() + ".json"
        #expect(chmod(fixture.bindings.appendingPathComponent(correct).path, 0o644) == 0)
        #expect(throws: CopilotFileError.unsafePath) {
            try CopilotFileAccess.readIdentity(at: descriptor, filename: correct, owner: getuid())
        }
        #expect(throws: CopilotFileError.unsafePath) {
            try CopilotFileAccess.openRegular(at: descriptor, name: "../sentinel", owner: getuid())
        }
        let link = fixture.bindings.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.bindings.appendingPathComponent(correct))
        #expect(throws: CopilotFileError.unsafePath) {
            try CopilotFileAccess.readIdentity(at: descriptor, filename: "link.json", owner: getuid())
        }
    }

    @Test func deadAndReusedPIDsNeverProveALiveSession() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let dead = try await fixture.reader(lookup: { _ in .dead }).read(surfaceIDs: [fixture.surface])
        let ended = try #require(dead.sessions.first)
        #expect(ended.liveness == .dead && ended.state == .unknown)
        let reused = CopilotProcessIdentity(
            pid: fixture.process.pid, parentPID: 1, uid: getuid(), startSeconds: 2, startMicroseconds: 0
        )
        let changed = try await fixture.reader(lookup: { _ in .found(reused) }).read(surfaceIDs: [fixture.surface])
        #expect(changed.sessions[0].sessionIssues?.contains(.identityChanged) == true)
        #expect(changed.sessions[0].liveness == .ambiguous)
        #expect(changed.sessions[0].state == .unknown)
    }

    @Test func multipleLiveOrUnverifiableOwnerMarkersAreAmbiguous() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        try Data().write(to: fixture.session.appendingPathComponent("inuse.4343.lock"))
        let owner = fixture.process
        let other = CopilotProcessIdentity(pid: 4343, parentPID: 1, uid: getuid(), startSeconds: 1, startMicroseconds: 0)
        let live = try await fixture.reader(lookup: { pid in
            .found(pid == owner.pid ? owner : other)
        }).read(surfaceIDs: [fixture.surface])
        #expect(live.sessions[0].sessionIssues?.contains(.ambiguousIdentity) == true)
        #expect(live.sessions[0].state == .unknown)
        let unknown = try await fixture.reader(lookup: { pid in
            pid == owner.pid ? .found(owner) : .unavailable
        }).read(surfaceIDs: [fixture.surface])
        #expect(unknown.sessions[0].sessionIssues?.contains(.ambiguousIdentity) == true)
        let stale = try await fixture.reader(lookup: { pid in
            pid == owner.pid ? .dead : .found(other)
        }).read(surfaceIDs: [fixture.surface])
        let ambiguous = try #require(stale.sessions.first)
        #expect(ambiguous.sessionIssues?.contains(.ambiguousIdentity) == true)
        #expect(ambiguous.liveness == .ambiguous && ambiguous.state == .unknown)
    }

    /// `/restart` or `/update` before the next hook: the binding still names the live parent
    /// (4242) and its direct child (5000) holds the session's only live lock.
    private func restartLookup(
        _ fixture: CopilotReaderFixture, extra: [Int32: CopilotProcessIdentity] = [:]
    ) -> @Sendable (Int32) -> CopilotProcessLookup {
        let table = [
            fixture.process.pid: fixture.process,
            5000: CopilotProcessIdentity(pid: 5000, parentPID: fixture.process.pid, uid: getuid(),
                                         startSeconds: 2, startMicroseconds: 0),
        ].merging(extra) { _, new in new }
        return { pid in table[pid].map { .found($0) } ?? .dead }
    }

    private func moveLock(_ fixture: CopilotReaderFixture, to pids: [Int32]) throws {
        try FileManager.default.removeItem(at: fixture.session.appendingPathComponent("inuse.\(fixture.process.pid).lock"))
        for pid in pids { try Data().write(to: fixture.session.appendingPathComponent("inuse.\(pid).lock")) }
    }

    @Test func inPlaceRestartChildHoldingTheOnlyLockKeepsTheSessionAlive() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        try moveLock(fixture, to: [5000])

        let snapshot = try await fixture.reader(lookup: restartLookup(fixture)).read(surfaceIDs: [fixture.surface])

        let session = try #require(snapshot.sessions.first)
        #expect(session.liveness == .alive)
        #expect(session.state == .idle)
        #expect(session.sessionIssues?.isEmpty ?? true)
        let descriptor = try CopilotFileAccess.openDirectory(fixture.session, owner: getuid())
        defer { close(descriptor) }
        let evidence = try CopilotIdentityVerifier(lookup: restartLookup(fixture))
            .inspect(record: fixture.record, sessionDirectory: descriptor)
        #expect(evidence.status == .alive && evidence.process?.pid == 5000)
        // A different process later holding that lock is a changed identity, not the same session.
        let replaced = restartLookup(fixture, extra: [5000: CopilotProcessIdentity(
            pid: 5000, parentPID: fixture.process.pid, uid: getuid(), startSeconds: 3, startMicroseconds: 0)])
        #expect(try CopilotIdentityVerifier(lookup: replaced)
            .verifyStable(evidence, record: fixture.record, sessionDirectory: descriptor).status == .changed)
    }

    @Test(arguments: ["no-lock", "parent-and-child", "two-children", "grandchild", "unrelated", "older-child", "other-session"])
    func boundOwnerAliveWithoutExactRestartEvidenceIsNotAlive(_ variant: String) throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let owner = fixture.process
        var extra: [Int32: CopilotProcessIdentity] = [:]
        var expected = CopilotIdentityStatus.ambiguous
        switch variant {
        case "no-lock":
            try moveLock(fixture, to: [])
            expected = .unknown
        case "parent-and-child":
            try Data().write(to: fixture.session.appendingPathComponent("inuse.5000.lock"))
        case "two-children":
            try moveLock(fixture, to: [5000, 5001])
            extra[5001] = .init(pid: 5001, parentPID: owner.pid, uid: getuid(), startSeconds: 2, startMicroseconds: 0)
        case "grandchild":
            try moveLock(fixture, to: [6000])
            extra[6000] = .init(pid: 6000, parentPID: 5000, uid: getuid(), startSeconds: 3, startMicroseconds: 0)
        case "unrelated":
            try moveLock(fixture, to: [5000])
            extra[5000] = .init(pid: 5000, parentPID: 1, uid: getuid(), startSeconds: 2, startMicroseconds: 0)
        case "older-child":
            try moveLock(fixture, to: [5000])
            extra[5000] = .init(pid: 5000, parentPID: owner.pid, uid: getuid(), startSeconds: 1, startMicroseconds: 0)
        default:
            let other = try fixture.addSession(surface: fixture.surface)
            try moveLock(fixture, to: [])
            try Data().write(to: other.appendingPathComponent("inuse.5000.lock"))
            expected = .unknown
        }
        let descriptor = try CopilotFileAccess.openDirectory(fixture.session, owner: getuid())
        defer { close(descriptor) }

        let evidence = try CopilotIdentityVerifier(lookup: restartLookup(fixture, extra: extra))
            .inspect(record: fixture.record, sessionDirectory: descriptor)

        #expect(evidence.status == expected)
    }

    @Test func liveParentHoldingItsOwnLockStaysTheVerifiedProcess() throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let descriptor = try CopilotFileAccess.openDirectory(fixture.session, owner: getuid())
        defer { close(descriptor) }

        let evidence = try CopilotIdentityVerifier(lookup: restartLookup(fixture))
            .inspect(record: fixture.record, sessionDirectory: descriptor)

        #expect(evidence.status == .alive && evidence.process == fixture.process)
    }

    @Test func processGenerationChangesDuringReadDiscardTheCandidate() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let probe = CopilotChangingProbe(owner: fixture.process)
        let snapshot = try await fixture.reader(lookup: { probe.read($0) }).read(surfaceIDs: [fixture.surface])
        #expect(snapshot.sessions[0].sessionIssues?.contains(.identityChanged) == true)
        #expect(snapshot.sessions[0].state == .unknown)
    }

    @Test func markerBirthMustNotPrecedeOwnerAndMarkerIdentityMustStayStable() throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let descriptor = try CopilotFileAccess.openDirectory(fixture.session, owner: getuid())
        defer { close(descriptor) }
        let owner = fixture.process
        let verifier = CopilotIdentityVerifier(lookup: { _ in .found(owner) })
        let before = try verifier.inspect(record: fixture.record, sessionDirectory: descriptor)
        #expect(before.status == .alive)
        let marker = fixture.session.appendingPathComponent("inuse.\(owner.pid).lock")
        try Data("replacement".utf8).write(to: marker, options: [.atomic])
        let after = try verifier.verifyStable(before, record: fixture.record, sessionDirectory: descriptor)
        #expect(after.status == .changed)
        let future = CopilotProcessIdentity(
            pid: owner.pid, parentPID: 1, uid: getuid(), startSeconds: UInt64(Date().timeIntervalSince1970) + 500,
            startMicroseconds: 0
        )
        let futureRecord = CopilotIdentityRecord(
            sessionID: fixture.sessionID, surfaceID: fixture.surface, launchWorkspaceID: fixture.workspace,
            ownerPID: future.pid, ownerStartSeconds: future.startSeconds, ownerStartMicroseconds: 0,
            recordedAt: fixture.record.recordedAt
        )
        #expect(try CopilotIdentityVerifier(lookup: { _ in .found(future) })
            .inspect(record: futureRecord, sessionDirectory: descriptor).status == .ambiguous)
    }

    @Test func nativeProbeOnlyReturnsSameUserGeneration() throws {
        guard case .found(let process) = CopilotProcessProbe.read(getpid()) else {
            Issue.record("Current process BSD metadata unavailable")
            return
        }
        #expect(process.pid == getpid())
        #expect(process.uid == getuid())
        #expect(process.startSeconds > 0)
        #expect(process.startMicroseconds < 1_000_000)
    }

    @Test func missingAndSymlinkedMarkersNeverImplyWorking() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("assistant.turn_start", data: ["turnId": "1"])])
        let marker = fixture.session.appendingPathComponent("inuse.\(fixture.process.pid).lock")
        try FileManager.default.removeItem(at: marker)
        let missing = try await fixture.reader().read(surfaceIDs: [fixture.surface])
        #expect(missing.sessions[0].liveness == .unknown)
        #expect(missing.sessions[0].state == .unknown)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: fixture.events)
        let link = try await fixture.reader().read(surfaceIDs: [fixture.surface])
        #expect(link.sessions[0].sessionIssues?.contains(.ambiguousIdentity) == true)
        #expect(link.sessions[0].state == .unknown)
    }

    @Test func oversizedRegistrationAndDirectorySymlinkAreRejected() throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let filename = fixture.sessionID.uuidString.lowercased() + ".json"
        let recordURL = fixture.bindings.appendingPathComponent(filename)
        try Data(repeating: 32, count: 16_385).write(to: recordURL)
        let descriptor = try CopilotFileAccess.openDirectory(fixture.bindings, owner: getuid())
        defer { close(descriptor) }
        #expect(throws: CopilotFileError.tooLarge) {
            try CopilotFileAccess.readIdentity(at: descriptor, filename: filename, owner: getuid())
        }
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.bindings)
        #expect(throws: CopilotFileError.unsafePath) {
            try CopilotFileAccess.openDirectory(alias, owner: getuid())
        }
    }
}

nonisolated final class CopilotChangingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let owner: CopilotProcessIdentity

    init(owner: CopilotProcessIdentity) { self.owner = owner }

    func read(_ pid: Int32) -> CopilotProcessLookup {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return .found(.init(
            pid: pid, parentPID: owner.parentPID, uid: owner.uid,
            startSeconds: count > 2 ? owner.startSeconds + 1 : owner.startSeconds,
            startMicroseconds: owner.startMicroseconds
        ))
    }
}
