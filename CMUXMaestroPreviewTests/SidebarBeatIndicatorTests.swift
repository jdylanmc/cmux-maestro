import AppKit
import SwiftUI
import Testing

/// Agent-row Beat icon: pure summary and state, controller presentation, the native glow layer,
/// and synthetic offscreen renders. Offscreen evidence only; it does not prove CMUX-hosted behaviour.
@MainActor
@Suite(.serialized, SidebarAppKitTestScope())
struct SidebarBeatIndicatorTests {
    private func beat(_ id: String, session: String, cron: String = "0 9 * * 1-5", enabled: Bool = true) -> SidebarBeat {
        SidebarBeat(id: id, sessionId: session, cron: cron, prompt: "Synthetic prompt", enabled: enabled,
                    createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", revision: 1)
    }

    private func session(_ id: UUID, _ liveness: AgentProcessLiveness, observedAt: Date = Date()) -> SidebarCopilotSession {
        let f = SidebarTreeFixtures()
        return SidebarCopilotSession(id: id, workspaceID: f.workspaceA, surfaceID: f.surfaceA, liveness: liveness,
                                     state: .idle, model: nil, observedAt: observedAt, nodes: [], childrenComplete: true,
                                     treeDegraded: false, omittedChildrenCount: 0, omittedActiveChildrenCount: 0)
    }

    // MARK: Summary

    @Test func summaryCountsEnabledBeatsPerExactSession() {
        let first = UUID(), second = UUID(), unknown = UUID()
        let summaries = SidebarBeatSummaries(beats: [
            beat("a", session: first.uuidString.lowercased(), cron: "*/15 * * * *"),
            beat("b", session: first.uuidString.lowercased(), cron: "0 9 * * *"),
            beat("c", session: first.uuidString.lowercased(), enabled: false),
            beat("d", session: second.uuidString.lowercased(), enabled: false),
            beat("e", session: unknown.uuidString.lowercased())
        ])
        #expect(summaries.summary(for: first) == .init(beatIDs: ["a", "b"], schedules: ["*/15 * * * *", "0 9 * * *"]))
        #expect(summaries.summary(for: first)?.enabledCount == 2)
        #expect(summaries.summary(for: second) == nil, "Disabled Beats never attach")
        #expect(summaries.summary(for: nil) == nil)
        // A Beat for a session no row shows stays in the summary but attaches to no other row.
        #expect(summaries.summary(for: unknown)?.enabledCount == 1)
        #expect(Set(summaries.sessions.keys) == [first, unknown])
    }

    @Test func summaryMatchesOnlyTheCanonicalSessionUUID() {
        let id = UUID()
        let summaries = SidebarBeatSummaries(beats: [
            beat("upper", session: id.uuidString),
            beat("prefix", session: String(id.uuidString.lowercased().prefix(8))),
            beat("title", session: "Synthetic agent title")
        ])
        #expect(summaries.sessions.isEmpty, "No title, prefix or non-canonical match")
        #expect(SidebarBeatSummaries(beats: []) == .empty)
    }

    @Test func controllerDerivesSummariesAndIndicatorsOnChangeOnly() throws {
        let stores = SidebarStoreFixture()
        defer { stores.cleanup() }
        let id = UUID()
        #expect(stores.beats.summaries == .empty && stores.beats.indicators == .init())
        #expect(stores.beats.perform { _ = try $0.create(session: id, cron: "0 9 * * *", prompt: "Synthetic") } == nil)
        #expect(stores.beats.summaries.summary(for: id)?.enabledCount == 1)
        #expect(stores.beats.indicators.state(for: id) == .dim, "No liveness yet")
        stores.beats.updateLiveness(.init(availability: .ready, sessions: [session(id, .alive)], issues: [], generatedAt: Date()))
        #expect(stores.beats.indicators.state(for: id) == .lit)
        let beatID = try #require(stores.beats.beats.first?.id)
        #expect(stores.beats.perform { try $0.disable(id: beatID) } == nil)
        #expect(stores.beats.summaries == .empty && stores.beats.indicators.state(for: id) == .none)
    }

    // MARK: Row state and liveness

    @Test func rowStateMapsEnabledBeatsAndLiveness() {
        let running = UUID(), ended = UUID(), unknown = UUID(), disabled = UUID()
        let summaries = SidebarBeatSummaries(beats: [
            beat("r", session: running.uuidString.lowercased()),
            beat("r2", session: running.uuidString.lowercased(), cron: "0 * * * *"),
            beat("e", session: ended.uuidString.lowercased()),
            beat("u", session: unknown.uuidString.lowercased()),
            beat("d", session: disabled.uuidString.lowercased(), enabled: false)
        ])
        let indicators = SidebarBeatIndicators(summaries: summaries, running: [running, disabled], ended: [ended])
        #expect(indicators.state(for: running) == .lit)
        #expect(indicators.state(for: ended) == .dim)
        #expect(indicators.state(for: unknown) == .dim)
        #expect(indicators.state(for: disabled) == .none)
        #expect(indicators.state(for: UUID()) == .none)
        #expect(indicators.state(for: nil) == .none)
        #expect(indicators.accessibilityValue(for: running) == "2 on, running")
        #expect(indicators.accessibilityValue(for: ended) == "1 on, not running")
        #expect(indicators.accessibilityValue(for: unknown) == "1 on, not known to be running")
        #expect(indicators.accessibilityValue(for: disabled).isEmpty)
        let help = indicators.help(for: running)
        #expect(help.hasPrefix("2 Beats on: 0 9 * * 1-5; 0 * * * *.") && !help.contains("Synthetic prompt"))
        #expect(indicators.help(for: ended).contains("Beats fire only while it runs"))
    }

    @Test func livenessIsAliveInACurrentObservation() {
        let alive = UUID(), dead = UUID(), ambiguous = UUID()
        let now = Date()
        let tree = SidebarCopilotTree(availability: .ready, sessions: [
            session(alive, .alive, observedAt: now), session(dead, .dead, observedAt: now),
            session(ambiguous, .ambiguous, observedAt: now)
        ], issues: [], generatedAt: now)
        let summaries = SidebarBeatSummaries(beats: [alive, dead, ambiguous].map {
            beat($0.uuidString, session: $0.uuidString.lowercased())
        })
        let indicators = SidebarBeatIndicators(summaries: summaries, tree: tree, now: now)
        #expect(SidebarBeatIndicators.runningSessions(in: tree).map(\.id) == [alive])
        #expect(indicators.state(for: alive) == .lit)
        #expect(indicators.state(for: dead) == .dim && indicators.accessibilityValue(for: dead).hasSuffix(", not running"))
        #expect(indicators.state(for: ambiguous) == .dim
                && indicators.accessibilityValue(for: ambiguous).hasSuffix("not known to be running"))
    }

