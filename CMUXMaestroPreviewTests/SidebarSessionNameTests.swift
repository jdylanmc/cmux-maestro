import AppKit
import SwiftUI
import Testing

/// Agent rows lead with Copilot's session name (ADR 0022). Synthetic offscreen renders and
/// presentation data only; this does not prove CMUX-hosted behaviour.
@MainActor
@Suite(.serialized, SidebarAppKitTestScope())
struct SidebarSessionNameTests {
    private static let namedSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000005A1")!
    private static let unnamedSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000005A2")!
    private static let plainSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000005A3")!
    private static let browserSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000005A4")!
    private static let namedSession = UUID(uuidString: "5A000000-0000-0000-0000-0000000000A1")!
    private static let unnamedSession = UUID(uuidString: "77777777-0000-0000-0000-0000000000A2")!
    private static let managedSession = UUID(uuidString: "5C000000-0000-0000-0000-0000000000A3")!

    private static let namedTitle = "SYNTHETIC-ALPHA - Waiting…"
    private static let unnamedTitle = "SYNTHETIC-BETA - Proposing foc…"
    private static let plainTitle = "Synthetic plain shell - zsh"
    private static let browserTitle = "Synthetic page - Docs"

    private struct Observed {
        let id: UUID
        let surface: UUID
        var name: String?
        var state: CopilotWorkState = .idle
    }

    @MainActor private struct Rendered {
        let window: NSWindow
        let hosting: NSView
        let model: SidebarConnectionModel
        let polling: SidebarCopilotPolling
        let stores: SidebarStoreFixture
        let hierarchy: HierarchySnapshot

