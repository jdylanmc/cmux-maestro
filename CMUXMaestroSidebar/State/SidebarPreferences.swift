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
    private let historyStore: SidebarPreferenceStore<SidebarHistorySettings>
    var history: SidebarHistorySettings { historyStore.value.settings }
    var historyNotice: String? { historyStore.value.notice }

    var selectedMode: SidebarMode {
        didSet {
            guard selectedMode != oldValue else { return }
            defaults.set(selectedMode.rawValue, forKey: Self.selectedModeKey)
        }
    }

    convenience init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(defaults: .standard, historyFile: root.appendingPathComponent("CMUXMaestroPreview/sidebar-history.json"))
    }

    init(defaults: UserDefaults, historyFile: URL) {
        self.defaults = defaults
        selectedMode = defaults.string(forKey: Self.selectedModeKey)
            .flatMap(SidebarMode.init(rawValue:)) ?? .hierarchy
        historyStore = SidebarPreferenceStore(file: .init(url: historyFile), legacy: {
            guard let stored = defaults.object(forKey: Self.historyKey) else { return nil }
            guard let data = stored as? Data, data.count <= SidebarHistorySettings.maximumStoredBytes else {
                throw SidebarPreferenceRejection(notice: SidebarHistorySettings.unreadableNotice)
            }
            return try JSONDecoder().decode(SidebarHistorySettings.self, from: data)
        }, migrated: {
            // The successfully written file is the migration marker. Never mirror back a
            // window's snapshot; leave malformed legacy data untouched until explicit reset.
            defaults.removeObject(forKey: Self.historyKey)
        })
    }

    func setRetention(_ retention: SidebarHistoryRetention) {
        historyStore.apply { $0.retention = retention }
    }

    func dismiss(_ outcomes: Set<SidebarDismissedOutcome>) {
        guard !outcomes.isEmpty else { return }
        historyStore.apply {
            $0.dismissed.formUnion(outcomes)
            guard $0.isValid,
                  try JSONEncoder().encode($0).count <= SidebarHistorySettings.maximumStoredBytes else {
                throw SidebarPreferenceRejection(
                    notice: "Dismissal storage is full or invalid (limit 2,048 / 1 MiB). Nothing new was dismissed. Restore dismissed history to free space."
                )
            }
        }
    }

    func restoreDismissed() {
        historyStore.apply { $0.dismissed = [] }
    }

    func resetHistory() { historyStore.apply(reset: true) { _ in } }
}
