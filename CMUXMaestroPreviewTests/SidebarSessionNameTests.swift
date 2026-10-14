import AppKit
import SwiftUI
import Testing

/// Agent rows lead with Copilot's session name (ADR 0022). Synthetic offscreen renders and
/// presentation data only; this does not prove CMUX-hosted behaviour.
@MainActor
@Suite(.serialized, SidebarAppKitTestScope())
struct SidebarSessionNameTests {
    private let namedSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000005A1")!
    private let unnamedSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000005A2")!
    private let plainSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000005A3")!
    private let browserSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000005A4")!
    private let namedSession = UUID(uuidString: "50000000-0000-0000-0000-0000000000A1")!
    private let unnamedSession = UUID(uuidString: "50000000-0000-0000-0000-0000000000A2")!

    private static let namedTitle = "SYNTHETIC-ALPHA - Waiting…"
    private static let unnamedTitle = "SYNTHETIC-BETA - Proposing foc…"
    private static let plainTitle = "Synthetic plain shell - zsh"
    private static let browserTitle = "Synthetic page - Docs"

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
        func title(_ label: String) -> SidebarTitleNativeButton? { titles.first { $0.accessibilityLabel() == label } }
        func frame(_ view: NSView) -> CGRect { hosting.convert(view.bounds, from: view) }
        func close() {
            window.contentView = nil
            window.close()
            model.setVisible(false)
            stores.cleanup()
        }
    }

    private func render(name: String, width: CGFloat, preferences: SidebarPreferences) async throws -> Rendered {
        let f = SidebarTreeFixtures()
        let stores = SidebarStoreFixture()
        preferences.selectedMode = .hierarchy
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
                    surface(namedSurface, Self.namedTitle, .terminal, focused: true),
                    surface(unnamedSurface, Self.unnamedTitle, .terminal),
                    surface(plainSurface, Self.plainTitle, .terminal),
                    surface(browserSurface, Self.browserTitle, .browser)
                ])
            )], windowID: f.windowID
        )
        let polling = SidebarCopilotPolling(
            read: neutralRead { [namedSession, unnamedSession, namedSurface, unnamedSurface] _ in
                let now = Date()
                var named = CopilotSessionObservation(
                    sessionID: namedSession, surfaceID: namedSurface, launchWorkspaceID: f.workspaceA,
                    liveness: .alive, state: .idle, model: nil, children: [], observedAt: now)
                named.sessionName = name
                let unnamed = CopilotSessionObservation(
                    sessionID: unnamedSession, surfaceID: unnamedSurface, launchWorkspaceID: f.workspaceA,
                    liveness: .alive, state: .working, model: nil, children: [], observedAt: now)
                return CopilotSnapshot(generatedAt: now, sessions: [named, unnamed], issues: [], isComplete: true)
            },
            pause: { try await Task.sleep(for: .milliseconds(20)) }
        )
        let model = SidebarConnectionModel(copilot: polling)
        model.replaceHierarchy(with: hierarchy)
        model.showConnected(workspaceCount: 1, surfaceCount: 4)
        let topology = SidebarTopology(hierarchy)
        polling.update(topology: topology, connected: true)
        model.navigation.update(topology: topology, connected: true, workspaceAllowed: true, surfaceAllowed: true,
                                perform: { _ in })
        model.setVisible(true)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: SidebarView(model: model, preferences: preferences, stores: stores)
            .background(Color.white))
        window.contentView = hosting
        let rendered = Rendered(window: window, hosting: hosting, model: model, polling: polling,
                                stores: stores, hierarchy: hierarchy)
        await sidebarEventually {
            hosting.layoutSubtreeIfNeeded()
            return polling.tree.sessions.count == 2 && rendered.titles.contains {
                $0.accessibilityLabel()?.hasPrefix("Focus Terminal \(name.prefix(20))") == true
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        hosting.layoutSubtreeIfNeeded()
        return rendered
    }

    @Test func copilotRowShowsSessionNameAndOthersKeepTheirCMUXTitle() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let r = try await render(name: "Synthetic review task", width: 340, preferences: fixture.preferences())
        defer { r.close() }
        #expect(r.title("Focus Terminal Synthetic review task") != nil, "Session name replaces the surface title")
        #expect(r.titles.allSatisfy { $0.accessibilityLabel()?.contains("SYNTHETIC-ALPHA") != true },
                "The \"X - Status\" surface title is not shown for a named session")
        #expect(r.title("Focus Terminal \(Self.unnamedTitle)") != nil, "Unavailable name falls back unchanged")
        #expect(r.title("Focus Terminal \(Self.plainTitle)") != nil, "Plain terminal keeps the CMUX title")
        #expect(r.title("Focus Browser \(Self.browserTitle)") != nil, "Browser keeps the CMUX title")

        let tree = r.polling.tree
        let named = try #require(tree.sessions.first { $0.id == namedSession })
        let unnamed = try #require(tree.sessions.first { $0.id == unnamedSession })
        #expect(named.sessionName == "Synthetic review task")
        #expect(unnamed.sessionName == nil)
        let now = Date()
        let hover = SidebarAgentHoverContent.card(
            for: .session(namedSession), hierarchy: r.hierarchy, connected: true, tree: tree,
            managed: .empty, availability: .ready, now: now)
        #expect(hover?.title == "Synthetic review task", "Hover card uses the same display name")
        let fallbackHover = SidebarAgentHoverContent.card(
            for: .session(unnamedSession), hierarchy: r.hierarchy, connected: true, tree: tree,
            managed: .empty, availability: .ready, now: now)
        #expect(fallbackHover?.title == Self.unnamedTitle)
        let pinned = SidebarPresentation.pinnedDetails(
            hierarchy: r.hierarchy, connected: true, tree: tree, managed: .empty, availability: .ready, now: now)
        #expect(pinned.title == "Synthetic review task", "Active window footer matches the row")
        #expect(SidebarPresentation.agentTitle(for: unnamed, in: r.hierarchy) == Self.unnamedTitle)
    }

    @Test func longSessionNameStaysOnOneLineAtNarrowWidth() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let long = "Synthetic " + String(repeating: "long session name ", count: 11)
        let r = try await render(name: String(long.prefix(200)), width: 220, preferences: fixture.preferences())
        defer { r.close() }
        let named = try #require(r.titles.first {
            $0.accessibilityLabel()?.hasPrefix("Focus Terminal Synthetic long session name") == true
        })
        let plain = try #require(r.title("Focus Terminal \(Self.plainTitle)"))
        let namedFrame = r.frame(named), plainFrame = r.frame(plain)
        #expect(namedFrame.maxX <= r.hosting.bounds.width, "Title never widens the sidebar: \(namedFrame)")
        #expect(namedFrame.height == plainFrame.height, "Title stays on one line: \(namedFrame) vs \(plainFrame)")
    }
}
