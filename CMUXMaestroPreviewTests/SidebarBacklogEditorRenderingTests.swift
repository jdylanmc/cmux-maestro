import AppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized, SidebarAppKitTestScope())
struct SidebarBacklogEditorRenderingTests {
    @Test(arguments: SidebarMode.allCases, [false, true])
    func firstUseEditsProductionFieldAndSavesWithoutOpening(mode: SidebarMode, submitWithReturn: Bool) async throws {
        let mounted = try Mounted(mode: mode)
        defer { mounted.close() }
        try await mounted.openEditor(usingMenu: submitWithReturn)
        let field = try #require(mounted.field)
        let editorWindow = try #require(field.window)
        let url = "https://example.com/explicit?state=open#backlog"
        try type(url, into: field)
        try render(editorWindow, name: "backlog-editor-\(mode.rawValue)-\(submitWithReturn ? "return" : "save")")
        if submitWithReturn {
            try pressReturn(in: field)
        } else {
            try press("Save", in: editorWindow)
        }
        await sidebarEventually { mounted.field == nil }
        let fresh = mounted.fixture.preferences()
        #expect(fresh.backlog.urlText(for: mounted.ids.workspaceA) == url)
        #expect(fresh.backlog.urlText(for: mounted.ids.workspaceB) == "https://example.org/other")
        #expect(fresh.backlogNotice == nil)
        await sidebarEventually { mounted.model.backlog.status == nil }
        #expect(!nodes(mounted.hosting).contains { $0.identifier == "sidebar-backlog-status" })
        #expect(mounted.hostCalls == 0, "Save/Return configures; neither opens nor separately focuses CMUX.")
        await sidebarEventually { mounted.window.isKeyWindow }
        #expect(mounted.hasLiveRootResponder)
    }

