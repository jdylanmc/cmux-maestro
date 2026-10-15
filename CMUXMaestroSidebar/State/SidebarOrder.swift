import Foundation

/// Maestro-local sidebar order (ADR 0021). Never written back to CMUX.
nonisolated struct SidebarOrderScope: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case workspaces, surfaces }
    let kind: Kind
    /// CMUX window UUID for workspaces; CMUX workspace UUID for surfaces.
    let id: UUID

    static func workspaces(window: UUID) -> Self { .init(kind: .workspaces, id: window) }
    static func surfaces(workspace: UUID) -> Self { .init(kind: .surfaces, id: workspace) }
}

nonisolated struct SidebarOrderItem: Equatable, Sendable {
    let id: UUID
    /// Nil when CMUX did not report pin state. Unknown is never treated as unpinned
    /// (ADR 0002): such an item keeps its base position and cannot move or be a target.
    let pinned: Bool?
    /// Presentation block the row renders in (e.g. managed agents before other surfaces).
    /// Items never move between blocks.
    var block: Int = 0

    init(id: UUID, pinned: Bool?, block: Int = 0) {
        self.id = id
        self.pinned = pinned
        self.block = block
    }

    fileprivate var group: Group? { pinned.map { Group(block: block, pinned: $0) } }

    fileprivate struct Group: Hashable { let block: Int; let pinned: Bool }
}

nonisolated enum SidebarOrderPlacement: Equatable, Sendable {
    case before(UUID)
    case after(UUID)

    var target: UUID {
        switch self {
        case .before(let id), .after(let id): id
        }
    }
}

nonisolated enum SidebarOrderDirection: Sendable { case up, down }

nonisolated enum SidebarOrderRefusal: Error, Equatable, Sendable {
    case ambiguous, pinUnknown, unknownItem, outsideScope, acrossPinBoundary, acrossBlock, atEdge

    var notice: String {
        switch self {
        case .ambiguous: "CMUX reported the same item twice, so this list can't be reordered."
        case .pinUnknown: "CMUX did not report whether this item is pinned, so it can't be reordered."
        case .unknownItem: "That item is no longer shown. Nothing was moved."
        case .outsideScope: "Items move only among their siblings. Nothing was moved."
        case .acrossPinBoundary: "Pinned and unpinned items keep their own groups. Nothing was moved."
        case .acrossBlock: "Managed agents and other surfaces keep their own groups. Nothing was moved."
        case .atEdge: "Already at the edge of its group. Nothing was moved."
        }
    }
}

/// Pure ordering rules. The base order (CMUX's, or Maestro's default presentation of it)
/// is kept; a saved list only permutes items inside their own group.
nonisolated enum SidebarOrdering {
    /// Display order of `items` (base order) under `saved`.
    /// - Saved IDs keep their saved relative order; stale saved IDs are ignored.
    /// - An unsaved (new) item goes right after its base-order predecessor in the
    ///   same group, or first in the group when it has none.
    /// - Each group (block × pinned) keeps the positions the base gave it, so a
    ///   reorder never crosses the pin boundary or a presentation block.
    /// - Items with unknown pin state keep their base position.
    /// - Duplicate IDs leave the base order unchanged.
    static func display(_ items: [SidebarOrderItem], saved: [UUID]?) -> [UUID] {
        guard let saved, !saved.isEmpty, refusal(items) == nil else { return items.map(\.id) }
        var groups: [SidebarOrderItem.Group: [UUID]] = [:]
        for item in items { if let group = item.group { groups[group, default: []].append(item.id) } }
        return fill(items, groups.mapValues { merge($0, saved: saved) })
    }

    static func arrange<Value>(
        _ values: [Value], saved: [UUID]?, item: (Value) -> SidebarOrderItem
    ) -> [Value] {
        let items = values.map(item)
        guard isUnambiguous(items) else { return values }
        let byID = Dictionary(uniqueKeysWithValues: zip(items.map(\.id), values))
        return display(items, saved: saved).compactMap { byID[$0] }
    }

    /// Why the whole list can't be reordered, or nil.
    static func refusal(_ items: [SidebarOrderItem]) -> SidebarOrderRefusal? {
        isUnambiguous(items) ? nil : .ambiguous
    }

    /// New saved list after moving `id` next to the placement target, or a refusal.
    /// The result is the full display order of present items, so stale IDs are pruned.
    static func move(
        _ id: UUID, to placement: SidebarOrderPlacement, in items: [SidebarOrderItem], saved: [UUID]?
    ) -> Result<[UUID], SidebarOrderRefusal> {
        if let refusal = refusal(items) { return .failure(refusal) }
        guard let moving = items.first(where: { $0.id == id }) else { return .failure(.unknownItem) }
        guard let target = items.first(where: { $0.id == placement.target }) else { return .failure(.outsideScope) }
        guard moving.pinned != nil, target.pinned != nil else { return .failure(.pinUnknown) }
        guard moving.block == target.block else { return .failure(.acrossBlock) }
        guard moving.pinned == target.pinned else { return .failure(.acrossPinBoundary) }
        let current = display(items, saved: saved)
        guard id != target.id else { return .success(current) }
        let groupOf = Dictionary(uniqueKeysWithValues: items.compactMap { item in item.group.map { (item.id, $0) } })
        var groups: [SidebarOrderItem.Group: [UUID]] = [:]
        for itemID in current { if let group = groupOf[itemID] { groups[group, default: []].append(itemID) } }
        guard let key = moving.group, var group = groups[key]?.filter({ $0 != id }),
              let index = group.firstIndex(of: target.id) else { return .failure(.outsideScope) }
        if case .before = placement { group.insert(id, at: index) } else { group.insert(id, at: index + 1) }
        groups[key] = group
        return .success(fill(items, groups))
    }

    /// Placement for Move Up/Down among the rows actually shown, skipping other
    /// groups. Nil at the edge of the group.
    static func step(
        _ id: UUID, _ direction: SidebarOrderDirection, visible: [UUID], items: [SidebarOrderItem]
    ) -> SidebarOrderPlacement? {
        guard refusal(items) == nil, let moving = items.first(where: { $0.id == id }), moving.group != nil,
              let index = visible.firstIndex(of: id) else { return nil }
        let groupOf = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.group) })
        let candidates = direction == .up
            ? Array(visible[..<index].reversed()) : Array(visible[(index + 1)...])
        guard let neighbor = candidates.first(where: { groupOf[$0] == moving.group }) else { return nil }
        return direction == .up ? .before(neighbor) : .after(neighbor)
    }

    static func isUnambiguous(_ items: [SidebarOrderItem]) -> Bool {
        Set(items.map(\.id)).count == items.count
    }

    private static func merge(_ base: [UUID], saved: [UUID]) -> [UUID] {
        let present = Set(base)
        var seen: Set<UUID> = []
        var result = saved.filter { present.contains($0) && seen.insert($0).inserted }
        for (offset, id) in base.enumerated() where !seen.contains(id) {
            // Earlier base items are already placed, so the predecessor always exists.
            let position = offset == 0 ? 0 : (result.firstIndex(of: base[offset - 1]).map { $0 + 1 } ?? result.count)
            result.insert(id, at: position)
            seen.insert(id)
        }
        return result
    }

    private static func fill(_ items: [SidebarOrderItem], _ groups: [SidebarOrderItem.Group: [UUID]]) -> [UUID] {
        var slots = groups.mapValues { $0.makeIterator() }
        return items.compactMap { item in
            guard let group = item.group else { return item.id }
            return slots[group]?.next()
        }
    }
}