    @Test(arguments: ["stale-observation", "stale-tree", "hidden", "disconnected", "unavailable"])
    func staleOrUnavailableLivenessIsNotKnownToBeRunning(_ condition: String) {
        let id = UUID()
        let now = Date()
        let old = now.addingTimeInterval(-(SidebarCopilotTree.maximumAge + 5))
        let availability: SidebarCopilotAvailability = switch condition {
        case "hidden": .hidden
        case "disconnected": .disconnected
        case "unavailable": .unavailable
        default: .ready
        }
        let tree = SidebarCopilotTree(
            availability: availability,
            sessions: [session(id, .alive, observedAt: condition == "stale-observation" ? old : now)],
            issues: [], generatedAt: condition == "stale-tree" ? old : now
        )
        let summaries = SidebarBeatSummaries(beats: [beat("s", session: id.uuidString.lowercased())])
        let indicators = SidebarBeatIndicators(summaries: summaries, tree: tree, now: now)
        #expect(!tree.isCurrent(tree.sessions[0], now: now))
        #expect(indicators.state(for: id) == .dim)
        #expect(indicators.accessibilityValue(for: id) == "1 on, not known to be running")
        // The same tree is current a moment later only when its evidence is.
        let fresh = SidebarCopilotTree(availability: .partial, sessions: [session(id, .alive, observedAt: now)],
                                       issues: [], generatedAt: now)
        #expect(SidebarBeatIndicators(summaries: summaries, tree: fresh, now: now).state(for: id) == .lit)
    }

    @Test func controllerDimsWhenTheClockMakesLivenessStale() {
        var clock = Date()
        let stores = SidebarStoreFixture()
        defer { stores.cleanup() }
        let controller = SidebarBeatsController(file: SidebarBeatsFile(root: stores.root.appendingPathComponent("Clocked")),
                                                now: { clock })
        let id = UUID()
        #expect(controller.perform { _ = try $0.create(session: id, cron: "0 9 * * *", prompt: "Synthetic") } == nil)
        controller.updateLiveness(.init(availability: .ready, sessions: [session(id, .alive, observedAt: clock)],
                                        issues: [], generatedAt: clock))
        #expect(controller.indicators.state(for: id) == .lit)
        clock = clock.addingTimeInterval(SidebarCopilotTree.maximumAge + 1)
        controller.refresh()
        #expect(controller.indicators.state(for: id) == .dim)
    }

    // MARK: Presentation

