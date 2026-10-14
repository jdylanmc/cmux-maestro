import AppKit
import SwiftUI
import Testing

/// An expanded agent row and its rendered descendants hover and show focus as one group.
/// Synthetic offscreen renders only; this does not prove CMUX-hosted behaviour.
@MainActor
@Suite(.serialized, SidebarAppKitTestScope())
struct SidebarRowGroupTests {
    private let f = SidebarTreeFixtures()
    private let plainSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000006A3")!
    private let managedRootSession = UUID(uuidString: "60000000-0000-0000-0000-0000000000B1")!
    private let managedChildSession = UUID(uuidString: "60000000-0000-0000-0000-0000000000B2")!
    private let secondSession = UUID(uuidString: "60000000-0000-0000-0000-0000000000B3")!

    @MainActor private struct Rendered {
        let window: NSWindow
        let hosting: NSView
        let model: SidebarConnectionModel
        let stores: SidebarStoreFixture

        func views(_ view: NSView? = nil) -> [NSView] {
            (view ?? hosting).subviews.flatMap { [$0] + views($0) }
        }
        var titles: [SidebarTitleNativeButton] { views().compactMap { $0 as? SidebarTitleNativeButton } }
        func title(prefix: String) throws -> SidebarTitleNativeButton {
            try #require(titles.first { $0.accessibilityLabel()?.hasPrefix(prefix) == true }, "No title \(prefix) in \(titles.compactMap { $0.accessibilityLabel() })")
        }
        /// An internal task row's name field; tasks render as the agent's tree-connector children.
        func task(_ name: String) throws -> NSTextField {
            try #require(tasks.first { $0.stringValue == name }, "No task \(name) in \(tasks.map(\.stringValue))")
        }
        var tasks: [NSTextField] {
            views().compactMap { $0 as? NSTextField }.filter { $0.accessibilityIdentifier() == "internal-task-name" }
        }
        var groups: [SidebarRowGroupHoverView] { views().compactMap { $0 as? SidebarRowGroupHoverView } }
        func frame(_ view: NSView) -> CGRect {
            let rect = hosting.convert(view.bounds, from: view)
            // A task name field draws 4pt below its row's band (see SidebarInternalTaskRow).
            return view.accessibilityIdentifier() == "internal-task-name" ? rect.offsetBy(dx: 0, dy: -4) : rect
        }
        /// The smallest tracked group containing both rows.
        func group(containing rows: NSView...) throws -> SidebarRowGroupHoverView {
            let frames = rows.map(frame)
            return try #require(groups
                .filter { group in frames.allSatisfy { frame(group).insetBy(dx: -0.5, dy: -0.5).contains($0) } }
                .min { frame($0).height < frame($1).height },
                "No group around \(frames) in \(groups.map(frame))")
        }

