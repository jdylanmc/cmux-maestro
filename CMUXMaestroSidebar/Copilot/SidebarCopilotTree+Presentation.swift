import Foundation

extension SidebarCopilotTree {
    /// Fresh evidence still replaces stored values; minute-resolution "Observed" labels
    /// and actual presentation changes are the only reasons to invalidate the outline.
    func hasSamePresentation(as other: Self) -> Bool {
        var lhs = self
        var rhs = other
        lhs.normalizePresentationDates()
        rhs.normalizePresentationDates()
        return lhs == rhs
    }

    private mutating func normalizePresentationDates() {
        generatedAt = generatedAt.map(Self.displayMinute)
        nextHistoryExpiry = nil
        for index in sessions.indices { sessions[index].observedAt = Self.displayMinute(sessions[index].observedAt) }
        for index in statusSessions.indices {
            statusSessions[index].observedAt = Self.displayMinute(statusSessions[index].observedAt)
        }
        managedDetails = managedDetails.mapValues {
            .init(sessionName: $0.sessionName, iconId: $0.iconId, iconColor: $0.iconColor,
                  petId: $0.petId, readAt: .distantPast)
        }
    }

    private static func displayMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: floor(date.timeIntervalSinceReferenceDate / 60) * 60)
    }
}
