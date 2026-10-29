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
    private static let projectionKey = "sidebar.projection"
    private static let historyKey = "sidebar.completedHistory.v1"
    private static let attentionKey = "sidebar.attention.v1"
    private static let showEndedKey = "sidebar.showEnded"
    private static let pinnedFooterHeightKey = "sidebar.pinnedFooterHeight"
    private static let agentIconStyleKey = "sidebar.agentIconStyle"
    private static let terminalIconStyleKey = "sidebar.terminalIconStyle"
    private static let eventTailWindowKey = "sidebar.eventTailWindowMiB"
    private let defaults: UserDefaults
    private let notificationStore: SidebarPreferenceStore<SidebarNotificationSettings>
    var notificationsMuted: Bool { notificationStore.value.settings.muted }
    var notificationNotice: String? { notificationStore.value.notice }
    func setNotificationsMuted(_ muted: Bool) { notificationStore.apply { $0.muted = muted } }
    private let layoutStore: SidebarLayoutStore
    var layout: SidebarLayoutSettings { layoutStore.value.settings }
    var layoutNotice: String? { layoutStore.value.notice }
    private let historyStore: SidebarPreferenceStore<SidebarHistorySettings>
    private let attentionStore: SidebarPreferenceStore<SidebarAttentionSettings>
    private let iconStore: SidebarPreferenceStore<SidebarIconSettings>
    var icons: SidebarIconSettings { iconStore.value.settings }
    var iconNotice: String? { iconStore.value.notice }
    private let orderStore: SidebarPreferenceStore<SidebarOrderSettings>
    var order: SidebarOrderSettings { orderStore.value.settings }
    var orderNotice: String? { orderStore.value.notice }
    private let tagStore: SidebarPreferenceStore<SidebarTagSettings>
    var tagSettings: SidebarTagSettings { tagStore.value.settings }
    var tagNotice: String? { tagStore.value.notice }
    @ObservationIgnored private let agentTagsFile: SidebarAgentTagsFile?
    /// Whether Copilot still keeps a session's state; a full tag store drops only sessions it no longer keeps.
    @ObservationIgnored private let sessionRetained: (UUID) -> Bool
    /// Agents' own tags by exact session; the last good read stays when a later read fails.
    private(set) var agentTags: [UUID: [String]] = [:]
    var history: SidebarHistorySettings { historyStore.value.settings }
    var historyNotice: String? { historyStore.value.notice }
    var attention: SidebarAttentionSettings { attentionStore.value.settings }
    var attentionNotice: String? { attentionStore.value.notice }
    private(set) var eventTailWindowMiB = CopilotTailWindow.defaultMiB
    private(set) var eventTailWindowNotice: String?
    var showEnded: Bool {
        didSet { defaults.set(showEnded, forKey: Self.showEndedKey) }
    }
    /// Height the human dragged the Active window footer to; nil keeps the automatic size.
    var pinnedFooterHeight: Double? {
        didSet {
            if let pinnedFooterHeight, pinnedFooterHeight.isFinite, pinnedFooterHeight > 0 {
                defaults.set(pinnedFooterHeight, forKey: Self.pinnedFooterHeightKey)
            } else {
                defaults.removeObject(forKey: Self.pinnedFooterHeightKey)
            }
        }
    }
    var agentIconStyle: SidebarAgentIconStyle {
        didSet { defaults.set(agentIconStyle.rawValue, forKey: Self.agentIconStyleKey) }
    }
    var terminalIconStyle: SidebarTerminalIconStyle {
        didSet { defaults.set(terminalIconStyle.rawValue, forKey: Self.terminalIconStyleKey) }
    }

    /// One choice for every workspace in every window.
    var projection: SidebarProjection {
        didSet {
            guard projection != oldValue else { return }
            defaults.set(projection.rawValue, forKey: Self.projectionKey)
        }
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
            layoutStore: .shared, agentTagsFile: .standard(), sessionRetained: Self.copilotKeepsSession
        )
    }

    init(
        defaults: UserDefaults, historyFile: URL, attentionFile: URL, layoutStore: SidebarLayoutStore,
        iconFile: URL? = nil, orderFile: URL? = nil, tagFile: URL? = nil,
        agentTagsFile: SidebarAgentTagsFile? = nil, sessionRetained: @escaping (UUID) -> Bool = { _ in true }
    ) {
        self.defaults = defaults
        self.layoutStore = layoutStore
        notificationStore = SidebarPreferenceStore(
            file: .init(url: historyFile.deletingLastPathComponent().appendingPathComponent("sidebar-notifications.json")),
            initializeMissingFile: false, preserveSettingsOnSaveFailure: true
        )
        iconStore = SidebarPreferenceStore(
            file: .init(url: iconFile ?? historyFile.deletingLastPathComponent().appendingPathComponent("sidebar-icons.json")),
            initializeMissingFile: false, preserveSettingsOnSaveFailure: true
        )
        orderStore = SidebarPreferenceStore(
            file: .init(url: orderFile ?? historyFile.deletingLastPathComponent().appendingPathComponent("sidebar-order.json")),
            initializeMissingFile: false, preserveSettingsOnSaveFailure: true
        )
        tagStore = SidebarPreferenceStore(
            file: .init(url: tagFile ?? historyFile.deletingLastPathComponent().appendingPathComponent("sidebar-tags.json")),
            initializeMissingFile: false, preserveSettingsOnSaveFailure: true
        )
        self.agentTagsFile = agentTagsFile
        self.sessionRetained = sessionRetained
        if let stored = defaults.object(forKey: Self.eventTailWindowKey) {
            if let number = stored as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
               let value = stored as? Int, CopilotTailWindow.range.contains(value) {
                eventTailWindowMiB = value
            } else {
                eventTailWindowNotice = Self.invalidEventTailWindow
            }
        }
        showEnded = defaults.bool(forKey: Self.showEndedKey)
        let storedFooter = defaults.double(forKey: Self.pinnedFooterHeightKey)
        pinnedFooterHeight = storedFooter.isFinite && storedFooter > 0 ? storedFooter : nil
        agentIconStyle = defaults.string(forKey: Self.agentIconStyleKey)
            .flatMap(SidebarAgentIconStyle.init(rawValue:)) ?? .maestro
        terminalIconStyle = defaults.string(forKey: Self.terminalIconStyleKey)
            .flatMap(SidebarTerminalIconStyle.init(rawValue:)) ?? .ghost
        selectedMode = defaults.string(forKey: Self.selectedModeKey)
            .flatMap(SidebarMode.init(rawValue:)) ?? .hierarchy
        projection = defaults.string(forKey: Self.projectionKey)
            .flatMap(SidebarProjection.init(rawValue:)) ?? .subAgents
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
            let settings = try JSONDecoder().decode(SidebarAttentionSettings.self, from: data)
            guard data.count <= settings.maximumEncodedBytes else {
                throw SidebarPreferenceRejection(notice: SidebarAttentionSettings.unreadableNotice)
            }
            return settings
        }, migrated: {
            defaults.removeObject(forKey: Self.attentionKey)
        })
        refreshTags()
    }

    func setDensity(_ density: SidebarDensity) { layoutStore.apply(.density(density)) }
    func setEventTailWindowMiB(_ value: Int) {
        guard CopilotTailWindow.range.contains(value) else {
            eventTailWindowNotice = Self.invalidEventTailWindow
            return
        }
        defaults.set(value, forKey: Self.eventTailWindowKey)
        eventTailWindowMiB = value
        eventTailWindowNotice = nil
    }

    private static var invalidEventTailWindow: String {
        String(localized: "reader.tail.invalid", defaultValue: "Invalid event tail size")
    }
    func setExpanded(_ expanded: Bool, for id: SidebarExpansionID) { layoutStore.apply(.expansion(id, expanded)) }
    func expandAll() { layoutStore.apply(.expandAll) }
    func resetLayout() { layoutStore.apply(.reset) }
    func refreshLayout() { layoutStore.refresh() }
    func setIdleTasksVisible(_ visible: Bool, in workspaceID: UUID) {
        layoutStore.apply(.idleTasks(workspaceID, visible))
    }

    func dismissInternalTask(_ outcome: SidebarDismissedOutcome, in tree: SidebarCopilotTree, now: Date = Date()) -> Bool {
        guard [.ready, .partial].contains(tree.availability),
              let generatedAt = tree.generatedAt, SidebarCopilotTree.isFresh(generatedAt, now: now),
              let session = tree.sessions.first(where: { $0.id == outcome.sessionID }),
              SidebarCopilotTree.isFresh(session.observedAt, now: now),
              let node = session.nodes.first(where: { $0.id == outcome.childID }),
              node.isInternalTask, node.dismissibleOutcome(sessionID: session.id) == outcome else { return false }
        dismiss([outcome])
        return historyNotice == nil && history.dismissed.contains(outcome)
    }

    func setIcon(_ choice: SidebarIconChoice, for target: SidebarIconTarget) {
        iconStore.apply {
            guard SidebarGlyphName.isValid(choice.glyph) else {
                throw SidebarPreferenceRejection(notice: "That icon name is invalid. Choose an icon from the bundled font.")
            }
            $0.overrides[target.key] = .custom(choice)
            guard $0.isValid else {
                throw SidebarPreferenceRejection(notice: "Icon storage is full (2,048 items). Reset unused choices to free space.")
            }
        }
    }

    func resetIconToDefault(for target: SidebarIconTarget) {
        iconStore.apply {
            if case .session = target { $0.overrides[target.key] = .standard }
            else { $0.overrides.removeValue(forKey: target.key) }
        }
    }

    func resetIconToAgentSelection(for target: SidebarIconTarget) {
        iconStore.apply {
            guard case .session = target else {
                throw SidebarPreferenceRejection(notice: "This item has no agent selection. Use Reset to default instead.")
            }
            $0.overrides.removeValue(forKey: target.key)
        }
    }

    func resetIcons() { iconStore.apply(reset: true) { _ in } }
    func refreshIcons() { iconStore.refresh() }

    /// Tags for one exact session: the human's, then the agent's own, with shared colors.
    func tags(for session: UUID?) -> [SidebarResolvedTag] {
        guard let session else { return [] }
        return SidebarResolvedTag.resolve(
            human: tagSettings.assignments[SidebarTagSettings.key(session)] ?? [],
            agent: agentTags[session] ?? [], colors: tagSettings.colors
        )
    }

    func humanTags(for session: UUID) -> [String] { tagSettings.assignments[SidebarTagSettings.key(session)] ?? [] }

    /// Replaces the human's tags for one session; the agent's own tags are untouched.
    /// Returns why nothing was saved, or nil.
    @discardableResult
    func setHumanTags(_ input: String, for session: UUID) -> String? {
        saveTags(input, colors: [:], for: session)
    }

    /// A human color for every occurrence of `slug`; nil restores the automatic color.
    @discardableResult
    func setTagColor(_ swatch: SidebarTagSwatch?, for slug: String) -> String? {
        guard SidebarTagSlug.isCanonical(slug) else { return SidebarTagError.noLetterOrNumber.message }
        return applyTags { try Self.setColors([slug: swatch], in: &$0, agentSlugs: $1) }
    }

    /// One write for the tag editor: the session's tags (`input`, nil leaves them) and any colors
    /// (nil swatch restores automatic). Everything is saved, or nothing is. Returns why, or nil.
    @discardableResult
    func saveTags(_ input: String?, colors: [String: SidebarTagSwatch?], for session: UUID) -> String? {
        var slugs: [String]?
        if let input {
            do { slugs = try SidebarTagSlug.parse(input) } catch { return error.message }
        }
        guard colors.keys.allSatisfy(SidebarTagSlug.isCanonical) else { return SidebarTagError.noLetterOrNumber.message }
        let retained = sessionRetained
        return applyTags { settings, agentSlugs in
            if let slugs {
                let key = SidebarTagSettings.key(session)
                if !slugs.isEmpty, settings.assignments[key] == nil,
                   settings.assignments.count >= SidebarTagSettings.maximumEntries {
                    // Full: drop only sessions Copilot no longer keeps (ADR 0026); otherwise refuse.
                    settings.assignments = settings.assignments.filter { UUID(uuidString: $0.key).map(retained) ?? false }
                }
                if slugs.isEmpty { settings.assignments.removeValue(forKey: key) } else { settings.assignments[key] = slugs }
            }
            try Self.setColors(colors, in: &settings, agentSlugs: agentSlugs)
        }
    }

    private static func setColors(
        _ colors: [String: SidebarTagSwatch?], in settings: inout SidebarTagSettings, agentSlugs: Set<String>?
    ) throws {
        for (slug, swatch) in colors {
            // Full: drop colors for slugs no session carries; otherwise refuse. Without a current
            // agent-store read, agent-only slugs are unknown, so nothing is dropped.
            if swatch != nil, settings.colors[slug] == nil, settings.colors.count >= SidebarTagSettings.maximumEntries,
               let agentSlugs {
                let used = Set(settings.assignments.values.joined()).union(agentSlugs).union(colors.keys)
                settings.colors = settings.colors.filter { used.contains($0.key) }
            }
            settings.colors[slug] = swatch
        }
    }

    private func applyTags(_ mutation: (inout SidebarTagSettings, Set<String>?) throws -> Void) -> String? {
        // Pruning decides from a fresh agent read, never the display cache; a failed read is nil.
        let agentSlugs: Set<String>?
        if let agentTagsFile {
            agentSlugs = (try? agentTagsFile.read()).map { Set($0.values.joined()) }
        } else {
            agentSlugs = []
        }
        tagStore.apply {
            try mutation(&$0, agentSlugs)
            guard $0.isValid else { throw SidebarPreferenceRejection(notice: "Tag storage is full.") }
        }
        return tagNotice
    }

    /// Removes every human tag and color; agents' own tags are unchanged.
    func resetTags() { tagStore.apply(reset: true) { _ in } }

    nonisolated static func copilotKeepsSession(_ id: UUID) -> Bool {
        guard let root = try? CopilotPaths.sessionStateRoot() else { return true }
        return sessionKept(id, under: root)
    }

    /// Only a state root that is a directory, with this session's entry reported missing (ENOENT),
    /// proves the session is gone. Any other answer, including a denied lookup, keeps it.
    nonisolated static func sessionKept(_ id: UUID, under root: URL) -> Bool {
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return true }
        guard lstat(root.appendingPathComponent(id.uuidString.lowercased()).path, &info) != 0 else { return true }
        return errno != ENOENT
    }

    func refreshTags() {
        tagStore.refresh()
        guard let agentTagsFile else { return }
        // A failed read keeps the last good tags; nothing is dropped or guessed.
        if let next = try? agentTagsFile.read(), next != agentTags { agentTags = next }
    }

    /// Changes Maestro's sidebar order only; nothing is sent to CMUX (ADR 0021).
    func applyOrder(_ change: SidebarOrderChange) { orderStore.apply(reset: change.resets) { try change.mutate(&$0) } }
    func resetOrder() { applyOrder(.resetAll) }
    var hasSavedOrder: Bool { !order.records.isEmpty }
    func refreshOrder() { orderStore.refresh() }

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
            $0.version = 2
            $0.acknowledged.formUnion(eligible)
            guard $0.isValid,
                  try JSONEncoder().encode($0).count <= SidebarAttentionSettings.maximumStoredBytes else {
                throw SidebarPreferenceRejection(
                    notice: String(localized: "attention.storage.full", defaultValue: "Acknowledgement archive is full (20,480 identities / 4 MiB). Nothing new was acknowledged. Reset clears all saved acknowledgements; previously read notices may reappear.")
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
