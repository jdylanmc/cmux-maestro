import Foundation
import Observation

nonisolated protocol SidebarPreferenceValue: Codable, Equatable, Sendable {
    init()
    static var maximumStoredBytes: Int { get }
    static var failOpen: Self { get }
    static var unreadableNotice: String { get }
    static var saveNotice: String { get }
    var isValid: Bool { get }
}

nonisolated struct SidebarPreferenceRead<Value: SidebarPreferenceValue>: Equatable, Sendable {
    var settings: Value
    var notice: String?

    init(settings: Value = Value(), notice: String? = nil) {
        self.settings = settings
        self.notice = notice
    }
}

nonisolated struct SidebarPreferenceRejection: Error {
    let notice: String
}

/// The layout store's coordination pattern, shared without any feature-specific mutation logic.
nonisolated struct SidebarPreferenceFile<Value: SidebarPreferenceValue>: Sendable {
    let url: URL

    init(url: URL) {
        self.url = url.standardizedFileURL
    }

    func read(presenter: NSFilePresenter? = nil) -> SidebarPreferenceRead<Value> {
        var result = unreadable
        var error: NSError?
        NSFileCoordinator(filePresenter: presenter).coordinate(readingItemAt: url, options: [], error: &error) {
            result = readUncoordinated($0)
        }
        return error == nil ? result : unreadable
    }

    /// Migration and actions share the same lock. An existing file is always authoritative,
    /// including corrupt/future-schema files; only an explicit reset may replace those.
    func update(
        reset: Bool = false,
        initializeOnly: Bool = false,
        presenter: NSFilePresenter? = nil,
        legacy: () throws -> Value? = { nil },
        mutation: (inout Value) throws -> Void
    ) -> SidebarPreferenceRead<Value> {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .init(settings: .failOpen, notice: Value.saveNotice)
        }
        var result = SidebarPreferenceRead<Value>(settings: .failOpen, notice: Value.saveNotice)
        var error: NSError?
        NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: url, options: .forMerging, error: &error) { coordinated in
            let exists = FileManager.default.fileExists(atPath: coordinated.path)
            var current: SidebarPreferenceRead<Value>
            if reset {
                current = .init()
            } else if exists {
                current = readUncoordinated(coordinated)
            } else {
                do {
                    let initial = try legacy() ?? Value()
                    guard initial.isValid else { result = unreadable; return }
                    current = .init(settings: initial)
                } catch {
                    result = unreadable
                    return
                }
            }
            guard current.notice == nil else { result = current; return }
            if initializeOnly && exists { result = current; return }
            var next = current.settings
            do {
                try mutation(&next)
                let data = try JSONEncoder().encode(next)
                guard next.isValid, data.count <= Value.maximumStoredBytes else {
                    result = .init(settings: current.settings, notice: Value.saveNotice)
                    return
                }
                try data.write(to: coordinated, options: .atomic)
                result = .init(settings: next)
            } catch let rejection as SidebarPreferenceRejection {
                result = .init(settings: current.settings, notice: rejection.notice)
            } catch {
                result = .init(settings: .failOpen, notice: Value.saveNotice)
            }
        }
        return error == nil ? result : .init(settings: .failOpen, notice: Value.saveNotice)
    }

    private var unreadable: SidebarPreferenceRead<Value> {
        .init(settings: .failOpen, notice: Value.unreadableNotice)
    }

    private func readUncoordinated(_ url: URL) -> SidebarPreferenceRead<Value> {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Value.maximumStoredBytes + 1) ?? Data()
            guard data.count <= Value.maximumStoredBytes else { return unreadable }
            let settings = try JSONDecoder().decode(Value.self, from: data)
            guard settings.isValid else { return unreadable }
            return .init(settings: settings)
        } catch {
            return unreadable
        }
    }
}

@MainActor
private enum SidebarPreferenceStores {
    static let all = NSHashTable<AnyObject>.weakObjects()
}

@Observable
@MainActor
final class SidebarPreferenceStore<Value: SidebarPreferenceValue> {
    private let file: SidebarPreferenceFile<Value>
    @ObservationIgnored private let legacy: () throws -> Value?
    @ObservationIgnored private let migrated: () -> Void
    @ObservationIgnored private var presenter: SidebarPreferencePresenter?
    private(set) var value: SidebarPreferenceRead<Value>

    init(
        file: SidebarPreferenceFile<Value>,
        legacy: @escaping () throws -> Value? = { nil },
        migrated: @escaping () -> Void = {}
    ) {
        self.file = file
        self.legacy = legacy
        self.migrated = migrated
        value = file.update(initializeOnly: true, legacy: legacy) { _ in }
        if value.notice == nil { migrated() }
        SidebarPreferenceStores.all.add(self)
        let presenter = SidebarPreferencePresenter(url: file.url) { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        self.presenter = presenter
        NSFileCoordinator.addFilePresenter(presenter)
        // Close the read/register race without writing or restarting migration.
        refresh()
    }

    deinit {
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
    }

    func apply(reset: Bool = false, _ mutation: (inout Value) throws -> Void) {
        value = file.update(reset: reset, presenter: presenter, legacy: legacy, mutation: mutation)
        if value.notice == nil { migrated() }
        // Same-process windows converge immediately; presenters cover sibling processes.
        for case let store as SidebarPreferenceStore<Value> in SidebarPreferenceStores.all.allObjects
        where store !== self && store.file.url == file.url {
            store.value = value
        }
    }

    private func refresh() {
        let next = file.read(presenter: presenter)
        if next != value { value = next }
    }
}

private nonisolated final class SidebarPreferencePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
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