    @Test func invalidAndFailedSaveRemainVisibleAndRemovedOwnerCannotWrite() async throws {
        let mounted = try Mounted(mode: .hierarchy)
        defer { mounted.close() }
        try await mounted.openEditor(usingMenu: false)
        let field = try #require(mounted.field)
        let editorWindow = try #require(field.window)
        try type("not a URL", into: field)
        try press("Save", in: editorWindow)
        await sidebarEventually {
            mounted.preferences.backlogNotice == SidebarBacklogSettings.invalidNotice
                && editorWindow.contentView.map { nodes($0).contains {
                    $0.label == SidebarBacklogSettings.invalidNotice || $0.value == SidebarBacklogSettings.invalidNotice
                } } == true
        }
        #expect(mounted.field != nil)
        #expect(mounted.fixture.preferences().backlog.urlText(for: mounted.ids.workspaceA) == nil)

        try type("https://example.com/explicit", into: field)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: mounted.fixture.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mounted.fixture.root.path) }
        try press("Save", in: editorWindow)
        await sidebarEventually {
            mounted.preferences.backlogNotice == SidebarBacklogSettings.saveNotice
                && editorWindow.contentView.map { nodes($0).contains {
                    $0.label == SidebarBacklogSettings.saveNotice || $0.value == SidebarBacklogSettings.saveNotice
                } } == true
        }
        #expect(mounted.field != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mounted.fixture.root.path)

        let original = mounted.ids.hierarchy()
        let remaining = HierarchySnapshot(
            sequence: 2, receivedSnapshot: true, workspaceListAvailable: true,
            workspaceMetadataAvailable: true, surfaceMetadataAvailable: true, workspacePathsAvailable: true,
            workspaces: original.workspaces.filter { $0.id != mounted.ids.workspaceA },
            windowID: mounted.ids.windowID
        )
        mounted.model.backlog.update(hierarchy: remaining, connected: true, allowed: true,
                                     perform: { _ in mounted.hostCalls += 1 })
        mounted.model.replaceHierarchy(with: remaining)
        await sidebarEventually {
            mounted.field == nil || editorWindow.contentView.map {
                nodes($0).contains { $0.label == "Save" && $0.enabled == false }
            } == true
        }
        if let retainedField = mounted.field {
            try pressReturn(in: retainedField)
            #expect(mounted.preferences.backlog.urlText(for: mounted.ids.workspaceA) == nil)
            try press("Cancel", in: editorWindow)
        }
        await sidebarEventually { mounted.field == nil && mounted.window.isKeyWindow }
        let fresh = mounted.fixture.preferences()
        #expect(fresh.backlog.urlText(for: mounted.ids.workspaceA) == nil)
        #expect(fresh.backlog.urlText(for: mounted.ids.workspaceB) == "https://example.org/other")
        #expect(mounted.hostCalls == 0)
        #expect(mounted.hasLiveRootResponder, "Dismissing a removed owner's editor must not leave a detached field responder.")
    }

    private func type(_ text: String, into field: NSTextField) throws {
        let window = try #require(field.window)
        try #require(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        #expect(field.stringValue == text)
    }

    private func pressReturn(in field: NSTextField) throws {
        let window = try #require(field.window)
        try #require(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.keyDown(with: try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        )))
    }

    private func press(_ label: String, in window: NSWindow) throws {
        let content = try #require(window.contentView)
        let button = try #require(nodes(content).first { $0.label == label })
        #expect(button.enabled != false)
        #expect(button.press())
    }

    private func render(_ window: NSWindow, name: String) throws {
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: folder.appendingPathComponent("\(name).png"))
    }

    @MainActor
    private final class Mounted {
        let fixture: SidebarPreferenceFixture
        let ids = SidebarTreeFixtures()
        let preferences: SidebarPreferences
        let model: SidebarConnectionModel
        let presentation: SidebarBacklogTestHost
        var window: NSWindow { presentation.window }
        var hosting: NSView { presentation.content }
        private let priorWindows: Set<ObjectIdentifier>
        var hostCalls = 0

        init(mode: SidebarMode) throws {
            fixture = try SidebarPreferenceFixture()
            preferences = fixture.preferences()
            preferences.selectedMode = mode
            preferences.setBacklogURL("https://example.org/other", for: ids.workspaceB)
            let now = Date()
            let node = SidebarOrchestrationNode(
                id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: "Synthetic editor owner",
                workspaceId: ids.workspaceA, surfaceId: ids.surfaceA, generation: 1,
                phase: "registered", availability: "active", createdAt: now, updatedAt: now
            )
            model = SidebarConnectionModel(
                copilot: SidebarCopilotPolling(
                    read: neutralRead { _ in .init(generatedAt: now, sessions: [], issues: [], isComplete: true) },
                    pause: { try await Task.sleep(for: .seconds(60)) }, expiryPause: sidebarFrozenExpiry, now: { now }
                ),
                orchestration: SidebarOrchestrationPolling(
                    read: { .init(version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: [node]) },
                    pause: { try await Task.sleep(for: .seconds(60)) }
                )
            )
            let hierarchy = ids.hierarchy()
            model.replaceHierarchy(with: hierarchy)
            model.showConnected(workspaceCount: 2, surfaceCount: 2)
            model.copilot.update(topology: SidebarTopology(hierarchy), connected: true)
            model.orchestration.update(topology: SidebarTopology(hierarchy), connected: true)
            priorWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
            do {
                presentation = try SidebarBacklogTestHost(
                    root: SidebarView(model: model, preferences: preferences), width: 340)
            } catch {
                model.setVisible(false)
                fixture.cleanup()
                throw error
            }
            model.backlog.update(hierarchy: hierarchy, connected: true, allowed: true,
                                 perform: { [weak self] _ in self?.hostCalls += 1 })
            model.navigation.update(topology: SidebarTopology(hierarchy), connected: true,
                                    workspaceAllowed: true, surfaceAllowed: true,
                                    perform: { [weak self] _ in self?.hostCalls += 1 })
        }

        var editorWindows: [NSWindow] {
            NSApp.windows.filter {
                $0 !== window && !priorWindows.contains(ObjectIdentifier($0)) && $0.isVisible
                    && $0.contentView.map { view in
                        SidebarBacklogEditorRenderingTests.descendants(view).contains {
                            ($0 as? NSTextField)?.accessibilityIdentifier() == "backlog-url"
                        }
                    } == true
            }
        }

        var field: NSTextField? {
            editorWindows.compactMap(\.contentView)
                .flatMap { SidebarBacklogEditorRenderingTests.descendants($0) }
                .compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "backlog-url" }
        }

        var hasLiveRootResponder: Bool {
            guard let responder = window.firstResponder else { return false }
            if responder === window { return true }
            guard let view = responder as? NSView else { return false }
            return view.window === window
        }

        func openEditor(usingMenu: Bool) async throws {
            let test = SidebarBacklogEditorRenderingTests()
            defer { diagnoseEditor(stage: "after editor presentation attempt") }
            await sidebarEventually {
                let calibrated = self.presentation.sampleReadiness()
                return calibrated && test.nodes(self.hosting).contains { $0.identifier == "backlog-\(self.ids.workspaceA)" }
            }
            diagnoseEditor(stage: "before editor action")
            try #require(presentation.isPresented && presentation.minimalActionPassed)
            hosting.layoutSubtreeIfNeeded()
            if usingMenu {
                let title = try #require(SidebarBacklogEditorRenderingTests.descendants(hosting)
                    .compactMap { $0 as? SidebarTitleNativeButton }
                    .first { $0.accessibilityLabel()?.hasPrefix("Focus workspace ") == true })
                var menu: NSMenu?
                for presenter in SidebarBacklogEditorRenderingTests.descendants(hosting)
                    .compactMap({ ($0 as? SidebarRowMenuAnchorView)?.presenter }) {
                    presenter.present = { value, _, _ in menu = value }
                }
                let showActions = try #require(title.showActions)
                showActions()
                let configure = try #require(menu?.items.flatMap { $0.submenu?.items ?? [] }
                    .first { $0.title == "Configure backlog URL..." })
                let presenter = try #require(configure.target as? SidebarRowMenuPresenter)
                presenter.invoke(configure)
            } else {
                let arrow = try #require(test.nodes(hosting).first { $0.identifier == "backlog-\(ids.workspaceA)" })
                #expect(arrow.press())
                #expect(model.backlog.status == .missingURL)
            }
            await sidebarEventually { self.field != nil }
            _ = try #require(field)
        }

        private func diagnoseEditor(stage: String) {
            presentation.diagnose(stage: stage)
            let candidates = NSApp.windows.filter {
                $0 === window || !priorWindows.contains(ObjectIdentifier($0))
            }
            print("Backlog \(stage) windows: \(candidates.count), showing \(min(candidates.count, 16))")
            for candidate in candidates.prefix(16) {
                var pending = candidate.contentView.map { [$0] } ?? []
                var views: [NSView] = []
                while views.count < 2_048, let view = pending.popLast() {
                    views.append(view)
                    pending += view.subviews
                }
                if !pending.isEmpty { print("Backlog native-view diagnostics reached the 2048-view bound.") }
                let fields = views.compactMap { $0 as? NSTextField }
                let exposed = candidate.contentView.map { SidebarBacklogEditorRenderingTests().nodes($0) } ?? []
                print("window=\(candidate.windowNumber) root=\(candidate === window) "
                      + "parent=\(String(describing: candidate.parent?.windowNumber)) visible=\(candidate.isVisible) "
                      + "key=\(candidate.isKeyWindow) frame=\(candidate.frame) "
                      + "controller=\(String(describing: candidate.contentViewController.map { Swift.type(of: $0) })) "
                      + "fields=\(fields.count) exactFields=\(fields.filter { $0.accessibilityIdentifier() == "backlog-url" }.count) "
                      + "exposedFields=\(exposed.filter { $0.identifier == "backlog-url" }.count)")
                for field in fields.prefix(32) {
                    print("fieldType=\(Swift.type(of: field)) id=\(field.accessibilityIdentifier() ?? "-") "
                          + "editable=\(field.isEditable) enabled=\(field.isEnabled) frame=\(field.frame)")
                }
                if fields.count > 32 { print("Backlog field diagnostics limited to first 32 of \(fields.count).") }
            }
        }

        func close() {
            model.setVisible(false)
            for editor in editorWindows { editor.close() }
            for child in window.childWindows ?? [] { child.close() }
            presentation.close()
            fixture.cleanup()
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private struct Accessible {
        let object: NSObject
        var identifier: String? { (object as AnyObject).accessibilityIdentifier?() ?? nil }
        var label: String? { (object as AnyObject).accessibilityLabel?() ?? nil }
        var value: String? {
            let selector = NSSelectorFromString("accessibilityValue")
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue() as? String
        }
        var enabled: Bool? { (object as AnyObject).isAccessibilityEnabled?() }
        func press() -> Bool { (object as AnyObject).accessibilityPerformPress?() ?? false }
    }

    private func nodes(_ view: NSView) -> [Accessible] {
        var pending: [NSObject] = [view]
        var visited = Set<ObjectIdentifier>()
        var result: [Accessible] = []
        while let object = pending.popLast(), result.count < 2_048 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            result.append(.init(object: object))
            let children = (object as AnyObject).accessibilityChildren?() ?? []
            pending += NSAccessibility.unignoredChildren(from: children).compactMap { $0 as? NSObject }
        }
        return result
    }
}
