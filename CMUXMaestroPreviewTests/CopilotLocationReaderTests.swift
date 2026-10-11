import Foundation
import Testing
@testable import CMUXMaestroPreview

struct CopilotLocationReaderTests: Sendable {
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
        #expect(try await read(fixture)?.branch == nil)
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
            #expect(try await read(fixture)?.branch == nil)
        }
        _ = try publish(fixture, data: valid(fixture), mode: 0o644)
        #expect(try await read(fixture)?.branch == nil)
    }

    @Test func symlinkedRecordAndNonLiveSessionsAreIgnored() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let target = try publish(fixture, name: "target.json", data: valid(fixture))
        let link = target.deletingLastPathComponent().appendingPathComponent(fixture.sessionID.uuidString.lowercased() + ".json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(try await read(fixture)?.branch == nil)
        try FileManager.default.removeItem(at: link)
        let stranger = UUID()
        let data = try CopilotSessionLocation.encode(sessionID: stranger, location: .init(branch: "stale", worktree: false), recordedAt: Date())
        _ = try publish(fixture, name: stranger.uuidString.lowercased() + ".json", data: data)
        let snapshot = try await fixture.reader().read(surfaceIDs: [fixture.surface])
        #expect(snapshot.sessions.map(\.sessionID) == [fixture.sessionID])
        #expect(snapshot.sessions.first?.branch == nil)
    }
}
