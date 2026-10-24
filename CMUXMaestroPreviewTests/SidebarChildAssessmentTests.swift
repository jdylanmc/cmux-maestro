import Foundation
import Testing

@MainActor
struct SidebarChildAssessmentTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let owner = ProviderSessionIdentity(providerID: "copilot", sessionID: "synthetic")

    @Test(arguments: [
        "id", "parent", "title", "state", "activity", "children", "detail", "kind", "model", "terminal", "attention",
        "legacyOnly", "flatOnly", "lossless", "absent", "owner", "schema", "path"
    ])
    func relevantInputChangesReassessAndMatchUncached(_ change: String) {
        let cache = SidebarSessionProjectionCache()
        let original = child()
        let initial = snapshot(legacy: [original], flat: .init(items: [original], legacyProjectionIsLossless: true))
        check(cache.assessment(snapshot: initial, index: 0), equals: initial.assess(initial.sessions[0], at: "sessions[0]"))
        #expect(cache.childAssessmentCount == 1)
        let modified = child(change)
        let legacy = change == "flatOnly" ? original : modified
        let flat = change == "legacyOnly" ? original : modified
        var changed = snapshot(
            legacy: [legacy],
            flat: change == "absent" ? nil : .init(items: [flat], legacyProjectionIsLossless: change != "lossless"),
            identity: change == "owner" ? .init(providerID: "other", sessionID: "synthetic") : owner,
            schema: change == "schema" ? 2 : 1
        )
        let index = change == "path" ? 1 : 0
        if index == 1 {
            changed = .init(generatedAt: date, workspaces: [], sessions: [changed.sessions[0], changed.sessions[0]])
        }
        check(cache.assessment(snapshot: changed, index: index),
              equals: changed.assess(changed.sessions[index], at: "sessions[\(index)]"))
        #expect(cache.childAssessmentCount == 2)
    }

    @Test func futureChildEvidenceRecoversAndEnvelopeRollbackRevalidates() {
        let cache = SidebarSessionProjectionCache()
        let future = child("future")
        func assess(at date: Date) -> AgentSessionObservationAssessment {
            let source = snapshot(legacy: [future], flat: .init(items: [future]), generatedAt: date)
            let result = cache.assessment(snapshot: source, index: 0)
            check(result, equals: source.assess(source.sessions[0], at: "sessions[0]"))
            return result
        }
        #expect(!assess(at: date).isValid)
        #expect(!assess(at: date).isValid)
        #expect(cache.retainedChildAssessmentCount == 0, "Invalid evidence is never cached")
        #expect(assess(at: date.addingTimeInterval(1)).isValid)
        #expect(assess(at: date.addingTimeInterval(2)).isValid)
        #expect(cache.childAssessmentCount == 3)
        #expect(!assess(at: date).isValid)
        #expect(cache.childAssessmentCount == 4)
    }

    @Test func sessionValidationStillRunsOnChildCacheHits() {
        let cache = SidebarSessionProjectionCache()
        let item = child()
        let source = snapshot(legacy: [item], flat: .init(items: [item]))
        #expect(cache.assessment(snapshot: source, index: 0).isValid)
        let contradictory = snapshot(legacy: [item], flat: .init(items: [item]), stateDetail: .idle)
        let stateResult = cache.assessment(snapshot: contradictory, index: 0)
        check(stateResult, equals: contradictory.assess(contradictory.sessions[0], at: "sessions[0]"))
        #expect(!stateResult.sessionStateIsValid)
        var session = source.sessions[0]
        session.observedAt = date.addingTimeInterval(1)
        let invalid = AgentSessionSnapshot(generatedAt: date, workspaces: [], sessions: [session])
        let result = cache.assessment(snapshot: invalid, index: 0)
        check(result, equals: invalid.assess(session, at: "sessions[0]"))
        #expect(!result.isValid)
        #expect(cache.childAssessmentCount == 1)
    }

    @Test func retainedAssessmentsAreBoundedPrunedAndCleared() {
        let cache = SidebarSessionProjectionCache()
        let empty = AgentSessionSnapshot(generatedAt: date, workspaces: [], sessions: [])
        let topology = SidebarTreeFixtures().topology()
        cache.prepare(snapshot: empty, topology: topology, history: .init(),
                      attention: .init(), revealingIdleTasksIn: [])
        for index in 0..<70 {
            let source = snapshot(legacy: [], flat: nil, identity: .init(providerID: "copilot", sessionID: "\(index)"))
            #expect(cache.assessment(snapshot: source, index: 0).isValid)
        }
        #expect(cache.retainedChildAssessmentCount == 64)
        cache.prepare(snapshot: empty, topology: topology, history: .init(),
                      attention: .init(), revealingIdleTasksIn: [])
        #expect(cache.retainedChildAssessmentCount == 0)
        _ = cache.assessment(snapshot: snapshot(legacy: [], flat: nil), index: 0)
        cache.removeAll()
        #expect(cache.retainedChildAssessmentCount == 0)
    }

    private func child(_ change: String = "") -> AgentChildWork {
        let modified = change == "legacyOnly" || change == "flatOnly"
        return .init(
            id: .init(change == "id" ? "different" : "child"),
            parent: change == "parent" ? .child(.init("missing")) : .session(owner),
            title: .known(change == "title" || modified ? "Changed" : "Synthetic"),
            state: change == "state" ? .known(.blocked) : .known(.working),
            activity: change == "activity" || change == "future"
                ? .known(.init(kind: .executing, lastEventAt: date.addingTimeInterval(change == "future" ? 1 : -1)))
                : .unknown(),
            children: change == "children" ? [child()] : [],
            stateDetail: change == "detail" ? .idle : nil,
            kind: change == "kind" ? .skill : .subagent,
            model: change == "model" ? .known(.init(identifier: "synthetic", displayName: nil)) : nil,
            terminalEvent: change == "terminal" ? .init(id: UUID(), timestamp: date) : nil,
            attention: change == "attention"
                ? [.init(kind: .answer, evidence: .init(source: "synthetic", eventID: UUID()), occurredAt: date)] : nil
        )
    }

    private func snapshot(
        legacy: [AgentChildWork], flat: AgentChildWorkObservation?,
        identity: ProviderSessionIdentity? = nil, generatedAt: Date? = nil, schema: Int = 1,
        stateDetail: AgentSessionStateDetail? = nil
    ) -> AgentSessionSnapshot {
        .init(schemaVersion: .init(rawValue: schema), generatedAt: generatedAt ?? date, workspaces: [], sessions: [
            .init(identity: identity ?? owner, binding: .unbound, title: .unknown(), state: .known(.working),
                  activity: .unknown(), model: .unknown(), paths: .unknown(), timing: .unknown(),
                  childWork: legacy, stateDetail: stateDetail, observedAt: generatedAt ?? date, childWorkObservation: flat)
        ])
    }

    private func check(_ actual: AgentSessionObservationAssessment, equals expected: AgentSessionObservationAssessment) {
        #expect(actual.firstError as? AgentSessionSnapshotValidationError
            == expected.firstError as? AgentSessionSnapshotValidationError)
        #expect(actual.sessionStateIsValid == expected.sessionStateIsValid)
        #expect(actual.children == expected.children)
        #expect(actual.invalidChildren == expected.invalidChildren)
        #expect(actual.invalidStates == expected.invalidStates)
        #expect(actual.unresolvedParents == expected.unresolvedParents)
        #expect(actual.omittedChildren == expected.omittedChildren)
        #expect(actual.hasUncountedChildren == expected.hasUncountedChildren)
    }
}
