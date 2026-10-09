import Foundation
import Testing
@_spi(CmuxHostTransport) import CmuxExtensionKit

@MainActor
struct SidebarBacklogTests {
    private let fixtures = SidebarTreeFixtures()
    private let url = "https://example.com/backlog?state=open#issues"

    @Test func savedConfigurationResolvesOnlyItsExactWorkspaceFeedbackWithoutOpening() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let recorder = Recorder()
        let model = model()
        model.update(context: context(recorder))
        model.backlog.open(workspaceID: fixtures.workspaceA, windowID: fixtures.windowID, urlText: nil)
        #expect(model.backlog.status == .missingURL)

        preferences.setBacklogURL(url, for: fixtures.workspaceB)
        model.backlog.configurationDidChange(settings: preferences.backlog, notice: preferences.backlogNotice)
        #expect(model.backlog.status == .missingURL, "Another workspace's save cannot resolve this one.")
        preferences.setBacklogURL("invalid", for: fixtures.workspaceA)
        model.backlog.configurationDidChange(settings: preferences.backlog, notice: preferences.backlogNotice)
        #expect(preferences.backlogNotice == SidebarBacklogSettings.invalidNotice)
        #expect(model.backlog.status == .missingURL)

        preferences.setBacklogURL(url, for: fixtures.workspaceA)
        let fresh = fixture.preferences()
        model.backlog.configurationDidChange(settings: fresh.backlog, notice: fresh.backlogNotice)
        #expect(fresh.backlog.urlText(for: fixtures.workspaceA) == url)
        #expect(fresh.backlog.urlText(for: fixtures.workspaceB) == url)
        #expect(model.backlog.status == nil && model.backlog.statusWorkspaceID == nil)
        #expect(recorder.actions.isEmpty)

