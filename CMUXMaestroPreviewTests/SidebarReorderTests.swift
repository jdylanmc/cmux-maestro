import AppKit
@_spi(CmuxHostTransport) import CmuxExtensionKit
import Foundation
import Testing

/// Test-only stand-in for a future host backend: CMUX is authoritative and records moves.
@MainActor
private final class FakeNativeReorderBackend: SidebarReorderBackend {
    enum Call: Equatable {
        case workspace(UUID, SidebarOrderPlacement, window: UUID)
        case surface(UUID, SidebarOrderPlacement, workspace: UUID)
        case reset(SidebarOrderScope)
        case resetAll
    }

    var calls: [Call] = []
    var capabilities = SidebarReorderCapabilities(canMove: true, canReset: false)

    func authority(for kind: SidebarOrderScope.Kind) -> SidebarReorderAuthority { .host }
    func capabilities(for kind: SidebarOrderScope.Kind) -> SidebarReorderCapabilities { capabilities }
    // A misbehaving host backend may report an overlay; composition must still ignore it.
    func overlay(for scope: SidebarOrderScope) -> [UUID]? { [UUID()] }
    func moveWorkspace(_ id: UUID, _ placement: SidebarOrderPlacement, window: UUID, siblings: [SidebarOrderItem]) -> SidebarReorderOutcome {
        calls.append(.workspace(id, placement, window: window))
        return .pending
    }
    func moveSurface(_ id: UUID, _ placement: SidebarOrderPlacement, workspace: UUID, siblings: [SidebarOrderItem]) -> SidebarReorderOutcome {
        calls.append(.surface(id, placement, workspace: workspace))
        return .pending
    }
    func resetOrder(_ scope: SidebarOrderScope) { calls.append(.reset(scope)) }
    var canResetAll: Bool { false }
    var hasSavedOrder: Bool { false }
    func resetAll() { calls.append(.resetAll) }
    func refresh() {}
    var notice: String? { nil }
}

@MainActor
@Suite(.serialized)
struct SidebarReorderTests {
    private let a = UUID(), b = UUID(), c = UUID()
    private let window = UUID(), workspace = UUID()

    private func items(_ ids: [UUID], pinned: Set<UUID> = []) -> [SidebarOrderItem] {
        ids.map { SidebarOrderItem(id: $0, pinned: pinned.contains($0)) }
    }

    private func compose(
        _ kind: SidebarOrderScope.Kind, _ ids: [UUID], backend: any SidebarReorderBackend, shown: Set<UUID>? = nil
    ) -> SidebarReorderList<UUID> {
        let scope: SidebarOrderScope = kind == .workspaces ? .workspaces(window: window) : .surfaces(workspace: workspace)
        return SidebarReorderComposition.compose(
            ids, kind: kind, scope: scope, backend: backend, shown: shown.map { set in { set.contains($0) } }
        ) { SidebarOrderItem(id: $0, pinned: false) }
    }

    private func menu(_ handle: SidebarReorderHandle) throws -> NSMenu {
        let presenter = SidebarRowMenuPresenter()
        presenter.groups = [.placement(handle)]
        return try #require(presenter.menu().items.first?.submenu)
    }