        func enter(_ group: SidebarRowGroupHoverView, at point: CGPoint) throws {
            group.mouseEntered(with: try event(.mouseEntered, at: point))
        }
        func exit(_ group: SidebarRowGroupHoverView, at point: CGPoint) throws {
            group.mouseExited(with: try event(.mouseExited, at: point))
        }
        private func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.enterExitEvent(
                with: type, location: hosting.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
            ))
        }

        func settle() async throws {
            try await Task.sleep(for: .milliseconds(350))
            hosting.layoutSubtreeIfNeeded()
        }

        func snapshot() throws -> NSBitmapImageRep {
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            return bitmap
        }

        func close() {
            window.contentView = nil
            window.close()
            model.setVisible(false)
            stores.cleanup()
        }
    }

    private struct Pixels {
        let bitmap: NSBitmapImageRep
        let scale: CGFloat
        init(_ bitmap: NSBitmapImageRep, width: CGFloat) {
            self.bitmap = bitmap
            scale = CGFloat(bitmap.pixelsWide) / width
        }
        func color(_ x: CGFloat, _ y: CGFloat) -> NSColor {
            (bitmap.colorAt(x: Int(x * scale), y: Int(y * scale)) ?? .clear).usingColorSpace(.sRGB) ?? .clear
        }
        func brightness(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            let c = color(x, y)
            return (c.redComponent + c.greenComponent + c.blueComponent) / 3
        }
        /// The focus bar's accent: clearly blue, unlike white, grey fills and black text.
        func isAccent(_ x: CGFloat, _ y: CGFloat) -> Bool {
            let c = color(x, y)
            return c.blueComponent - max(c.redComponent, c.greenComponent) > 0.2
        }
        /// Runs of accent pixels across a horizontal line.
        func accentRuns(y: CGFloat, from minX: CGFloat, to maxX: CGFloat) -> Int {
            var runs = 0, inside = false
            var x = minX
            while x < maxX {
                let accent = isAccent(x, y)
                if accent && !inside { runs += 1 }
                inside = accent
                x += 0.5
            }
            return runs
        }
    }

    private func surface(_ id: UUID, _ title: String, focused: Bool) -> HierarchySurface {
        .init(id: id, title: title, kind: .terminal, isFocused: focused, isPinned: false, unreadCount: 0,
              workingDirectory: .available(nil))
    }

    private func render(
        surfaces: [HierarchySurface], sessions: [CopilotSessionObservation],
        managed: [SidebarOrchestrationNode] = [], preferences: SidebarPreferences, width: CGFloat = 340,
        ready: @escaping @MainActor (Rendered) -> Bool
    ) async throws -> Rendered {
        let stores = SidebarStoreFixture()
        preferences.selectedMode = .hierarchy
        let hierarchy = HierarchySnapshot(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true, workspaceMetadataAvailable: true,
            surfaceMetadataAvailable: true, workspacePathsAvailable: true,
            workspaces: [.init(
                id: f.workspaceA, title: .available("Synthetic workspace"), detail: .available(nil),
                isSelected: .available(true), isPinned: .available(false), unreadCount: .available(0),
                rootPath: .available(nil), projectRootPath: .available(nil), surfaces: .available(surfaces)
            )], windowID: f.windowID
        )
        let polling = SidebarCopilotPolling(
            read: neutralRead { _ in CopilotSnapshot(generatedAt: Date(), sessions: sessions, issues: [], isComplete: true) },
            pause: { try await Task.sleep(for: .milliseconds(20)) }
        )
        let now = Date()
        let orchestration = SidebarOrchestrationPolling(read: {
            .init(version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: managed)
        }, pause: { try await Task.sleep(for: .seconds(60)) })
        let model = SidebarConnectionModel(copilot: polling, orchestration: orchestration)
        model.replaceHierarchy(with: hierarchy)
        model.showConnected(workspaceCount: 1, surfaceCount: surfaces.count)
        let topology = SidebarTopology(hierarchy)
        polling.update(topology: topology, connected: true)
        orchestration.update(topology: topology, connected: true)
        model.navigation.update(topology: topology, connected: true, workspaceAllowed: true, surfaceAllowed: true,
                                perform: { _ in Issue.record("Hover and focus rendering must not navigate") })
        model.setVisible(true)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: SidebarView(model: model, preferences: preferences, stores: stores)
            .background(Color.white))
        window.contentView = hosting
        let rendered = Rendered(window: window, hosting: hosting, model: model, stores: stores)
        await sidebarEventually {
            hosting.layoutSubtreeIfNeeded()
            return ready(rendered)
        }
        try await rendered.settle()
        return rendered
    }

    private func copilotSession(_ id: UUID, children: [CopilotChildWork], name: String) -> CopilotSessionObservation {
        var session = f.session(id: id, surface: f.surfaceA, state: .working, children: children)
        session.sessionName = name
        return session
    }

    private func child(_ id: String, _ name: String) -> CopilotChildWork {
        CopilotChildWork(id: id, parentID: nil, kind: .subagent, name: name, state: .working, model: nil)
    }

    private func renderCopilot(preferences: SidebarPreferences, focused: Bool = true) async throws -> Rendered {
        try await render(
            surfaces: [surface(f.surfaceA, "Synthetic agent - zsh", focused: focused),
                       surface(plainSurface, "Synthetic plain shell", focused: false)],
            sessions: [copilotSession(f.sessionID, children: [child("c1", "Synthetic child one"),
                                                              child("c2", "Synthetic child two")],
                                      name: "Synthetic agent")],
            preferences: preferences
        ) { r in
            r.tasks.contains { $0.stringValue == "Synthetic child two" }
        }
    }

    /// Hover on either the parent or a child highlights one continuous background over the whole group.
    @Test(arguments: ["parent", "child"])
    func hoveringAnyRowHighlightsTheWholeGroup(_ entry: String) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let r = try await renderCopilot(preferences: fixture.preferences(), focused: false)
        defer { r.close() }
        let head = try r.title(prefix: "Focus Terminal Synthetic agent")
        let first = try r.task("Synthetic child one")
        let last = try r.task("Synthetic child two")
        let plain = try r.title(prefix: "Focus Terminal Synthetic plain shell")
        let group = try r.group(containing: head, last)
        let groupFrame = r.frame(group)
        #expect(!groupFrame.contains(r.frame(plain)), "The next sibling surface is not part of the group")
        // The one tracked group spans parent minY to the last child's maxY.
        #expect(groupFrame.minY <= r.frame(head).minY && groupFrame.maxY >= r.frame(last).maxY, "\(groupFrame)")
        #expect(r.groups.filter { r.frame($0) == groupFrame }.count == 1)

        let width = r.hosting.bounds.width
        let before = Pixels(try r.snapshot(), width: width)
        let point = entry == "parent" ? CGPoint(x: r.frame(head).midX, y: r.frame(head).midY)
            : CGPoint(x: r.frame(first).midX, y: r.frame(first).midY)
        try r.enter(group, at: point)
        try await r.settle()
        #expect(group.isHovered)
        let after = Pixels(try r.snapshot(), width: width)

        // A blank strip near the trailing edge darkens continuously from the parent through every child.
        let x = groupFrame.maxX - 3
        var y = groupFrame.minY + 7
        var darkened = 0, total = 0
        while y < groupFrame.maxY - 7 {
            total += 1
            if after.brightness(x, y) < before.brightness(x, y) - 0.01 { darkened += 1 }
            y += 1
        }
        #expect(total > 40 && darkened == total, "Continuous group highlight: \(darkened)/\(total) at x=\(x)")
        for row in [head, first, last] {
            let rowFrame = r.frame(row)
            #expect(after.brightness(x, rowFrame.midY) < before.brightness(x, rowFrame.midY) - 0.01,
                    "Highlight covers row at y=\(rowFrame.midY)")
        }
        let below = r.frame(plain).midY
        #expect(abs(after.brightness(x, below) - before.brightness(x, below)) < 0.01, "Sibling row stays unlit")

        try r.exit(group, at: CGPoint(x: groupFrame.midX, y: groupFrame.maxY + 40))
        try await r.settle()
        let cleared = Pixels(try r.snapshot(), width: width)
        #expect(!group.isHovered)
        #expect(abs(cleared.brightness(x, r.frame(first).midY) - before.brightness(x, r.frame(first).midY)) < 0.01)
    }

    /// Group hover shows the parent's actions (…) only; children keep theirs on their own hover
    /// and add no inner highlight over the group's.
    @Test func groupHoverShowsOnlyTheParentActionsButton() {
        let hovered = SidebarRowGroupContext(hovered: true, focus: nil)
        let idle = SidebarRowGroupContext(hovered: false, focus: nil)
        #expect(SidebarRowHover.showsActions(hovered: false, focused: false, group: hovered, groupHead: true))
        #expect(!SidebarRowHover.showsActions(hovered: false, focused: false, group: hovered, groupHead: false))
        #expect(SidebarRowHover.showsActions(hovered: true, focused: false, group: hovered, groupHead: false))
        #expect(!SidebarRowHover.showsActions(hovered: false, focused: false, group: idle, groupHead: true))
        #expect(SidebarRowHover.showsActions(hovered: false, focused: true, group: idle, groupHead: false))
        #expect(SidebarRowHover.showsActions(hovered: true, focused: false, group: nil, groupHead: true))
        #expect(!SidebarRowHover.lit(hovered: true, group: hovered), "No inner child highlight inside a group")
        #expect(!SidebarRowHover.lit(hovered: true, group: idle))
        #expect(SidebarRowHover.lit(hovered: true, group: nil), "A row outside a group keeps its own highlight")
    }

    /// The focus bar spans the expanded group; collapsed, just the parent row.
    @Test(arguments: [true, false])
    func focusBarCoversTheExpandedGroupOrOnlyTheCollapsedRow(_ expanded: Bool) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let r = try await renderCopilot(preferences: preferences)
        defer { r.close() }
        let head = try r.title(prefix: "Focus Terminal Synthetic agent")
        let last = try r.task("Synthetic child two")
        let group = try r.group(containing: head, last)
        let groupFrame = r.frame(group)
        let lastFrame = r.frame(last)
        if !expanded {
            preferences.setExpanded(false, for: .surface(f.surfaceA))
            await sidebarEventually {
                r.hosting.layoutSubtreeIfNeeded()
                return r.tasks.isEmpty
            }
            try await r.settle()
        }
        let pixels = Pixels(try r.snapshot(), width: r.hosting.bounds.width)
        let headFrame = r.frame(head)
        func bar(at y: CGFloat) -> Bool {
            stride(from: groupFrame.minX - 1, through: groupFrame.minX + 3, by: 0.5).contains { pixels.isAccent($0, y) }
        }
        #expect(bar(at: headFrame.midY), "The parent row keeps its focus bar")
        if expanded {
            var y = headFrame.midY
            while y < lastFrame.maxY - 4 {
                #expect(bar(at: y), "Bar continues through children at y=\(y)")
                y += 2
            }
            #expect(bar(at: lastFrame.midY))
        } else {
            #expect(!bar(at: headFrame.maxY + 12), "Collapsed: the bar stops at the parent row")
        }
        #expect(pixels.accentRuns(y: headFrame.midY, from: 0, to: r.hosting.bounds.width) == 1, "One bar only")
    }

    /// Nested: a multi-session surface's expanded session group joins the outer surface group.
    @Test func nestedSessionGroupJoinsTheOuterGroupWithOneBarAndOneHighlight() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let r = try await render(
            surfaces: [surface(f.surfaceA, "Synthetic shared tab", focused: true),
                       surface(plainSurface, "Synthetic plain shell", focused: false)],
            sessions: [copilotSession(f.sessionID, children: [child("n1", "Synthetic nested child")], name: "Synthetic first"),
                       copilotSession(secondSession, children: [], name: "Synthetic second")],
            preferences: fixture.preferences()
        ) { r in
            r.tasks.contains { $0.stringValue == "Synthetic nested child" }
        }
        defer { r.close() }
        let head = try r.title(prefix: "Focus Terminal Synthetic shared tab")
        let nestedChild = try r.task("Synthetic nested child")
        let outer = try r.group(containing: head, nestedChild)
        let outerFrame = r.frame(outer)
        let width = r.hosting.bounds.width
        let before = Pixels(try r.snapshot(), width: width)
        let childY = r.frame(nestedChild).midY
        #expect(before.accentRuns(y: childY, from: 0, to: width) == 1, "One bar beside the nested child")
        #expect(before.accentRuns(y: r.frame(head).midY, from: 0, to: width) == 1)

        // Hovering the inner session's tracker lights nothing: the outer group owns the highlight.
        let inner = try #require(r.groups.filter {
            r.frame($0).contains(r.frame(nestedChild)) && r.frame($0).height < outerFrame.height
        }.min { r.frame($0).height < r.frame($1).height })
        try r.enter(inner, at: CGPoint(x: r.frame(nestedChild).midX, y: childY))
        try await r.settle()
        let innerOnly = Pixels(try r.snapshot(), width: width)
        let x = outerFrame.maxX - 3
        #expect(abs(innerOnly.brightness(x, childY) - before.brightness(x, childY)) < 0.01,
                "No competing nested highlight")

        try r.enter(outer, at: CGPoint(x: r.frame(nestedChild).midX, y: childY))
        try await r.settle()
        let lit = Pixels(try r.snapshot(), width: width)
        let headY = r.frame(head).midY
        #expect(lit.brightness(x, headY) < before.brightness(x, headY) - 0.01)
        #expect(lit.brightness(x, childY) < before.brightness(x, childY) - 0.01)
        // Same tint at parent and nested child: one layer, not two stacked highlights.
        #expect(abs(lit.brightness(x, childY) - lit.brightness(x, headY)) < 0.01)
    }

    /// Managed agents: the bar spans the root group when its surface is focused; a focused
    /// managed child keeps its own row-height bar and the root shows none.
    @Test(arguments: [true, false])
    func managedGroupBarFollowsTheFocusedSurfaceWithoutDoubleLines(_ rootFocused: Bool) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let now = Date()
        let root = SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: "Synthetic managed root",
            workspaceId: f.workspaceA, surfaceId: f.surfaceA, generation: 1, phase: "registered", availability: "active",
            copilotSessionId: managedRootSession, executionMode: .interactive, createdAt: now, updatedAt: now
        )
        let worker = SidebarOrchestrationNode(
            id: UUID(), runId: root.runId, parentId: root.id, role: "worker", label: "Synthetic managed child",
            workspaceId: f.workspaceA, surfaceId: f.surfaceB, generation: 1, phase: "registered", availability: "active",
            copilotSessionId: managedChildSession, executionMode: .interactive, createdAt: now, updatedAt: now
        )
        let r = try await render(
            surfaces: [surface(f.surfaceA, "Synthetic managed root", focused: rootFocused),
                       surface(f.surfaceB, "Synthetic managed child", focused: !rootFocused),
                       surface(plainSurface, "Synthetic plain shell", focused: false)],
            sessions: [f.session(id: managedRootSession, surface: f.surfaceA, state: .idle),
                       f.session(id: managedChildSession, surface: f.surfaceB, state: .idle)],
            managed: [root, worker], preferences: fixture.preferences()
        ) { r in
            r.titles.contains { $0.accessibilityLabel() == "Focus Synthetic managed child" }
                && r.titles.contains { $0.accessibilityLabel() == "Focus Synthetic managed root" }
        }
        defer { r.close() }
        let head = try r.title(prefix: "Focus Synthetic managed root")
        let childRow = try r.title(prefix: "Focus Synthetic managed child")
        let group = try r.group(containing: head, childRow)
        let width = r.hosting.bounds.width
        let pixels = Pixels(try r.snapshot(), width: width)
        let headY = r.frame(head).midY, childY = r.frame(childRow).midY
        #expect(pixels.accentRuns(y: headY, from: 0, to: width) == (rootFocused ? 1 : 0))
        #expect(pixels.accentRuns(y: childY, from: 0, to: width) == 1, "Exactly one bar beside the child")
        if rootFocused {
            #expect(stride(from: r.frame(group).minX - 1, through: r.frame(group).minX + 3, by: 0.5)
                .contains { pixels.isAccent($0, childY) }, "Root's bar spans its managed child")
        }

        let before = pixels
        try r.enter(group, at: CGPoint(x: r.frame(childRow).midX, y: childY))
        try await r.settle()
        let lit = Pixels(try r.snapshot(), width: width)
        let x = r.frame(group).maxX - 3
        #expect(lit.brightness(x, headY) < before.brightness(x, headY) - 0.01, "Hovering the child lights the root")
        #expect(lit.brightness(x, childY) < before.brightness(x, childY) - 0.01)
    }
}
