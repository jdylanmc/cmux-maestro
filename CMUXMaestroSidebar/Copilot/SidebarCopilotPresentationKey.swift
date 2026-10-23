import Foundation

/// Rendering compares displayed dates and freshness, while actions keep exact evidence timestamps.
struct SidebarCopilotPresentationKey: Equatable {
    private var content: SidebarCopilotTree
    private var freshness: [Bool]
    private var identityCounts: [UUID: Int] = [:]

    init(
        _ tree: SidebarCopilotTree, now: Date, workspaceID: UUID? = nil,
        managedSessionIDs: Set<UUID> = []
    ) {
        var tree = tree
        if let workspaceID {
            let identities = tree.sessions.reduce(into: [UUID: Int]()) { $0[$1.id, default: 0] += 1 }
            tree.sessions = tree.sessions.indices.filter { tree.sessions[$0].workspaceID == workspaceID }
                .map { tree.sessions[$0] }
            tree.statusSessions = tree.statusSessions.indices.filter { tree.statusSessions[$0].workspaceID == workspaceID }
                .map { tree.statusSessions[$0] }
            let shown = Set(tree.sessions.map(\.id) + tree.statusSessions.map(\.id)).union(managedSessionIDs)
            identityCounts = identities.filter { shown.contains($0.key) }
            tree.managedDetails = tree.managedDetails.filter { shown.contains($0.key) }
        }
        content = tree
        freshness = [tree.generatedAt.map { SidebarCopilotTree.isFresh($0, now: now) } ?? false]
        content.generatedAt = tree.generatedAt.map(Self.displayedMinute)
        for index in tree.sessions.indices {
            let observed = tree.sessions[index].observedAt
            freshness.append(SidebarCopilotTree.isFresh(observed, now: now))
            freshness.append(tree.generatedAt.map { observed <= $0.addingTimeInterval(1) } ?? false)
            content.sessions[index].observedAt = Self.displayedMinute(observed)
        }
        for index in tree.statusSessions.indices {
            content.statusSessions[index].observedAt = Self.displayedMinute(tree.statusSessions[index].observedAt)
        }
        for (id, details) in tree.managedDetails {
            // Dictionaries have no stable iteration order; retain this classification in the value.
            content.managedDetails[id] = .init(
                sessionName: details.sessionName, iconId: details.iconId, iconColor: details.iconColor,
                petId: details.petId,
                readAt: SidebarCopilotTree.isFresh(details.readAt, now: now) ? .distantFuture : .distantPast
            )
        }
    }

    private static func displayedMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }
}