        func views(_ view: NSView? = nil) -> [NSView] {
            let root = view ?? hosting
            return root.subviews.flatMap { [$0] + views($0) }
        }
        var titles: [SidebarTitleNativeButton] { views().compactMap { $0 as? SidebarTitleNativeButton } }
        var labels: [String] { titles.compactMap { $0.accessibilityLabel() } }
        func title(_ label: String) -> SidebarTitleNativeButton? { titles.first { $0.accessibilityLabel() == label } }
        func frame(_ view: NSView) -> CGRect { hosting.convert(view.bounds, from: view) }
        func text(_ view: NSView? = nil, _ file: String) throws -> String {
            let target = view ?? hosting
            target.layoutSubtreeIfNeeded()
            let bitmap = try #require(target.bitmapImageRepForCachingDisplay(in: target.bounds))
            target.cacheDisplay(in: target.bounds, to: bitmap)
            let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/layout-validation/offscreen")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Popover content is transparent; flatten onto white so OCR sees every line.
            let raw = try #require(bitmap.cgImage)
            let context = try #require(CGContext(
                data: nil, width: raw.width, height: raw.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: raw.width, height: raw.height))
            context.draw(raw, in: CGRect(x: 0, y: 0, width: raw.width, height: raw.height))
            let flat = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
            let url = folder.appendingPathComponent(file)
            try #require(flat.representation(using: .png, properties: [:])).write(to: url)
            return try SidebarRenderingEvidence.recognizedLines(in: url).joined(separator: "\n")
        }
        func close() {
            for child in window.childWindows ?? [] { child.close() }
            window.contentView = nil
            window.close()
            model.setVisible(false)
            stores.cleanup()
        }
    }

    private static let standard = [
        Observed(id: namedSession, surface: namedSurface, name: "Synthetic review task"),
        Observed(id: unnamedSession, surface: unnamedSurface, name: nil, state: .working)
    ]

    private func render(
        _ observed: [Observed] = standard, managedOn managedSurface: UUID? = nil, beatFor beat: UUID? = nil,
        width: CGFloat = 340, preferences: SidebarPreferences, until ready: @escaping (Rendered) -> Bool
    ) async throws -> Rendered {
        let f = SidebarTreeFixtures()
        let stores = SidebarStoreFixture()
        preferences.selectedMode = .hierarchy
        if let beat {
            #expect(stores.beats.perform { _ = try $0.create(session: beat, cron: "0 9 * * *", prompt: "Synthetic beat") } == nil)
        }
        func surface(_ id: UUID, _ title: String, _ kind: HierarchySurfaceKind, focused: Bool = false) -> HierarchySurface {
            .init(id: id, title: title, kind: kind, isFocused: focused, isPinned: false, unreadCount: 0,
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
                    surface(Self.namedSurface, Self.namedTitle, .terminal, focused: true),
                    surface(Self.unnamedSurface, Self.unnamedTitle, .terminal),
                    surface(Self.plainSurface, Self.plainTitle, .terminal),
                    surface(Self.browserSurface, Self.browserTitle, .browser)
                ])
            )], windowID: f.windowID
        )
        let start = Date()
        var all = observed
        if let managedSurface { all.append(Observed(id: Self.managedSession, surface: managedSurface, name: "Synthetic managed name")) }
        let sessions = all
        let polling = SidebarCopilotPolling(
            read: neutralRead { _ in
                let now = Date()
                return CopilotSnapshot(generatedAt: now, sessions: sessions.map {
                    var observation = CopilotSessionObservation(
                        sessionID: $0.id, surfaceID: $0.surface, launchWorkspaceID: f.workspaceA,
                        liveness: .alive, state: $0.state, model: nil, children: [], observedAt: now)
                    observation.sessionName = $0.name
                    return observation
                }, issues: [], isComplete: true)
            },
            pause: { try await Task.sleep(for: .milliseconds(20)) }
        )
        let nodes = managedSurface.map { surface in [SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: nil, role: "worker", label: "Synthetic launch label",
            workspaceId: f.workspaceA, surfaceId: surface, generation: 1, phase: "registered",
            availability: "active", copilotSessionId: Self.managedSession, executionMode: .interactive,
            createdAt: start, updatedAt: start
        )] } ?? []
        let orchestration = SidebarOrchestrationPolling(
            read: { .init(version: 1, generatedAt: Date(), complete: true, omittedCount: 0, nodes: nodes) },
            pause: { try await Task.sleep(for: .milliseconds(200)) }
        )
        let model = SidebarConnectionModel(copilot: polling, orchestration: orchestration)
        model.replaceHierarchy(with: hierarchy)
        model.showConnected(workspaceCount: 1, surfaceCount: 4)
        let topology = SidebarTopology(hierarchy)
        polling.update(topology: topology, connected: true)
        orchestration.update(topology: topology, connected: true)
        model.navigation.update(topology: topology, connected: true, workspaceAllowed: true, surfaceAllowed: true,
                                perform: { _ in })
        orchestration.setVisible(true)
        await sidebarEventually { orchestration.snapshot.nodes.count == nodes.count && orchestration.snapshot.generatedAt >= start }
        polling.updateManagedSubjects(orchestration.snapshot)
        model.setVisible(true)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 600),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: SidebarView(model: model, preferences: preferences, stores: stores)
            .background(Color.white))
        window.contentView = hosting
        window.orderFront(nil)
        let rendered = Rendered(window: window, hosting: hosting, model: model, polling: polling,
                                stores: stores, hierarchy: hierarchy)
        await sidebarEventually {
            hosting.layoutSubtreeIfNeeded()
            return polling.tree.sessions.count == sessions.count && ready(rendered)
        }
        try await Task.sleep(for: .milliseconds(50))
        hosting.layoutSubtreeIfNeeded()
        return rendered
    }

    @Test func copilotRowShowsSessionNameAndOthersKeepTheirCMUXTitle() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let r = try await render(preferences: fixture.preferences()) {
            $0.title("Focus Terminal Synthetic review task") != nil
        }
        defer { r.close() }
        #expect(r.title("Focus Terminal Synthetic review task") != nil, "Session name replaces the surface title")
        #expect(r.labels.allSatisfy { !$0.contains("SYNTHETIC-ALPHA") },
                "The \"X - Status\" surface title is not shown for a named session")
        #expect(r.title("Focus Terminal \(Self.unnamedTitle)") != nil, "Unavailable name falls back unchanged")
        #expect(r.title("Focus Terminal \(Self.plainTitle)") != nil, "Plain terminal keeps the CMUX title")
        #expect(r.title("Focus Browser \(Self.browserTitle)") != nil, "Browser keeps the CMUX title")

        let tree = r.polling.tree
        let named = try #require(tree.sessions.first { $0.id == Self.namedSession })
        let unnamed = try #require(tree.sessions.first { $0.id == Self.unnamedSession })
        #expect(named.sessionName == "Synthetic review task")
        #expect(unnamed.sessionName == nil)
        let now = Date()
        let hover = SidebarAgentHoverContent.card(
            for: .session(Self.namedSession), hierarchy: r.hierarchy, connected: true, tree: tree,
            managed: .empty, availability: .ready, now: now)
        #expect(hover?.title == "Synthetic review task", "Hover card uses the same display name")
        let fallbackHover = SidebarAgentHoverContent.card(
            for: .session(Self.unnamedSession), hierarchy: r.hierarchy, connected: true, tree: tree,
            managed: .empty, availability: .ready, now: now)
        #expect(fallbackHover?.title == Self.unnamedTitle)
        let pinned = SidebarPresentation.pinnedDetails(
            hierarchy: r.hierarchy, connected: true, tree: tree, managed: .empty, availability: .ready, now: now)
        #expect(pinned.title == "Synthetic review task" && pinned.titleIsSessionName,
                "Active window footer matches the row")
        #expect(SidebarPresentation.agentTitle(for: unnamed, in: r.hierarchy) == Self.unnamedTitle)
    }

    @Test func twoSessionsOnOneSurfaceKeepTheTerminalTitleAndExpandedRowsShowNames() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let shared = [
            Observed(id: Self.namedSession, surface: Self.namedSurface, name: "Synthetic first agent"),
            Observed(id: Self.unnamedSession, surface: Self.namedSurface, name: nil)
        ]
        let shortNamed = String(Self.namedSession.uuidString.prefix(8)).lowercased()
        let shortUnnamed = String(Self.unnamedSession.uuidString.prefix(8)).lowercased()
        let r = try await render(shared, preferences: fixture.preferences()) {
            $0.title("Focus Copilot session Synthetic first agent, \(shortNamed)") != nil
        }
        defer { r.close() }
        #expect(r.title("Focus Terminal \(Self.namedTitle)") != nil, "Two sessions: the surface keeps its CMUX title")
        #expect(r.title("Focus Copilot session Synthetic first agent, \(shortNamed)") != nil,
                "Expanded session row leads with its name")
        #expect(r.title("Focus Copilot session \(shortUnnamed)") != nil, "Unnamed session row keeps its ID label")
        let text = try r.text(nil, "session-name-shared-surface.png")
        #expect(text.contains("Synthetic first agent"), "Rendered name: \(text)")
        #expect(text.components(separatedBy: "Synthetic first agent").count == 2, "Name drawn once, on its row: \(text)")
        #expect(text.contains("SYNTHETIC-ALPHA - Waiting"), "Shared surface keeps the terminal title: \(text)")
    }

    @Test func sessionOnAnotherAgentsSurfaceHasNoRow() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        // A managed agent owns the surface; an unmanaged named session bound there has nothing of its own to focus.
        let observed = [Observed(id: Self.namedSession, surface: Self.unnamedSurface, name: "Synthetic context name")]
        let short = String(Self.namedSession.uuidString.prefix(8)).lowercased()
        let r = try await render(observed, managedOn: Self.unnamedSurface, preferences: fixture.preferences()) {
            $0.title("Focus Synthetic launch label") != nil
        }
        defer { r.close() }
        #expect(r.titles.allSatisfy { $0.accessibilityLabel()?.contains(short) != true }, "No row for the session")
        let text = try r.text(nil, "session-name-no-context-row.png")
        #expect(!text.contains("Synthetic context name") && !text.contains(short), "No row for the session: \(text)")
        #expect(!text.contains("context"), "No context row or section: \(text)")
        #expect(text.contains("Synthetic launch label"), "Managed row keeps its launch label: \(text)")
    }

    @Test func beatTargetUsesTheSessionName() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let icons: (Rendered) -> [SidebarBeatNativeButton] = { $0.views().compactMap { $0 as? SidebarBeatNativeButton } }
        let r = try await render(beatFor: Self.namedSession, preferences: fixture.preferences()) {
            icons($0).count == 1 && $0.stores.beats.indicators.running.contains(Self.namedSession)
        }
        defer { r.close() }
        try #require(icons(r).first).performClick(nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(r.stores.beats.scopedSession == Self.namedSession)
        let panel = try #require(r.window.childWindows?.first?.contentView, "Beats panel opens")
        let text = try r.text(panel, "session-name-beat-target.png")
        #expect(text.contains("For Synthetic review task"), "Beat target titled by session name: \(text)")
        #expect(!text.contains("SYNTHETIC-ALPHA"), "Not the terminal title: \(text)")
    }

    @Test func longSessionNameStaysOnOneLineAtNarrowWidth() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let long = String(("Synthetic " + String(repeating: "long session name ", count: 11)).prefix(200))
        let observed = [Observed(id: Self.namedSession, surface: Self.namedSurface, name: long)]
        let r = try await render(observed, width: 220, preferences: fixture.preferences()) {
            $0.labels.contains { $0.hasPrefix("Focus Terminal Synthetic long session name") }
        }
        defer { r.close() }
        let named = try #require(r.titles.first {
            $0.accessibilityLabel()?.hasPrefix("Focus Terminal Synthetic long session name") == true
        })
        let plain = try #require(r.title("Focus Terminal \(Self.plainTitle)"))
        let namedFrame = r.frame(named), plainFrame = r.frame(plain)
        #expect(namedFrame.maxX <= r.hosting.bounds.width, "Title never widens the sidebar: \(namedFrame)")
        #expect(namedFrame.height == plainFrame.height, "Title stays on one line: \(namedFrame) vs \(plainFrame)")
    }

    @Test func footerStripsCopilotSuffixOnlyFromTerminalTitles() {
        var terminal = SidebarDetailContent(title: "Synthetic work - GitHub Copilot")
        terminal.isAgent = true
        #expect(SidebarPinnedFooter.displayTitle(terminal) == "Synthetic work")
        var named = terminal
        named.titleIsSessionName = true
        #expect(SidebarPinnedFooter.displayTitle(named) == "Synthetic work - GitHub Copilot",
                "A session name is shown whole")
    }
}