    @Test func presentationRescopesInPlaceAndHeaderReopenClearsScope() {
        let stores = SidebarStoreFixture()
        defer { stores.cleanup() }
        let controller = stores.beats
        let a = UUID(), b = UUID()
        #expect(!controller.isPresented && controller.scopedSession == nil)
        controller.present(scope: a)
        #expect(controller.isPresented && controller.scopedSession == a)
        controller.present(scope: b)
        #expect(controller.isPresented && controller.scopedSession == b, "A second row rescopes the open panel")
        controller.showAll()
        #expect(controller.isPresented && controller.scopedSession == nil, "Show all keeps the panel open")
        controller.present(scope: a)
        controller.present(scope: nil)
        #expect(controller.isPresented && controller.scopedSession == nil, "The header opens every Beat")
        controller.present(scope: a)
        controller.dismiss()
        #expect(!controller.isPresented && controller.scopedSession == nil, "Closing clears the scope")
    }

    @Test func sessionEndingWhileScopedKeepsScopeButCannotAddBeats() {
        let stores = SidebarStoreFixture()
        defer { stores.cleanup() }
        let controller = stores.beats
        let id = UUID()
        #expect(controller.perform { _ = try $0.create(session: id, cron: "0 9 * * *", prompt: "Synthetic") } == nil)
        let now = Date()
        controller.updateLiveness(.init(availability: .ready, sessions: [session(id, .alive, observedAt: now)],
                                        issues: [], generatedAt: now))
        controller.present(scope: id)
        let target = SidebarBeatTarget(id: id, title: "Synthetic agent", live: true)
        #expect(SidebarBeatsPanel.newBeatUnavailable(scope: id, targets: [target]) == nil)
        controller.updateLiveness(.init(availability: .ready, sessions: [session(id, .dead, observedAt: now)],
                                        issues: [], generatedAt: now))
        #expect(controller.isPresented && controller.scopedSession == id)
        #expect(controller.indicators.state(for: id) == .dim)
        #expect(controller.indicators.accessibilityValue(for: id) == "1 on, not running")
        #expect(SidebarBeatsPanel.newBeatUnavailable(scope: id, targets: []) == "Start this agent's session to add a Beat.")
        #expect(SidebarBeatsCopy.sessionTitle(id.uuidString.lowercased()) == "Session \(id.uuidString.lowercased().prefix(8))")
    }

    @Test func formHasNoShowAllAndKeepsItsDraftOnScopeChange() {
        let existing = beat("x", session: UUID().uuidString.lowercased())
        #expect(SidebarBeatsMode.list.offersShowAll)
        #expect(!SidebarBeatsMode.form(nil).offersShowAll && !SidebarBeatsMode.form(existing).offersShowAll)
        #expect(SidebarBeatsMode.form(existing).afterScopeChange() == .form(existing))
        #expect(SidebarBeatsMode.form(nil).afterScopeChange() == .form(nil))
        #expect(SidebarBeatsMode.list.afterScopeChange() == .list)
    }

    // MARK: Glow and Reduce Motion

    @Test func glowAnimatesOnlyWhenLitVisibleAndMotionIsAllowed() {
        #expect(SidebarBeatGlow.animates(.lit, reduceMotion: false, visible: true))
        #expect(!SidebarBeatGlow.animates(.lit, reduceMotion: true, visible: true))
        #expect(!SidebarBeatGlow.animates(.lit, reduceMotion: false, visible: false))
        #expect(!SidebarBeatGlow.animates(.dim, reduceMotion: false, visible: true))
        #expect(!SidebarBeatGlow.animates(.none, reduceMotion: false, visible: true))
        #expect(NSImage(systemSymbolName: SidebarBeatIndicator.symbol, accessibilityDescription: nil) != nil)
        #expect(SidebarBeatIndicator.symbol == SidebarHeaderAction.beats.symbol, "Same icon as the Beats panel button")
        #expect(SidebarBeatIndicator.titleHeight(fontSize: 11) == SidebarBeatIndicator.titleHeight(fontSize: 11))
    }