    @Test func factorySelectsMaestroLocalForBothKindsToday() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let backend = SidebarReorderBackends.make(
            grantedActionScopes: Set(CmuxExtensionActionScope.allCases),
            host: CmuxSidebarHost(performAction: { _, _ in }), store: fixture.preferences()
        )
        #expect(backend.selection == .init(workspaces: .maestroLocal, surfaces: .maestroLocal))
        #expect(backend.capabilities(for: .workspaces) == .full && backend.capabilities(for: .surfaces) == .full)
        let model = SidebarConnectionModel()
        model.setReorderBackend(backend)
        let first = try #require(model.reorderBackend)
        model.setReorderBackend(SidebarScopedReorderBackend.localOnly(store: fixture.preferences()))
        #expect(model.reorderBackend === first)
        model.setReorderBackend(.init(workspaces: FakeNativeReorderBackend(), surfaces: first.surfaces))
        #expect(model.reorderBackend !== first)
        #expect(model.reorderBackend?.selection == .init(workspaces: .host, surfaces: .maestroLocal))
    }

    @Test func nativeScopeShowsCMUXOrderRoutesMovesToHostAndLeavesLocalFileAlone() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let file = fixture.root.appendingPathComponent("sidebar-order.json")
        // A local order saved before CMUX became authoritative for workspaces.
        preferences.applyOrder(.move(c, .before(a), scope: .workspaces(window: window), items: items([a, b, c])))
        preferences.applyOrder(.move(c, .before(a), scope: .surfaces(workspace: workspace), items: items([a, b, c])))
        let savedBytes = try Data(contentsOf: file)

        let native = FakeNativeReorderBackend()
        let backend = SidebarScopedReorderBackend(workspaces: native, surfaces: LocalSidebarReorderBackend(store: preferences))
        let session = SidebarReorderDragSession()

        let workspaces = compose(.workspaces, [a, b, c], backend: backend)
        #expect(workspaces.displayed == [a, b, c] && workspaces.authority == .host && !workspaces.hasCustomOrder)
        let workspaceContext = SidebarReorderContext(workspaces, backend: backend, session: session)
        let workspaceHandle = workspaceContext.handle(for: b, noun: "workspace")
        #expect(workspaceHandle.accessibilityActions.map(\.name) == ["Move up", "Move down"])
        let workspaceMenu = try menu(workspaceHandle)
        #expect(!workspaceMenu.items.contains { $0.title.hasPrefix("Reset") })
        #expect(workspaceMenu.items.last?.title == SidebarReorderContext.hostHelp)
        workspaceMenu.items.first { $0.title == "Move Up" }.map { SidebarRowMenuPresenter().invoke($0) }
        workspaceHandle.move(.after(c))
        #expect(native.calls == [.workspace(b, .before(a), window: window), .workspace(b, .after(c), window: window)])
        workspaceHandle.resetScope()
        #expect(native.calls.count == 2)
        // The saved local order is neither applied nor deleted.
        #expect(try Data(contentsOf: file) == savedBytes)
        #expect(preferences.order.ids(for: .workspaces(window: window)) == [c, a, b])

        // Surfaces stay Maestro-local in the same backend.
        let surfaces = compose(.surfaces, [a, b, c], backend: backend)
        #expect(surfaces.displayed == [c, a, b] && surfaces.authority == .maestroLocal && surfaces.hasCustomOrder)
        let surfaceContext = SidebarReorderContext(surfaces, backend: backend, session: session)
        let surfaceHandle = surfaceContext.handle(for: b, noun: "surface")
        #expect(surfaceHandle.accessibilityActions.map(\.name) == ["Move up in Maestro"])
        let surfaceMenu = try menu(surfaceHandle)
        #expect(surfaceMenu.items.contains { $0.title == "Reset Order in Workspace" && $0.isEnabled })
        #expect(surfaceMenu.items.last?.title == SidebarReorderContext.localHelp)
        surfaceHandle.move(.before(c))
        #expect(preferences.order.ids(for: .surfaces(workspace: workspace)) == [b, c, a])
        #expect(native.calls.count == 2)
        surfaceHandle.resetScope()
        #expect(preferences.order.ids(for: .surfaces(workspace: workspace)) == nil)
        #expect(preferences.order.ids(for: .workspaces(window: window)) == [c, a, b])
    }

    @Test func hostCapabilitiesLimitWhatTheUIOffers() throws {
        let native = FakeNativeReorderBackend()
        native.capabilities = .none
        let session = SidebarReorderDragSession()
        session.begin(.workspaces(window: window), a)
        let context = SidebarReorderContext(compose(.workspaces, [a, b], backend: native), backend: native, session: session)
        let handle = context.handle(for: b, noun: "workspace")
        #expect(context.unavailable == "CMUX does not allow reordering this list.")
        #expect(handle.dragSource == nil && handle.accessibilityActions.isEmpty)
        #expect(!handle.accepts(dragging: session.dragging))
        for item in try menu(handle).items { #expect(!item.isEnabled) }
        handle.move(.before(a))
        #expect(native.calls.isEmpty)
    }

    @Test func localRowMenuOffersMaestroOnlyMovesAndReset() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let backend = SidebarScopedReorderBackend.localOnly(store: preferences)
        let context = SidebarReorderContext(
            compose(.surfaces, [a, b, c], backend: backend), backend: backend, session: SidebarReorderDragSession()
        )
        let submenu = try menu(context.handle(for: a, noun: "surface"))
        let titles = submenu.items.map(\.title)
        #expect(titles.contains("Move Up") && titles.contains("Move Down") && titles.contains("Reset Order in Workspace"))
        #expect(titles.last == SidebarReorderContext.localHelp)
        #expect(submenu.items.first { $0.title == "Move Up" }?.isEnabled == false)
        #expect(submenu.items.first { $0.title == "Reset Order in Workspace" }?.isEnabled == false)
        let down = try #require(submenu.items.first { $0.title == "Move Down" })
        #expect(down.isEnabled)
        SidebarRowMenuPresenter().invoke(down)
        #expect(preferences.order.ids(for: .surfaces(workspace: workspace)) == [b, a, c])
        #expect(context.handle(for: b, noun: "surface").accessibilityActions.map(\.name)
            == ["Move up in Maestro", "Move down in Maestro"])
        #expect(context.handle(for: a, noun: "surface").accessibilityActions.map(\.name) == ["Move down in Maestro"])

        // Rows hidden from the list (managed surfaces) are kept in scope but not shown.
        let partial = compose(.surfaces, [a, b, c], backend: backend, shown: [a, c])
        #expect(partial.displayed == [a, c] && partial.items.count == 3)

        let noWindow = SidebarReorderComposition.compose(
            [a, b], kind: .workspaces, scope: nil, backend: backend
        ) { SidebarOrderItem(id: $0, pinned: false) }
        let unknownWindow = SidebarReorderContext(noWindow, backend: backend, session: SidebarReorderDragSession())
        let handleWithoutWindow = unknownWindow.handle(for: a, noun: "workspace")
        #expect(handleWithoutWindow.dragSource == nil && handleWithoutWindow.accessibilityActions.isEmpty)
        for item in try menu(handleWithoutWindow).items { #expect(!item.isEnabled) }
    }

    @Test func dragAcceptsOnlySameScopeSiblingsInTheSamePinGroup() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let backend = SidebarScopedReorderBackend.localOnly(store: fixture.preferences())
        let session = SidebarReorderDragSession()
        let scope = SidebarOrderScope.workspaces(window: window)
        let list = SidebarReorderComposition.compose(
            [a, b, c], kind: .workspaces, scope: scope, backend: backend
        ) { SidebarOrderItem(id: $0, pinned: $0 == a) }
        let context = SidebarReorderContext(list, backend: backend, session: session)
        let target = context.handle(for: c, noun: "workspace")
        #expect(!target.accepts(dragging: session.dragging))
        session.begin(scope, b)
        #expect(target.accepts(dragging: session.dragging))
        #expect(!context.handle(for: b, noun: "workspace").accepts(dragging: session.dragging))
        #expect(!context.handle(for: a, noun: "workspace").accepts(dragging: session.dragging))
        session.begin(.surfaces(workspace: UUID()), b)
        #expect(!target.accepts(dragging: session.dragging))
        session.end()
        #expect(session.dragging == nil && session.indicator == nil)
    }

    @Test func settingsResetIsHiddenWheneverAnyKindIsHostOrdered() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let file = fixture.root.appendingPathComponent("sidebar-order.json")
        preferences.applyOrder(.move(c, .before(a), scope: .workspaces(window: window), items: items([a, b, c])))
        let savedBytes = try Data(contentsOf: file)

        let native = FakeNativeReorderBackend()
        let allNative = SidebarReorderSettings(backend: SidebarScopedReorderBackend(workspaces: native, surfaces: native))
        #expect(!allNative.resetShown && !allNative.resetEnabled)
        #expect(allNative.copy.hasSuffix(SidebarReorderContext.hostHelp))
        allNative.reset()
        #expect(native.calls.isEmpty)
        #expect(try Data(contentsOf: file) == savedBytes)

        let local = LocalSidebarReorderBackend(store: preferences)
        let mixed = SidebarReorderSettings(backend: SidebarScopedReorderBackend(workspaces: native, surfaces: local))
        #expect(!mixed.resetShown)
        #expect(mixed.copy.contains("Workspace moves change CMUX's order; surface moves change Maestro's order only."))
        mixed.reset()
        #expect(try Data(contentsOf: file) == savedBytes)

        let localOnly = SidebarReorderSettings(backend: SidebarScopedReorderBackend.localOnly(store: preferences))
        #expect(localOnly.resetShown && localOnly.resetEnabled)
        #expect(localOnly.copy.hasSuffix(SidebarReorderContext.localHelp))
        localOnly.reset()
        #expect(preferences.order.records.isEmpty && !localOnly.resetEnabled)
    }

    @Test func dropTargetValidatesShowsCueExitsAndPerformsOnlyForSiblings() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let backend = SidebarScopedReorderBackend.localOnly(store: preferences)
        let session = SidebarReorderDragSession()
        let scope = SidebarOrderScope.surfaces(workspace: workspace)
        let context = SidebarReorderContext(compose(.surfaces, [a, b, c], backend: backend), backend: backend, session: session)
        let onC = SidebarReorderDropTarget(handle: context.handle(for: c, noun: "surface"), height: 40)
        let onA = SidebarReorderDropTarget(handle: context.handle(for: a, noun: "surface"), height: 40)

        // No drag in progress, or a foreign payload: nothing is accepted.
        #expect(!onC.validate(hasPayload: true))
        session.begin(scope, a)
        #expect(!onC.validate(hasPayload: false))
        #expect(!onC.update(hasPayload: false, locationY: 5) && session.indicator == nil)

        // Dropping a row onto itself is refused and moves nothing.
        #expect(!onA.validate(hasPayload: true))
        #expect(!onA.perform(hasPayload: true, locationY: 5))
        #expect(session.dragging == nil && preferences.order.records.isEmpty)

        session.begin(scope, a)
        #expect(onC.update(hasPayload: true, locationY: 30))
        #expect(session.indicator == .init(scope: scope, placement: .after(c)))
        onA.exit()
        #expect(session.indicator != nil)
        onC.exit()
        #expect(session.indicator == nil)
        #expect(onC.update(hasPayload: true, locationY: 30))
        #expect(onC.perform(hasPayload: true, locationY: 30))
        #expect(preferences.order.ids(for: scope) == [b, c, a])
        #expect(session.dragging == nil && session.indicator == nil)
    }

    @Test func voiceOverMovesAnnounceTheResultAndReportRefusal() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let backend = SidebarScopedReorderBackend.localOnly(store: preferences)
        let names = [a: "Alpha", b: "Beta", c: "Gamma"]
        let list = SidebarReorderComposition.compose(
            [a, b, c], kind: .surfaces, scope: .surfaces(workspace: workspace), backend: backend,
            title: { names[$0] ?? "" }
        ) { SidebarOrderItem(id: $0, pinned: false) }
        let context = SidebarReorderContext(list, backend: backend, session: SidebarReorderDragSession())
        let actions = context.handle(for: b, noun: "surface").accessibilityActions
        let up = try #require(actions.first)
        #expect(up.perform() == .init(succeeded: true, message: "Moved above Alpha"))
        let down = try #require(context.handle(for: a, noun: "surface").accessibilityActions.last)
        #expect(down.perform() == .init(succeeded: true, message: "Moved below Beta"))

        // A store that can't be read refuses the move; VoiceOver hears why.
        try Data("{\"version\":9}".utf8).write(to: fixture.root.appendingPathComponent("sidebar-order.json"))
        preferences.refreshOrder()
        let refused = context.handle(for: c, noun: "surface").announcedMove(.before(a))
        #expect(refused == .init(succeeded: false, message: SidebarOrderSettings.unreadableNotice))
    }

    @Test func unknownPinStateMakesOnlyThatRowUnmovable() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let backend = SidebarScopedReorderBackend.localOnly(store: fixture.preferences())
        let session = SidebarReorderDragSession()
        let list = SidebarReorderComposition.compose(
            [a, b, c], kind: .workspaces, scope: .workspaces(window: window), backend: backend
        ) { SidebarOrderItem(id: $0, pinned: $0 == b ? nil : false) }
        let context = SidebarReorderContext(list, backend: backend, session: session)
        let unknown = context.handle(for: b, noun: "workspace")
        #expect(unknown.unavailable == SidebarOrderRefusal.pinUnknown.notice)
        #expect(unknown.dragSource == nil && unknown.accessibilityActions.isEmpty)
        for item in try menu(unknown).items { #expect(!item.isEnabled) }
        #expect(unknown.move(.before(a)) == .refused(SidebarOrderRefusal.pinUnknown.notice))
        session.begin(.workspaces(window: window), a)
        #expect(!unknown.accepts(dragging: session.dragging))
        // Known rows still move, stepping past the unknown one.
        #expect(context.handle(for: c, noun: "workspace").step(.up) == .before(a))
    }

    @Test func managedRootAgentsReorderInTheWorkspaceSurfaceListWithinTheirBlock() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let backend = SidebarScopedReorderBackend.localOnly(store: preferences)
        let start = Date(timeIntervalSince1970: 1_000)
        func node(_ label: String, surface: UUID, parent: UUID? = nil, offset: TimeInterval) -> SidebarOrchestrationNode {
            .init(id: UUID(), runId: UUID(), parentId: parent, role: "worker", label: label,
                  workspaceId: workspace, surfaceId: surface, generation: 1, phase: "completed", availability: "ready",
                  createdAt: start.addingTimeInterval(offset), updatedAt: start.addingTimeInterval(offset))
        }
        func surface(_ id: UUID, _ title: String) -> HierarchySurface {
            .init(id: id, title: title, kind: .terminal, isFocused: false, isPinned: false, unreadCount: 0,
                  workingDirectory: .available(nil))
        }
        let agentSurfaceA = UUID(), agentSurfaceB = UUID(), childSurface = UUID(), plain = UUID(), orphan = UUID()
        let first = node("First", surface: agentSurfaceA, offset: 0)
        let second = node("Second", surface: agentSurfaceB, offset: 10)
        let child = node("Child", surface: childSurface, parent: first.id, offset: 20)
        let gone = node("Gone", surface: orphan, offset: 30)
        let surfaces = [surface(agentSurfaceA, "a"), surface(plain, "Plain"), surface(agentSurfaceB, "b"), surface(childSurface, "c")]
        func compose() -> SidebarReorderList<SidebarSurfaceUnit> {
            SidebarSurfaceUnit.compose(
                workspaceID: workspace, surfaces: surfaces, managed: [first, second, child, gone],
                observations: .waiting, now: start, backend: backend
            )
        }
        var list = compose()
        // Managed roots first (default order), then other surfaces; the child agent is not a sibling.
        #expect(list.visible == [agentSurfaceA, agentSurfaceB, orphan, plain])
        #expect(list.displayed.compactMap(\.surface).map(\.id) == [plain])
        let context = SidebarReorderContext(list, backend: backend, session: SidebarReorderDragSession())
        let secondHandle = context.handle(for: agentSurfaceB, noun: "agent")
        #expect(secondHandle.step(.up) == .before(agentSurfaceA))
        #expect(secondHandle.step(.down) == nil, "An agent whose surface is gone has unknown pin state")
        #expect(context.handle(for: plain, noun: "surface").step(.up) == nil, "Blocks keep their place")
        #expect(context.handle(for: orphan, noun: "agent").unavailable == SidebarOrderRefusal.pinUnknown.notice)
        #expect(secondHandle.move(.before(plain)) == .refused(SidebarOrderRefusal.acrossBlock.notice))

        let menuTitles = try menu(secondHandle).items.map(\.title)
        #expect(menuTitles.contains("Move Up") && menuTitles.last == SidebarReorderContext.localHelp)
        #expect(secondHandle.move(.before(agentSurfaceA)) == .applied)
        list = compose()
        #expect(list.visible == [agentSurfaceB, agentSurfaceA, orphan, plain])
        #expect(ManagedHierarchyContent.orderedRoots([first, second, gone], visible: list.visible).map(\.label)
            == ["Second", "First", "Gone"])
        #expect(ManagedHierarchyContent.orderedRoots([first, second], visible: nil).map(\.label) == ["First", "Second"])
    }
}
