import Foundation
import Testing
@testable import CMUXMaestroPreview

struct SidebarMoodObservationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func node() -> SidebarOrchestrationNode {
        .init(id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: "Synthetic",
              workspaceId: UUID(), surfaceId: UUID(), generation: 1, phase: "turn-running",
              availability: "busy", copilotSessionId: UUID(), executionMode: .interactive,
              createdAt: now, updatedAt: now)
    }

    private func record(_ node: SidebarOrchestrationNode, sequence: Int = 1, mood: String = "happy") -> [String: Any] {
        ["nodeId": node.id.uuidString.lowercased(), "runId": node.runId.uuidString.lowercased(),
         "sessionId": node.copilotSessionId!.uuidString.lowercased(), "workspaceId": node.workspaceId.uuidString.lowercased(),
         "surfaceId": node.surfaceId.uuidString.lowercased(), "generation": node.generation,
         "sequence": sequence, "source": "self-report", "mood": mood, "lastChangedAt": 1_800_000_000_000]
    }

    private func data(_ records: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "moods": records], options: [.sortedKeys])
    }

    private func snapshot(_ node: SidebarOrchestrationNode) -> SidebarOrchestrationSnapshot {
        .init(version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: [node])
    }

    @Test func coldStartNoopClearAndStaleSequences() throws {
        let node = node()
        let base = snapshot(node)
        var cache = SidebarMoodObservation.Cache()
        let old = try data([record(node)])
        let initial = cache.applying(old, to: base)
        #expect(initial.nodes[0].selfReportedMood == nil)
        #expect(initial.nodes[0].selfReportedMoodSequence == 1)
        #expect(cache.applying(old, to: base).nodes[0].selfReportedMood == nil)
        let fresh = try data([record(node, sequence: 2)])
        let shown = cache.applying(fresh, to: base)
        #expect(shown.nodes[0].selfReportedMood == .happy)
        #expect(shown.nodes[0].selfReportedMood?.selfReportLabel != nil)
        #expect(shown.nodes[0].phase == node.phase && shown.nodes[0].availability == node.availability)
        #expect(cache.applying(fresh, to: base) == shown)
        let clear = try data([record(node, sequence: 3, mood: "clear")])
        #expect(cache.applying(clear, to: base).nodes[0].selfReportedMood == nil)
        #expect(cache.applying(fresh, to: base).nodes[0].selfReportedMood == nil)
        #expect(cache.applying(try data([record(node, sequence: 3)]), to: base).nodes[0].selfReportedMood == nil)
        let afterClear = cache.applying(try data([record(node, sequence: 4, mood: "confused")]), to: base)
        #expect(afterClear.nodes[0].selfReportedMood == .confused)
        #expect(afterClear.nodes[0].selfReportedMoodSequence == 4)
        var restart = SidebarMoodObservation.Cache()
        #expect(restart.applying(try data([record(node, sequence: 4)]), to: base).nodes[0].selfReportedMood == nil)
        var unavailableAtStart = SidebarMoodObservation.Cache()
        #expect(unavailableAtStart.applying(Data("invalid".utf8), to: base).moodsUnavailable)
        #expect(unavailableAtStart.applying(old, to: base).nodes[0].selfReportedMood == nil)
    }

    @Test func everyIdentityFieldMustMatchAndUnmatchedClaimsCannotReplay() throws {
        let node = node()
        let base = snapshot(node)
        for field in ["nodeId", "runId", "sessionId", "workspaceId", "surfaceId", "generation"] {
            var cache = SidebarMoodObservation.Cache()
            _ = cache.applying(nil, to: base)
            var foreign = record(node)
            foreign[field] = field == "generation" ? 2 : UUID().uuidString.lowercased() as Any
            let result = cache.applying(try data([foreign]), to: base)
            #expect(result.nodes[0].selfReportedMood == nil)
            #expect(!result.moodsUnavailable && result.complete)
        }
        var cache = SidebarMoodObservation.Cache()
        _ = cache.applying(nil, to: base)
        let claim = try data([record(node)])
        #expect(cache.applying(claim, to: base).nodes[0].selfReportedMood == .happy)
        let empty = SidebarOrchestrationSnapshot(version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: [])
        _ = cache.applying(claim, to: empty)
        #expect(cache.applying(claim, to: base).nodes[0].selfReportedMood == nil)
        _ = cache.applying(nil, to: empty)
        #expect(cache.applying(claim, to: base).nodes[0].selfReportedMood == nil)
        var nextGeneration = record(node, sequence: 2)
        nextGeneration["generation"] = 2
        #expect(cache.applying(try data([nextGeneration]), to: base).nodes[0].selfReportedMood == nil)
        #expect(cache.applying(claim, to: base).nodes[0].selfReportedMood == nil)
    }

    @Test func malformedDataIsCosmeticAndCannotRestoreAnOldClaim() throws {
        let node = node()
        let base = snapshot(node)
        var cache = SidebarMoodObservation.Cache()
        _ = cache.applying(nil, to: base)
        let claim = try data([record(node)])
        #expect(cache.applying(claim, to: base).nodes[0].selfReportedMood == .happy)
        var invalid = [
            Data("{}".utf8), Data("{\"version\":1,\"version\":1,\"moods\":[]}".utf8),
            try data([record(node), record(node)]),
            Data(repeating: 32, count: SidebarMoodObservation.maximumBytes + 1)
        ]
        let mutations: [(String, Any)] = [
            ("mood", "thinking"), ("mood", NSNull()), ("source", "inferred"), ("reason", "private"),
            ("sequence", true), ("generation", 0), ("sequence", 9_007_199_254_740_992),
            ("sessionId", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"), ("lastChangedAt", -1)
        ]
        for (field, value) in mutations {
            var bad = record(node)
            bad[field] = value
            invalid.append(try data([bad]))
        }
        invalid.append(Data(String(decoding: claim, as: UTF8.self)
            .replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":1.0").utf8))
        for bytes in invalid {
            #expect(throws: (any Error).self) { try SidebarMoodObservation.decode(bytes) }
            let rejected = cache.applying(bytes, to: base)
            #expect(rejected.moodsUnavailable && rejected.complete)
            #expect(rejected.nodes[0].phase == node.phase && rejected.nodes[0].selfReportedMood == nil)
        }
        #expect(cache.applying(claim, to: base).nodes[0].selfReportedMood == nil)
        #expect(cache.applying(try data([record(node, sequence: 2)]), to: base).nodes[0].selfReportedMood == .happy)
        _ = cache.applying(nil, to: base)
        #expect(cache.applying(try data([record(node, sequence: 2)]), to: base).nodes[0].selfReportedMood == nil)
    }

    @Test func parserAndReplayCapacityRefuseWithoutEviction() throws {
        let node = node()
        let base = snapshot(node)
        let records = (0..<1024).map { _ in record(self.node()) }
        #expect(try SidebarMoodObservation.decode(data(records)).moods.count == 1024)
        #expect(throws: (any Error).self) { try SidebarMoodObservation.decode(data(records + [record(node)])) }
        let workspaceFull = (0..<129).map { _ -> [String: Any] in
            var value = record(self.node())
            value["workspaceId"] = node.workspaceId.uuidString.lowercased()
            return value
        }
        #expect(throws: (any Error).self) { try SidebarMoodObservation.decode(data(workspaceFull)) }
        var cache = SidebarMoodObservation.Cache()
        _ = cache.applying(try data(records), to: base)
        let refused = cache.applying(try data([record(node)]), to: base)
        #expect(refused.moodsUnavailable && refused.nodes[0].selfReportedMood == nil)
        _ = cache.applying(nil, to: base)
        #expect(cache.applying(try data([record(node)]), to: base).moodsUnavailable)
        #expect(cache.applying(try data([record(node)]), to: base).nodes[0].selfReportedMood == nil)
    }

    @Test func orchestrationCacheResolvesChangedMoodsWithoutChangingLifecycleBytes() throws {
        let node = node()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let current = try encoder.encode(snapshot(node))
        var cache = SidebarOrchestrationReader.Cache()
        _ = try SidebarOrchestrationReader.resolve(current: current, icons: nil, processes: nil,
                                                    cache: &cache, now: now)
        let shown = try SidebarOrchestrationReader.resolve(
            current: current, icons: nil, processes: nil, moods: data([record(node)]), cache: &cache, now: now
        )
        #expect(shown.nodes[0].selfReportedMood == .happy)
        #expect(cache.validationCount == 1)
        #expect(try encoder.encode(shown) == current, "Authored mood metadata is not lifecycle wire evidence")
        let malformed = try SidebarOrchestrationReader.resolve(
            current: current, icons: nil, processes: nil, moods: Data("invalid".utf8), cache: &cache, now: now
        )
        #expect(malformed.complete && malformed.moodsUnavailable)
        #expect(malformed.nodes[0].selfReportedMood == nil)
    }

    @Test func freshExactObservationKeepsReportsEligibleWithoutLifecycleHeartbeat() throws {
        let owner = node()
        let base = snapshot(owner)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lifecycle = try encoder.encode(base)
        var cache = SidebarOrchestrationReader.Cache()
        func read(_ sequence: Int, mood: String = "happy", at date: Date) throws -> SidebarOrchestrationSnapshot {
            try SidebarOrchestrationReader.resolve(
                current: lifecycle, icons: nil, processes: nil,
                moods: data([record(owner, sequence: sequence, mood: mood)]), cache: &cache, now: date)
        }
        func observed(at date: Date, liveness: AgentProcessLiveness = .alive) -> SidebarCopilotSession {
            var session = SidebarCopilotSession(
                id: owner.copilotSessionId!, workspaceID: owner.workspaceId, surfaceID: owner.surfaceId,
                liveness: liveness, state: .idle, model: nil, observedAt: date, nodes: [],
                childrenComplete: true, treeDegraded: false, omittedChildrenCount: 0, omittedActiveChildrenCount: 0)
            session.presentation = .init(turnClean: true)
            session.attention = [.init(kind: .turnFinished,
                                       evidence: .init(source: "copilot.events", eventID: owner.id), occurredAt: date)]
            return session
        }
        func project(_ managed: SidebarOrchestrationSnapshot, session: SidebarCopilotSession,
                     at date: Date, availability: SidebarOrchestrationAvailability = .stale) -> SidebarPetMoodInput {
            .project(session: session, tree: .init(availability: .ready, sessions: [session], issues: [], generatedAt: date),
                     managed: managed, availability: availability, now: date)
        }
        let cold = try read(1, at: now)
        #expect(project(cold, session: observed(at: now), at: now, availability: .ready).selfReport == nil)
        let later = now.addingTimeInterval(SidebarOrchestrationReader.staleInterval + 1)
        let live = observed(at: later)
        let accepted = try read(2, at: later)
        #expect(SidebarOrchestrationReader.isStale(accepted, now: later))
        #expect(accepted.nodes[0].updatedAt == now)
        let input = project(accepted, session: live, at: later)
        #expect(input.selfReport == .happy && input.selfReportSequence == 2)
        #expect(SidebarPetMood.resolve(input, now: later).mood == .proud)
        #expect(input.session == live, "A self-report must not change work or attention")
        #expect(try encoder.encode(accepted) == lifecycle, "No synthetic lifecycle heartbeat")

        let muchLater = later.addingTimeInterval(120)
        let retained = try read(2, at: muchLater)
        #expect(project(retained, session: observed(at: muchLater), at: muchLater).selfReport == .happy)
        let cleared = try read(3, mood: "clear", at: muchLater)
        let afterClear = project(cleared, session: observed(at: muchLater), at: muchLater)
        #expect(afterClear.selfReport == nil && afterClear.selfReportSequence == 3)
        #expect(SidebarPetMood.resolve(afterClear, now: muchLater).mood == .content)
        #expect(project(try read(2, at: muchLater), session: observed(at: muchLater), at: muchLater).selfReport == nil)

        var resumed = base
        resumed.nodes[0].generation += 1
        let wrongGeneration = try SidebarOrchestrationReader.resolve(
            current: encoder.encode(resumed), icons: nil, processes: nil,
            moods: data([record(owner, sequence: 4)]), cache: &cache, now: muchLater)
        let rejected = project(wrongGeneration, session: observed(at: muchLater), at: muchLater)
        #expect(rejected.identity?.generation == 2 && rejected.selfReport == nil)
        #expect(rejected.session?.state == .idle && rejected.session?.attention == observed(at: muchLater).attention)

        for unavailable in [SidebarOrchestrationAvailability.unavailable, .waiting, .hidden, .disconnected] {
            #expect(project(accepted, session: live, at: later, availability: unavailable).selfReport == nil)
        }
        for scenario in ["stale-tree", "stale-session", "denied", "duplicate", "ambiguous", "dead", "status-only"] {
            var subject = live
            var tree = SidebarCopilotTree(availability: .ready, sessions: [subject], issues: [], generatedAt: later)
            switch scenario {
            case "stale-tree": tree.generatedAt = now
            case "stale-session": subject.observedAt = now
            case "denied": tree.issues = [.permissionDenied]
            case "ambiguous": subject = observed(at: later, liveness: .ambiguous)
            case "dead": subject = observed(at: later, liveness: .dead)
            case "status-only": subject.statusOnly = true
            default: break
            }
            tree.sessions = scenario == "duplicate" ? [subject, subject] : [subject]
            let unavailable = SidebarPetMoodInput.project(
                session: subject, tree: tree, managed: accepted, availability: .stale, now: later)
            #expect(unavailable.selfReport == nil, "\(scenario) cannot authorize an overlay")
        }
    }
}