    @Test func glowLayerCarriesTheCoreAnimationPulseOnlyWhenAllowed() throws {
        let key = SidebarBeatGlow.animationKey
        let button = SidebarBeatNativeButton()
        button.frame = NSRect(x: 0, y: 0, width: 20, height: 32)
        let glyph = button.glyph
        glyph.state = .lit
        #expect(glyph.glowLayer.animation(forKey: key) == nil, "No window: no animation")
        #expect(glyph.glowLayer.opacity == SidebarBeatGlow.staticIntensity)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container
        container.addSubview(button)
        let pulse = try #require(glyph.glowLayer.animation(forKey: key) as? CABasicAnimation)
        #expect(pulse.keyPath == "opacity" && pulse.autoreverses && pulse.repeatCount == .infinity)
        #expect(pulse.duration == 1 && pulse.fromValue as? Float == SidebarBeatGlow.dimmest)
        #expect(glyph.glowLayer.contents != nil)

        glyph.reduceMotion = true
        #expect(glyph.glowLayer.animation(forKey: key) == nil, "Reduce Motion: static glow")
        #expect(glyph.glowLayer.opacity == SidebarBeatGlow.staticIntensity)
        glyph.reduceMotion = false
        #expect(glyph.glowLayer.animation(forKey: key) != nil)

        container.isHidden = true
        #expect(glyph.glowLayer.animation(forKey: key) == nil, "Hidden ancestor: no animation")
        container.isHidden = false
        #expect(glyph.glowLayer.animation(forKey: key) != nil)

        glyph.state = .dim
        #expect(glyph.glowLayer.animation(forKey: key) == nil && glyph.glowLayer.opacity == 0)
        glyph.state = .lit
        #expect(glyph.glowLayer.animation(forKey: key) != nil)
        button.removeFromSuperview()
        #expect(glyph.glowLayer.animation(forKey: key) == nil, "Leaving the window stops the pulse")
    }

    // MARK: Rendering

    private final class Navigations { var count = 0 }

    @MainActor private struct Rendered {
        let window: NSWindow
        let hosting: NSView
        let model: SidebarConnectionModel
        let stores: SidebarStoreFixture
        let navigations: Navigations
        let fixtures: SidebarTreeFixtures
        let density: SidebarDensity

        func views(_ view: NSView? = nil) -> [NSView] {
            let root = view ?? hosting
            return root.subviews.flatMap { [$0] + views($0) }
        }
        var icons: [SidebarBeatNativeButton] { views().compactMap { $0 as? SidebarBeatNativeButton } }
        func title(_ label: String) -> SidebarTitleNativeButton? {
            views().compactMap { $0 as? SidebarTitleNativeButton }.first { $0.accessibilityLabel() == label }
        }
        func frame(_ view: NSView) -> CGRect { hosting.convert(view.bounds, from: view) }
        func close() {
            for child in window.childWindows ?? [] { child.close() }
            window.contentView = nil
            window.close()
            model.setVisible(false)
            stores.cleanup()
        }
    }

