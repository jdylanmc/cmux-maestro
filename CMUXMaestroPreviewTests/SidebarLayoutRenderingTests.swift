import AppKit
import SwiftUI
import Testing

/// Offscreen synthetic SwiftUI/AppKit rendering only, not CMUX-host visual or system AX verification.
@MainActor
struct SidebarLayoutRenderingTests {
    @Test func syntheticSidebarRendersAtNarrowWidthsInBothDensitiesAndModes() async throws {
        let fixtures = SidebarTreeFixtures()
        let model = makeModel(fixtures: fixtures, longMetadata: false)
        let longModel = makeModel(fixtures: fixtures, longMetadata: true)
        defer { model.setVisible(false); longModel.setVisible(false) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent(".build/layout-validation/offscreen")
        let state = root.appendingPathComponent(".build/layout-tests/\(UUID())")
        defer { try? FileManager.default.removeItem(at: state) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "SidebarLayoutRenderingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SidebarPreferences(
            defaults: defaults,
            layoutStore: SidebarLayoutStore(file: .init(url: state.appendingPathComponent("layout.json")))
        )
        preferences.setRetention(.never)
        let scenarios: [(String, SidebarExpansionID?)] = [
            ("expanded", nil), ("workspace", .workspace(fixtures.workspaceA)),
            ("surface", .surface(fixtures.surfaceA)), ("session", .session(fixtures.sessionID)),
            ("child", .child("root", sessionID: fixtures.sessionID))
        ]
        for density in SidebarDensity.allCases {
            preferences.setDensity(density)
            for (name, collapsed) in scenarios {
                preferences.expandAll()
                if let collapsed { preferences.setExpanded(false, for: collapsed) }
                for width in [240, 320] {
                    preferences.selectedMode = .hierarchy
                    try await render(model: model, preferences: preferences, width: width,
                                     destination: folder.appendingPathComponent("\(density.rawValue)-\(name)-\(width).png"))
                }
            }
            preferences.selectedMode = .taskboard
            try await render(model: model, preferences: preferences, width: 240,
                             destination: folder.appendingPathComponent("\(density.rawValue)-taskboard-240.png"))

            let additional: [(String, RenderAppearance, SidebarConnectionModel)] = [
                ("dark", .dark, model),
                ("increased-contrast", .increasedContrast, model),
                ("long-metadata", .light, longModel),
                ("long-metadata-dark-contrast", .darkIncreasedContrast, longModel)
            ]
            for (name, appearance, scenarioModel) in additional {
                preferences.expandAll()
                // Keep a visible collapsed summary in the standard dark/contrast examples.
                if scenarioModel === model {
                    preferences.setExpanded(false, for: .child("root", sessionID: fixtures.sessionID))
                }
                for mode in SidebarMode.allCases {
                    preferences.selectedMode = mode
                    try await render(
                        model: scenarioModel, preferences: preferences, width: 240, appearance: appearance,
                        destination: folder.appendingPathComponent("\(density.rawValue)-\(name)-\(mode.rawValue)-240.png")
                    )
                }
            }
        }
    }

    private func makeModel(fixtures: SidebarTreeFixtures, longMetadata: Bool) -> SidebarConnectionModel {
        let now = Date()
        let rootLabel = "Synthetic coordinator reviewing deeply nested layout and accessibility coverage"
        let childLabel = "Synthetic child verifying long metadata without losing running or blocked status"
        var children: [CopilotChildWork] = [
            .init(id: "root", parentID: nil, kind: .subagent, name: longMetadata ? rootLabel : "Same name",
                  state: .idle, model: nil)
        ]
        if longMetadata {
            children.append(.init(
                id: "nested", parentID: "root", kind: .subagent,
                name: "Synthetic nested coordinator for the deliberately long presentation fixture",
                state: .idle, model: nil
            ))
        }
        children.append(.init(
            id: "running", parentID: longMetadata ? "nested" : "root", kind: .subagent,
            name: longMetadata ? childLabel : "Same name", state: .working, model: nil
        ))
        children.append(.init(
            id: "blocked", parentID: longMetadata ? "running" : "root", kind: .subagent,
            name: longMetadata ? "Synthetic nested child waiting for an explicit permission decision" : "Synthetic waiting task",
            state: .blocked, model: nil, attention: [
                .init(kind: .permission, evidence: .init(source: "copilot.events", eventID: fixtures.otherSessionID), occurredAt: now)
            ]
        ))
        let snapshot = fixtures.snapshot(sessions: [
            .init(sessionID: fixtures.sessionID, surfaceID: fixtures.surfaceA, launchWorkspaceID: fixtures.workspaceA,
                  liveness: .alive, state: .working,
                  model: longMetadata ? "synthetic-model-with-a-deliberately-long-display-name-for-narrow-layout-review" : nil,
                  children: children, observedAt: now)
        ], now: now)
        let polling = SidebarCopilotPolling(
            read: { _ in snapshot }, pause: { try await Task.sleep(for: .seconds(60)) }, now: { now }
        )
        let original = fixtures.hierarchy()
        let path = "/synthetic/workspaces/long-project-name/worktrees/accessible-layout/components/deeply-nested-presentation"
        let hierarchy = HierarchySnapshot(
            sequence: original.sequence, receivedSnapshot: true, workspaceListAvailable: true,
            workspaceMetadataAvailable: true, surfaceMetadataAvailable: true, workspacePathsAvailable: true,
            workspaces: original.workspaces.map { workspace in
                guard longMetadata, workspace.id == fixtures.workspaceA else { return workspace }
                return HierarchyWorkspace(
                    id: workspace.id, title: .available("Synthetic workspace with a deliberately long display title"),
                    detail: .available(nil), isSelected: .available(false), isPinned: .available(false),
                    unreadCount: .available(0), rootPath: .available(path),
                    projectRootPath: .available(path + "/project-root"),
                    surfaces: .available([
                        .init(id: fixtures.surfaceA, title: "Synthetic surface for long metadata and nested task labels",
                              kind: .terminal, isFocused: false, isPinned: false, unreadCount: 0,
                              workingDirectory: .available(path + "/project-root/feature-layout"))
                    ])
                )
            },
            windowID: fixtures.windowID
        )
        let model = SidebarConnectionModel(copilot: polling)
        model.replaceHierarchy(with: hierarchy)
        model.showConnected(workspaceCount: 2, surfaceCount: 2)
        let topology = SidebarTopology(hierarchy)
        model.navigation.update(
            topology: topology, connected: true, workspaceAllowed: true, surfaceAllowed: true, perform: { _ in }
        )
        polling.update(topology: topology, connected: true)
        model.setVisible(true)
        return model
    }

    private func render(
        model: SidebarConnectionModel, preferences: SidebarPreferences, width: Int,
        appearance: RenderAppearance = .light, destination: URL
    ) async throws {
        // Yield between renders so unrelated asynchronous navigation tests can service their deadlines.
        try await Task.sleep(for: .milliseconds(10))
        model.setVisible(true)
        await sidebarEventually { model.copilot.tree.sessions.count == 1 }
        let frame = NSRect(x: 0, y: 0, width: width, height: 1_000)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance.nativeName)
        let evidence = AppearanceEvidence()
        // The public contrast getter is read-only; this SDK-exposed backing key is test-only.
        // A high-contrast NSAppearance alone does not update SwiftUI's contrast environment.
        let view = NSHostingView(rootView: SidebarView(model: model, preferences: preferences)
            .background(AppearanceProbe(evidence: evidence).frame(width: 0, height: 0))
            .environment(\._colorSchemeContrast, appearance.contrast)
            .background(appearance.colorScheme == .dark ? Color.black : Color.white))
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        view.frame = frame
        view.layoutSubtreeIfNeeded()
        #expect(!window.isVisible)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(evidence.colorScheme == appearance.colorScheme)
        #expect(evidence.contrast == appearance.contrast)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(bitmap.pixelsWide >= width)
        #expect(bitmap.pixelsHigh >= 1_000)
        #expect(png.count > 1_024)
        try png.write(to: destination)
    }

    private enum RenderAppearance {
        case light, dark, increasedContrast, darkIncreasedContrast

        var colorScheme: ColorScheme {
            self == .dark || self == .darkIncreasedContrast ? .dark : .light
        }

        var contrast: ColorSchemeContrast {
            self == .increasedContrast || self == .darkIncreasedContrast ? .increased : .standard
        }

        var nativeName: NSAppearance.Name {
            switch self {
            case .light: .aqua
            case .dark: .darkAqua
            case .increasedContrast: .accessibilityHighContrastAqua
            case .darkIncreasedContrast: .accessibilityHighContrastDarkAqua
            }
        }

    }

    private final class AppearanceEvidence {
        var colorScheme: ColorScheme?
        var contrast: ColorSchemeContrast?
    }

    private struct AppearanceProbe: NSViewRepresentable {
        let evidence: AppearanceEvidence

        func makeNSView(context: Context) -> NSView {
            evidence.colorScheme = context.environment.colorScheme
            evidence.contrast = context.environment.colorSchemeContrast
            return NSView()
        }

        func updateNSView(_ view: NSView, context: Context) {
            evidence.colorScheme = context.environment.colorScheme
            evidence.contrast = context.environment.colorSchemeContrast
        }
    }
}
