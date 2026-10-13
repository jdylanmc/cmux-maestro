import AppKit
import SwiftUI
import Testing
@testable import CMUXMaestroPreview

/// Hosted SidebarView wiring checked through native controls and resulting model/preference state.
@MainActor
@Suite(SidebarAppKitTestScope())
struct SidebarHostedWiringTests {
    @Test func hierarchyDismissPersistsExactOutcomeAndReprojectsHistory() async throws {
        let hosted = try await SidebarHostedSidebar(mode: .hierarchy)
        defer { hosted.close() }
        let dismiss = try #require(hosted.button("Dismiss Finished child, completed outcome"))
        #expect(hosted.preferences.history.dismissed.isEmpty)
        dismiss.activate()
        let key = SidebarDismissedOutcome(sessionID: hosted.fixtures.sessionID, childID: "finished",
                                          eventID: hosted.childEventID)
        #expect(hosted.preferences.history.dismissed == [key])
        await sidebarEventually {
            hosted.model.copilot.tree.sessions.first?.nodes.contains { $0.id == "finished" } == false
                && hosted.button("Dismiss Finished child, completed outcome") == nil
        }
        #expect(hosted.model.copilot.tree.sessions.first?.nodes.contains { $0.id == "finished" } == false,
                "The model must reproject the persisted history")
        #expect(hosted.button("Dismiss Finished child, completed outcome") == nil)
        #expect(hosted.navigations.isEmpty && hosted.preferences.attention.acknowledged.isEmpty,
                "Dismissal neither navigates nor acknowledges")
    }

    @Test(arguments: [SidebarMode.hierarchy, .taskboard], [true, false])
    func focusAcknowledgesExactAttentionOnlyAfterNavigationSucceeds(mode: SidebarMode, succeeds: Bool) async throws {
        let hosted = try await SidebarHostedSidebar(mode: mode, navigationSucceeds: succeeds)
        defer { hosted.close() }
        try #require(hosted.model.copilot.tree.attentionOwnerCount == 1)
        let label = mode == .hierarchy ? "Focus Terminal Wiring row" : "Focus Copilot session 10000000"
        let focus = try #require(hosted.button(label))
        focus.activate()
        let target = SidebarNavigationTarget.surface(workspaceID: hosted.fixtures.workspaceA,
                                                     surfaceID: hosted.fixtures.surfaceA)
        await sidebarEventually { hosted.navigations == [target] && hosted.model.navigation.status != .selecting }
        #expect(hosted.navigations == [target])
        let expected = SidebarAcknowledgedOutcome(
            sessionID: hosted.fixtures.sessionID, ownerID: nil,
            evidence: .init(source: "copilot.events", eventID: hosted.attentionEventID)
        )
        if succeeds {
            await sidebarEventually {
                hosted.preferences.attention.acknowledged == [expected]
                    && hosted.model.copilot.tree.attentionOwnerCount == 0
            }
            #expect(hosted.preferences.attention.acknowledged == [expected])
            #expect(hosted.model.copilot.tree.attentionOwnerCount == 0, "The model must reproject acknowledgements")
        } else {
            #expect(hosted.preferences.attention.acknowledged.isEmpty, "Failed navigation must not mark work seen")
            #expect(hosted.model.copilot.tree.attentionOwnerCount == 1)
        }
        #expect(hosted.preferences.history.dismissed.isEmpty)
    }

    @Test func taskboardHidesEndedSessionUntilShowEndedThroughSharedProjection() async throws {
        let hosted = try await SidebarHostedSidebar(mode: .taskboard, liveness: .dead, attention: false, children: false)
        defer { hosted.close() }
        try #require(hosted.model.copilot.tree.sessions.first?.liveness == .dead)
        #expect(!hosted.preferences.showEnded)
        #expect(hosted.button("Focus Copilot session 10000000") == nil, "Ended work is hidden by default")
        hosted.preferences.showEnded = true
        await sidebarEventually { hosted.button("Focus Copilot session 10000000") != nil }
        #expect(hosted.button("Focus Copilot session 10000000") != nil, "Show ended reveals the same session")
        hosted.preferences.showEnded = false
        await sidebarEventually { hosted.button("Focus Copilot session 10000000") == nil }
        #expect(hosted.button("Focus Copilot session 10000000") == nil)
    }

    /// The focus title swallows every hit inside its bounds, so no secondary native control may sit there.
    @Test(arguments: [SidebarMode.hierarchy, .taskboard])
    func focusTitlesContainAndOverlapNoSecondaryNativeControls(mode: SidebarMode) async throws {
        let hosted = try await SidebarHostedSidebar(mode: mode)
        defer { hosted.close() }
        let views = hosted.descendants()
        let titles = views.compactMap { $0 as? SidebarTitleNativeButton }
            .filter { $0.accessibilityLabel()?.hasPrefix("Focus ") == true }
        try #require(!titles.isEmpty)
        let secondary = views.compactMap { $0 as? NSControl }.filter { control in
            !titles.contains { $0 === control } && !(control is NSScroller) && !control.isHiddenOrHasHiddenAncestor
        }
        try #require(secondary.contains { $0 is SidebarIconNativeButton } && secondary.contains { $0.accessibilityIdentifier() == "hover-copy-value" },
                     "Fixture must render secondary native controls")
        for title in titles {
            let frame = hosted.host.convert(title.bounds, from: title)
            for control in secondary {
                #expect(!control.isDescendant(of: title),
                        "\(type(of: control)) \(control.accessibilityLabel() ?? "") is nested in \(title.accessibilityLabel() ?? "")")
                let other = hosted.host.convert(control.bounds, from: control)
                #expect(!frame.intersects(other),
                        "\(type(of: control)) \(control.accessibilityLabel() ?? "") overlaps \(title.accessibilityLabel() ?? "")")
            }
        }
    }

    @Test func internalTaskDisclosureStoresExpansionInPreferencesNotViewState() async throws {
        let hosted = try await SidebarHostedSidebar(mode: .hierarchy)
        defer { hosted.close() }
        func taskNames() -> [NSTextField] {
            hosted.descendants().compactMap { $0 as? NSTextField }
                .filter { $0.accessibilityIdentifier() == "internal-task-name" }
        }
        try #require(taskNames().count == 1)
        let layout = hosted.preferences.layout
        let disclosure = try #require(hosted.descendants().compactMap { $0 as? SidebarTitleNativeButton }
            .first { $0.accessibilityLabel()?.hasPrefix("Internal tasks.") == true })
        disclosure.activate()
        await sidebarEventually { taskNames().isEmpty }
        #expect(taskNames().isEmpty)
        #expect(hosted.preferences.layout != layout, "Disclosure state is stored in layout preferences")
        hosted.remount()
        #expect(taskNames().isEmpty, "A fresh view restores the stored disclosure")
        #expect(hosted.navigations.isEmpty)
    }
}