    /// Two terminal rows, each with one live session. Beats: two on for A, B as given, one for an unseen session.
    private func render(otherBeatEnabled: Bool = false, preferences: SidebarPreferences) async throws -> Rendered {
        let f = SidebarTreeFixtures()
        let stores = SidebarStoreFixture()
        preferences.selectedMode = .hierarchy
        #expect(stores.beats.perform {
            _ = try $0.create(session: f.sessionID, cron: "*/15 * * * *", prompt: "Synthetic check")
            _ = try $0.create(session: f.sessionID, cron: "0 9 * * 1-5", prompt: "Synthetic plan")
            let other = try $0.create(session: f.otherSessionID, cron: "0 12 * * *", prompt: "Synthetic off")
            if !otherBeatEnabled { try $0.disable(id: other.id) }
            _ = try $0.create(session: UUID(), cron: "0 18 * * *", prompt: "Synthetic elsewhere")
        } == nil)
        func surface(_ id: UUID, _ title: String, pinned: Bool, unread: Int) -> HierarchySurface {
            .init(id: id, title: title, kind: .terminal, isFocused: false, isPinned: pinned, unreadCount: unread,
                  workingDirectory: .available(nil))
        }
        let hierarchy = HierarchySnapshot(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true, workspaceMetadataAvailable: true,
            surfaceMetadataAvailable: true, workspacePathsAvailable: true,
            workspaces: [.init(
                id: f.workspaceA, title: .available("Synthetic workspace"), detail: .available(nil),
                isSelected: .available(true), isPinned: .available(false), unreadCount: .available(0),
                rootPath: .available(nil), projectRootPath: .available(nil),
                surfaces: .available([
                    surface(f.surfaceA, "Synthetic beat agent", pinned: true, unread: 3),
                    surface(f.surfaceB, "Synthetic quiet agent", pinned: false, unread: 0)
                ])
            )], windowID: f.windowID
        )
        let observations = [
            f.session(id: f.sessionID, surface: f.surfaceA, liveness: .alive, state: .idle),
            f.session(id: f.otherSessionID, surface: f.surfaceB, liveness: .alive, state: .idle)
        ]
        let polling = SidebarCopilotPolling(
            read: neutralRead { _ in
                let now = Date()
                return CopilotSnapshot(generatedAt: now, sessions: observations.map {
                    CopilotSessionObservation(sessionID: $0.sessionID, surfaceID: $0.surfaceID,
                                              launchWorkspaceID: $0.launchWorkspaceID, liveness: $0.liveness,
                                              state: $0.state, model: nil, children: [], observedAt: now)
                }, issues: [], isComplete: true)
            },
            pause: { try await Task.sleep(for: .milliseconds(20)) }
        )
        let model = SidebarConnectionModel(copilot: polling)
        model.replaceHierarchy(with: hierarchy)
        model.showConnected(workspaceCount: 1, surfaceCount: 2)
        let topology = SidebarTopology(hierarchy)
        let navigations = Navigations()
        polling.update(topology: topology, connected: true)
        model.navigation.update(topology: topology, connected: true, workspaceAllowed: true, surfaceAllowed: true,
                                perform: { _ in navigations.count += 1 })
        model.setVisible(true)
        // Titled and ordered front, as the inspector popover test does, so the Beats popover can present.
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 340, height: 600),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: SidebarView(model: model, preferences: preferences, stores: stores)
            .background(Color.white))
        window.contentView = hosting
        window.orderFront(nil)
        let rendered = Rendered(window: window, hosting: hosting, model: model, stores: stores,
                                navigations: navigations, fixtures: f, density: preferences.layout.density)
        let expectedIcons = otherBeatEnabled ? 2 : 1
        await sidebarEventually {
            hosting.layoutSubtreeIfNeeded()
            return polling.tree.sessions.count == 2 && rendered.icons.count == expectedIcons
                && stores.beats.indicators.running.contains(f.sessionID)
        }
        try await Task.sleep(for: .milliseconds(50))
        hosting.layoutSubtreeIfNeeded()
        return rendered
    }

    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func ink(_ bitmap: NSBitmapImageRep, in rect: CGRect, of view: NSView) throws -> Int {
        let scale = Double(bitmap.pixelsWide) / Double(view.bounds.width)
        var count = 0
        guard rect.width > 0, rect.height > 0 else { return 0 }
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if color.redComponent + color.greenComponent + color.blueComponent < 2.7 { count += 1 }
            }
        }
        return count
    }

    private var evidenceFolder: URL {
        get throws {
            let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/layout-validation/offscreen")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
    }

    @Test func iconIsTheRightmostItemAtRestAndOnHover() async throws {
        let preferenceFixture = try SidebarPreferenceFixture()
        defer { preferenceFixture.cleanup() }
        let r = try await render(preferences: preferenceFixture.preferences())
        defer { r.close() }
        try #require(r.icons.count == 1, "Only the session with an enabled Beat shows the icon")
        let icon = try #require(r.icons.first)
        #expect(icon.accessibilityLabel() == "Beats for this agent")
        #expect(icon.accessibilityValue() as? String == "2 on, running")
        #expect(icon.accessibilityRole() == .button && icon.isEnabled)
        let tip = try #require(icon.toolTip)
        #expect(tip.contains("*/15 * * * *") && tip.contains("0 9 * * 1-5"))
        #expect(!tip.contains("Synthetic check") && !tip.contains("0 18 * * *") && !tip.contains("0 12 * * *"))

        let title = try #require(r.title("Focus Terminal Synthetic beat agent"))
        #expect(r.title("Focus Terminal Synthetic quiet agent") != nil)
        let iconFrame = r.frame(icon)
        let titleFrame = r.frame(title)
        let titleLine = SidebarBeatIndicator.titleHeight(fontSize: r.density.rowTitleSize)
        #expect(iconFrame.minX >= titleFrame.maxX + 24, "After the 24-point actions slot")
        #expect(iconFrame.width == SidebarBeatIndicator.width && iconFrame.height == titleLine + 18)
        #expect(abs(iconFrame.midY - titleFrame.midY) <= 1, "Glyph sits on the title line of the same row")
        // Trailing content edge: where the header's rightmost control ends (SidebarHeaderTests: width - 5).
        let headerEdge = try #require(r.views().compactMap { $0 as? NSButton }
            .filter { r.frame($0).size == CGSize(width: 28, height: 28) }.map { r.frame($0).maxX }.max())
        #expect(abs(iconFrame.maxX - headerEdge) <= 2,
                "Icon ends at the row's trailing content edge: icon \(iconFrame.maxX), header \(headerEdge)")
        let glyphRect = icon.glyph.convert(icon.glyph.glyphRect, to: r.hosting)
        #expect(abs(glyphRect.maxX - (headerEdge - SidebarBeatGlyphView.trailingInset)) <= 1,
                "Visible glyph sits 8 pt in from the trailing edge: \(glyphRect.maxX) vs \(headerEdge)")
        let band = CGRect(x: 0, y: iconFrame.minY, width: r.hosting.bounds.width, height: titleLine)
        let right = CGRect(x: iconFrame.maxX + 1, y: band.minY,
                           width: max(0, r.hosting.bounds.width - iconFrame.maxX - 2), height: band.height)
        let slot = CGRect(x: iconFrame.minX - 26, y: iconFrame.minY, width: 24, height: iconFrame.height)

        let resting = try bitmap(r.hosting)
        try #require(resting.representation(using: .png, properties: [:]))
            .write(to: try evidenceFolder.appendingPathComponent("beat-indicator-row.png"))
        #expect(try ink(resting, in: CGRect(x: titleFrame.maxX, y: band.minY, width: slot.minX - titleFrame.maxX,
                                            height: band.height), of: r.hosting) > 0, "Pin and unread before the icon")
        #expect(try ink(resting, in: iconFrame.intersection(band), of: r.hosting) > 0)
        #expect(try ink(resting, in: slot, of: r.hosting) == 0, "Actions slot is empty at rest")
        #expect(try ink(resting, in: right, of: r.hosting) == 0)
        let underTitle = CGRect(x: iconFrame.minX, y: iconFrame.minY + titleLine + 1,
                                width: iconFrame.width, height: iconFrame.height - titleLine - 1)
        #expect(try ink(resting, in: underTitle, of: r.hosting) == 0, "Glyph and glow stay on the title line")
        let glowFrame = r.frame(icon.glyph.glowView)
        #expect(glowFrame.minY == iconFrame.minY && glowFrame.height == titleLine && glowFrame.minX == iconFrame.minX)
        let glow = icon.glyph.glowView.convert(icon.glyph.glowLayer.frame, to: r.hosting)
        #expect(abs(glow.midX - glyphRect.midX) <= 0.5 && abs(glow.midY - glyphRect.midY) <= 1, "Glow under the glyph")

        // Hover/keyboard state: the actions button appears in its slot, still left of the icon.
        title.focusChanged(true)
        try await Task.sleep(for: .milliseconds(60))
        r.hosting.layoutSubtreeIfNeeded()
        #expect(r.frame(icon) == iconFrame, "Showing actions does not move the icon")
        let hovered = try bitmap(r.hosting)
        try #require(hovered.representation(using: .png, properties: [:]))
            .write(to: try evidenceFolder.appendingPathComponent("beat-indicator-row-hover.png"))
        #expect(try ink(hovered, in: slot, of: r.hosting) > 0, "Actions button shows in its slot")
        #expect(try ink(hovered, in: right, of: r.hosting) == 0, "Nothing right of the icon on hover")
        title.focusChanged(false)
    }

    @Test func clickOpensScopedBeatsWithoutNavigationOrFocus() async throws {
        let preferenceFixture = try SidebarPreferenceFixture()
        defer { preferenceFixture.cleanup() }
        let r = try await render(preferences: preferenceFixture.preferences())
        defer { r.close() }
        let icon = try #require(r.icons.first)
        let responder = r.window.firstResponder
        #expect(r.stores.beats.scopedSession == nil && (r.window.childWindows ?? []).isEmpty)
        icon.performClick(nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(r.stores.beats.isPresented && r.stores.beats.scopedSession == r.fixtures.sessionID)
        #expect(r.navigations.count == 0 && r.model.navigation.status == .idle)
        #expect(r.window.firstResponder === responder)
        let popover = try #require(r.window.childWindows?.first?.contentView, "Beats panel opens")
        popover.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let image = try evidenceFolder.appendingPathComponent("beat-indicator-scoped-panel.png")
        try #require(try bitmap(popover).representation(using: .png, properties: [:])).write(to: image)
        let text = try SidebarRenderingEvidence.recognizedLines(in: image).joined(separator: "\n")
        // Scoped list: this session's two Beats only, with the way back to every Beat.
        #expect(text.contains("Show all") && text.contains("Synthetic check") && text.contains("Synthetic plan"),
                "Scoped panel: \(text)")
        #expect(!text.contains("Synthetic off") && !text.contains("Synthetic elsewhere") && !text.contains("not running"),
                "Only this session's Beats: \(text)")
        #expect(icon.accessibilityPerformPress())
        #expect(r.navigations.count == 0 && r.stores.beats.scopedSession == r.fixtures.sessionID)
    }

    @Test func secondRowRescopesTheOpenPanelInPlace() async throws {
        let preferenceFixture = try SidebarPreferenceFixture()
        defer { preferenceFixture.cleanup() }
        let r = try await render(otherBeatEnabled: true, preferences: preferenceFixture.preferences())
        defer { r.close() }
        let icons = r.icons.sorted { r.frame($0).minY < r.frame($1).minY }
        try #require(icons.count == 2)
        icons[0].performClick(nil)
        try await Task.sleep(for: .milliseconds(150))
        let panel = try #require(r.window.childWindows?.first)
        #expect(r.stores.beats.scopedSession == r.fixtures.sessionID)
        icons[1].performClick(nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(r.stores.beats.isPresented && r.stores.beats.scopedSession == r.fixtures.otherSessionID)
        #expect(r.window.childWindows?.count == 1 && r.window.childWindows?.first === panel && panel.isVisible,
                "Same popover, rescoped; never dismissed and re-presented")
        #expect(r.navigations.count == 0)
    }

    @Test func showAllAndHeaderReopenClearTheScope() async throws {
        let preferenceFixture = try SidebarPreferenceFixture()
        defer { preferenceFixture.cleanup() }
        let r = try await render(preferences: preferenceFixture.preferences())
        defer { r.close() }
        let icon = try #require(r.icons.first)
        icon.performClick(nil)
        try await Task.sleep(for: .milliseconds(150))
        let content = try #require(r.window.childWindows?.first?.contentView)
        // SwiftUI exposes borderless buttons as unlabeled AppKit buttons; "Show all" is the only one
        // outside the Beat list's scroll view on the scope line's trailing half.
        let candidates = r.views(content).compactMap { $0 as? NSButton }.filter { button in
            button.enclosingScrollView == nil && content.convert(button.bounds, from: button).minX > content.bounds.midX
        }
        try #require(candidates.count == 1, "Show all: \(candidates.map { content.convert($0.bounds, from: $0) })")
        let showAll = try #require(candidates.first)
        showAll.performClick(nil)
        try await Task.sleep(for: .milliseconds(80))
        #expect(r.stores.beats.isPresented && r.stores.beats.scopedSession == nil)

        icon.performClick(nil)
        try await Task.sleep(for: .milliseconds(80))
        #expect(r.stores.beats.scopedSession == r.fixtures.sessionID)
        // Header order is directory, Beats, Taskboard, settings (SidebarHeaderTests); its buttons are 28 points.
        let headerButtons = r.views().compactMap { $0 as? NSButton }
            .filter { r.frame($0).size == CGSize(width: 28, height: 28) }
            .sorted { r.frame($0).minX < r.frame($1).minX }
        try #require(headerButtons.count == 4 && !(headerButtons[1] is SidebarTitleNativeButton))
        let header = headerButtons[1]
        header.performClick(nil)
        try await Task.sleep(for: .milliseconds(80))
        #expect(r.stores.beats.scopedSession == nil, "Reopening from the header shows every Beat")
        #expect(r.navigations.count == 0)
    }

    @Test func formDraftSurvivesAScopeChangeAndOffersNoShowAll() async throws {
        let stores = SidebarStoreFixture()
        defer { stores.cleanup() }
        let a = UUID(), b = UUID()
        #expect(stores.beats.perform { _ = try $0.create(session: a, cron: "0 9 * * *", prompt: "Synthetic base") } == nil)
        let existing = try #require(stores.beats.beats.first)
        stores.beats.present(scope: a)
        let targets = [SidebarBeatTarget(id: a, title: "Synthetic A", live: true),
                       SidebarBeatTarget(id: b, title: "Synthetic B", live: true)]
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 340, height: 560),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Light and opaque so OCR reads every line on CI's virtual display too.
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: SidebarBeatsPanel(
            controller: stores.beats, targets: targets, mode: .form(existing), close: {})
            .background(Color.white))
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func views(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + views($0) } }
        try await Task.sleep(for: .milliseconds(80))
        hosting.layoutSubtreeIfNeeded()
        let editor = try #require(views(hosting).compactMap { $0 as? NSTextView }.first { $0.string == "Synthetic base" })
        editor.insertText(" draft", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        stores.beats.present(scope: b)
        try await Task.sleep(for: .milliseconds(80))
        hosting.layoutSubtreeIfNeeded()
        #expect(stores.beats.scopedSession == b)
        let after = try #require(views(hosting).compactMap { $0 as? NSTextView }.first)
        #expect(after.string == "Synthetic base draft", "Draft kept: \(after.string)")
        let image = try evidenceFolder.appendingPathComponent("beat-indicator-scoped-form.png")
        try #require(try bitmap(hosting).representation(using: .png, properties: [:])).write(to: image)
        let text = try SidebarRenderingEvidence.recognizedLines(in: image).joined(separator: "\n")
        #expect(text.contains("Presets") && text.contains("For Synthetic B"), "Form rendered: \(text)")
        #expect(!text.contains("Local time"), "Timing detail is a tooltip: \(text)")
        #expect(!text.contains("Show all"), "A form offers no Show all: \(text)")
        #expect(stores.beats.beats.first?.prompt == "Synthetic base", "Nothing saved")
    }

    // MARK: Terse panel copy

    /// Sentences moved out of the visible panel into tooltips and accessibility. Checked by offscreen
    /// OCR; hosted SwiftUI accessibility is not reachable here, so that copy is checked via `SidebarBeatsCopy`.
    private static let removedSentences = [
        "Recurring prompts", "No beats.", "Next (estimate)", "Local time", "Copilot decides",
        "not running", "Start this agent", "Open an agent session", "bytes", "Loaded the latest"
    ]

    private func renderPanel(_ stores: SidebarStoreFixture, targets: [SidebarBeatTarget],
                             mode: SidebarBeatsMode = .list, name: String) async throws -> String {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 340, height: 560),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: SidebarBeatsPanel(controller: stores.beats, targets: targets, mode: mode, close: {})
            .background(Color.white))
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(120))
        hosting.layoutSubtreeIfNeeded()
        let image = try evidenceFolder.appendingPathComponent(name)
        try #require(try bitmap(hosting).representation(using: .png, properties: [:])).write(to: image)
        return try SidebarRenderingEvidence.recognizedLines(in: image).joined(separator: "\n")
    }

    @Test func panelShowsNoProse() async throws {
        let stores = SidebarStoreFixture()
        defer { stores.cleanup() }
        let live = UUID(), ended = UUID()
        let targets = [SidebarBeatTarget(id: live, title: "Synthetic live", live: true)]
        let empty = try await renderPanel(stores, targets: targets, name: "beats-terse-empty.png")
        #expect(empty.contains("Beats") && empty.contains(SidebarBeatsCopy.empty), "Empty: \(empty)")
        #expect(stores.beats.perform { _ = try $0.create(session: live, cron: "0 * * * *", prompt: "Synthetic hourly") } == nil)
        #expect(stores.beats.perform { _ = try $0.create(session: ended, cron: "5 4 * * *", prompt: "Synthetic custom") } == nil)
        let list = try await renderPanel(stores, targets: targets, name: "beats-terse-list.png")
        #expect(list.contains("Hourly") && list.contains("5 4 * * *") && list.contains("Synthetic hourly"), "Rows: \(list)")
        let base = try #require(stores.beats.beats.first { $0.sessionId == live.uuidString.lowercased() })
        let form = try await renderPanel(stores, targets: targets, mode: .form(base), name: "beats-terse-form.png")
        #expect(form.contains("Presets"), "Form: \(form)")
        for rendered in [empty, list, form] {
            for sentence in Self.removedSentences {
                #expect(!rendered.contains(sentence), "\"\(sentence)\" is not visible: \(rendered)")
            }
        }
    }

    @Test func honestyFactsLiveInTooltipsAndAccessibility() throws {
        let next = Date(timeIntervalSince1970: 1_800_000_000)
        let running = SidebarBeatsCopy.rowDetail(cron: "0 * * * *", enabled: true, running: true, next: next)
        #expect(running.contains("On.") && running.contains("Next run estimate:") && running.contains("Copilot decides exact timing")
                && running.contains("only while the session runs"))
        let ended = SidebarBeatsCopy.rowDetail(cron: "0 * * * *", enabled: true, running: false, next: nil)
        #expect(ended.contains("Session not running") && ended.contains("only while the session runs") && !ended.contains("Next"))
        let off = SidebarBeatsCopy.rowDetail(cron: "0 * * * *", enabled: false, running: true, next: nil)
        #expect(off.contains("Off.") && !off.contains("Next") && !off.contains("Active") && !off.contains("Scheduled"))
        #expect(SidebarBeatsCopy.timing.contains("Copilot decides exact timing") && SidebarBeatsCopy.timing.contains("while the session is running"))
        let preview = try #require(SidebarBeatsCopy.preview([next, next.addingTimeInterval(3600)], now: next))
        #expect(preview.caption.hasPrefix("Next ≈ ") && preview.caption.count < 24)
        #expect(preview.detail.contains("estimate") && preview.detail.contains(SidebarBeatsCopy.timing))
        #expect(SidebarBeatsCopy.preview([]) == nil)
        #expect(SidebarBeatsCopy.presetLabel("0  *  * * *") == "Hourly" && SidebarBeatsCopy.presetLabel("*/15 * * * *") == "Every 15 min")
        #expect(SidebarBeatsCopy.presetLabel("0 9 * * 1-5") == "Weekdays 9:00" && SidebarBeatsCopy.presetLabel("5 4 * * *") == nil)
        #expect(SidebarBeatsCopy.byteCounter(100) == nil && SidebarBeatsCopy.byteCounter(3072) == "3072/4096 B")
        #expect(SidebarBeatsCopy.byteCounter(5000) != nil)
        #expect(SidebarBeatsPanel.newBeatUnavailable(scope: nil, targets: []) == "Open an agent session to target it.")
        #expect(BeatsError.changedElsewhere.message.contains("Load the latest"))
    }
}
