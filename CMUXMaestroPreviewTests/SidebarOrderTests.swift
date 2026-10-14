import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct SidebarOrderTests {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    private func items(_ ids: [UUID], pinned: Set<UUID> = []) -> [SidebarOrderItem] {
        ids.map { SidebarOrderItem(id: $0, pinned: pinned.contains($0)) }
    }

    @Test func withoutSavedOrderCMUXOrderIsShownUnchanged() {
        let cmux = items([a, b, c])
        #expect(SidebarOrdering.display(cmux, saved: nil) == [a, b, c])
        #expect(SidebarOrdering.display(cmux, saved: []) == [a, b, c])
    }

    @Test func savedIDsKeepRelativeOrderAndNewItemsFollowTheirCMUXPredecessor() {
        // b follows a and d follows c in CMUX, so each lands right after that predecessor.
        #expect(SidebarOrdering.display(items([a, b, c, d]), saved: [c, a]) == [c, d, a, b])
        // A new first item has no predecessor and goes first.
        #expect(SidebarOrdering.display(items([e, a, b]), saved: [b, a]) == [e, b, a])
        // Consecutive new items keep their CMUX order.
        #expect(SidebarOrdering.display(items([a, d, e, b]), saved: [b, a]) == [b, a, d, e])
    }

    @Test func staleSavedIDsAreIgnoredAndPrunedOnTheNextSave() throws {
        let stale = UUID()
        let cmux = items([a, b, c])
        #expect(SidebarOrdering.display(cmux, saved: [stale, c, stale, b, a]) == [c, b, a])
        let moved = try SidebarOrdering.move(a, to: .before(c), in: cmux, saved: [stale, c, b, a]).get()
        #expect(moved == [a, c, b])
        #expect(!moved.contains(stale))
    }

    @Test func pinnedItemsStayInTheirGroupsSlots() {
        let cmux = items([a, b, c, d], pinned: [a, b])
        // Saved order mixes groups; each group keeps CMUX's slots.
        #expect(SidebarOrdering.display(cmux, saved: [d, b, c, a]) == [b, a, d, c])
        #expect(SidebarOrdering.move(c, to: .before(a), in: cmux, saved: nil) == .failure(.acrossPinBoundary))
        #expect(SidebarOrdering.move(a, to: .after(d), in: cmux, saved: nil) == .failure(.acrossPinBoundary))
        #expect(SidebarOrdering.move(b, to: .before(a), in: cmux, saved: nil) == .success([b, a, c, d]))
        // The first unpinned item cannot step up into the pinned group.
        #expect(SidebarOrdering.step(c, .up, visible: [a, b, c, d], items: cmux) == nil)
        #expect(SidebarOrdering.step(b, .down, visible: [a, b, c, d], items: cmux) == nil)
        // Interleaved pin slots (surfaces across panes) are skipped, not crossed.
        let interleaved = items([a, c, b, d], pinned: [a, b])
        #expect(SidebarOrdering.step(b, .up, visible: [a, c, b, d], items: interleaved) == .before(a))
        #expect(SidebarOrdering.move(b, to: .before(a), in: interleaved, saved: nil) == .success([b, c, a, d]))
    }

    @Test func movesNeverCrossTheWorkspaceBoundary() throws {
        let other = UUID()
        let workspaceA = SidebarOrderScope.surfaces(workspace: UUID())
        let workspaceB = SidebarOrderScope.surfaces(workspace: UUID())
        #expect(SidebarOrdering.move(a, to: .before(other), in: items([a, b]), saved: nil) == .failure(.outsideScope))
        #expect(SidebarOrdering.move(other, to: .before(a), in: items([a, b]), saved: nil) == .failure(.unknownItem))
        var settings = SidebarOrderSettings()
        try settings.move(b, to: .before(a), in: workspaceA, items: items([a, b]))
        #expect(settings.ids(for: workspaceA) == [b, a])
        #expect(settings.ids(for: workspaceB) == nil)
        #expect(throws: SidebarPreferenceRejection.self) {
            try settings.move(c, to: .before(a), in: workspaceB, items: items([c, d]))
        }
        #expect(settings.ids(for: workspaceB) == nil && settings.ids(for: workspaceA) == [b, a])
    }

    @Test func moveUpAndDownStopAtTheEdgesAndFollowVisibleRows() {
        let cmux = items([a, b, c, d])
        let visible = [a, b, c, d]
        #expect(SidebarOrdering.step(a, .up, visible: visible, items: cmux) == nil)
        #expect(SidebarOrdering.step(d, .down, visible: visible, items: cmux) == nil)
        #expect(SidebarOrdering.step(b, .up, visible: visible, items: cmux) == .before(a))
        #expect(SidebarOrdering.step(b, .down, visible: visible, items: cmux) == .after(c))
        // A row hidden from this list (e.g. a managed surface) is stepped over.
        #expect(SidebarOrdering.step(c, .up, visible: [a, c, d], items: cmux) == .before(a))
        #expect(SidebarOrdering.move(b, to: .after(c), in: cmux, saved: nil) == .success([a, c, b, d]))
        #expect(SidebarOrdering.move(d, to: .before(a), in: cmux, saved: nil) == .success([d, a, b, c]))
        #expect(SidebarOrdering.move(b, to: .before(b), in: cmux, saved: nil) == .success([a, b, c, d]))
    }

    @Test func duplicateCMUXIdentityIsAmbiguousAndKeepsCMUXOrder() {
        let cmux = items([a, b, a])
        #expect(SidebarOrdering.display(cmux, saved: [b, a]) == [a, b, a])
        #expect(SidebarOrdering.move(b, to: .before(a), in: cmux, saved: nil) == .failure(.ambiguous))
        #expect(SidebarOrdering.step(b, .up, visible: [a, b], items: cmux) == nil)
    }

    @Test func returningToCMUXOrderAndResetDropTheRecord() throws {
        let scope = SidebarOrderScope.workspaces(window: UUID())
        let other = SidebarOrderScope.surfaces(workspace: UUID())
        var settings = SidebarOrderSettings()
        try settings.move(c, to: .before(a), in: scope, items: items([a, b, c]))
        #expect(settings.ids(for: scope) == [c, a, b])
        try settings.move(c, to: .after(b), in: scope, items: items([a, b, c]))
        #expect(settings.ids(for: scope) == nil && settings.records.isEmpty)
        try settings.move(b, to: .before(a), in: scope, items: items([a, b]))
        try settings.move(d, to: .before(c), in: other, items: items([c, d]))
        try SidebarOrderChange.reset(scope).mutate(&settings)
        #expect(settings.ids(for: scope) == nil && settings.ids(for: other) == [d, c])
        #expect(SidebarOrderChange.resetAll.resets && !SidebarOrderChange.reset(scope).resets)
    }

    @Test func scopeCountIsCappedByEvictingTheLeastRecentlyChanged() throws {
        var settings = SidebarOrderSettings()
        let first = SidebarOrderScope.surfaces(workspace: UUID())
        try settings.move(b, to: .before(a), in: first, items: items([a, b]))
        for _ in 0..<SidebarOrderSettings.maximumScopes {
            try settings.move(b, to: .before(a), in: .surfaces(workspace: UUID()), items: items([a, b]))
        }
        #expect(settings.records.count == SidebarOrderSettings.maximumScopes)
        #expect(settings.ids(for: first) == nil)
        #expect(settings.isValid)
    }

    @Test func dropLocationMapsToTheNearerRowEdge() {
        #expect(SidebarReorderDrop.placement(locationY: 0, height: 40, target: a) == .before(a))
        #expect(SidebarReorderDrop.placement(locationY: 19.9, height: 40, target: a) == .before(a))
        #expect(SidebarReorderDrop.placement(locationY: 20, height: 40, target: a) == .after(a))
        #expect(SidebarReorderDrop.placement(locationY: 60, height: 40, target: a) == .after(a))
        #expect(SidebarReorderDrop.placement(locationY: 10, height: 0, target: a) == .before(a))
        #expect(SidebarReorderDrop.placement(locationY: .nan, height: 40, target: a) == .before(a))
    }

    @Test func orderPersistsInItsOwnContainerFileAndLeavesOtherPreferencesAlone() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let scope = SidebarOrderScope.workspaces(window: UUID())
        let layout = preferences.layout, history = preferences.history, icons = preferences.icons
        preferences.applyOrder(.move(c, .before(a), scope: scope, items: items([a, b, c])))
        #expect(preferences.orderNotice == nil)
        let file = fixture.root.appendingPathComponent("sidebar-order.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.layoutFile.path))
        let reconstructed = fixture.preferences()
        #expect(reconstructed.order.ids(for: scope) == [c, a, b])
        #expect(reconstructed.layout == layout && reconstructed.history == history && reconstructed.icons == icons)

        reconstructed.applyOrder(.move(a, .before(c), scope: scope, items: items([a, b, c, d], pinned: [d])))
        #expect(reconstructed.orderNotice == nil)
        #expect(fixture.preferences().order.ids(for: scope) == [a, c, b, d])

        preferences.applyOrder(.move(d, .before(a), scope: scope, items: items([a, b, c, d], pinned: [d])))
        #expect(preferences.orderNotice == SidebarOrderRefusal.acrossPinBoundary.notice)
        #expect(fixture.preferences().order.ids(for: scope) == [a, c, b, d])

        preferences.resetOrder()
        #expect(preferences.order.records.isEmpty && preferences.orderNotice == nil)
        #expect(fixture.preferences().order.records.isEmpty)
    }

    @Test func unreadableOrderFallsBackToCMUXOrderUntilReset() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let file = fixture.root.appendingPathComponent("sidebar-order.json")
        try Data("{\"version\":2,\"records\":[]}".utf8).write(to: file)
        let preferences = fixture.preferences()
        #expect(preferences.orderNotice == SidebarOrderSettings.unreadableNotice)
        #expect(preferences.order.records.isEmpty)
        let scope = SidebarOrderScope.workspaces(window: UUID())
        preferences.applyOrder(.move(b, .before(a), scope: scope, items: items([a, b])))
        #expect(preferences.orderNotice == SidebarOrderSettings.unreadableNotice)
        #expect(try Data(contentsOf: file) == Data("{\"version\":2,\"records\":[]}".utf8))
        preferences.resetOrder()
        #expect(preferences.orderNotice == nil)
        preferences.applyOrder(.move(b, .before(a), scope: scope, items: items([a, b])))
        #expect(fixture.preferences().order.ids(for: scope) == [b, a])
    }

    @Test func aNewPinnedItemInAnInterleavedListFollowsItsPinnedPredecessor() {
        let n = UUID()
        // CMUX: a(p) c n(p) b(p) d. Saved: b a d c. n follows a, its pinned CMUX predecessor.
        let cmux = items([a, c, n, b, d], pinned: [a, n, b])
        #expect(SidebarOrdering.display(cmux, saved: [b, a, d, c]) == [b, d, a, n, c])
    }

    @Test func unknownPinStateKeepsTheItemInPlaceAndUnmovable() {
        let cmux = [SidebarOrderItem(id: a, pinned: false), SidebarOrderItem(id: b, pinned: nil),
                    SidebarOrderItem(id: c, pinned: false)]
        #expect(SidebarOrdering.display(cmux, saved: [c, a]) == [c, b, a])
        #expect(SidebarOrdering.move(b, to: .before(a), in: cmux, saved: nil) == .failure(.pinUnknown))
        #expect(SidebarOrdering.move(c, to: .before(b), in: cmux, saved: nil) == .failure(.pinUnknown))
        #expect(SidebarOrdering.step(b, .up, visible: [a, b, c], items: cmux) == nil)
        #expect(SidebarOrdering.step(c, .up, visible: [a, b, c], items: cmux) == .before(a))
        #expect(SidebarOrdering.move(c, to: .before(a), in: cmux, saved: nil) == .success([c, b, a]))
    }

    @Test func presentationBlocksKeepTheirSlots() {
        let cmux = [SidebarOrderItem(id: a, pinned: false, block: 0), SidebarOrderItem(id: b, pinned: false, block: 0),
                    SidebarOrderItem(id: c, pinned: false, block: 1), SidebarOrderItem(id: d, pinned: false, block: 1)]
        #expect(SidebarOrdering.display(cmux, saved: [d, b, c, a]) == [b, a, d, c])
        #expect(SidebarOrdering.move(c, to: .before(a), in: cmux, saved: nil) == .failure(.acrossBlock))
        #expect(SidebarOrdering.step(c, .up, visible: [a, b, c, d], items: cmux) == nil)
        #expect(SidebarOrdering.move(b, to: .before(a), in: cmux, saved: nil) == .success([b, a, c, d]))
    }

    @Test func evictionKeepsALiveWorkspaceListThatWasSavedFirst() throws {
        var settings = SidebarOrderSettings()
        let workspaces = SidebarOrderScope.workspaces(window: UUID())
        try settings.move(b, to: .before(a), in: workspaces, items: items([a, b]))
        for _ in 0..<(SidebarOrderSettings.maximumScopes + 10) {
            try settings.move(b, to: .before(a), in: .surfaces(workspace: UUID()), items: items([a, b]))
        }
        #expect(settings.records.count == SidebarOrderSettings.maximumScopes)
        #expect(settings.ids(for: workspaces) == [b, a])
    }

    @Test func byteCapEvictsOldestSurfaceListsAndKeepsTheOneBeingSaved() throws {
        var settings = SidebarOrderSettings()
        let workspaces = SidebarOrderScope.workspaces(window: UUID())
        try settings.move(b, to: .before(a), in: workspaces, items: items([a, b]))
        var scopes: [SidebarOrderScope] = []
        for _ in 0..<60 {
            let ids = (0..<SidebarOrderSettings.maximumIDsPerScope).map { _ in UUID() }
            let scope = SidebarOrderScope.surfaces(workspace: UUID())
            scopes.append(scope)
            try settings.move(ids[ids.count - 1], to: .before(ids[0]), in: scope, items: items(ids))
        }
        let size = try JSONEncoder().encode(settings).count
        #expect(size <= SidebarOrderSettings.maximumStoredBytes)
        #expect(settings.records.count < 61)
        let newest = try #require(scopes.last), oldest = try #require(scopes.first)
        #expect(settings.ids(for: newest) != nil)
        #expect(settings.ids(for: oldest) == nil)
        #expect(settings.ids(for: workspaces) == [b, a])
        #expect(settings.isValid)
    }
}
