import Foundation
import Testing

@MainActor
struct AgentSnapshotCompatibilityTests {
    @Test(arguments: ["hierarchy", "taskboard", "degraded-unbound"])
    func originalV1FixturesDecodeInBothContractsWithoutInventingLiveEvidence(_ name: String) throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        let data = try Data(contentsOf: url)
        let current = try AgentSessionSnapshotJSONCodec.decode(data)
        let legacy = try LegacyV1Snapshot.decode(data)
        try current.validate()
        #expect(legacy.schemaVersion == 1)
        #expect(legacy.sessions.count == current.sessions.count)
        #expect(legacy.sessions.map(\.state.value?.rawValue) == current.sessions.map(\.state.value?.rawValue))
        #expect(current.completeness == nil && !current.isComplete)
        #expect(current.issues == nil)
        #expect(current.sessions.allSatisfy {
            $0.stateDetail == nil && $0.liveness == nil && $0.observedAt == nil
                && $0.launchBinding == nil && $0.childWorkLayout == nil && $0.appearance == nil && $0.attention == nil
        })
        if name == "taskboard" {
            #expect(current.sessions.last?.state == .known(.done))
            #expect(current.sessions.last?.workState == .completed)
            #expect(legacy.sessions.last?.state.value == .done)
        }
    }

    @Test func frozenV1ClientDecodesAdditiveLiveFieldsAndDoesNotMistakeNovelStatesForDone() throws {
        let fixtures = SidebarTreeFixtures()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let states: [CopilotWorkState] = [.working, .idle, .blocked, .completed, .failed, .cancelled, .unknown]
        let observations = states.enumerated().map { index, state in
            fixtures.session(id: UUID(), state: state, children: [
                .init(id: "child-\(index)", parentID: "not-yet-observed", kind: .subagent, name: "Synthetic",
                      state: state, model: "child-model", terminalEvent: .init(id: UUID(), timestamp: now))
            ], now: now)
        }
        let current = CopilotSnapshotAdapter.snapshot(
            fixtures.snapshot(sessions: observations, issues: [.loadingHistory], complete: false, now: now),
            workspaceBySurface: fixtures.topology().workspaceBySurface
        )
        try current.validate()
        let encoded = try AgentSessionSnapshotJSONCodec.encode(current)
        let legacy = try LegacyV1Snapshot.decode(encoded)
        #expect(legacy.sessions.count == 7)
        #expect(legacy.sessions.map(\.state.value?.rawValue) == ["working", nil, "blocked", "done", nil, nil, nil])
        #expect(legacy.sessions.map(\.childWork.first?.state.value?.rawValue) == ["working", nil, "blocked", "done", nil, nil, nil])
        #expect(legacy.sessions[1].state.availability == .unknown)
        #expect(legacy.sessions[4].state.availability == .unknown)
        #expect(legacy.sessions[5].state.availability == .unknown)
        #expect(legacy.sessions.map(\.identity.sessionID) == observations.map(\.sessionID.uuidString))
        #expect(legacy.sessions.allSatisfy { $0.childWork.count == 1 })
        #expect(legacy.sessions[0].childWork[0].title.value == "Synthetic")
        #expect(legacy.generatedAt == now)
        #expect(legacy.workspaces.count == 2)

        // A permissive/string-only "legacy" decoder would fail to catch this
        // incompatible wire change. Keep the old enum as a real negative oracle.
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var sessions = try #require(object["sessions"] as? [[String: Any]])
        sessions[1]["state"] = ["availability": "known", "value": "idle"]
        object["sessions"] = sessions
        #expect(throws: DecodingError.self) {
            try LegacyV1Snapshot.decode(JSONSerialization.data(withJSONObject: object))
        }
    }
}

// Frozen decoding shape from schema v1 at faa38c6. No production domain types:
// compiling the new structs alone is not proof that an old client can decode.
private struct LegacyV1Snapshot: Decodable {
    let schemaVersion: Int
    let generatedAt: Date
    let workspaces: [Workspace]
    let sessions: [Session]

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom {
            let container = try $0.singleValueContainer()
            let value = try container.decode(String.self)
            return try Date.ISO8601FormatStyle(includingFractionalSeconds: value.contains("."),
                                              timeZone: TimeZone(secondsFromGMT: 0)!).parse(value)
        }
        return try decoder.decode(Self.self, from: data)
    }

    enum Availability: String, Decodable { case known, unknown, degraded }
    enum State: String, Decodable { case unknown, queued, working, blocked, done }
    enum ActivityKind: String, Decodable { case unknown, planning, executing, waiting, reviewing, idle }
    enum SurfaceKind: String, Decodable { case unknown, terminal, editor, browser, other }
    struct Value<T: Decodable>: Decodable {
        let availability: Availability
        let value: T?
        let detail: String?
    }
    struct Identity: Decodable {
        let providerID: String
        let sessionID: String
    }
    struct Binding: Decodable {
        let workspaceID: String
        let surfaceID: String
    }
    enum BindingObservation: Decodable {
        case bound(Binding), unbound, unknown(Binding?, String?), degraded(Binding?, String)
        enum Keys: String, CodingKey { case kind, binding, lastKnownBinding, detail }
        enum Kind: String, Decodable { case bound, unbound, unknown, degraded }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .bound: self = .bound(try container.decode(Binding.self, forKey: .binding))
            case .unbound: self = .unbound
            case .unknown:
                self = .unknown(try container.decodeIfPresent(Binding.self, forKey: .lastKnownBinding),
                                try container.decodeIfPresent(String.self, forKey: .detail))
            case .degraded:
                self = .degraded(try container.decodeIfPresent(Binding.self, forKey: .lastKnownBinding),
                                 try container.decode(String.self, forKey: .detail))
            }
        }
    }
    enum Parent: Decodable {
        case session(Identity), child(String)
        enum Keys: String, CodingKey { case kind, providerSession, childWorkID }
        enum Kind: String, Decodable { case session, child }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .session: self = .session(try container.decode(Identity.self, forKey: .providerSession))
            case .child: self = .child(try container.decode(String.self, forKey: .childWorkID))
            }
        }
    }
    struct Activity: Decodable {
        let kind: ActivityKind
        let summary: String?
        let lastEventAt: Date?
    }
    struct Model: Decodable {
        let identifier: String
        let displayName: String?
    }
    struct Path: Decodable { let value: String }
    struct Worktree: Decodable {
        let path: Path
        let branch: Value<String>
    }
    struct Paths: Decodable {
        let currentDirectory: Value<Path>
        let worktree: Value<Worktree>
    }
    struct Timing: Decodable {
        let startedAt: Date
        let updatedAt: Date
        let completedAt: Date?
    }
    struct Surface: Decodable {
        let id: String
        let workspaceID: String
        let title: Value<String>
        let kind: SurfaceKind
    }
    struct Workspace: Decodable {
        let id: String
        let title: Value<String>
        let surfaces: [Surface]
    }
    struct Child: Decodable {
        let id: String
        let parent: Parent
        let title: Value<String>
        let state: Value<State>
        let activity: Value<Activity>
        let children: [Child]
    }
    struct Session: Decodable {
        let identity: Identity
        let binding: BindingObservation
        let title: Value<String>
        let state: Value<State>
        let activity: Value<Activity>
        let model: Value<Model>
        let paths: Value<Paths>
        let timing: Value<Timing>
        let childWork: [Child]
    }
}
