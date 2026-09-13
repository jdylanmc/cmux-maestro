import Foundation
import Observation

enum SidebarMode: String, CaseIterable, Identifiable {
    case hierarchy
    case taskboard

    var id: Self { self }

    var title: String {
        switch self {
        case .hierarchy:
            "Hierarchy"
        case .taskboard:
            "Taskboard"
        }
    }
}

@Observable
@MainActor
final class SidebarPreferences {
    private static let selectedModeKey = "sidebar.selectedMode"
    private static let historyKey = "sidebar.completedHistory.v1"
    private let defaults: UserDefaults
    private(set) var history: SidebarHistorySettings
    private(set) var historyNotice: String?

    var selectedMode: SidebarMode {
        didSet {
            guard selectedMode != oldValue else { return }
            defaults.set(selectedMode.rawValue, forKey: Self.selectedModeKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedMode = defaults.string(forKey: Self.selectedModeKey)
            .flatMap(SidebarMode.init(rawValue:)) ?? .hierarchy
        if let stored = defaults.object(forKey: Self.historyKey) {
            if let data = stored as? Data, data.count <= SidebarHistorySettings.maximumStoredBytes,
               let decoded = try? JSONDecoder().decode(SidebarHistorySettings.self, from: data),
               decoded.isValid {
                history = decoded
            } else {
                // Fail open: corrupt preferences must never silently hide work.
                history = SidebarHistorySettings(retention: .never)
                historyNotice = "History settings could not be read. Nothing is hidden by history controls. Reset history settings to recover."
            }
        } else {
            history = SidebarHistorySettings()
            save(history)
        }
    }

    func setRetention(_ retention: SidebarHistoryRetention) {
        var next = history
        next.retention = retention
        save(next)
    }

    func dismiss(_ outcomes: Set<SidebarDismissedOutcome>) {
        guard !outcomes.isEmpty else { return }
        var next = history
        next.dismissed.formUnion(outcomes)
        guard next.isValid else {
            historyNotice = "Dismissal storage is full or invalid (limit 2,048). Nothing new was dismissed. Restore dismissed history to free space."
            return
        }
        save(next)
    }

    func restoreDismissed() {
        var next = history
        next.dismissed = []
        save(next)
    }

    func resetHistory() { save(SidebarHistorySettings()) }

    private func save(_ next: SidebarHistorySettings) {
        guard next.isValid, let data = try? JSONEncoder().encode(next),
              data.count <= SidebarHistorySettings.maximumStoredBytes else {
            historyNotice = "History settings could not be saved. Previous history settings remain in use."
            return
        }
        defaults.set(data, forKey: Self.historyKey)
        history = next
        historyNotice = nil
    }
}
