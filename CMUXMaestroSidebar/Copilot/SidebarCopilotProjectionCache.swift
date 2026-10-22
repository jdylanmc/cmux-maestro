import Foundation

/// Memoizes structural work, never the reader's identity checks or evidence timestamps.
struct SidebarCopilotProjectionCache {
    let tree: SidebarCopilotTree
    private let input: AgentSessionSnapshot
    private struct ObservationTime: Equatable {
        let fresh: Bool
        let valid: Bool
        let withinEnvelope: Bool
    }
    private let observationTimes: [ObservationTime?]
    private let projectedAt: Date
    let nextClockChange: Date?
    private let nextGeneratedChange: Date?
    private let bounded: Bool

    init(snapshot: AgentSessionSnapshot, tree: SidebarCopilotTree, now: Date) {
        self.tree = tree
        input = Self.content(snapshot)
        observationTimes = Self.times(snapshot, now: now)
        projectedAt = now
        var clockChange = tree.nextHistoryExpiry
        var generatedChange: Date?
        func include(_ date: Date?) {
            guard let date, date.timeIntervalSinceReferenceDate.isFinite else { return }
            if date > now { clockChange = min(clockChange ?? date, date) }
            if date > snapshot.generatedAt { generatedChange = min(generatedChange ?? date, date) }
        }
        var remaining = AgentSessionObservationAssessment.maximumNodes * 2
        for session in snapshot.sessions {
            include(session.activity.value?.lastEventAt)
            include(session.timing.value?.startedAt)
            include(session.timing.value?.updatedAt)
            include(session.timing.value?.completedAt)
            for signal in session.attention ?? [] { include(signal.occurredAt) }
            var pending = session.childWork + (session.childWorkObservation?.items ?? [])
            while let child = pending.popLast(), remaining > 0 {
                remaining -= 1
                include(child.terminalEvent?.timestamp)
                include(child.activity.value?.lastEventAt)
                for signal in child.attention ?? [] { include(signal.occurredAt) }
                pending.append(contentsOf: child.children)
            }
            if remaining == 0 { break }
        }
        bounded = remaining > 0
        nextClockChange = clockChange
        nextGeneratedChange = generatedChange
    }

    func matches(_ snapshot: AgentSessionSnapshot, now: Date) -> Bool {
        bounded && now >= projectedAt
            && (nextClockChange.map { now < $0 } ?? true)
            && (nextGeneratedChange.map { snapshot.generatedAt < $0 } ?? true)
            && observationTimes == Self.times(snapshot, now: now)
            && input == Self.content(snapshot)
    }

    private static func times(_ snapshot: AgentSessionSnapshot, now: Date) -> [ObservationTime?] {
        snapshot.sessions.map { session in
            session.observedAt.map {
                ObservationTime(
                    fresh: SidebarCopilotTree.isFresh($0, now: now),
                    valid: $0.timeIntervalSince1970.isFinite && $0 <= snapshot.generatedAt,
                    withinEnvelope: $0 <= snapshot.generatedAt.addingTimeInterval(1)
                )
            }
        }
    }

    private static func content(_ snapshot: AgentSessionSnapshot) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            schemaVersion: snapshot.schemaVersion, generatedAt: .distantPast, workspaces: snapshot.workspaces,
            sessions: snapshot.sessions.map {
                var session = $0
                session.observedAt = nil
                return session
            },
            issues: snapshot.issues, completeness: snapshot.completeness
        )
    }
}
