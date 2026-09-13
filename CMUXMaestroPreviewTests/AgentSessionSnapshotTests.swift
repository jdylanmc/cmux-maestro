import Foundation
import Testing
@testable import CMUXMaestroPreview

struct AgentSessionSnapshotTests {
    typealias AgentActivity = CMUXMaestroPreview.AgentActivity
    @Test(arguments: ["hierarchy", "taskboard", "degraded-unbound"])
    func decodesAndValidatesFixture(named fixtureName: String) throws {
        let snapshot = try decodeFixture(named: fixtureName)

        try snapshot.validate()
        #expect(snapshot.schemaVersion == .current)
    }

    @Test(arguments: ["hierarchy", "taskboard", "degraded-unbound"])
    func fixtureRoundTripsThroughCodable(named fixtureName: String) throws {
        let snapshot = try decodeFixture(named: fixtureName)

        let encoded = try AgentSessionSnapshotJSONCodec.encode(snapshot)
        let decoded = try AgentSessionSnapshotJSONCodec.decode(encoded)

        #expect(decoded == snapshot)
        try decoded.validate()
    }

    @Test
    func fractionalTimestampPayloadRoundTripsExactly() throws {
        let payload = Data(
            """
            {
              "schemaVersion": 1,
              "generatedAt": "2026-09-10T18:00:00.125Z",
              "workspaces": [],
              "sessions": []
            }
            """.utf8
        )

        let snapshot = try AgentSessionSnapshotJSONCodec.decode(payload)
        let encoded = try AgentSessionSnapshotJSONCodec.encode(snapshot)
        let decoded = try AgentSessionSnapshotJSONCodec.decode(encoded)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        #expect(decoded == snapshot)
        #expect(object["generatedAt"] as? String == "2026-09-10T18:00:00.125000000Z")
        try decoded.validate()
    }

    @Test
    func programmaticSubsecondDateRoundTripsExactly() throws {
        let date = Date(timeIntervalSince1970: 1_789_060_800.123456)
        let snapshot = AgentSessionSnapshot(
            generatedAt: date,
            workspaces: [],
            sessions: []
        )

        let encoded = try AgentSessionSnapshotJSONCodec.encode(snapshot)
        let decoded = try AgentSessionSnapshotJSONCodec.decode(encoded)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let generatedAt = try #require(object["generatedAt"] as? String)
        let fractionalDigits = generatedAt
            .split(separator: ".", maxSplits: 1)
            .last?
            .dropLast()

        #expect(decoded.generatedAt == date)
        #expect(fractionalDigits?.count == AgentSessionSnapshotJSONCodec.fractionalSecondDigits)
        #expect(generatedAt != "2026-09-10T17:20:00Z")
        try decoded.validate()
    }

    @Test
    func keepsProviderIdentitySeparateFromCMUXIdentity() throws {
        let snapshot = try decodeFixture(named: "hierarchy")
        let firstSession = try #require(snapshot.sessions.first)
        let firstWorkspace = try #require(snapshot.workspaces.first)
        let firstSurface = try #require(firstWorkspace.surfaces.first)
        let binding = try #require(boundBinding(from: firstSession.binding))

        #expect(firstSession.identity.sessionID == "session-100")
        #expect(binding.workspaceID == firstWorkspace.id)
        #expect(binding.surfaceID == firstSurface.id)
        #expect(firstSession.identity.sessionID != firstWorkspace.id.rawValue)
        #expect(firstSession.identity.sessionID != firstSurface.id.rawValue)
    }

    @Test
    func preservesDuplicateLookingSessionsByStableIdentity() throws {
        let snapshot = try decodeFixture(named: "hierarchy")

        #expect(snapshot.sessions.count == 2)
        #expect(snapshot.sessions[0].title == snapshot.sessions[1].title)
        #expect(snapshot.sessions[0].identity != snapshot.sessions[1].identity)
    }

    @Test
    func representsNestedChildWork() throws {
        let snapshot = try decodeFixture(named: "hierarchy")
        let rootChild = try #require(snapshot.sessions.first?.childWork.first)
        let nestedChild = try #require(rootChild.children.first)

        #expect(rootChild.parent == .session(snapshot.sessions[0].identity))
        #expect(nestedChild.parent == .child(rootChild.id))
    }

