import Foundation

/// A cosmetic expression and its honest basis, never work or completion evidence.
struct SidebarPetMood: Equatable {
    let mood: SidebarPetSheet.Mood
    let basis: String

    static let minimumMoodHold: TimeInterval = 3
    static let sleepyAfter: TimeInterval = 60
    static let confusedToolFailureThreshold: UInt8 = 3

    var preemptsHold: Bool { [.question, .needsPermission, .sad, .gone].contains(mood) }
    var description: String { "\(mood.title) · \(basis)" }

    static func resolve(_ input: SidebarPetMoodInput, now: Date) -> Self {
        let session = input.session
        // The projection has already removed stale or unbound observations.
        let attention = session?.attention ?? []
        if attention.contains(where: { $0.kind == .permission }) {
            return .init(mood: .needsPermission, basis: String(localized: "mood.basis.permission", defaultValue: "Pending permission"))
        }
        if attention.contains(where: { $0.kind == .answer }) {
            return .init(mood: .question, basis: String(localized: "mood.basis.question", defaultValue: "Pending answer"))
        }
        if session?.liveness == .dead {
            return .init(mood: .gone, basis: String(localized: "mood.basis.gone", defaultValue: "Process ended"))
        }
        guard input.observationAvailable, let session else {
            return .init(mood: .idle, basis: String(localized: "mood.basis.unavailable", defaultValue: "Observation unavailable"))
        }
        if session.state == .failed || session.nodes.contains(where: {
            $0.isInternalTask && !$0.historyAncestor && !$0.statusOnly && $0.state == .failed
                && $0.attention.contains(where: { $0.kind == .error })
        }) {
            return .init(mood: .sad, basis: String(localized: "mood.basis.failure", defaultValue: "Failure reported"))
        }
        let facts = session.presentation
        if session.state == .cancelled {
            if facts?.abortReason == .userAbort {
                return .init(mood: .startled, basis: String(localized: "mood.basis.abort", defaultValue: "User aborted"))
            }
            return .init(mood: .idle, basis: String(localized: "mood.basis.cancelled", defaultValue: "Cancelled; reason unknown or not a user abort"))
        }
        if facts?.errorCategory == .quota || facts?.errorCategory == .authorization
            || facts?.modelTrouble == true
            || (facts?.consecutiveToolFailures.map { $0 >= confusedToolFailureThreshold } ?? false) {
            return .init(mood: .confused, basis: String(localized: "mood.basis.trouble", defaultValue: "Observed technical difficulty"))
        }
        if let report = input.selfReport, (input.selfReportSequence ?? 0) > 0,
           let label = report.selfReportLabel {
            let mood: SidebarPetSheet.Mood
            switch report {
            case .happy: mood = .proud
            case .celebrating: mood = .celebrating
            case .confused: mood = .confused
            case .clear: mood = .idle
            }
            return .init(mood: mood, basis: label)
        }
        if facts?.compactionActive == true {
            return .init(mood: .compacting, basis: String(localized: "mood.basis.compacting", defaultValue: "Compaction active"))
        }
        if session.nodes.contains(where: { $0.isInternalTask && !$0.statusOnly && !$0.historyAncestor && $0.state == .working }) {
            return .init(mood: .delegating, basis: String(localized: "mood.basis.delegating", defaultValue: "Working internal task"))
        }
        if session.activity?.kind == .executing {
            return .init(mood: .working, basis: String(localized: "mood.basis.working", defaultValue: "Executing tool"))
        }
        if facts?.primaryTurnOpen == true {
            return .init(mood: .thinking, basis: String(localized: "mood.basis.thinking", defaultValue: "Primary turn open"))
        }
        if attention.contains(where: { $0.kind == .turnFinished }) {
            if let deadline = sleepyDeadline(input), now >= deadline {
                return .init(mood: .sleepy, basis: String(localized: "mood.basis.sleepy", defaultValue: "Turn finished; awaiting acknowledgement"))
            }
            if facts?.turnClean == true {
                return .init(mood: .content, basis: String(localized: "mood.basis.content", defaultValue: "Turn finished; observed clean, not proof of success"))
            }
        }
        return .init(mood: .idle, basis: session.state == .idle
                     ? String(localized: "mood.basis.idle", defaultValue: "Observed idle")
                     : String(localized: "mood.basis.neutral", defaultValue: "No specific mood established"))
    }

    static func sleepyDeadline(_ input: SidebarPetMoodInput) -> Date? {
        input.session?.attention.filter { $0.kind == .turnFinished }.compactMap(\.occurredAt).max()
            .map {
                // "Older than" excludes the boundary; wake at the first representable instant after it.
                let boundary = $0.addingTimeInterval(sleepyAfter).timeIntervalSinceReferenceDate
                return Date(timeIntervalSinceReferenceDate: boundary.nextUp)
            }
    }
}
