import AppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized, SidebarAppKitTestScope())
struct SidebarMotionTests {
    @Test func retainedManagedIdentityDoesNotMaskNewWorkingObservation() async throws {
        let f = SidebarTreeFixtures()
        let preferenceFixture = try SidebarPreferenceFixture()
        defer { preferenceFixture.cleanup() }
        let preferences = preferenceFixture.preferences()
        let now = Date()
        let oldDate = now.addingTimeInterval(-172_800)
        let old = SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: "Retained coordinator",
            workspaceId: f.workspaceA, surfaceId: f.surfaceA, generation: 1,
            phase: "turn-failed", availability: "idle", copilotSessionId: f.otherSessionID,
            executionMode: .interactive, createdAt: oldDate, updatedAt: oldDate
        )
        let child = SidebarOrchestrationNode(
            id: UUID(), runId: old.runId, parentId: old.id, role: "worker", label: "Protected descendant",
            workspaceId: f.workspaceA, surfaceId: f.surfaceB, generation: 1,
            phase: "permission-denied", availability: "idle", copilotSessionId: UUID(),
            executionMode: .interactive, createdAt: oldDate, updatedAt: oldDate
        )
        let snapshot = f.snapshot(sessions: [
            f.session(id: f.otherSessionID, liveness: .dead, state: .unknown, now: now),
            f.session(state: .working, now: now)
        ], now: now)
        let poller = SidebarCopilotPolling(read: { _ in snapshot }, pause: { try await Task.sleep(for: .seconds(60)) },
                                          expiryPause: sidebarFrozenExpiry, now: { now })
        let orchestration = SidebarOrchestrationPolling(read: {
            .init(version: 1, generatedAt: oldDate, complete: true, omittedCount: 0, nodes: [old, child])
        }, pause: { try await Task.sleep(for: .seconds(60)) })
        let model = SidebarConnectionModel(copilot: poller, orchestration: orchestration)
        let hierarchy = HierarchySnapshot(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true, workspaceMetadataAvailable: true,
            surfaceMetadataAvailable: true, workspacePathsAvailable: false,
            workspaces: [.init(id: f.workspaceA, title: .available("Synthetic"), detail: .available(nil),
                              isSelected: .available(true), isPinned: .available(false), unreadCount: .available(0),
                              rootPath: .unavailable, projectRootPath: .unavailable,
                              surfaces: .available([f.surfaceA, f.surfaceB].map {
                                  .init(id: $0, title: "New observed session", kind: .terminal, isFocused: false,
                                        isPinned: false, unreadCount: 0, workingDirectory: .unavailable)
                              }))], windowID: f.windowID
        )
        model.showConnected(workspaceCount: 1, surfaceCount: 2)
        model.replaceHierarchy(with: hierarchy)
        model.navigation.update(topology: SidebarTopology(hierarchy), connected: true,
                                workspaceAllowed: true, surfaceAllowed: true,
                                perform: { _ in Issue.record("Projection must not navigate") })
        model.setVisible(true)
        defer { model.setVisible(false) }
        preferences.setExpanded(true, for: .managed(old.id))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: SidebarView(model: model, preferences: preferences))
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        await sidebarEventually { poller.tree.sessions.count == 2 && orchestration.snapshot.nodes.count == 2 }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let rows = descendants(hosting).compactMap { $0 as? SidebarTitleNativeButton }
        let retainedRow = try #require(rows.first { $0.accessibilityLabel() == "Focus Retained coordinator" })
        let observedRow = try #require(rows.first { $0.accessibilityLabel() == "Focus Terminal New observed session" })
        #expect(rows.contains { $0.accessibilityLabel() == "Focus Protected descendant" })
        #expect(try greenPixels(in: retainedRow) == 0, "Never borrow the new session's working state")
        #expect(try greenPixels(in: observedRow) > 0, "The new session retains its own production status row")
        #expect(orchestration.snapshot.nodes == [old, child], "Ownership, ancestry and generations are unchanged")
        #expect(!window.isVisible && model.navigation.status == .idle)
        #expect(preferences.attention.acknowledged.isEmpty)
    }

    private func greenPixels(in row: NSView) throws -> Int {
        row.layoutSubtreeIfNeeded()
        let bitmap = try #require(row.bitmapImageRepForCachingDisplay(in: row.bounds))
        row.cacheDisplay(in: row.bounds, to: bitmap)
        var green = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.greenComponent > color.redComponent + 0.15
                    && color.greenComponent > color.blueComponent + 0.15 { green += 1 }
            }
        }
        return green
    }

    @Test func ringMakesOneLinearRevolutionAndReducedMotionHasNoPhaseChange() throws {
        #expect(SidebarPresentation.statusDescription(SidebarPresentation.state(.blocked), needsInput: true) == "Needs input. Blocked")
        #expect(SidebarPresentation.statusDescription(SidebarPresentation.state(.unknown)) == "Unknown")
        for (time, angle) in [(0.0, 0.0), (0.25, 90), (0.5, 180), (0.75, 270), (1, 0), (1.25, 90)] {
            let date = Date(timeIntervalSinceReferenceDate: time)
            #expect(SidebarPresentation.workingRotation(at: date, reduceMotion: false) == angle)
            #expect(SidebarPresentation.workingRotation(at: date, reduceMotion: true) == 0)
        }
    }

    @Test func nativeMotionAndStaticNegativeControlsStayInsideTheStatusLane() async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, reduceMotion, needsInput) in [
            ("working", false, false), ("reduced-motion", true, false), ("needs-input", false, true)
        ] {
            let host = NSHostingView(rootView:
                HStack {
                    SidebarStateBadge(visual: SidebarPresentation.state(.working), needsInput: needsInput)
                    Text("Synthetic status").font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 5)
                .environment(\._accessibilityReduceMotion, reduceMotion)
                .background(SidebarActivityBackground(visual: SidebarPresentation.state(.working)))
                .background(Color.white)
                .frame(width: 280, height: 40)
            )
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 40),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            let first = try capture(host, to: folder.appendingPathComponent("polish-\(name)-frame0.png"))
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            let second = try capture(host, to: folder.appendingPathComponent("polish-\(name)-frame1.png"))
            #expect(!window.isVisible)
            let left = differences(first, second, columns: 0..<40)
            let rest = differences(first, second, columns: 40..<first.pixelsWide)
            #expect(rest == 0, "No row shimmer or text motion: \(name)")
            if name == "working" {
                #expect(left > 0, "The actual native working ring advances while hosted")
            } else {
                #expect(left == 0, "Static negative control: \(name)")
            }
            print("P57 native motion \(name): changedStatusPixels=\(left), changedOtherPixels=\(rest)")
        }
    }

    private func capture(_ view: NSView, to file: URL) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        try #require(view.bounds == NSRect(x: 0, y: 0, width: 280, height: 40),
                     "Both native snapshots must use the same logical viewport, not a transient intrinsic height")
        let before = view.bounds
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 560, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(view.bounds == before && bitmap.size == before.size)
        print("P57 capture \(file.lastPathComponent): before=\(before), after=\(view.bounds), bitmapSize=\(bitmap.size)")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
        return bitmap
    }

    private func differences(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, columns: Range<Int>) -> Int {
        var count = 0
        for y in 0..<a.pixelsHigh {
            for x in columns {
                if a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { count += 1 }
            }
        }
        return count
    }
}