    @Test
    func scopesChildWorkIdentityToProviderSession() throws {
        let snapshot = try decodeFixture(named: "hierarchy")

        #expect(snapshot.sessions[0].childWork[0].id == ChildWorkID("task-1"))
        #expect(snapshot.sessions[1].childWork[0].id == ChildWorkID("task-1"))
        try snapshot.validate()

        let encoded = try AgentSessionSnapshotJSONCodec.encode(snapshot)
        let decoded = try AgentSessionSnapshotJSONCodec.decode(encoded)
        #expect(decoded == snapshot)
        try decoded.validate()
    }

    @Test
    func representsTaskboardStates() throws {
        let snapshot = try decodeFixture(named: "taskboard")

        #expect(snapshot.sessions.map(\.state) == [
            .known(.blocked),
            .known(.working),
            .known(.done),
        ])
    }

    @Test
    func preservesSessionAndChildStateObservationSemantics() throws {
        let taskboard = try decodeFixture(named: "taskboard")
        let degraded = try decodeFixture(named: "degraded-unbound")
        let degradedSession = try #require(degraded.sessions.first)

        #expect(taskboard.sessions[0].state == .known(.blocked))
        #expect(taskboard.sessions[1].state == .known(.working))
        #expect(degradedSession.state == .degraded(
            "Current state observation is unavailable",
            value: .working
        ))
        #expect(degradedSession.childWork[0].state == .unknown(
            detail: "Provider omitted the child state"
        ))
        #expect(degradedSession.childWork[1].state == .degraded(
            "Current child state observation is unavailable",
            value: .done
        ))

        let encoded = try AgentSessionSnapshotJSONCodec.encode(degraded)
        let decoded = try AgentSessionSnapshotJSONCodec.decode(encoded)
        #expect(decoded.sessions[0].state == degradedSession.state)
        #expect(decoded.sessions[0].childWork.map(\.state) == degradedSession.childWork.map(\.state))
        try decoded.validate()
    }

    @Test
    func representsEveryBindingObservationExplicitly() throws {
        let hierarchy = try decodeFixture(named: "hierarchy")
        let taskboard = try decodeFixture(named: "taskboard")
        let degraded = try decodeFixture(named: "degraded-unbound")

        #expect(hierarchy.sessions[0].binding == .bound(
            AgentSessionBinding(
                workspaceID: WorkspaceID("workspace-primary"),
                surfaceID: SurfaceID("surface-terminal")
            )
        ))
        #expect(taskboard.sessions[0].binding == .unknown(
            detail: "Provider does not report binding state"
        ))
        #expect(taskboard.sessions[1].binding == .unbound)
        #expect(degraded.sessions[0].binding == .degraded(
            lastKnownBinding: AgentSessionBinding(
                workspaceID: WorkspaceID("workspace-degraded"),
                surfaceID: SurfaceID("surface-last-known")
            ),
            detail: "Current binding could not be observed"
        ))
    }

    @Test
    func representsDegradedSessionDataExplicitly() throws {
        let session = try #require(
            decodeFixture(named: "degraded-unbound").sessions.first
        )

        #expect(session.title.availability == .unknown)
        #expect(session.state.availability == .degraded)
        #expect(session.activity.availability == .degraded)
        #expect(session.paths.availability == .degraded)
        #expect(session.timing.availability == .degraded)
    }

    @Test
    func rejectsUnsupportedSchemaVersion() throws {
        let snapshot = AgentSessionSnapshot(
            schemaVersion: SnapshotSchemaVersion(rawValue: 2),
            generatedAt: Date(),
            workspaces: [],
            sessions: []
        )

        #expect(throws: AgentSessionSnapshotValidationError.unsupportedSchemaVersion(2)) {
            try snapshot.validate()
        }
    }

    @Test
    func rejectsInvalidAvailabilityCombinations() throws {
        let snapshot = minimalSnapshot(
            title: SnapshotValue(availability: .known, value: nil, detail: nil)
        )

        #expect(throws: AgentSessionSnapshotValidationError.invalidAvailability(
            path: "sessions[0].title"
        )) {
            try snapshot.validate()
        }
    }

    @Test
    func rejectsInvalidHierarchyReferences() throws {
        let workspaceID = WorkspaceID("workspace")
        let snapshot = AgentSessionSnapshot(
            generatedAt: Self.referenceDate,
            workspaces: [
                CMUXWorkspaceSnapshot(
                    id: workspaceID,
                    title: .known("Workspace"),
                    surfaces: [
                        CMUXSurfaceSnapshot(
                            id: SurfaceID("surface"),
                            workspaceID: workspaceID,
                            title: .known("Surface"),
                            kind: .terminal
                        ),
                    ]
                ),
            ],
            sessions: [
                minimalSession(
                    binding: .bound(
                        AgentSessionBinding(
                            workspaceID: workspaceID,
                            surfaceID: SurfaceID("missing")
                        )
                    )
                ),
            ]
        )

        #expect(throws: AgentSessionSnapshotValidationError.invalidHierarchyReference(
            path: "sessions[0].binding.binding.surfaceID",
            reference: "missing"
        )) {
            try snapshot.validate()
        }
    }

    @Test
    func rejectsInvalidLastKnownBindingReference() throws {
        let snapshot = minimalSnapshot(
            binding: .degraded(
                lastKnownBinding: AgentSessionBinding(
                    workspaceID: WorkspaceID("missing"),
                    surfaceID: SurfaceID("missing")
                ),
                detail: "Current binding unavailable"
            )
        )

        #expect(throws: AgentSessionSnapshotValidationError.invalidHierarchyReference(
            path: "sessions[0].binding.lastKnownBinding.workspaceID",
            reference: "missing"
        )) {
            try snapshot.validate()
        }
    }

    @Test
    func rejectsInvalidChildParentReference() {
        let child = AgentChildWork(
            id: ChildWorkID("child"),
            parent: .child(ChildWorkID("not-the-parent")),
            title: .known("Child work"),
            state: .known(.working),
            activity: .known(AgentActivity(kind: .executing))
        )
        let snapshot = AgentSessionSnapshot(
            generatedAt: Self.referenceDate,
            workspaces: [],
            sessions: [
                minimalSession(childWork: [child]),
            ]
        )

        #expect {
            try snapshot.validate()
        } throws: { error in
            guard case let AgentSessionSnapshotValidationError.invalidHierarchyReference(
                path,
                _
            ) = error else {
                return false
            }
            return path == "sessions[0].childWork[0].parent"
        }
    }

    @Test
    func rejectsInvalidTimestampOrdering() {
        let timing = AgentSessionTiming(
            startedAt: Self.referenceDate,
            updatedAt: Self.referenceDate.addingTimeInterval(-60)
        )
        let snapshot = AgentSessionSnapshot(
            generatedAt: Self.referenceDate,
            workspaces: [],
            sessions: [
                minimalSession(timing: .known(timing)),
            ]
        )

        #expect(throws: AgentSessionSnapshotValidationError.invalidTimestampOrder(
            path: "sessions[0].timing"
        )) {
            try snapshot.validate()
        }
    }

    @Test
    func rejectsDuplicateStableIdentity() {
        let session = minimalSession()
        let snapshot = AgentSessionSnapshot(
            generatedAt: Self.referenceDate,
            workspaces: [],
            sessions: [session, session]
        )

        #expect(throws: AgentSessionSnapshotValidationError.duplicateIdentity(
            "fixture-provider:fixture-session"
        )) {
            try snapshot.validate()
        }
    }

    @Test
    func rejectsDuplicateChildWorkIdentityWithinProviderSession() {
        let identity = ProviderSessionIdentity(
            providerID: "fixture-provider",
            sessionID: "fixture-session"
        )
        let child = AgentChildWork(
            id: ChildWorkID("task-1"),
            parent: .session(identity),
            title: .known("Task"),
            state: .known(.working),
            activity: .known(AgentActivity(kind: .executing))
        )
        let snapshot = AgentSessionSnapshot(
            generatedAt: Self.referenceDate,
            workspaces: [],
            sessions: [
                minimalSession(childWork: [child, child]),
            ]
        )

        #expect(throws: AgentSessionSnapshotValidationError.duplicateIdentity("task-1")) {
            try snapshot.validate()
        }
    }

    @Test
    func acceptsKnownDoneTimingAndBoundedKnownActivity() throws {
        let timing = AgentSessionTiming(
            startedAt: Self.referenceDate.addingTimeInterval(-180),
            updatedAt: Self.referenceDate.addingTimeInterval(-60),
            completedAt: Self.referenceDate.addingTimeInterval(-30)
        )
        let snapshot = minimalSnapshot(
            state: .known(.done),
            activity: .known(
                AgentActivity(
                    kind: .idle,
                    lastEventAt: Self.referenceDate.addingTimeInterval(-45)
                )
            ),
            timing: .known(timing)
        )

        try snapshot.validate()
    }

    @Test
    func rejectsKnownDoneTimingWithoutCompletion() {
        let snapshot = minimalSnapshot(
            state: .known(.done),
            activity: .known(AgentActivity(kind: .idle)),
            timing: .known(
                AgentSessionTiming(
                    startedAt: Self.referenceDate.addingTimeInterval(-120),
                    updatedAt: Self.referenceDate.addingTimeInterval(-60)
                )
            )
        )

        #expect(throws: AgentSessionSnapshotValidationError.invalidStateTiming(
            path: "sessions[0].timing"
        )) {
            try snapshot.validate()
        }
    }

    @Test
    func rejectsKnownCompletionForActiveState() {
        let snapshot = minimalSnapshot(
            state: .known(.working),
            timing: .known(
                AgentSessionTiming(
                    startedAt: Self.referenceDate.addingTimeInterval(-120),
                    updatedAt: Self.referenceDate.addingTimeInterval(-60),
                    completedAt: Self.referenceDate.addingTimeInterval(-30)
                )
            )
        )

        #expect(throws: AgentSessionSnapshotValidationError.invalidStateTiming(
            path: "sessions[0].timing"
        )) {
            try snapshot.validate()
        }
    }

    @Test
    func rejectsKnownActivityBeforeKnownStart() {
        let snapshot = minimalSnapshot(
            activity: .known(
                AgentActivity(
                    kind: .executing,
                    lastEventAt: Self.referenceDate.addingTimeInterval(-180)
                )
            )
        )

        #expect(throws: AgentSessionSnapshotValidationError.invalidTimestampOrder(
            path: "sessions[0].activity.value.lastEventAt"
        )) {
            try snapshot.validate()
        }
    }

    @Test
    func rejectsKnownActivityAfterKnownCompletion() {
        let snapshot = minimalSnapshot(
            state: .known(.done),
            activity: .known(
                AgentActivity(
                    kind: .idle,
                    lastEventAt: Self.referenceDate.addingTimeInterval(-15)
                )
            ),
            timing: .known(
                AgentSessionTiming(
                    startedAt: Self.referenceDate.addingTimeInterval(-180),
                    updatedAt: Self.referenceDate.addingTimeInterval(-60),
                    completedAt: Self.referenceDate.addingTimeInterval(-30)
                )
            )
        )

        #expect(throws: AgentSessionSnapshotValidationError.invalidTimestampOrder(
            path: "sessions[0].activity.value.lastEventAt"
        )) {
            try snapshot.validate()
        }
    }

    @Test
    func acceptsActivityAtKnownTimingBounds() throws {
        let startedAt = Self.referenceDate.addingTimeInterval(-180)
        let completedAt = Self.referenceDate.addingTimeInterval(-30)
        let timing = AgentSessionTiming(
            startedAt: startedAt,
            updatedAt: Self.referenceDate.addingTimeInterval(-60),
            completedAt: completedAt
        )

        try minimalSnapshot(
            state: .known(.done),
            activity: .known(
                AgentActivity(
                    kind: .idle,
                    lastEventAt: startedAt
                )
            ),
            timing: .known(timing)
        ).validate()
        try minimalSnapshot(
            state: .known(.done),
            activity: .known(
                AgentActivity(
                    kind: .idle,
                    lastEventAt: completedAt
                )
            ),
            timing: .known(timing)
        ).validate()
        try minimalSnapshot(
            state: .known(.done),
            activity: .degraded(
                "Current activity unavailable",
                value: AgentActivity(
                    kind: .idle,
                    lastEventAt: startedAt
                )
            ),
            timing: .known(timing)
        ).validate()
        try minimalSnapshot(
            state: .known(.done),
            activity: .degraded(
                "Current activity unavailable",
                value: AgentActivity(
                    kind: .idle,
                    lastEventAt: completedAt
                )
            ),
            timing: .known(timing)
        ).validate()
    }

    @Test
    func rejectsDegradedActivityBeforeKnownStart() {
        let snapshot = minimalSnapshot(
            activity: .degraded(
                "Current activity unavailable",
                value: AgentActivity(
                    kind: .executing,
                    lastEventAt: Self.referenceDate.addingTimeInterval(-180)
                )
            )
        )

        #expect(throws: AgentSessionSnapshotValidationError.invalidTimestampOrder(
            path: "sessions[0].activity.value.lastEventAt"
        )) {
            try snapshot.validate()
        }
    }

    @Test
    func rejectsDegradedActivityAfterKnownCompletionBeforeSnapshot() {
        let snapshot = minimalSnapshot(
            state: .known(.done),
            activity: .degraded(
                "Current activity unavailable",
                value: AgentActivity(
                    kind: .idle,
                    lastEventAt: Self.referenceDate.addingTimeInterval(-15)
                )
            ),
            timing: .known(
                AgentSessionTiming(
                    startedAt: Self.referenceDate.addingTimeInterval(-180),
                    updatedAt: Self.referenceDate.addingTimeInterval(-60),
                    completedAt: Self.referenceDate.addingTimeInterval(-30)
                )
            )
        )

        #expect(throws: AgentSessionSnapshotValidationError.invalidTimestampOrder(
            path: "sessions[0].activity.value.lastEventAt"
        )) {
            try snapshot.validate()
        }
    }

    @Test
    func acceptsDegradedActivityWithoutLastEventAt() throws {
        try minimalSnapshot(
            activity: .degraded(
                "Current activity unavailable",
                value: AgentActivity(kind: .executing)
            )
        ).validate()
    }

    @Test
    func preservesUnknownAndDegradedTimingSemantics() throws {
        try minimalSnapshot(
            state: .known(.done),
            activity: .known(AgentActivity(kind: .idle)),
            timing: .unknown()
        ).validate()
        try minimalSnapshot(
            state: .known(.done),
            activity: .known(AgentActivity(kind: .idle)),
            timing: .degraded(
                "Completion observation unavailable",
                value: AgentSessionTiming(
                    startedAt: Self.referenceDate.addingTimeInterval(-120),
                    updatedAt: Self.referenceDate.addingTimeInterval(-60)
                )
            )
        ).validate()
        try minimalSnapshot(
            state: .known(.working),
            timing: .degraded(
                "Current timing observation unavailable",
                value: AgentSessionTiming(
                    startedAt: Self.referenceDate.addingTimeInterval(-120),
                    updatedAt: Self.referenceDate.addingTimeInterval(-60),
                    completedAt: Self.referenceDate.addingTimeInterval(-30)
                )
            )
        ).validate()
    }

    @Test
    func rejectsKnownDoneExecutingSession() {
        let snapshot = minimalSnapshot(
            state: .known(.done),
            activity: .known(AgentActivity(kind: .executing)),
            timing: .known(
                AgentSessionTiming(
                    startedAt: Self.referenceDate.addingTimeInterval(-120),
                    updatedAt: Self.referenceDate.addingTimeInterval(-60),
                    completedAt: Self.referenceDate.addingTimeInterval(-30)
                )
            )
        )

        #expect(throws: AgentSessionSnapshotValidationError.incompatibleStateActivity(
            path: "sessions[0].activity"
        )) {
            try snapshot.validate()
        }
    }

    @Test
    func rejectsKnownDoneExecutingChildWork() {
        let identity = ProviderSessionIdentity(
            providerID: "fixture-provider",
            sessionID: "fixture-session"
        )
        let child = AgentChildWork(
            id: ChildWorkID("task-1"),
            parent: .session(identity),
            title: .known("Completed task"),
            state: .known(.done),
            activity: .known(AgentActivity(kind: .executing))
        )
        let snapshot = AgentSessionSnapshot(
            generatedAt: Self.referenceDate,
            workspaces: [],
            sessions: [minimalSession(childWork: [child])]
        )

        #expect(throws: AgentSessionSnapshotValidationError.incompatibleStateActivity(
            path: "sessions[0].childWork[0].activity"
        )) {
            try snapshot.validate()
        }
    }

    @Test
    func acceptsRequiredKnownAndUnavailableStateActivityCombinations() throws {
        try minimalSnapshot(
            state: .known(.done),
            activity: .known(AgentActivity(kind: .idle)),
            timing: .known(
                AgentSessionTiming(
                    startedAt: Self.referenceDate.addingTimeInterval(-120),
                    updatedAt: Self.referenceDate.addingTimeInterval(-60),
                    completedAt: Self.referenceDate.addingTimeInterval(-30)
                )
            )
        ).validate()
        try minimalSnapshot(
            state: .known(.working),
            activity: .known(AgentActivity(kind: .executing))
        ).validate()
        try minimalSnapshot(
            state: .known(.queued),
            activity: .known(AgentActivity(kind: .waiting))
        ).validate()
        try minimalSnapshot(
            state: .unknown(detail: "Current state unavailable"),
            activity: .known(AgentActivity(kind: .executing))
        ).validate()
        try minimalSnapshot(
            state: .degraded("Current state unavailable", value: .done),
            activity: .known(AgentActivity(kind: .executing))
        ).validate()
        try minimalSnapshot(
            state: .known(.done),
            activity: .degraded(
                "Current activity unavailable",
                value: AgentActivity(kind: .executing)
            ),
            timing: .known(
                AgentSessionTiming(
                    startedAt: Self.referenceDate.addingTimeInterval(-120),
                    updatedAt: Self.referenceDate.addingTimeInterval(-60),
                    completedAt: Self.referenceDate.addingTimeInterval(-30)
                )
            )
        ).validate()
    }
}

