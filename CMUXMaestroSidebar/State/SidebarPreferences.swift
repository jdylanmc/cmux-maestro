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

enum SidebarAgentIconStyle: String, CaseIterable, Identifiable {
    case maestro, copilot
    var id: Self { self }
    var title: String { self == .maestro ? "Maestro bot" : "Copilot" }
}

enum SidebarTerminalIconStyle: String, CaseIterable, Identifiable {
    case ghost, cli
    var id: Self { self }
    var title: String { self == .ghost ? "Ghost" : ">_" }
    var glyph: String { self == .ghost ? "md-ghost" : "md-console_line" }
}

@Observable
@MainActor
final class SidebarPreferences {
    private static let selectedModeKey = "sidebar.selectedMode"
    private static let historyKey = "sidebar.completedHistory.v1"
    private static let attentionKey = "sidebar.attention.v1"
    private static let showEndedKey = "sidebar.showEnded"
    private static let agentIconStyleKey = "sidebar.agentIconStyle"
    private static let terminalIconStyleKey = "sidebar.terminalIconStyle"
    private let defaults: UserDefaults
    private let layoutStore: SidebarLayoutStore
    var layout: SidebarLayoutSettings { layoutStore.value.settings }
    var layoutNotice: String? { layoutStore.value.notice }
    private let historyStore: SidebarPreferenceStore<SidebarHistorySettings>
    private let attentionStore: SidebarPreferenceStore<SidebarAttentionSettings>
    var history: SidebarHistorySettings { historyStore.value.settings }
    var historyNotice: String? { historyStore.value.notice }
    var attention: SidebarAttentionSettings { attentionStore.value.settings }
    var attentionNotice: String? { attentionStore.value.notice }
    var showEnded: Bool {
        didSet { defaults.set(showEnded, forKey: Self.showEndedKey) }
    }
    var agentIconStyle: SidebarAgentIconStyle {
        didSet { defaults.set(agentIconStyle.rawValue, forKey: Self.agentIconStyleKey) }
    }
    var terminalIconStyle: SidebarTerminalIconStyle {
        didSet { defaults.set(terminalIconStyle.rawValue, forKey: Self.terminalIconStyleKey) }
    }

    var selectedMode: SidebarMode {
        didSet {
            guard selectedMode != oldValue else { return }
            defaults.set(selectedMode.rawValue, forKey: Self.selectedModeKey)
        }
    }

    convenience init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(
            defaults: .standard,
            historyFile: root.appendingPathComponent("CMUXMaestroPreview/sidebar-history.json"),
            attentionFile: root.appendingPathComponent("CMUXMaestroPreview/sidebar-attention.json"),
            layoutStore: .shared
        )
    }

    init(defaults: UserDefaults, historyFile: URL, attentionFile: URL, layoutStore: SidebarLayoutStore) {
        self.defaults = defaults
        self.layoutStore = layoutStore
        showEnded = defaults.bool(forKey: Self.showEndedKey)
        agentIconStyle = defaults.string(forKey: Self.agentIconStyleKey)
            .flatMap(SidebarAgentIconStyle.init(rawValue:)) ?? .maestro
        terminalIconStyle = defaults.string(forKey: Self.terminalIconStyleKey)
            .flatMap(SidebarTerminalIconStyle.init(rawValue:)) ?? .ghost
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
        attentionStore = SidebarPreferenceStore(file: .init(url: attentionFile), legacy: {
            guard let stored = defaults.object(forKey: Self.attentionKey) else { return nil }
            guard let data = stored as? Data, data.count <= SidebarAttentionSettings.maximumStoredBytes else {
                throw SidebarPreferenceRejection(notice: SidebarAttentionSettings.unreadableNotice)
            }
            return try JSONDecoder().decode(SidebarAttentionSettings.self, from: data)
        }, migrated: {
            defaults.removeObject(forKey: Self.attentionKey)
        })
    }

    func setDensity(_ density: SidebarDensity) { layoutStore.apply(.density(density)) }
    func setExpanded(_ expanded: Bool, for id: SidebarExpansionID) { layoutStore.apply(.expansion(id, expanded)) }
    func expandAll() { layoutStore.apply(.expandAll) }
    func resetLayout() { layoutStore.apply(.reset) }
    func refreshLayout() { layoutStore.refresh() }

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
        historyStore.apply { $0.dismissed = []; $0.dismissedManaged = nil }
    }

    func resetHistory() { historyStore.apply(reset: true) { _ in } }

    func acknowledge(_ outcomes: Set<SidebarAcknowledgedOutcome>, in tree: SidebarCopilotTree) {
        // The current-window projection, not a captured row or persisted key,
        // decides eligibility. Blocking requests are never acknowledgement targets.
        let eligible = outcomes.intersection(tree.acknowledgeableOutcomes)
        guard !eligible.isEmpty else { return }
        attentionStore.apply {
            $0.acknowledged.formUnion(eligible)
            guard $0.isValid,
                  try JSONEncoder().encode($0).count <= SidebarAttentionSettings.maximumStoredBytes else {
                throw SidebarPreferenceRejection(
                    notice: "Acknowledgement storage is full or invalid (limit 2,048 / 1 MiB). Nothing new was acknowledged. Reset acknowledgements to free space."
                )
            }
        }
    }

    func resetAcknowledgements() { attentionStore.apply(reset: true) { _ in } }

    func dismissManaged(_ outcome: SidebarDismissedManagedOutcome) {
        historyStore.apply {
            $0.dismissedManaged = ($0.dismissedManaged ?? []).union([outcome])
            guard $0.isValid,
                  try JSONEncoder().encode($0).count <= SidebarHistorySettings.maximumStoredBytes else {
                throw SidebarPreferenceRejection(
                    notice: "Dismissal storage is full or invalid. Nothing new was hidden. Restore dismissed history to free space."
                )
            }
        }
    }
}
