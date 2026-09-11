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
    private let defaults: UserDefaults

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
    }
}
