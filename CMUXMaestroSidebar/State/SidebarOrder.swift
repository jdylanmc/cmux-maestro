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
    let pinned: Bool
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
    case ambiguous, unknownItem, outsideScope, acrossPinBoundary, atEdge

    var notice: String {
        switch self {
        case .ambiguous: "CMUX reported the same item twice, so Maestro's order is unavailable here."
        case .unknownItem: "That item is no longer shown. Nothing was moved."
        case .outsideScope: "Items move only among their siblings. Nothing was moved."
        case .acrossPinBoundary: "Pinned and unpinned items keep their own groups. Nothing was moved."
        case .atEdge: "Already at the edge of its group. Nothing was moved."
        }
    }
}

/// Pure ordering rules. CMUX's order is the base; a saved list only permutes it.
nonisolated enum SidebarOrdering {
    /// Display order of `items` (CMUX order) under `saved`.
    /// - Saved IDs keep their saved relative order; stale saved IDs are ignored.
    /// - An unsaved (new) item goes right after its CMUX-order predecessor in the
    ///   same pin group, or first in the group when it has none.
    /// - Pinned and unpinned items each keep the positions CMUX gave their group,
    ///   so reordering never moves an item across the pin boundary.
    /// - Duplicate IDs are ambiguous evidence: CMUX order is returned unchanged.
    static func display(_ items: [SidebarOrderItem], saved: [UUID]?) -> [UUID] {
        guard let saved, !saved.isEmpty, isUnambiguous(items) else { return items.map(\.id) }
        return fill(items, pinned: merge(items.filter(\.pinned).map(\.id), saved: saved),
                    unpinned: merge(items.filter { !$0.pinned }.map(\.id), saved: saved))
    }

    static func arrange<Value>(
        _ values: [Value], saved: [UUID]?, item: (Value) -> SidebarOrderItem
    ) -> [Value] {
        let items = values.map(item)
        guard isUnambiguous(items) else { return values }
        let byID = Dictionary(uniqueKeysWithValues: zip(items.map(\.id), values))
        return display(items, saved: saved).compactMap { byID[$0] }
    }

    /// New saved list after moving `id` next to the placement target, or a refusal.
    /// The result is the full display order of present items, so stale IDs are pruned.
    static func move(
        _ id: UUID, to placement: SidebarOrderPlacement, in items: [SidebarOrderItem], saved: [UUID]?
    ) -> Result<[UUID], SidebarOrderRefusal> {
        guard isUnambiguous(items) else { return .failure(.ambiguous) }
        guard let moving = items.first(where: { $0.id == id }) else { return .failure(.unknownItem) }
        guard let target = items.first(where: { $0.id == placement.target }) else { return .failure(.outsideScope) }
        guard moving.pinned == target.pinned else { return .failure(.acrossPinBoundary) }
        let current = display(items, saved: saved)
        guard id != target.id else { return .success(current) }
        let pinnedIDs = Set(items.filter(\.pinned).map(\.id))
        var group = current.filter { pinnedIDs.contains($0) == moving.pinned && $0 != id }
        guard let index = group.firstIndex(of: target.id) else { return .failure(.outsideScope) }
        if case .before = placement { group.insert(id, at: index) } else { group.insert(id, at: index + 1) }
        let other = current.filter { pinnedIDs.contains($0) != moving.pinned }
        return .success(fill(items, pinned: moving.pinned ? group : other, unpinned: moving.pinned ? other : group))
    }

    /// Placement for Move Up/Down among the rows actually shown, skipping the
    /// other pin group. Nil at the edge of the group.
    static func step(
        _ id: UUID, _ direction: SidebarOrderDirection, visible: [UUID], items: [SidebarOrderItem]
    ) -> SidebarOrderPlacement? {
        guard isUnambiguous(items), let moving = items.first(where: { $0.id == id }),
              let index = visible.firstIndex(of: id) else { return nil }
        let pinned = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.pinned) })
        let candidates = direction == .up
            ? Array(visible[..<index].reversed()) : Array(visible[(index + 1)...])
        guard let neighbor = candidates.first(where: { pinned[$0] == moving.pinned }) else { return nil }
        return direction == .up ? .before(neighbor) : .after(neighbor)
    }

    static func isUnambiguous(_ items: [SidebarOrderItem]) -> Bool {
        Set(items.map(\.id)).count == items.count
    }

    private static func merge(_ cmux: [UUID], saved: [UUID]) -> [UUID] {
        let present = Set(cmux)
        var seen: Set<UUID> = []
        var result = saved.filter { present.contains($0) && seen.insert($0).inserted }
        for (offset, id) in cmux.enumerated() where !seen.contains(id) {
            // Earlier CMUX items are already placed, so the predecessor always exists.
            let position = offset == 0 ? 0 : (result.firstIndex(of: cmux[offset - 1]).map { $0 + 1 } ?? result.count)
            result.insert(id, at: position)
            seen.insert(id)
        }
        return result
    }

    private static func fill(_ items: [SidebarOrderItem], pinned: [UUID], unpinned: [UUID]) -> [UUID] {
        var pinnedSlots = pinned.makeIterator(), unpinnedSlots = unpinned.makeIterator()
        return items.compactMap { $0.pinned ? pinnedSlots.next() : unpinnedSlots.next() }
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
    /// Least recently changed first; the oldest scope is evicted when full.
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
            if records.count > Self.maximumScopes { records.removeFirst(records.count - Self.maximumScopes) }
            while try JSONEncoder().encode(self).count > Self.maximumStoredBytes, records.count > 1 {
                records.removeFirst()
            }
        }
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