nonisolated struct SidebarOrderRecord: Codable, Equatable, Sendable {
    let scope: SidebarOrderScope
    var ids: [UUID]
}

/// `sidebar-order.json` in the sidebar's own container. Separate from layout,
/// history and acknowledgement records.
nonisolated struct SidebarOrderSettings: SidebarPreferenceValue {
    static let maximumScopes = 256
    static let maximumIDsPerScope = 512
    static let maximumStoredBytes = 1_048_576
    static let failOpen = Self()
    static let unreadableNotice = "Sidebar order could not be read. CMUX's order is shown. Reset sidebar order in settings to recover."
    static let saveNotice = "Sidebar order could not be saved. CMUX's order is unchanged. Check local storage and retry."

    var version = 1
    /// Least recently changed first. When full, surface lists are evicted before workspace lists.
    private(set) var records: [SidebarOrderRecord] = []

    var isValid: Bool {
        version == 1 && records.count <= Self.maximumScopes
            && Set(records.map(\.scope)).count == records.count
            && records.allSatisfy {
                !$0.ids.isEmpty && $0.ids.count <= Self.maximumIDsPerScope && Set($0.ids).count == $0.ids.count
            }
    }

    func ids(for scope: SidebarOrderScope) -> [UUID]? {
        records.first { $0.scope == scope }?.ids
    }

    mutating func move(
        _ id: UUID, to placement: SidebarOrderPlacement, in scope: SidebarOrderScope, items: [SidebarOrderItem]
    ) throws {
        switch SidebarOrdering.move(id, to: placement, in: items, saved: ids(for: scope)) {
        case .failure(let refusal):
            throw SidebarPreferenceRejection(notice: refusal.notice)
        case .success(let order):
            records.removeAll { $0.scope == scope }
            // Matching CMUX needs no record; this also keeps the file small.
            guard order != items.map(\.id) else { return }
            guard order.count <= Self.maximumIDsPerScope else {
                throw SidebarPreferenceRejection(notice: "This list is too long to reorder (limit 512). Nothing was moved.")
            }
            records.append(.init(scope: scope, ids: order))
            while records.count > Self.maximumScopes, evictOne(keeping: scope) {}
            while try JSONEncoder().encode(self).count > Self.maximumStoredBytes, evictOne(keeping: scope) {}
        }
    }

    /// Drops the least recently changed surface list first; a window's workspace list is
    /// saved rarely but read constantly, so it goes only when no surface list is left.
    private mutating func evictOne(keeping scope: SidebarOrderScope) -> Bool {
        let candidates = records.indices.filter { records[$0].scope != scope }
        guard let index = candidates.first(where: { records[$0].scope.kind == .surfaces }) ?? candidates.first else {
            return false
        }
        records.remove(at: index)
        return true
    }

    mutating func reset(_ scope: SidebarOrderScope) {
        records.removeAll { $0.scope == scope }
    }
}

nonisolated enum SidebarOrderChange: Sendable {
    case move(UUID, SidebarOrderPlacement, scope: SidebarOrderScope, items: [SidebarOrderItem])
    case reset(SidebarOrderScope)
    case resetAll

    var resets: Bool {
        if case .resetAll = self { return true }
        return false
    }

    func mutate(_ value: inout SidebarOrderSettings) throws {
        switch self {
        case .move(let id, let placement, let scope, let items): try value.move(id, to: placement, in: scope, items: items)
        case .reset(let scope): value.reset(scope)
        case .resetAll: break
        }
    }
}

/// Pure mapping from a drop location inside a row to an insertion placement.
nonisolated enum SidebarReorderDrop {
    static func placement(locationY: Double, height: Double, target: UUID) -> SidebarOrderPlacement {
        guard height.isFinite, height > 0, locationY.isFinite else { return .before(target) }
        return locationY < height / 2 ? .before(target) : .after(target)
    }
}
