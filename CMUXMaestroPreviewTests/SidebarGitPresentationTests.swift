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

    @Test func hoverAndPinnedCountsFollowTheirOwnExactSubjectAndGeneration() throws {
        let first = gitNode(changes: .init(files: 4, insertions: 123, deletions: 45, untrackedFiles: 1, binaryFiles: 2))
        let second = gitNode(changes: .init(files: 9, insertions: 987, deletions: 65, untrackedFiles: 2, binaryFiles: 3))
        let nodes = [first, second]
        let tree = SidebarCopilotTree(
            availability: .ready,
            sessions: nodes.map { node in
                .init(
                    id: node.copilotSessionId!, workspaceID: node.workspaceId, surfaceID: node.surfaceId,
                    liveness: .alive, state: .working, model: "same model", observedAt: now, nodes: [],
                    childrenComplete: true, treeDegraded: false, omittedChildrenCount: 0, omittedActiveChildrenCount: 0
                )
            }, issues: [], generatedAt: now
        )
        let managed = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: nodes
        )
        for focused in nodes {
            let hierarchy = hierarchy(nodes: nodes, focused: focused.surfaceId)
            let pinned = SidebarPresentation.pinnedDetails(
                hierarchy: hierarchy, connected: true, tree: tree, managed: managed, availability: .ready, now: now
            )
            #expect(pinned.gitChanges == focused.gitChanges)
            #expect(pinned.inspection?.sessionID == focused.copilotSessionId)
            for hovered in nodes {
                let hover = try #require(SidebarAgentHoverContent.card(
                    for: .managed(hovered.id, generation: hovered.generation),
                    hierarchy: hierarchy, connected: true, tree: tree, managed: managed, availability: .ready, now: now
                ))
                let line = try #require(hover.lines.first { $0.title == "Git changes" })
                #expect(line.gitChanges == hovered.gitChanges, "Pinned focus cannot lend counts to another hover")
                let expected = hovered.id == first.id
                    ? "Assigned directory: 4 changed files · +123 / −45 lines vs HEAD. Includes 1 untracked and 2 binary files; their lines and submodule contents are excluded."
                    : "Assigned directory: 9 changed files · +987 / −65 lines vs HEAD. Includes 2 untracked and 3 binary files; their lines and submodule contents are excluded."
                #expect(line.value == expected)
                #expect(line.help == SidebarPresentation.assignedGitHelp && line.copyableValue == nil)
                #expect(SidebarAgentHoverContent.card(
                    for: .managed(hovered.id, generation: hovered.generation + 1),
                    hierarchy: hierarchy, connected: true, tree: tree, managed: managed, availability: .ready, now: now
                ) == nil, "A different generation cannot reuse the represented snapshot")
            }
        }
    }

    @Test(arguments: [nil, "unavailable", "verified"] as [String?], [-61.0, 0.0, 61.0])
    func unavailableAndExpiredGitPayloadsNeverBecomeZero(status: String?, age: Double) throws {
        let node = gitNode(changes: maximumChanges, status: status, captured: now.addingTimeInterval(-age))
        let line = try #require(SidebarPresentation.managedGitDetails(node, now: now).first { $0.title == "Git changes" })
        let expected = status == "verified" && age == 0
        #expect(line.gitChanges == (expected ? maximumChanges : nil))
        if !expected {
            #expect(line.value == "Assigned directory: Current counts unavailable")
            #expect(!line.value.contains("+0") && !line.value.contains("0 files"))
        }
        #expect(SidebarDetailContent(title: "Synthetic", lines: [line]).gitChanges == line.gitChanges)
    }

    @Test func freshZeroCountsRemainDifferentFromMissingCounts() {
        let changes = SidebarGitChanges(files: 0, insertions: 0, deletions: 0, untrackedFiles: 0, binaryFiles: 0)
        let fresh = SidebarPresentation.managedGitDetails(gitNode(changes: changes), now: now)
        let missing = SidebarPresentation.managedGitDetails(gitNode(changes: nil), now: now)
        #expect(fresh.first { $0.title == "Git changes" }?.gitChanges == changes)
        #expect(fresh.first { $0.title == "Git changes" }?.value ==
            "Assigned directory: 0 changed files · +0 / −0 lines vs HEAD. Includes 0 untracked and 0 binary files; their lines and submodule contents are excluded.")
        #expect(missing.first { $0.title == "Git changes" }?.gitChanges == nil)
        #expect(missing.first { $0.title == "Git changes" }?.value == "Assigned directory: Current counts unavailable")
    }

    @Test(arguments: ["light", "dark", "light-increased", "dark-increased"], [160.0, 280.0])
    func bothDetailConsumersContainLargeCountsWithReadableSemanticColors(appearance: String, width: Double) throws {
        let dark = appearance.hasPrefix("dark")
        let increased = appearance.hasSuffix("increased")
        let lines = SidebarPresentation.managedGitDetails(gitNode(changes: maximumChanges), now: now)
        let hover = SidebarHoverCard(
            data: .init(id: "synthetic-large-git", category: "Agent preview", title: "Synthetic Git", lines: lines),
            close: { Issue.record("Rendering must not close") },
            copyValue: { _ in Issue.record("Rendering must not copy"); return false }
        )
        let pinned = SidebarPinnedFooter(
            content: .init(title: "Synthetic Git", lines: lines), maximumHeight: 600,
            inspect: { Issue.record("Rendering must not inspect or acknowledge") }
        )
        for (name, content) in [("hover", AnyView(hover)), ("pinned", AnyView(pinned))] {
            let frame = NSRect(x: 0, y: 0, width: width, height: 600)
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark
                ? (increased ? .accessibilityHighContrastDarkAqua : .darkAqua)
                : (increased ? .accessibilityHighContrastAqua : .aqua))
            let hosting = NSHostingView(rootView: content
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\._colorSchemeContrast, increased ? .increased : .standard)
                .tint(.purple).foregroundStyle(.purple)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = hosting
            defer { window.contentView = nil; window.close() }
            hosting.frame = frame
            hosting.layoutSubtreeIfNeeded()
            let metrics = SidebarRenderingEvidence.metrics(for: hosting)
            #expect(metrics.viewportWidth > 0 && metrics.documentWidth <= metrics.viewportWidth + 1,
                    "No horizontal scroll or overflow in \(name)")
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            var background: NSColor?
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
            }
            let backgroundLuminance = luminance(try #require(background))
            var greenContrast = 0.0
            var redContrast = 0.0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    let foregroundLuminance = luminance(color)
                    let contrast = (max(foregroundLuminance, backgroundLuminance) + 0.05)
                        / (min(foregroundLuminance, backgroundLuminance) + 0.05)
                    if color.greenComponent > color.redComponent + 0.12
                        && color.greenComponent > color.blueComponent + 0.08 { greenContrast = max(greenContrast, contrast) }
                    if color.redComponent > color.greenComponent + 0.12
                        && color.redComponent > color.blueComponent + 0.08 { redContrast = max(redContrast, contrast) }
                }
            }
            #expect(greenContrast >= 4.5 && redContrast >= 4.5,
                    "Caption-sized semantic text needs 4.5:1 contrast in \(name), \(appearance)")
            #expect(!window.isVisible && !window.isKeyWindow && !window.isMainWindow)
            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/layout-validation/offscreen")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("git-counts-\(name)-\(appearance)-\(Int(width)).png"))
        }
    }

    private func luminance(_ color: NSColor) -> Double {
        let channels = [color.redComponent, color.greenComponent, color.blueComponent].map { value in
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }

    private func hierarchy(nodes: [SidebarOrchestrationNode], focused: UUID) -> HierarchySnapshot {
        .init(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true,
            workspaceMetadataAvailable: true, surfaceMetadataAvailable: true, workspacePathsAvailable: true,
            workspaces: nodes.map { node in
                .init(
                    id: node.workspaceId, title: .available("Same workspace"), detail: .available(nil),
                    isSelected: .available(node.surfaceId == focused), isPinned: .available(false),
                    unreadCount: .available(0), rootPath: .available("/synthetic"), projectRootPath: .available(nil),
                    surfaces: .available([.init(
                        id: node.surfaceId, title: "Same surface", kind: .terminal, isFocused: node.surfaceId == focused,
                        isPinned: false, unreadCount: 0, workingDirectory: .available("/synthetic/reported")
                    )])
                )
            }, windowID: UUID()
        )
    }

    private func gitNode(
        changes: SidebarGitChanges?, status: String? = "verified", captured: Date? = nil
    ) -> SidebarOrchestrationNode {
        .init(
            id: UUID(), runId: UUID(), parentId: nil, role: "worker", label: "Synthetic Git",
            workspaceId: UUID(), surfaceId: UUID(), generation: 1,
            phase: "turn-running", availability: "busy", copilotSessionId: UUID(), executionMode: .interactive,
            worktreeLabel: "assigned-tree", branchLabel: "assigned-branch",
            gitEvidenceStatus: status, gitEvidenceAt: captured ?? now,
            gitChangesStatus: status, gitChanges: changes, gitChangesAt: captured ?? now,
            createdAt: now, updatedAt: now
        )
    }
}
