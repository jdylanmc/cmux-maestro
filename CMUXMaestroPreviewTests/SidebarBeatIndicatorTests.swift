import AppKit
import SwiftUI
import Testing

/// Agent-row Beat icon: pure summary and state, plus one synthetic offscreen render.
/// Offscreen evidence only; it does not prove CMUX-hosted behaviour.
@MainActor
@Suite(.serialized, SidebarAppKitTestScope())
struct SidebarBeatIndicatorTests {
    private func beat(_ id: String, session: String, cron: String = "0 9 * * 1-5", enabled: Bool = true) -> SidebarBeat {
        SidebarBeat(id: id, sessionId: session, cron: cron, prompt: "Synthetic prompt", enabled: enabled,
                    createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", revision: 1)
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

    @Test func controllerDerivesSummariesOnRefreshOnly() throws {
        let stores = SidebarStoreFixture()
        defer { stores.cleanup() }
        let session = UUID()
        #expect(stores.beats.summaries == .empty)
        #expect(stores.beats.perform { _ = try $0.create(session: session, cron: "0 9 * * *", prompt: "Synthetic") } == nil)
        #expect(stores.beats.summaries.summary(for: session)?.enabledCount == 1)
        let id = try #require(stores.beats.beats.first?.id)
        #expect(stores.beats.perform { try $0.disable(id: id) } == nil)
        #expect(stores.beats.summaries == .empty)
    }

    // MARK: Row state

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

    @Test func livenessComesFromTheBeatsPanelTargets() {
        let f = SidebarTreeFixtures()
        func session(_ id: UUID, _ liveness: AgentProcessLiveness) -> SidebarCopilotSession {
            SidebarCopilotSession(id: id, workspaceID: f.workspaceA, surfaceID: f.surfaceA, liveness: liveness,
                                  state: .idle, model: nil, observedAt: Date(), nodes: [], childrenComplete: true,
                                  treeDegraded: false, omittedChildrenCount: 0, omittedActiveChildrenCount: 0)
        }
        let alive = UUID(), dead = UUID(), ambiguous = UUID()
        let tree = SidebarCopilotTree(availability: .ready, sessions: [
            session(alive, .alive), session(dead, .dead), session(ambiguous, .ambiguous)
        ], issues: [], generatedAt: Date())
        let summaries = SidebarBeatSummaries(beats: [alive, dead, ambiguous].map {
            beat($0.uuidString, session: $0.uuidString.lowercased())
        })
        let indicators = SidebarBeatIndicators(summaries: summaries, tree: tree)
        #expect(SidebarBeatIndicators.runningSessions(in: tree).map(\.id) == [alive])
        #expect(indicators.state(for: alive) == .lit)
        #expect(indicators.state(for: dead) == .dim && indicators.accessibilityValue(for: dead).hasSuffix("not running"))
        #expect(indicators.state(for: ambiguous) == .dim
                && indicators.accessibilityValue(for: ambiguous).hasSuffix("not known to be running"))
    }

    // MARK: Glow and Reduce Motion

    @Test func glowBreathesOnlyWhenLitAndMotionIsAllowed() {
        #expect(SidebarBeatGlow.animates(.lit, reduceMotion: false))
        #expect(!SidebarBeatGlow.animates(.lit, reduceMotion: true))
        #expect(!SidebarBeatGlow.animates(.dim, reduceMotion: false))
        #expect(!SidebarBeatGlow.animates(.none, reduceMotion: false))
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let samples = stride(from: 0.0, to: SidebarBeatGlow.period, by: 0.1).map {
            SidebarBeatGlow.intensity(.lit, at: start.addingTimeInterval($0), reduceMotion: false)
        }
        #expect(samples.allSatisfy { $0 >= 0.35 && $0 <= 1 } && samples.max()! - samples.min()! > 0.6)
        // One breath every period.
        #expect(abs(SidebarBeatGlow.intensity(.lit, at: start, reduceMotion: false)
                    - SidebarBeatGlow.intensity(.lit, at: start.addingTimeInterval(SidebarBeatGlow.period), reduceMotion: false)) < 1e-9)
        for offset in [0.0, 0.5, 1.3] {
            #expect(SidebarBeatGlow.intensity(.lit, at: start.addingTimeInterval(offset), reduceMotion: true)
                    == SidebarBeatGlow.staticIntensity, "Reduce Motion keeps a static glow")
            #expect(SidebarBeatGlow.intensity(.dim, at: start.addingTimeInterval(offset), reduceMotion: false) == 0)
        }
        #expect(NSImage(systemSymbolName: SidebarBeatIndicator.symbol, accessibilityDescription: nil) != nil)
        #expect(SidebarBeatIndicator.symbol == SidebarHeaderAction.beats.symbol, "Same icon as the Beats panel button")
    }

    // MARK: Rendering

    @Test func iconIsTrailingOnTheBeatTargetRowAndOpensScopedBeats() async throws {
        let f = SidebarTreeFixtures()
        let preferenceFixture = try SidebarPreferenceFixture()
        let stores = SidebarStoreFixture()
        defer { preferenceFixture.cleanup(); stores.cleanup() }
        let preferences = preferenceFixture.preferences()
        preferences.selectedMode = .hierarchy
        #expect(stores.beats.perform {
            _ = try $0.create(session: f.sessionID, cron: "*/15 * * * *", prompt: "Synthetic check")
            _ = try $0.create(session: f.sessionID, cron: "0 9 * * 1-5", prompt: "Synthetic plan")
            let quiet = try $0.create(session: f.otherSessionID, cron: "0 12 * * *", prompt: "Synthetic off")
            try $0.disable(id: quiet.id)
            _ = try $0.create(session: UUID(), cron: "0 18 * * *", prompt: "Synthetic elsewhere")
        } == nil)

        let now = Date()
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
            f.session(id: f.sessionID, surface: f.surfaceA, liveness: .alive, state: .idle, now: now),
            f.session(id: f.otherSessionID, surface: f.surfaceB, liveness: .alive, state: .idle, now: now)
        ]
        let polling = SidebarCopilotPolling(
            read: neutralRead { _ in CopilotSnapshot(generatedAt: Date(), sessions: observations, issues: [], isComplete: true) },
            pause: { try await Task.sleep(for: .milliseconds(20)) }
        )
        let model = SidebarConnectionModel(copilot: polling)
        model.replaceHierarchy(with: hierarchy)
        model.showConnected(workspaceCount: 1, surfaceCount: 2)
        let topology = SidebarTopology(hierarchy)
        var navigations = 0
        polling.update(topology: topology, connected: true)
        model.navigation.update(topology: topology, connected: true, workspaceAllowed: true, surfaceAllowed: true,
                                perform: { _ in navigations += 1 })
        model.setVisible(true)
        defer { model.setVisible(false) }

        let width = 340
        // Titled and ordered front, as the inspector popover test does, so the Beats popover can present.
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 600),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: SidebarView(model: model, preferences: preferences, stores: stores)
            .background(Color.white))
        window.contentView = hosting
        window.orderFront(nil)
        defer {
            for child in window.childWindows ?? [] { child.close() }
            window.contentView = nil
            window.close()
        }
        func views(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + views($0) } }
        await sidebarEventually {
            hosting.layoutSubtreeIfNeeded()
            return polling.tree.sessions.count == 2 && views(hosting).contains { $0 is SidebarBeatNativeButton }
        }
        try await Task.sleep(for: .milliseconds(50))
        hosting.layoutSubtreeIfNeeded()

        let icons = views(hosting).compactMap { $0 as? SidebarBeatNativeButton }
        try #require(icons.count == 1, "Only the session with an enabled Beat shows the icon")
        let icon = try #require(icons.first)
        #expect(icon.accessibilityLabel() == "Beats for this agent")
        #expect(icon.accessibilityValue() as? String == "2 on, running")
        #expect(icon.accessibilityRole() == .button && icon.isEnabled)
        let tip = try #require(icon.toolTip)
        #expect(tip.contains("*/15 * * * *") && tip.contains("0 9 * * 1-5"))
        #expect(!tip.contains("Synthetic check") && !tip.contains("0 18 * * *") && !tip.contains("0 12 * * *"))

        let titles = views(hosting).compactMap { $0 as? SidebarTitleNativeButton }
        let beatTitle = try #require(titles.first { $0.accessibilityLabel() == "Focus Terminal Synthetic beat agent" })
        #expect(titles.contains { $0.accessibilityLabel() == "Focus Terminal Synthetic quiet agent" })
        let iconFrame = hosting.convert(icon.bounds, from: icon)
        let titleFrame = hosting.convert(beatTitle.bounds, from: beatTitle)
        let titleLine = SidebarBeatIndicator.titleHeight(fontSize: preferences.layout.density.rowTitleSize)
        #expect(iconFrame.minX >= titleFrame.maxX)
        #expect(iconFrame.width == 20 && iconFrame.height == titleLine + 18)
        #expect(abs(iconFrame.midY - titleFrame.midY) <= 1, "Glyph sits on the title line of the same row")

        // Pixels: pin and unread ink lie between the title and the icon; nothing lies to its right.
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let scale = Double(bitmap.pixelsWide) / Double(hosting.bounds.width)
        func ink(_ rect: CGRect) throws -> Int {
            var count = 0
            for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
                for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                    let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if color.redComponent + color.greenComponent + color.blueComponent < 2.7 { count += 1 }
                }
            }
            return count
        }
        let band = CGRect(x: 0, y: iconFrame.minY, width: hosting.bounds.width, height: titleLine)
        #expect(try ink(CGRect(x: titleFrame.maxX, y: band.minY, width: iconFrame.minX - titleFrame.maxX, height: band.height)) > 0)
        #expect(try ink(CGRect(x: iconFrame.minX, y: band.minY, width: iconFrame.width, height: band.height)) > 0)
        #expect(try ink(CGRect(x: iconFrame.maxX + 1, y: band.minY,
                               width: max(0, hosting.bounds.width - iconFrame.maxX - 2), height: band.height)) == 0)
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: folder.appendingPathComponent("beat-indicator-row.png"))

        // Click: scoped Beats panel, no CMUX navigation, no focus change.
        let responder = window.firstResponder
        #expect(stores.beats.scopedSession == nil && (window.childWindows ?? []).isEmpty)
        icon.performClick(nil)
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        #expect(stores.beats.scopedSession == f.sessionID)
        #expect(navigations == 0 && model.navigation.status == .idle)
        #expect(window.firstResponder === responder)
        let popover = try #require(window.childWindows?.first?.contentView, "Beats panel opens")
        popover.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let panelBitmap = try #require(popover.bitmapImageRepForCachingDisplay(in: popover.bounds))
        popover.cacheDisplay(in: popover.bounds, to: panelBitmap)
        let panelImage = folder.appendingPathComponent("beat-indicator-scoped-panel.png")
        try #require(panelBitmap.representation(using: .png, properties: [:])).write(to: panelImage)
        let text = try SidebarRenderingEvidence.recognizedLines(in: panelImage).joined(separator: "\n")
        // Scoped list: this session's two Beats only, with the way back to every Beat.
        #expect(text.contains("Show all") && text.contains("Synthetic check") && text.contains("Synthetic plan"),
                "Scoped panel: \(text)")
        #expect(!text.contains("Synthetic off") && !text.contains("Synthetic elsewhere") && !text.contains("not running"),
                "Only this session's Beats: \(text)")
        #expect(icon.accessibilityPerformPress())
        #expect(navigations == 0 && stores.beats.scopedSession == f.sessionID)
    }
}
