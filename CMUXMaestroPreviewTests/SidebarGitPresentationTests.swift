import AppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized, SidebarAppKitTestScope())
struct SidebarGitPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let maximumChanges = SidebarGitChanges(
        files: 1_000_000_000, insertions: 1_000_000_000, deletions: 1_000_000_000,
        untrackedFiles: 10, binaryFiles: 20
    )

    @Test(arguments: [160.0, 220.0, 280.0])
    func largeGitCountsFitProposedWidthWithoutHorizontalOverflow(width: Double) {
        let controller = NSHostingController(rootView: GitChangeBadge(changes: maximumChanges))
        let narrow = controller.sizeThatFits(in: .init(width: width, height: 1_000))
        let wide = controller.sizeThatFits(in: .init(width: 1_000, height: 1_000))
        #expect(narrow.width <= width, "Git counts must accept the available detail width")
        #expect(narrow.height > wide.height, "Large counts wrap rather than clip, shrink or scroll horizontally")
    }

    @Test(arguments: [false, true])
    func managedHoverUsesSemanticGitColorsWithoutUserTint(dark: Bool) throws {
        let changes = SidebarGitChanges(files: 3, insertions: 24, deletions: 2, untrackedFiles: 1, binaryFiles: 1)
        let node = gitNode(changes: changes)
        let data = SidebarHoverCardData(
            id: "synthetic-git", category: "Agent preview", title: "Synthetic Git",
            lines: SidebarPresentation.managedGitDetails(node, now: now)
        )
        let view = SidebarHoverCard(data: data, close: {
            Issue.record("Git rendering must not close or navigate")
        }, copyValue: { _ in
            Issue.record("Git rendering must not copy or acknowledge")
            return false
        })
        .tint(.purple)
        .foregroundStyle(.purple)
        .environment(\.colorScheme, dark ? .dark : .light)
        .background(Color(nsColor: .windowBackgroundColor))
        let frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.frame = frame
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        var greenPixels = 0
        var redPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if color.greenComponent > color.redComponent + 0.12
                    && color.greenComponent > color.blueComponent + 0.08 { greenPixels += 1 }
                if color.redComponent > color.greenComponent + 0.12
                    && color.redComponent > color.blueComponent + 0.08 { redPixels += 1 }
            }
        }
        #expect(greenPixels > 10, "Hover additions use semantic green, not plain text or user tint")
        #expect(redPixels > 10, "Hover deletions use semantic red, not plain text or user tint")
        #expect(!window.isVisible && !window.isKeyWindow && !window.isMainWindow)
    }

    private func gitNode(changes: SidebarGitChanges) -> SidebarOrchestrationNode {
        .init(
            id: UUID(), runId: UUID(), parentId: nil, role: "worker", label: "Synthetic Git",
            workspaceId: UUID(), surfaceId: UUID(), generation: 1,
            phase: "turn-running", availability: "busy", executionMode: .interactive,
            worktreeLabel: "assigned-tree", branchLabel: "assigned-branch",
            gitEvidenceStatus: "verified", gitEvidenceAt: now,
            gitChangesStatus: "verified", gitChanges: changes, gitChangesAt: now,
            createdAt: now, updatedAt: now
        )
    }
}