        preferences.setBacklogURL("", for: fixtures.workspaceA)
        model.backlog.configurationDidChange(settings: preferences.backlog, notice: preferences.backlogNotice)
        #expect(model.backlog.status == nil, "Removing configuration is not an open attempt.")
        model.backlog.open(workspaceID: fixtures.workspaceA, windowID: fixtures.windowID, urlText: nil)
        preferences.resetBacklogs()
        model.backlog.configurationDidChange(settings: preferences.backlog, notice: preferences.backlogNotice)
        #expect(model.backlog.status == .missingURL)
        #expect(recorder.actions.isEmpty)
    }

    @Test func unsuccessfulConfigurationReadOrSaveDoesNotResolveInvalidFeedback() {
        let recorder = Recorder()
        let model = model()
        model.update(context: context(recorder))
        model.backlog.open(workspaceID: fixtures.workspaceA, windowID: fixtures.windowID, urlText: "invalid")
        let settings = SidebarBacklogSettings(urls: [fixtures.workspaceA.uuidString: url])
        for notice in [SidebarBacklogSettings.invalidNotice, SidebarBacklogSettings.saveNotice,
                       SidebarBacklogSettings.unreadableNotice] {
            model.backlog.configurationDidChange(settings: settings, notice: notice)
            #expect(model.backlog.status == .invalidURL)
        }
        model.backlog.configurationDidChange(settings: .init(), notice: nil)
        #expect(model.backlog.status == .missingURL)
        #expect(recorder.actions.isEmpty)
    }

    @Test func configurationChangesPreservePendingAndUnconfirmedRequests() async {
        let recorder = Recorder(hold: true)
        let model = model()
        model.update(context: context(recorder))
        model.backlog.open(workspaceID: fixtures.workspaceA, windowID: fixtures.windowID, urlText: url)
        await sidebarEventually { recorder.actions.count == 1 }
        let pending = model.backlog.pending
        model.backlog.configurationDidChange(settings: .init(), notice: nil)
        #expect(model.backlog.status == .opening && model.backlog.pending == pending)
        model.setVisible(false)
        model.backlog.configurationDidChange(
            settings: .init(urls: [fixtures.workspaceA.uuidString: url]), notice: nil
        )
        #expect(model.backlog.status == .cancelled)
        #expect(model.backlog.statusWorkspaceID == fixtures.workspaceA)
        recorder.reply(.accepted)
        await Task.yield()
        #expect(model.backlog.status == .cancelled)
        #expect(recorder.actions.count == 1)
    }

    @Test func exactSameNamedWorkspacesOpenTheirOwnURLsUsingOnlyTypedBrowserSplits() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        preferences.setBacklogURL(url, for: fixtures.workspaceA)
        preferences.setBacklogURL("https://example.org/other", for: fixtures.workspaceB)
        let recorder = Recorder()
        let model = model()
        let original = snapshot()
        model.update(context: context(recorder, snapshot: original))
        for (workspace, surface, expected) in [
            (fixtures.workspaceA, fixtures.surfaceA, url),
            (fixtures.workspaceB, fixtures.surfaceB, "https://example.org/other")
        ] {
            model.backlog.open(workspaceID: workspace, windowID: fixtures.windowID,
                               urlText: preferences.backlog.urlText(for: workspace))
            await sidebarEventually { model.backlog.status == .accepted }
            #expect(recorder.actions.last == .splitBrowser(
                workspaceID: workspace, surfaceID: surface, direction: .right, url: expected
            ))
        }
        #expect(recorder.actions.count == 2)
        #expect(model.hierarchy.workspaces.allSatisfy { $0.title == .available("Same workspace") })
        #expect(model.navigation.status == .idle)
    }

    enum MissingGrantCase: String, CaseIterable {
        case none, splitOnly, urlOnly, selectionOnly

        var grants: Set<CmuxExtensionActionScope> {
            switch self {
            case .none: []
            case .splitOnly: [.splitSurface]
            case .urlOnly: [.openURL]
            case .selectionOnly: [.selectWorkspace, .selectSurface]
            }
        }
    }

    @Test(arguments: MissingGrantCase.allCases.map(\.rawValue))
    func eachMissingRequiredGrantDeniesWithoutHostEffects(name: String) throws {
        let scenario = try #require(MissingGrantCase(rawValue: name))
        let recorder = Recorder()
        let model = model()
        model.update(context: context(recorder, grants: scenario.grants))
        model.backlog.open(workspaceID: fixtures.workspaceA, windowID: fixtures.windowID, urlText: url)
        #expect(model.backlog.status == .denied)
        #expect(recorder.actions.isEmpty)
    }

    @Test(arguments: ["", "example.com/backlog", "file:///tmp/backlog", "javascript:alert(1)",
                      "https://", "https://example.com/a b", "https://example.com/\nsecret"])
    func missingAndInvalidURLsNeverReachHost(text: String) {
        let recorder = Recorder()
        let model = model()
        model.update(context: context(recorder))
        model.backlog.open(workspaceID: fixtures.workspaceA, windowID: fixtures.windowID, urlText: text)
        #expect(model.backlog.status == (text.isEmpty ? .missingURL : .invalidURL))
        #expect(recorder.actions.isEmpty)
    }

    @Test(arguments: ["workspace", "surface", "metadata", "window", "duplicate-workspace", "duplicate-surface", "ambiguous-focus"])
    func unavailableOrAmbiguousTargetsCannotFallBack(change: String) {
        let recorder = Recorder()
        let model = model()
        var source = snapshot()
        switch change {
        case "workspace": source.workspaces.removeFirst()
        case "surface": source.workspaces[0].surfaces = []
        case "window": source.windowID = UUID()
        case "duplicate-workspace": source.workspaces.append(source.workspaces[0])
        case "duplicate-surface": source.workspaces[1].surfaces.append(source.workspaces[0].surfaces[0])
        case "ambiguous-focus":
            source.workspaces[0].surfaces.append(.init(id: UUID(), title: "Second", kind: .terminal, isFocused: true))
        default: break
        }
        model.update(context: context(recorder, snapshot: source,
                                      readScopes: change == "metadata" ? [.workspaceMetadata] : [.workspaceMetadata, .surfaceMetadata]))
        model.backlog.open(workspaceID: fixtures.workspaceA, windowID: fixtures.windowID, urlText: url)
        #expect(model.backlog.status == .unavailable)
        #expect(recorder.actions.isEmpty)
    }

    @Test func prefersExactFocusedAnchorAndOtherwiseUsesCurrentWorkspaceOrder() async {
        let recorder = Recorder()
        let model = model()
        var source = snapshot()
        let first = UUID()
        source.workspaces[0].surfaces.insert(.init(id: first, title: "First", kind: .terminal), at: 0)
        model.update(context: context(recorder, snapshot: source))
        model.backlog.open(workspaceID: fixtures.workspaceA, windowID: fixtures.windowID, urlText: url)
        await sidebarEventually { model.backlog.status == .accepted }
        #expect(recorder.actions == [.splitBrowser(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA, direction: .right, url: url)])
        source.sequence += 1
        source.workspaces[0].surfaces[1].isFocused = false
        model.update(context: context(recorder, snapshot: source))
        model.backlog.open(workspaceID: fixtures.workspaceA, windowID: fixtures.windowID, urlText: url)
        await sidebarEventually { model.backlog.status == .accepted }
        #expect(recorder.actions.last == .splitBrowser(workspaceID: fixtures.workspaceA, surfaceID: first, direction: .right, url: url))
    }

    @Test func targetRemovedBeforeTaskDispatchIsNotReplacedByAnotherAnchor() async {
        let recorder = Recorder()
        let model = model()
        model.update(context: context(recorder))
        model.backlog.open(workspaceID: fixtures.workspaceA, windowID: fixtures.windowID, urlText: url)
        var changed = snapshot(sequence: 2)
        changed.workspaces[0].surfaces = [.init(id: UUID(), title: "Replacement", kind: .terminal)]
        model.update(context: context(recorder, snapshot: changed))
        await Task.yield()
        #expect(model.backlog.status == .unavailable)
        #expect(recorder.actions.isEmpty)
    }

    @Test func normalFocusAndTopologyUpdatesDoNotCancelSuccessfulCreation() async {
        let recorder = Recorder(hold: true)
        let model = model()
        model.update(context: context(recorder))
        model.backlog.open(workspaceID: fixtures.workspaceA, windowID: fixtures.windowID, urlText: url)
        await sidebarEventually { recorder.actions.count == 1 }
        var changed = snapshot(sequence: 2)
        changed.selectedWorkspaceID = fixtures.workspaceA
        changed.workspaces[0].surfaces[0].isFocused = false
        changed.workspaces[0].surfaces.append(.init(id: UUID(), title: "Backlog", kind: .browser, isFocused: true))
        model.update(context: context(recorder, snapshot: changed))
        #expect(model.backlog.status == .opening)
        recorder.reply(.accepted)
        await sidebarEventually { model.backlog.status == .accepted }
        #expect(recorder.actions.count == 1)
    }

    @Test(arguments: ["disconnect", "hide", "permission", "window", "surface"])
    func pendingInvalidationIgnoresLateAcceptanceWithoutRetry(change: String) async {
        let recorder = Recorder(hold: true)
        let model = model()
        model.update(context: context(recorder))
        model.backlog.open(workspaceID: fixtures.workspaceA, windowID: fixtures.windowID, urlText: url)
        await sidebarEventually { recorder.actions.count == 1 }
        var source = snapshot(sequence: 2)
        let expected: SidebarBacklog.Status
        switch change {
        case "disconnect":
            model.connectionStatusDidChange(.waitingForHost)
            expected = .disconnected
        case "hide":
            model.setVisible(false)
            expected = .cancelled
        case "permission":
            model.update(context: context(recorder, snapshot: source, grants: []))
            expected = .denied
        default:
            if change == "window" { source.windowID = UUID() }
            else { source.workspaces[0].surfaces = [] }
            model.update(context: context(recorder, snapshot: source))
            expected = .unavailable
        }
        recorder.reply(.accepted)
        await Task.yield()
        #expect(model.backlog.status == expected)
        #expect(model.backlog.pending == nil)
        #expect(recorder.actions.count == 1)
    }

    @Test func rejectionCancellationAndRepeatedActivationStayExplicit() async {
        let recorder = Recorder(hold: true)
        let model = model()
        model.update(context: context(recorder))
        model.backlog.open(workspaceID: fixtures.workspaceA, windowID: fixtures.windowID, urlText: url)
        model.backlog.open(workspaceID: fixtures.workspaceA, windowID: fixtures.windowID, urlText: url)
        await sidebarEventually { recorder.actions.count == 1 }
        recorder.reply(.rejected("Sensitive host detail"))
        await sidebarEventually { model.backlog.status == .rejected }
        #expect(model.backlog.status?.message.contains("Sensitive") == false)
        model.backlog.open(workspaceID: fixtures.workspaceB, windowID: fixtures.windowID, urlText: url)
        await sidebarEventually { recorder.actions.count == 2 }
        recorder.reply(.cancelled)
        await sidebarEventually { model.backlog.status == .cancelled }
        #expect(recorder.actions.count == 2)
    }

    @Test func injectedDeadlineReportsUnconfirmedAndIgnoresLateReply() async {
        let (stream, ticks) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { ticks.finish() }
        let backlog = SidebarBacklog(timeout: {
            for await _ in stream { return }
            try Task.checkCancellation()
        })
        let recorder = Recorder(hold: true)
        let model = SidebarConnectionModel(backlog: backlog)
        model.update(context: context(recorder))
        backlog.open(workspaceID: fixtures.workspaceA, windowID: fixtures.windowID, urlText: url)
        await sidebarEventually { recorder.actions.count == 1 }
        ticks.yield(())
        await sidebarEventually { backlog.status == .timedOut }
        recorder.reply(.accepted)
        await Task.yield()
        #expect(backlog.status == .timedOut)
        #expect(recorder.actions.count == 1)
    }

    private func model() -> SidebarConnectionModel {
        SidebarConnectionModel(backlog: SidebarBacklog(timeout: { try await sidebarFrozenExpiry(0) }))
    }

    private func snapshot(sequence: UInt64 = 1) -> CmuxSidebarSnapshot {
        .init(sequence: sequence, windowID: fixtures.windowID, selectedWorkspaceID: fixtures.workspaceB,
              workspaces: [(fixtures.workspaceA, fixtures.surfaceA), (fixtures.workspaceB, fixtures.surfaceB)].map {
            .init(id: $0.0, title: "Same workspace",
                  surfaces: [.init(id: $0.1, title: "Same terminal", kind: .terminal, isFocused: true)])
        })
    }

    private func context(
        _ recorder: Recorder, snapshot: CmuxSidebarSnapshot? = nil,
        grants: Set<CmuxExtensionActionScope> = [.splitSurface, .openURL],
        readScopes: Set<CmuxExtensionScope> = [.workspaceMetadata, .surfaceMetadata]
    ) -> CmuxSidebarContext {
        .init(snapshot: (snapshot ?? self.snapshot()).filtered(for: readScopes, actionScopes: grants),
              host: .init(performAction: { action, reply in recorder.perform(action, reply: reply) }))
    }

    @MainActor
    private final class Recorder {
        var actions: [CmuxSidebarAction] = []
        let hold: Bool
        var completion: (@MainActor @Sendable (CmuxSidebarActionResult) -> Void)?
        init(hold: Bool = false) { self.hold = hold }
        func perform(_ action: CmuxSidebarAction, reply: @escaping @MainActor @Sendable (CmuxSidebarActionResult) -> Void) {
            actions.append(action)
            if hold { completion = reply } else { reply(.accepted) }
        }
        func reply(_ result: CmuxSidebarActionResult) {
            let captured = completion
            completion = nil
            captured?(result)
        }
    }
}
