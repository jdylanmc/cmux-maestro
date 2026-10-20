import Foundation
import Testing
@testable import CMUXMaestroPreview

struct CopilotLocationReaderTests: Sendable {
    @Test(arguments: [true, false], [true, false])
    func activeTouchPrecedesSessionDirectoryAndPreservesStaleLabel(current: Bool, bindingMatches: Bool) async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let identity = CopilotWorktreeIdentity(
            key: "0123456789abcdef", repository: "touched", head: .branch("topic"), linked: false
        )
        _ = try publish(fixture, data: CopilotSessionLocation.encode(
            sessionID: fixture.sessionID, location: nil,
            current: .init(evidence: .nonRepository, source: nil), recordedAt: Date(),
            active: .init(identity: identity, touchedAt: 1_800_000_000_000, isCurrent: current,
                          bindingKey: bindingMatches ? CopilotActiveWorktree.bindingKey(fixture.record)
                              : String(repeating: "0", count: 64))
        ))
        #expect(try await read(fixture)?.currentWorktree
            == .init(evidence: .verified(identity), isCurrent: current && bindingMatches))
    }

    private func publish(_ fixture: CopilotReaderFixture, name: String? = nil, data: Data, mode: mode_t = 0o600) throws -> URL {
        let directory = fixture.root.appendingPathComponent("locations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name ?? fixture.sessionID.uuidString.lowercased() + ".json")
        try data.write(to: file)
        chmod(file.path, mode)
        return file
    }

    private func valid(_ fixture: CopilotReaderFixture, branch: String = "feat/x", worktree: Bool = false) throws -> Data {
        try CopilotSessionLocation.encode(sessionID: fixture.sessionID, location: .init(branch: branch, worktree: worktree),
                                          recordedAt: Date())
    }

    private func read(_ fixture: CopilotReaderFixture) async throws -> CopilotSessionObservation? {
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        return try await fixture.reader().read(surfaceIDs: [fixture.surface]).sessions.first
    }

    /// A rejected location must leave the same live session, with no location fields.
    private func expectSurvivesWithoutLocation(
        _ fixture: CopilotReaderFixture, baseline: CopilotSessionObservation,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let session = try #require(try await read(fixture), sourceLocation: sourceLocation)
        #expect(session.sessionID == fixture.sessionID, sourceLocation: sourceLocation)
        #expect(session.surfaceID == fixture.surface, sourceLocation: sourceLocation)
        #expect(session.liveness == .alive, sourceLocation: sourceLocation)
        #expect(session.state == baseline.state, sourceLocation: sourceLocation)
        #expect(session.branch == nil && session.worktree == nil, sourceLocation: sourceLocation)
    }

    @Test func validLocationIsPublishedOnTheLiveSession() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        _ = try publish(fixture, data: valid(fixture, branch: "topic", worktree: true))
        let session = try await read(fixture)
        #expect(session?.branch == "topic")
        #expect(session?.worktree == true)
    }

    @Test func missingWrongKeysWrongSessionOversizeAndLooseModeAreIgnored() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let baseline = try #require(try await read(fixture))
        #expect(baseline.liveness == .alive)
        #expect(baseline.branch == nil && baseline.worktree == nil)
        let text = String(decoding: try valid(fixture), as: UTF8.self)
        let other = try CopilotSessionLocation.encode(sessionID: UUID(), location: .init(branch: "b", worktree: false), recordedAt: Date())
        let variants: [Data] = [
            Data(text.dropLast().appending(",\"path\":\"/x\"}").utf8),
            Data(text.replacingOccurrences(of: "\"branch\"", with: "\"branches\"").utf8),
            other,
            Data(text.utf8) + Data(repeating: 32, count: 2_000),
        ]
        for variant in variants {
            _ = try publish(fixture, data: variant)
            try await expectSurvivesWithoutLocation(fixture, baseline: baseline)
        }
        _ = try publish(fixture, data: valid(fixture), mode: 0o644)
        try await expectSurvivesWithoutLocation(fixture, baseline: baseline)
        // Control: the same record with a private mode is accepted.
        _ = try publish(fixture, data: valid(fixture))
        #expect(try await read(fixture)?.branch == "feat/x")
    }

    @Test func symlinkedRecordAndNonLiveSessionsAreIgnored() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let baseline = try #require(try await read(fixture))
        let target = try publish(fixture, name: "target.json", data: valid(fixture))
        let link = target.deletingLastPathComponent().appendingPathComponent(fixture.sessionID.uuidString.lowercased() + ".json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try await expectSurvivesWithoutLocation(fixture, baseline: baseline)
        try FileManager.default.removeItem(at: link)
        let stranger = UUID()
        let data = try CopilotSessionLocation.encode(sessionID: stranger, location: .init(branch: "stale", worktree: false), recordedAt: Date())
        _ = try publish(fixture, name: stranger.uuidString.lowercased() + ".json", data: data)
        let snapshot = try await fixture.reader().read(surfaceIDs: [fixture.surface])
        #expect(snapshot.sessions.map(\.sessionID) == [fixture.sessionID])
        #expect(snapshot.sessions.first?.liveness == .alive)
        #expect(snapshot.sessions.first?.branch == nil)
    }

    /// Current only while the session's `workspace.yaml` is the exact version the hook observed.
    @Test func currentWorktreeIsCurrentUntilTheSessionDirectoryRecordChanges() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let yaml = fixture.session.appendingPathComponent("workspace.yaml")
        try Data("id: x\ncwd: /synthetic/a\n".utf8).write(to: yaml)
        let directory = try CopilotFileAccess.openDirectory(fixture.session, owner: getuid())
        defer { close(directory) }
        let stamp = try CopilotFileAccess.statEntry(at: directory, name: "workspace.yaml")
        let identity = CopilotWorktreeIdentity(key: "0123456789abcdef", repository: "repo", head: .branch("topic"), linked: true)
        let current = CopilotSessionWorktree(evidence: .verified(identity), source: CopilotWorktreeSource(stamp))
        _ = try publish(fixture, data: try CopilotSessionLocation.encode(
            sessionID: fixture.sessionID, location: nil, current: current, recordedAt: Date()))
        let fresh = try #require(try await read(fixture))
        #expect(fresh.currentWorktree == .init(evidence: .verified(identity), isCurrent: true))
        #expect(fresh.branch == nil)
        try Data("id: x\ncwd: /synthetic/elsewhere\n".utf8).write(to: yaml)
        #expect(try await read(fixture)?.currentWorktree == .init(evidence: .verified(identity), isCurrent: false))
    }
}
