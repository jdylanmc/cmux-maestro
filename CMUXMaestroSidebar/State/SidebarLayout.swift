import Foundation
import Observation

nonisolated enum SidebarDensity: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact, comfortable

    var id: Self { self }
    var title: String { self == .compact ? "Compact" : "Comfortable" }
    func spacing(_ compact: Double) -> Double { compact * (self == .compact ? 1 : 1.35) }
    var controlSize: Double { self == .compact ? 20 : 24 }
    var rowHeight: Double { self == .compact ? 46 : 52 }
    var rowTitleSize: Double { self == .compact ? 11 : 12 }
    var rowMetadataSize: Double { self == .compact ? 9 : 10 }
    func stacksActions(width: Double) -> Bool { width < (self == .compact ? 240 : 280) }

    func indentation(depth: Int, unresolved: Bool, width: Double) -> Double {
        let level = max(0, depth) + (unresolved ? 1 : 0)
        let points = Double(min(level, 3) * 8 + max(0, level - 3) * 4)
        return min(spacing(points), max(0, min(32, width * 0.12)))
    }
}

nonisolated struct SidebarExpansionID: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case workspace, surface, session, child, managed }
    let kind: Kind
    let id: UUID
    var provider: String? = nil
    var childID: String? = nil

    static func workspace(_ id: UUID) -> Self { .init(kind: .workspace, id: id) }
    static func surface(_ id: UUID) -> Self { .init(kind: .surface, id: id) }
    static func session(_ id: UUID, provider: String = "copilot") -> Self {
        .init(kind: .session, id: id, provider: provider)
    }
    static func child(_ childID: String, sessionID: UUID, provider: String = "copilot") -> Self {
        .init(kind: .child, id: sessionID, provider: provider, childID: childID)
    }
    static func managed(_ id: UUID) -> Self { .init(kind: .managed, id: id) }

    var isValid: Bool {
        switch kind {
        case .workspace, .surface, .managed:
            return provider == nil && childID == nil
        case .session, .child:
            guard let provider, !provider.isEmpty, provider.utf8.count <= 64,
                  provider.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
                return false
            }
            if kind == .session { return childID == nil }
            guard let childID, !childID.isEmpty, childID.utf8.count <= 512 else { return false }
            return !childID.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
    }
}

nonisolated struct SidebarLayoutSettings: Codable, Equatable, Sendable {
    static let maximumOverrides = 2_048
    static let maximumStoredBytes = 1_048_576
    var version = 1
    // Nil/absent means the original density. Expanded rows never need stored entries.
    var densityOverride: SidebarDensity? = nil
    private(set) var collapsed: [SidebarExpansionID] = []

    var density: SidebarDensity { densityOverride ?? .compact }
    var isValid: Bool {
        version == 1 && collapsed.count <= Self.maximumOverrides
            && collapsed.allSatisfy(\.isValid) && Set(collapsed).count == collapsed.count
    }

    func isExpanded(_ id: SidebarExpansionID) -> Bool { !collapsed.contains(id) }

    mutating func setDensity(_ value: SidebarDensity) {
        densityOverride = value == .compact ? nil : value
    }

    mutating func setExpanded(_ expanded: Bool, for id: SidebarExpansionID) {
        guard id.isValid else { return }
        collapsed.removeAll { $0 == id }
        if !expanded { collapsed.append(id) }
        // Eviction can only reveal more work; never prune from a window's topology.
        if collapsed.count > Self.maximumOverrides {
            collapsed.removeFirst(collapsed.count - Self.maximumOverrides)
        }
    }
}

nonisolated enum SidebarLayoutChange: Sendable {
    case density(SidebarDensity)
    case expansion(SidebarExpansionID, Bool)
    case expandAll
    case reset

    var isValid: Bool {
        if case .expansion(let id, _) = self { return id.isValid }
        return true
    }

    var resets: Bool {
        if case .reset = self { return true }
        return false
    }

    func mutate(_ value: inout SidebarLayoutSettings) throws {
        switch self {
        case .density(let density): value.setDensity(density)
        case .expansion(let id, let expanded): value.setExpanded(expanded, for: id)
        case .expandAll:
            for id in value.collapsed { value.setExpanded(true, for: id) }
        case .reset: break
        }
        // Large valid identities may exhaust the byte budget before the entry budget.
        while try JSONEncoder().encode(value).count > SidebarLayoutSettings.maximumStoredBytes,
              let oldest = value.collapsed.first {
            value.setExpanded(true, for: oldest)
        }
    }
}

typealias SidebarLayoutRead = SidebarPreferenceRead<SidebarLayoutSettings>

extension SidebarLayoutSettings: SidebarPreferenceValue {
    nonisolated static var failOpen: Self { .init() }
    nonisolated static var unreadableNotice: String { SidebarLayoutFile.unreadableNotice }
    nonisolated static var saveNotice: String { SidebarLayoutFile.saveNotice }
}

nonisolated struct SidebarLayoutFile: Sendable {
    let url: URL
    var coordinatedFile: SidebarPreferenceFile<SidebarLayoutSettings> { .init(url: url) }
    static var standard: Self {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(url: root.appendingPathComponent("CMUXMaestroPreview/sidebar-layout.json"))
    }
    static let unreadableNotice = "Layout settings could not be read. All branches are expanded. Reset layout settings to recover; history and attention are unchanged."
    static let saveNotice = "Layout settings could not be saved. All branches are expanded. Check local storage and retry or reset layout settings."

    func read(presenter: NSFilePresenter? = nil) -> SidebarLayoutRead {
        coordinatedFile.read(presenter: presenter, defaultsWhenMissing: true)
    }

    func apply(_ change: SidebarLayoutChange, presenter: NSFilePresenter? = nil) -> SidebarLayoutRead {
        guard change.isValid else { return read(presenter: presenter) }
        return coordinatedFile.update(reset: change.resets, presenter: presenter) { try change.mutate(&$0) }
    }
}

@Observable
@MainActor
final class SidebarLayoutStore {
    static let shared = SidebarLayoutStore()
    private let store: SidebarPreferenceStore<SidebarLayoutSettings>
    var value: SidebarLayoutRead { store.value }

    init(file: SidebarLayoutFile = .standard) {
        store = SidebarPreferenceStore(file: file.coordinatedFile, initializeMissingFile: false)
    }

    func refresh() {
        store.refresh()
    }

    func apply(_ change: SidebarLayoutChange) {
        guard change.isValid else { store.refresh(); return }
        store.apply(reset: change.resets) { try change.mutate(&$0) }
    }
}
