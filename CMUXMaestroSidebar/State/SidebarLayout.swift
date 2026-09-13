import Foundation
import Observation

enum SidebarDensity: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact, comfortable

    var id: Self { self }
    var title: String { self == .compact ? "Compact" : "Comfortable" }
    func spacing(_ compact: Double) -> Double { compact * (self == .compact ? 1 : 1.35) }
    var controlSize: Double { self == .compact ? 20 : 24 }
    func stacksActions(width: Double) -> Bool { width < (self == .compact ? 240 : 280) }

    func indentation(depth: Int, unresolved: Bool, width: Double) -> Double {
        // Deep trees must leave room for status and controls at narrow sidebar widths.
        min(Double(max(0, depth) + (unresolved ? 1 : 0)) * spacing(4), max(0, width * 0.15))
    }
}

struct SidebarExpansionID: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case workspace, surface, session, child }
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

    var isValid: Bool {
        switch kind {
        case .workspace, .surface:
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

struct SidebarLayoutSettings: Codable, Equatable, Sendable {
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

enum SidebarLayoutChange: Sendable {
    case density(SidebarDensity)
    case expansion(SidebarExpansionID, Bool)
    case expandAll
    case reset
}

struct SidebarLayoutRead: Equatable, Sendable {
    var settings = SidebarLayoutSettings()
    var notice: String? = nil
}

/// A coordinated read-modify-write merges one action, not a window's stale snapshot.
/// File coordination also serializes separate ExtensionKit processes in the same container.
struct SidebarLayoutFile: Sendable {
    let url: URL
    static var standard: Self {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(url: root.appendingPathComponent("CMUXMaestroPreview/sidebar-layout.json"))
    }
    static let unreadableNotice = "Layout settings could not be read. All branches are expanded. Reset layout settings to recover; history and attention are unchanged."
    static let saveNotice = "Layout settings could not be saved. All branches are expanded. Check local storage and retry or reset layout settings."

    func read(presenter: NSFilePresenter? = nil) -> SidebarLayoutRead {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        var result = SidebarLayoutRead(notice: Self.unreadableNotice)
        var error: NSError?
        NSFileCoordinator(filePresenter: presenter).coordinate(readingItemAt: url, options: [], error: &error) { coordinated in
            result = readUncoordinated(coordinated)
        }
        return error == nil ? result : .init(notice: Self.unreadableNotice)
    }

    func apply(_ change: SidebarLayoutChange, presenter: NSFilePresenter? = nil) -> SidebarLayoutRead {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .init(notice: Self.saveNotice)
        }
        var result = SidebarLayoutRead(notice: Self.saveNotice)
        var error: NSError?
        NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: url, options: .forMerging, error: &error) { coordinated in
            var current = readUncoordinated(coordinated)
            if case .reset = change { current = .init() }
            // Only the explicit reset action replaces corrupt or future-schema data.
            guard current.notice == nil else { result = current; return }
            var next = current.settings
            switch change {
            case .density(let value): next.setDensity(value)
            case .expansion(let id, let expanded):
                guard id.isValid else { result = current; return }
                next.setExpanded(expanded, for: id)
            case .expandAll:
                for id in next.collapsed { next.setExpanded(true, for: id) }
            case .reset: break
            }
            do {
                var data = try JSONEncoder().encode(next)
                // Large but valid IDs may exhaust the byte budget before the entry budget.
                while data.count > SidebarLayoutSettings.maximumStoredBytes, let oldest = next.collapsed.first {
                    next.setExpanded(true, for: oldest)
                    data = try JSONEncoder().encode(next)
                }
                guard next.isValid, data.count <= SidebarLayoutSettings.maximumStoredBytes else { return }
                try data.write(to: coordinated, options: .atomic)
                result = .init(settings: next)
            } catch {
                result = .init(notice: Self.saveNotice)
            }
        }
        return error == nil ? result : .init(notice: Self.saveNotice)
    }

    private func readUncoordinated(_ url: URL) -> SidebarLayoutRead {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        do {
            // Limit the read itself, not only the decoded result.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: SidebarLayoutSettings.maximumStoredBytes + 1) ?? Data()
            guard data.count <= SidebarLayoutSettings.maximumStoredBytes else {
                return .init(notice: Self.unreadableNotice)
            }
            let settings = try JSONDecoder().decode(SidebarLayoutSettings.self, from: data)
            guard settings.isValid else { return .init(notice: Self.unreadableNotice) }
            return .init(settings: settings)
        } catch {
            return .init(notice: Self.unreadableNotice)
        }
    }
}

@Observable
@MainActor
final class SidebarLayoutStore {
    static let shared = SidebarLayoutStore()
    private static let stores = NSHashTable<SidebarLayoutStore>.weakObjects()
    private let file: SidebarLayoutFile
    @ObservationIgnored private var presenter: SidebarLayoutPresenter?
    private(set) var value: SidebarLayoutRead

    init(file: SidebarLayoutFile = .standard) {
        self.file = file
        value = file.read()
        Self.stores.add(self)
        let presenter = SidebarLayoutPresenter(url: file.url) { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        self.presenter = presenter
        NSFileCoordinator.addFilePresenter(presenter)
    }

    deinit {
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
    }

    func refresh() {
        let next = file.read(presenter: presenter)
        if next != value { value = next }
    }

    func apply(_ change: SidebarLayoutChange) {
        value = file.apply(change, presenter: presenter)
        // Immediate local coherence; file presentation also observes other extension processes.
        for store in Self.stores.allObjects where store !== self && store.file.url == file.url {
            store.value = value
        }
    }

    private final class SidebarLayoutPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
        let presentedItemURL: URL?
        let presentedItemOperationQueue: OperationQueue
        private let changed: @Sendable () -> Void

        init(url: URL, changed: @escaping @Sendable () -> Void) {
            presentedItemURL = url
            self.changed = changed
            presentedItemOperationQueue = OperationQueue()
            presentedItemOperationQueue.maxConcurrentOperationCount = 1
            super.init()
        }

        func presentedItemDidChange() { changed() }
    }
}