private extension AgentSessionSnapshotTests {
    static let referenceDate = Date(timeIntervalSince1970: 1_789_060_800)

    func decodeFixture(named name: String) throws -> AgentSessionSnapshot {
        let fixtureURL = try #require(
            Bundle(for: FixtureBundleToken.self).url(
                forResource: name,
                withExtension: "json"
            )
        )
        return try AgentSessionSnapshotJSONCodec.decode(Data(contentsOf: fixtureURL))
    }

    func minimalSnapshot(
        binding: AgentSessionBindingObservation = .unbound,
        title: SnapshotValue<String> = .known("Fixture session"),
        state: SnapshotValue<AgentSessionState> = .known(.working),
        activity: SnapshotValue<AgentActivity> = .known(AgentActivity(kind: .executing)),
        timing: SnapshotValue<AgentSessionTiming> = .known(
            AgentSessionTiming(
                startedAt: referenceDate.addingTimeInterval(-120),
                updatedAt: referenceDate.addingTimeInterval(-60)
            )
        )
    ) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            generatedAt: Self.referenceDate,
            workspaces: [],
            sessions: [
                minimalSession(
                    binding: binding,
                    title: title,
                    state: state,
                    activity: activity,
                    timing: timing
                ),
            ]
        )
    }

    func minimalSession(
        binding: AgentSessionBindingObservation = .unbound,
        title: SnapshotValue<String> = .known("Fixture session"),
        state: SnapshotValue<AgentSessionState> = .known(.working),
        activity: SnapshotValue<AgentActivity> = .known(AgentActivity(kind: .executing)),
        timing: SnapshotValue<AgentSessionTiming> = .known(
            AgentSessionTiming(
                startedAt: referenceDate.addingTimeInterval(-120),
                updatedAt: referenceDate.addingTimeInterval(-60)
            )
        ),
        childWork: [AgentChildWork] = []
    ) -> AgentSessionSnapshotItem {
        AgentSessionSnapshotItem(
            identity: ProviderSessionIdentity(
                providerID: "fixture-provider",
                sessionID: "fixture-session"
            ),
            binding: binding,
            title: title,
            state: state,
            activity: activity,
            model: .known(AgentModel(identifier: "fixture-model")),
            paths: .unknown(),
            timing: timing,
            childWork: childWork
        )
    }

    func boundBinding(
        from observation: AgentSessionBindingObservation
    ) -> AgentSessionBinding? {
        guard case let .bound(binding) = observation else {
            return nil
        }
        return binding
    }
}

private final class FixtureBundleToken {}
