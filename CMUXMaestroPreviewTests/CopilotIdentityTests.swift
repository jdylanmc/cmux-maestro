import Darwin
import Foundation
import Testing
@testable import CMUXMaestroPreview

nonisolated struct CopilotIdentityTests {
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
        #expect(dead.sessions[0].liveness == .dead)
        #expect(dead.sessions[0].state == .unknown)
        let reused = CopilotProcessIdentity(
            pid: fixture.process.pid, parentPID: 1, uid: getuid(), startSeconds: 2, startMicroseconds: 0
        )
        let changed = try await fixture.reader(lookup: { _ in .found(reused) }).read(surfaceIDs: [fixture.surface])
        #expect(changed.issues.contains(.identityChanged))
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
        #expect(live.issues.contains(.ambiguousIdentity))
        #expect(live.sessions[0].state == .unknown)
        let unknown = try await fixture.reader(lookup: { pid in
            pid == owner.pid ? .found(owner) : .unavailable
        }).read(surfaceIDs: [fixture.surface])
        #expect(unknown.issues.contains(.ambiguousIdentity))
        let stale = try await fixture.reader(lookup: { pid in
            pid == owner.pid ? .dead : .found(other)
        }).read(surfaceIDs: [fixture.surface])
        #expect(stale.issues.contains(.ambiguousIdentity))
        #expect(stale.sessions[0].liveness == .ambiguous)
    }

    @Test func processGenerationChangesDuringReadDiscardTheCandidate() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let probe = CopilotChangingProbe(owner: fixture.process)
        let snapshot = try await fixture.reader(lookup: { probe.read($0) }).read(surfaceIDs: [fixture.surface])
        #expect(snapshot.issues.contains(.identityChanged))
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
        #expect(link.issues.contains(.ambiguousIdentity))
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