/// A synthetic, offscreen SidebarView with one session that has a completed (dismissible) child
/// outcome and an acknowledgeable turn-finished attention signal.
@MainActor
final class SidebarHostedSidebar {
    let fixtures = SidebarTreeFixtures()
    let preferenceFixture: SidebarPreferenceFixture
    let preferences: SidebarPreferences
    let model: SidebarConnectionModel
    let window: NSWindow
    let host: NSHostingView<AnyView>
    let now = Date()
    let childEventID = UUID()
    let attentionEventID = UUID()
    private(set) var navigations: [SidebarNavigationTarget] = []

    init(
        mode: SidebarMode, liveness: CopilotLiveness = .alive, attention: Bool = true, children: Bool = true,
        navigationSucceeds: Bool = true, width: CGFloat = 340, height: CGFloat = 900
    ) async throws {
        preferenceFixture = try SidebarPreferenceFixture()
        preferences = preferenceFixture.preferences()
        preferences.selectedMode = mode
        let date = now
        let child = CopilotChildWork(
            id: "finished", parentID: nil, kind: .subagent, name: "Finished child", state: .completed, model: nil,
            terminalEvent: .init(id: childEventID, timestamp: date)
        )
        let observation = CopilotSessionObservation(
            sessionID: fixtures.sessionID, surfaceID: fixtures.surfaceA, launchWorkspaceID: fixtures.workspaceA,
            liveness: liveness, state: .idle, model: "wiring-model", children: children ? [child] : [],
            observedAt: date,
            attention: attention ? [.init(kind: .turnFinished,
                                          evidence: .init(source: "copilot.events", eventID: attentionEventID),
                                          occurredAt: date)] : []
        )
        let snapshot = fixtures.snapshot(sessions: [observation], now: date)
        let polling = SidebarCopilotPolling(
            read: neutralRead { _ in snapshot }, pause: { try await sidebarFrozenExpiry(0) },
            expiryPause: sidebarFrozenExpiry, now: { date }
        )
        let orchestration = SidebarOrchestrationPolling(read: { .empty }, pause: { try await sidebarFrozenExpiry(0) })
        model = SidebarConnectionModel(copilot: polling, orchestration: orchestration)
        let hierarchy = HierarchySnapshot(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true, workspaceMetadataAvailable: true,
            surfaceMetadataAvailable: true, workspacePathsAvailable: true,
            workspaces: [.init(
                id: fixtures.workspaceA, title: .available("Wiring workspace"), detail: .available(nil),
                isSelected: .available(true), isPinned: .available(false), unreadCount: .available(0),
                rootPath: .available("/synthetic/wiring"), projectRootPath: .available(nil),
                surfaces: .available([
                    .init(id: fixtures.surfaceA, title: "Wiring row", kind: .terminal, isFocused: true,
                          isPinned: false, unreadCount: 0, workingDirectory: .available("/synthetic/wiring"))
                ])
            )], windowID: fixtures.windowID
        )
        model.replaceHierarchy(with: hierarchy)
        model.showConnected(workspaceCount: 1, surfaceCount: 1)
        let topology = SidebarTopology(hierarchy)
        polling.update(topology: topology, connected: true)
        orchestration.update(topology: topology, connected: true)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: AnyView(EmptyView()))
        model.navigation.update(topology: topology, connected: true, workspaceAllowed: true, surfaceAllowed: true,
                                perform: { [weak self] target in
            self?.navigations.append(target)
            if !navigationSucceeds { throw CocoaError(.featureUnsupported) }
        })
        model.setVisible(true)
        for workspace in hierarchy.workspaces { preferences.setIdleTasksVisible(true, in: workspace.id) }
        window.contentView = host
        remount()
        host.frame = window.contentLayoutRect
        await sidebarEventually { polling.tree.sessions.count == 1 && polling.tree.sessions[0].nodes.isEmpty != children }
        try #require(polling.tree.sessions.count == 1 && polling.tree.sessions[0].nodes.isEmpty != children)
        host.layoutSubtreeIfNeeded()
    }

    func remount() {
        let date = now
        host.rootView = AnyView(SidebarView(model: model, preferences: preferences, actionNow: { date })
            .environment(\.sidebarPresentationNow, { date })
            .environment(\._accessibilityReduceMotion, true))
        host.layoutSubtreeIfNeeded()
    }

    func descendants() -> [NSView] {
        host.layoutSubtreeIfNeeded()
        func visit(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + visit($0) } }
        return visit(host)
    }

    func button(_ label: String) -> SidebarTitleNativeButton? {
        descendants().compactMap { $0 as? SidebarTitleNativeButton }.first { $0.accessibilityLabel() == label }
    }

    func close() {
        model.setVisible(false)
        window.contentView = nil
        window.close()
        preferenceFixture.cleanup()
    }
}
