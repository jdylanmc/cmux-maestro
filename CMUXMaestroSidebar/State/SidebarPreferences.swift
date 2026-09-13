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
    private static let attentionKey = "sidebar.attention.v1"
    private let defaults: UserDefaults
    private let layoutStore: SidebarLayoutStore
    var layout: SidebarLayoutSettings { layoutStore.value.settings }
    var layoutNotice: String? { layoutStore.value.notice }
    private(set) var history: SidebarHistorySettings
    private(set) var historyNotice: String?
    private(set) var attention = SidebarAttentionSettings()
    private(set) var attentionNotice: String?

    var selectedMode: SidebarMode {
        didSet {
            guard selectedMode != oldValue else { return }
            defaults.set(selectedMode.rawValue, forKey: Self.selectedModeKey)
        }
    }

    init(defaults: UserDefaults = .standard, layoutStore: SidebarLayoutStore? = nil) {
        self.defaults = defaults
        self.layoutStore = layoutStore ?? .shared
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
        if let stored = defaults.object(forKey: Self.attentionKey) {
            if let data = stored as? Data, data.count <= SidebarAttentionSettings.maximumStoredBytes,
               let decoded = try? JSONDecoder().decode(SidebarAttentionSettings.self, from: data),
               decoded.isValid {
                attention = decoded
            } else {
                attentionNotice = "Acknowledgements could not be read. No attention is hidden. Reset acknowledgements to recover."
            }
        }
    }

    func setDensity(_ density: SidebarDensity) { layoutStore.apply(.density(density)) }
    func setExpanded(_ expanded: Bool, for id: SidebarExpansionID) { layoutStore.apply(.expansion(id, expanded)) }
    func expandAll() { layoutStore.apply(.expandAll) }
    func resetLayout() { layoutStore.apply(.reset) }
    func refreshLayout() { layoutStore.refresh() }

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

    func acknowledge(_ outcomes: Set<SidebarAcknowledgedOutcome>, in tree: SidebarCopilotTree) {
        // The current-window projection, not a captured row or persisted key,
        // decides eligibility. Blocking requests are never acknowledgement targets.
        let eligible = outcomes.intersection(tree.acknowledgeableOutcomes)
        guard !eligible.isEmpty else { return }
        var next = attention
        next.acknowledged.formUnion(eligible)
        guard next.isValid else {
            attentionNotice = "Acknowledgement storage is full or invalid (limit 2,048). Nothing new was acknowledged. Reset acknowledgements to free space."
            return
        }
        saveAttention(next)
    }

    func resetAcknowledgements() { saveAttention(SidebarAttentionSettings()) }

    private func saveAttention(_ next: SidebarAttentionSettings) {
        guard next.isValid, let data = try? JSONEncoder().encode(next),
              data.count <= SidebarAttentionSettings.maximumStoredBytes else {
            attentionNotice = "Acknowledgements could not be saved. Previous acknowledgements remain in use."
            return
        }
        defaults.set(data, forKey: Self.attentionKey)
        attention = next
        attentionNotice = nil
    }

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
