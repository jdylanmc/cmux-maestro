import AppKit
import SwiftUI
import Testing
@_spi(CmuxHostTransport) import CmuxExtensionKit

@MainActor
@Suite(.serialized)
struct SidebarPinnedDetailsTests {
    private let fixtures = SidebarTreeFixtures()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func hierarchy(
        active: UUID? = nil, kind: HierarchySurfaceKind = .terminal,
        focused: Bool = true, duplicateFocus: Bool = false, duplicateID: Bool = false,
        granted: Bool = true, paths: Bool = true
    ) -> HierarchySnapshot {
        let active = active ?? fixtures.workspaceA
        return .init(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true,
            workspaceMetadataAvailable: granted, surfaceMetadataAvailable: granted,
            workspacePathsAvailable: paths,
            workspaces: [fixtures.workspaceA, fixtures.workspaceB].enumerated().map { index, id in
                let surface = HierarchySurface(
                    id: index == 0 || duplicateID ? fixtures.surfaceA : fixtures.surfaceB,
                    title: "Same title", kind: kind, isFocused: focused, isPinned: false, unreadCount: 0,
                    workingDirectory: paths ? .available("/synthetic/worktree-\(index)") : .unavailable
                )
                return .init(
                    id: id, title: .available("Same workspace"), detail: .available(nil),
                    isSelected: .available(id == active), isPinned: .available(false), unreadCount: .available(0),
                    rootPath: paths ? .available("/synthetic") : .unavailable, projectRootPath: .available(nil),
                    surfaces: granted ? .available(duplicateFocus ? [surface, .init(
                        id: UUID(), title: "Other", kind: kind, isFocused: true,
                        isPinned: false, unreadCount: 0, workingDirectory: .unavailable
                    )] : [surface]) : .unavailable
                )
            }, windowID: fixtures.windowID
        )
    }

    private func session(
        id: UUID? = nil, other: Bool = false, liveness: CopilotLiveness = .alive,
        observedAt: Date? = nil
    ) -> SidebarCopilotSession {
        .init(
            id: id ?? (other ? fixtures.otherSessionID : fixtures.sessionID),
            workspaceID: other ? fixtures.workspaceB : fixtures.workspaceA,
            surfaceID: other ? fixtures.surfaceB : fixtures.surfaceA,
            liveness: liveness, state: .working, model: other ? "other-model" : "verified-model",
            observedAt: observedAt ?? now,
            nodes: [.init(id: "child", parentID: nil, depth: 0, kind: .subagent, name: "Child",
                          state: .idle, model: "child-model", ancestryUnresolved: false, hasChildren: false)],
            childrenComplete: true, treeDegraded: false, omittedChildrenCount: 0, omittedActiveChildrenCount: 0
        )
    }

    private func managed(
        id: UUID? = nil, runID: UUID? = nil, generation: Int = 1, sessionID: UUID? = nil,
        coordinator: Bool = false, updatedAt: Date? = nil, gitAt: Date? = nil
    ) -> SidebarOrchestrationNode {
        .init(
            id: id ?? fixtures.surfaceB, runId: runID ?? fixtures.workspaceB, parentId: nil,
            role: coordinator ? "coordinator" : "worker", label: "Verified agent",
            workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceA, generation: generation,
            phase: coordinator ? "registered" : "turn-running", availability: "busy",
            copilotSessionId: coordinator ? nil : sessionID ?? fixtures.sessionID, executionMode: .interactive,
            worktreeLabel: "pinned-46", branchLabel: "feat/pinned-details",
            gitEvidenceStatus: "verified", gitEvidenceAt: gitAt ?? now,
            gitChangesStatus: "verified",
            gitChanges: .init(files: 3, insertions: 24, deletions: 2, untrackedFiles: 0, binaryFiles: 0),
            gitChangesAt: gitAt ?? now, createdAt: now, updatedAt: updatedAt ?? now
        )
    }

    private func tree(_ sessions: [SidebarCopilotSession], generatedAt: Date? = nil) -> SidebarCopilotTree {
        .init(availability: .ready, sessions: sessions, issues: [], generatedAt: generatedAt ?? now)
    }

    private func snapshot(_ nodes: [SidebarOrchestrationNode]) -> SidebarOrchestrationSnapshot {
        .init(version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: nodes)
    }

    private func pinned(
        _ hierarchy: HierarchySnapshot? = nil, sessions: [SidebarCopilotSession]? = nil,
        nodes: [SidebarOrchestrationNode] = [], connected: Bool = true,
        availability: SidebarOrchestrationAvailability = .ready, generatedAt: Date? = nil
    ) -> SidebarDetailContent {
        SidebarPresentation.pinnedDetails(
            hierarchy: hierarchy ?? self.hierarchy(), connected: connected,
            tree: tree(sessions ?? [session()], generatedAt: generatedAt), managed: snapshot(nodes),
            availability: availability, now: now
        )
    }

    private func inspector(
        _ subject: SidebarInspection, hierarchy: HierarchySnapshot? = nil,
        sessions: [SidebarCopilotSession]? = nil, nodes: [SidebarOrchestrationNode] = [],
        connected: Bool = true, availability: SidebarOrchestrationAvailability = .ready
    ) -> SidebarDetailContent? {
        SidebarPresentation.inspectorDetails(
            for: subject, hierarchy: hierarchy ?? self.hierarchy(), connected: connected,
            tree: tree(sessions ?? [session()]), managed: snapshot(nodes), availability: availability, now: now
        )
    }

    @Test func followsOnlyUniqueCurrentWindowFocusAcrossSameNamedPeers() throws {
        let sessions = [session(), session(other: true)]
        let a = pinned(sessions: sessions)
        let b = pinned(hierarchy(active: fixtures.workspaceB), sessions: sessions)
        #expect(a.isAgent && b.isAgent)
        #expect(a.inspection?.surfaceID == fixtures.surfaceA && b.inspection?.surfaceID == fixtures.surfaceB)
        #expect(a.lines.contains(.init(title: "Model", value: "verified-model")))
        #expect(b.lines.contains(.init(title: "Model", value: "other-model")))
        #expect(a.lines.filter { $0.copyableSessionID != nil } == [.sessionID(fixtures.sessionID)])
        #expect(b.lines.filter { $0.copyableSessionID != nil } == [.sessionID(fixtures.otherSessionID)])
        var windowless = hierarchy()
        windowless.windowID = nil
        for invalid in [HierarchySnapshot.empty, windowless, hierarchy(focused: false),
                        hierarchy(duplicateFocus: true), hierarchy(duplicateID: true), hierarchy(granted: false)] {
            let result = pinned(invalid)
            #expect(!result.isAgent && result.inspection == nil && result.lines.isEmpty)
        }
        #expect(pinned(connected: false).lines.isEmpty)
        #expect(pinned(hierarchy(paths: false)).lines.contains(.init(title: "Working directory", value: "Path unavailable")))
    }

    @Test func ordinarySurfacesAndUnconfirmedIdentityCannotRetainAgentFields() {
        for kind in [HierarchySurfaceKind.browser, .markdown, .filePreview, .unknown] {
            let result = pinned(hierarchy(kind: kind), nodes: [managed()])
            #expect(!result.isAgent && result.notice == nil)
            #expect(result.visual?.title == kind.title)
            #expect(!result.lines.contains { ["Model", "Session ID", "Branch", "Git changes"].contains($0.title) })
        }
        let terminal = pinned(sessions: [], nodes: [managed()])
        #expect(!terminal.isAgent && terminal.notice == nil)
        #expect(pinned(sessions: [session(liveness: .dead)], nodes: [managed()]) == terminal)
        for sessions in [[session(), session()], [session(), session(id: UUID())],
                         [session(liveness: .ambiguous)], [session(liveness: .unknown)],
                         [session(), session(id: UUID(), liveness: .ambiguous)],
                         [session(), session(id: UUID(), liveness: .unknown)],
                         [session(), session(liveness: .dead)],
                         [session(), session(id: fixtures.sessionID, other: true, liveness: .dead)],
                         [session(observedAt: now.addingTimeInterval(-9))]] {
            let result = pinned(sessions: sessions, nodes: [managed()])
            #expect(!result.isAgent && result.notice != nil)
            #expect(!result.lines.contains { $0.copyableSessionID != nil || $0.title == "Model" })
        }
        #expect(!pinned(generatedAt: now.addingTimeInterval(-9)).isAgent)
        #expect(!pinned(sessions: [session(), session(id: fixtures.sessionID, other: true)]).isAgent)
        #expect(pinned(hierarchy(kind: .agentSession), sessions: []).notice != nil)
    }

    @Test func readerRepublishedDeadOwnerDoesNotSuppressItsLiveReplacement() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let now = now
        try fixture.writeRecord(.init(
            sessionID: fixture.sessionID, surfaceID: fixtures.surfaceA, launchWorkspaceID: fixtures.workspaceA,
            ownerPID: fixture.process.pid, ownerStartSeconds: fixture.process.startSeconds,
            ownerStartMicroseconds: fixture.process.startMicroseconds, recordedAt: fixture.record.recordedAt
        ))
        try fixture.writeEvents([copilotTestEvent("session.model_change", data: ["newModel": "ended-model"])])
        let initial = try await fixture.reader(clock: { now }).read(surfaceIDs: [fixtures.surfaceA])
        let initialTree = SidebarCopilotTree.project(initial, onto: SidebarTopology(hierarchy()), now: now)
        #expect(initialTree.sessions.first?.model == "ended-model")
        #expect(pinned(sessions: initialTree.sessions).lines.contains(.sessionID(fixture.sessionID)))

        let replacement = try fixture.addSession(surface: fixtures.surfaceA)
        let replacementID = try #require(UUID(uuidString: replacement.lastPathComponent))
        let owner = CopilotProcessIdentity(
            pid: 4343, parentPID: 1, uid: fixture.process.uid, startSeconds: 1, startMicroseconds: 0
        )
        try fixture.writeRecord(.init(
            sessionID: replacementID, surfaceID: fixtures.surfaceA, launchWorkspaceID: fixtures.workspaceA,
            ownerPID: owner.pid, ownerStartSeconds: owner.startSeconds,
            ownerStartMicroseconds: owner.startMicroseconds, recordedAt: fixture.record.recordedAt
        ))
        try Data().write(to: replacement.appendingPathComponent("inuse.\(owner.pid).lock"))
        try (copilotTestEvent("session.model_change", data: ["newModel": "replacement-model"]) + Data([10]))
            .write(to: replacement.appendingPathComponent("events.jsonl"))
        let node = managed(sessionID: replacementID)
        for date in [now, now.addingTimeInterval(2)] {
            let observation = try await fixture.reader(
                lookup: { $0 == owner.pid ? .found(owner) : .dead }, clock: { date }
            ).read(surfaceIDs: [fixtures.surfaceA])
            let ended = try #require(observation.sessions.first { $0.sessionID == fixture.sessionID })
            #expect(ended.liveness == .dead && ended.observedAt == date)
            let projected = SidebarCopilotTree.project(observation, onto: SidebarTopology(hierarchy()), now: date)
            #expect(projected.sessions.count == 2)
            let content = SidebarPresentation.pinnedDetails(
                hierarchy: hierarchy(), connected: true, tree: projected, managed: snapshot([node]),
                availability: .ready, now: date
            )
            #expect(content.isAgent && content.title == node.label && content.notice == nil)
            #expect(content.inspection?.sessionID == replacementID)
            #expect(content.lines.contains(.init(title: "Model", value: "replacement-model")))
            #expect(content.lines.filter { $0.copyableSessionID != nil } == [.sessionID(replacementID)])
            #expect(content.lines.contains(.init(title: "Branch", value: "feat/pinned-details")))
            #expect(content.lines.contains(.init(title: "Worktree", value: "pinned-46")))
            #expect(content.gitChanges == node.gitChanges)
            #expect(!content.lines.contains { $0.value.contains("ended-model") || $0.value.contains(fixture.sessionID.uuidString) })

            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            var copied: [UUID] = []
            var inspections = 0
            let hosting = NSHostingView(rootView: SidebarPinnedFooter(
                content: content, inspect: { inspections += 1 },
                copySessionID: { copied.append($0); return SidebarSessionCopy.copy($0, to: pasteboard) }
            ).frame(width: 300))
            hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 220)
            try await settle(hosting)
            let buttons = views(hosting).compactMap { $0 as? NSButton }
                .filter { $0.accessibilityIdentifier() == "hover-copy-value" }
            #expect(buttons.count == 1)
            #expect(try #require(buttons.first).accessibilityPerformPress())
            #expect(copied == [replacementID] && inspections == 0)
            #expect(pasteboard.string(forType: .string) == replacementID.uuidString)
        }
    }

    @Test func managedIdentityRequiresCurrentUniqueBindingAndNeverBorrowsFromReusedSurface() {
        let node = managed()
        let result = pinned(nodes: [node])
        #expect(result.title == node.label && result.isAgent)
        #expect(result.lines.contains(.init(title: "Branch", value: "feat/pinned-details")))
        #expect(result.lines.contains { $0.title == "Git changes" && $0.value.contains("+24") })
        for nodes in [[node, node], [managed(updatedAt: now.addingTimeInterval(-61))],
                      [managed(sessionID: UUID())]] {
            let unbound = pinned(nodes: nodes)
            #expect(unbound.title == "Same title" && unbound.isAgent)
            #expect(!unbound.lines.contains { $0.title == "Branch" || $0.title == "Worktree" })
            #expect(unbound.notice != nil)
        }
        let stale = pinned(nodes: [node], availability: .stale)
        #expect(stale.title == "Same title" && stale.notice != nil)
        let replaced = pinned(sessions: [session(id: fixtures.otherSessionID)], nodes: [node])
        #expect(replaced.lines.filter { $0.copyableSessionID != nil } == [.sessionID(fixtures.otherSessionID)])
        #expect(replaced.title != node.label)
        let staleGit = pinned(nodes: [managed(gitAt: now.addingTimeInterval(-3_600))])
        #expect(!staleGit.lines.contains { $0.title == "Branch" || $0.title == "Worktree" })
        #expect(staleGit.lines.contains { $0.title == "Git evidence" && $0.value.hasPrefix("Stale") })
        #expect(staleGit.lines.contains(.init(title: "Git changes", value: "Current counts unavailable")))
        #expect(pinned(nodes: [managed(coordinator: true)]).lines.contains(.sessionID(fixtures.sessionID)))
    }

    @Test func inspectorRevalidatesGenerationRunSessionPlacementAndPermission() throws {
        let node = managed()
        let subject = try #require(pinned(nodes: [node]).inspection)
        #expect(inspector(subject, nodes: [node])?.title == node.label)
        for replacement in [managed(generation: 2), managed(runID: UUID()),
                            managed(sessionID: fixtures.otherSessionID)] {
            #expect(inspector(subject, nodes: [replacement]) == nil)
        }
        #expect(inspector(subject, nodes: [node, node]) == nil)
        #expect(inspector(subject, sessions: [session(id: fixtures.otherSessionID)], nodes: [node]) == nil)
        #expect(inspector(subject, hierarchy: hierarchy(kind: .browser), nodes: [node]) == nil)
        #expect(inspector(subject, hierarchy: hierarchy(granted: false), nodes: [node]) == nil)
        #expect(inspector(subject, nodes: [node], connected: false) == nil)
        #expect(inspector(subject, nodes: [node], availability: .unavailable) == nil)
        var otherWindow = hierarchy()
        otherWindow.windowID = UUID()
        #expect(inspector(subject, hierarchy: otherWindow, nodes: [node]) == nil)
        let stale = try #require(inspector(subject, nodes: [node], availability: .stale))
        #expect(stale.notice != nil)
        #expect(stale.lines.contains(.sessionID(fixtures.sessionID)))
        let coordinator = managed(coordinator: true)
        let coordinatorSubject = try #require(pinned(nodes: [coordinator]).inspection)
        #expect(inspector(coordinatorSubject, sessions: [session(id: UUID())], nodes: [coordinator]) == nil)
    }

    @Test func childInspectionRetainsParentPlacementAndDoesNotChangePinnedSubject() throws {
        let before = pinned()
        let child = try #require(SidebarPresentation.inspection(
            for: .unmanaged(.child(sessionID: fixtures.sessionID, childID: "child")),
            hierarchy: hierarchy(), connected: true, tree: tree([session()]), managed: .empty,
            availability: .ready, now: now
        ))
        let detail = try #require(inspector(child))
        #expect(child.surfaceID == fixtures.surfaceA)
        #expect(detail.lines.contains(.sessionID(fixtures.sessionID, isParent: true)))
        #expect(detail.lines.contains(.init(title: "Model", value: "child-model")))
        #expect(detail.lines.contains { $0.title == "Placement" && $0.value.contains("parent session") })
        #expect(before == pinned())
        #expect(inspector(child, sessions: [session(id: UUID())]) == nil)
        var duplicate = session()
        duplicate.nodes.append(duplicate.nodes[0])
        #expect(inspector(child, sessions: [duplicate]) == nil)
        for selection in [UnmanagedSelection.workspace(fixtures.workspaceA),
                          .surface(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA),
                          .session(fixtures.sessionID)] {
            let target = try #require(SidebarPresentation.inspection(
                for: .unmanaged(selection), hierarchy: hierarchy(), connected: true,
                tree: tree([session()]), managed: .empty, availability: .ready, now: now
            ))
            #expect(inspector(target) != nil)
        }
    }

    @Test func workspaceInspectionNeedsNoSurfaceGrantAndRedactsPathsIndependently() throws {
        let target = SidebarInspection.Target.unmanaged(.workspace(fixtures.workspaceA))
        let subject = try #require(SidebarPresentation.inspection(
            for: target, hierarchy: hierarchy(), connected: true, tree: tree([session()]),
            managed: .empty, availability: .ready, now: now
        ))
        let raw = CmuxSidebarSnapshot(
            sequence: 1, windowID: fixtures.windowID, selectedWorkspaceID: nil,
            workspaces: [.init(
                id: fixtures.workspaceA, title: "Workspace without surfaces",
                rootPath: "/synthetic/worktree", projectRootPath: "/synthetic",
                surfaces: [.init(id: fixtures.surfaceA, title: "Terminal", kind: .terminal)]
            )]
        )
        func mapped(_ raw: CmuxSidebarSnapshot, scopes: Set<CmuxExtensionScope>) -> HierarchySnapshot {
            let model = SidebarConnectionModel()
            model.update(context: .init(snapshot: raw.filtered(for: scopes), host: .init(performAction: { _, _ in })))
            return model.hierarchy
        }
        for paths in [true, false] {
            let hierarchy = mapped(raw, scopes: paths ? [.workspaceMetadata, .workspacePaths] : [.workspaceMetadata])
            #expect(!SidebarTopology(hierarchy).canReadSessions)
            #expect(hierarchy.workspaces.first?.surfaces == .unavailable)
            let detail = try #require(inspector(subject, hierarchy: hierarchy))
            #expect(detail.title == "Workspace without surfaces")
            #expect(detail.lines == [
                .init(title: "Workspace ID", value: fixtures.workspaceA.uuidString),
                .init(title: "Workspace path", value: paths ? "/synthetic/worktree" : "Path unavailable"),
                .init(title: "Project path", value: paths ? "/synthetic" : "Path unavailable")
            ])
            for dependent in [
                SidebarInspection.Target.unmanaged(.surface(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA)),
                .unmanaged(.session(fixtures.sessionID)), .unmanaged(.child(sessionID: fixtures.sessionID, childID: "child")),
                .managed(managed())
            ] {
                #expect(SidebarPresentation.inspection(
                    for: dependent, hierarchy: hierarchy, connected: true, tree: tree([session()]),
                    managed: snapshot([managed()]), availability: .ready, now: now
                ) == nil)
            }
            #expect(inspector(subject, hierarchy: hierarchy, connected: false) == nil)
        }
        var windowless = raw
        windowless.windowID = nil
        var otherWindow = raw
        otherWindow.windowID = UUID()
        var removed = raw
        removed.workspaces = []
        var duplicate = raw
        duplicate.workspaces.append(raw.workspaces[0])
        for invalid in [
            HierarchySnapshot.empty, mapped(raw, scopes: []), mapped(raw, scopes: [.workspaceList, .workspacePaths]),
            mapped(windowless, scopes: [.workspaceMetadata]), mapped(otherWindow, scopes: [.workspaceMetadata]),
            mapped(removed, scopes: [.workspaceMetadata]), mapped(duplicate, scopes: [.workspaceMetadata])
        ] {
            #expect(inspector(subject, hierarchy: invalid) == nil)
        }
    }

    @Test func passiveProjectionAndHoverHaveNoInteractionOrUnsupportedMetrics() throws {
        let before = pinned(nodes: [managed()])
        _ = SidebarAgentHoverContent.card(
            for: .child(sessionID: fixtures.sessionID, childID: "child"), hierarchy: hierarchy(),
            connected: true, tree: tree([session()]), managed: snapshot([managed()]), availability: .ready, now: now
        )
        #expect(pinned(nodes: [managed()]) == before)
        #expect(!before.lines.contains { ["Context", "Elapsed", "Tokens", "Duration"].contains($0.title) })
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let presentation = try String(contentsOf: root.appendingPathComponent(
            "CMUXMaestroSidebar/UI/SidebarPresentation.swift"), encoding: .utf8)
        let projection = try #require(presentation.components(separatedBy: "static func pinnedDetails(").last?
            .components(separatedBy: "static func state(").first)
        for forbidden in ["markSeen(", "prepareSeen(", "acknowledge(", "SidebarNavigation", "context.host", "Timer"] {
            #expect(!projection.contains(forbidden))
        }
        let source = try String(contentsOf: root.appendingPathComponent(
            "CMUXMaestroSidebar/UI/SidebarView.swift"), encoding: .utf8)
        #expect(source.contains(".popover(isPresented: $showingInspector)"))
        #expect(source.contains("SidebarPresentation.focusInteraction(from: old, to: new)"))
        #expect(!source.contains("selectionDetails"))
        let footer = try #require(source.components(separatedBy: "struct SidebarPinnedFooter: View").last?
            .components(separatedBy: "private struct PathDetail").first)
        #expect(footer.contains("if content.isAgent { SidebarPlaceholderPet() }"))
        for forbidden in ["SidebarCloseButton", "prepareSeen(", "FocusButton", ".onHover", "RoundedRectangle"] {
            #expect(!footer.contains(forbidden))
        }
    }

    @Test func inspectorRendersFullMetadataThenClearsRevokedSubjectWithoutAffectingFooter() async throws {
        var observed = session()
        observed.nodes.append(.init(id: "skill", parentID: nil, depth: 0, kind: .skill, name: "Other work",
                                    state: .idle, model: nil, ancestryUnresolved: false, hasChildren: false))
        let pinned = pinned(sessions: [observed])
        let subject = try #require(pinned.inspection)
        let detail = try #require(inspector(subject, sessions: [observed]))
        #expect(detail.otherActivity.map(\.id) == ["skill"])
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let frame = NSRect(x: 0, y: 0, width: 300, height: 460)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        func view(_ content: SidebarDetailContent?) -> some View {
            SidebarInspector(content: content, close: {})
                .background(Color(nsColor: .windowBackgroundColor))
        }
        let hosting = NSHostingView(rootView: view(detail))
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        let responder = window.firstResponder
        for available in [true, false] {
            let content = available ? detail : inspector(subject, connected: false)
            hosting.rootView = view(content)
            try await settle(hosting)
            #expect(!window.isVisible && window.firstResponder === responder)
            if !available {
                #expect(!views(hosting).contains { $0.accessibilityIdentifier() == "hover-copy-value" })
            }
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let destination = folder.appendingPathComponent("pinned46-inspector-\(available ? "details" : "unavailable").png")
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination)
            let text = try SidebarRenderingEvidence.recognizedLines(in: destination)
            if available {
                #expect(text.contains { $0.contains("verified-model") })
            } else {
                #expect(text.contains { $0.contains("Details no longer available") })
                #expect(!text.contains { $0.contains("verified-model") })
            }
        }
        #expect(self.pinned(sessions: [observed]) == pinned)
    }

    @Test func footerRendersNativeLightDarkNarrowShortAndCopiesWithoutInspection() async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var inspections = 0
        var copies: [UUID] = []
        for dark in [false, true] {
            for width: CGFloat in [240, 340] {
                for height: CGFloat in [144, 220] {
                    let content = pinned(nodes: [managed()])
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height + 70),
                                          styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let hosting = NSHostingView(rootView: VStack {
                        SidebarPinnedFooter(content: content, maximumHeight: height, inspect: { inspections += 1 },
                                            copySessionID: { copies.append($0); return SidebarSessionCopy.copy($0, to: pasteboard) })
                        Spacer(minLength: 50)
                    }
                    .padding(10)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor)))
                    window.contentView = hosting
                    defer { window.contentView = nil; window.close() }
                    try await settle(hosting)
                    #expect(!window.isVisible && inspections == 0)
                    let buttons = views(hosting).compactMap { $0 as? NSButton }
                        .filter { $0.accessibilityIdentifier() == "hover-copy-value" }
                    let button = try #require(buttons.first)
                    #expect(buttons.count == 1)
                    #expect(button.acceptsFirstResponder && button.accessibilityLabel() == "Copy session ID")
                    #expect(button.accessibilityPerformPress())
                    try await settle(hosting)
                    #expect(button.accessibilityValue() as? String == "Copied")
                    #expect(pasteboard.string(forType: .string) == fixtures.sessionID.uuidString)
                    let feedback = try #require(views(hosting).compactMap { $0 as? NSTextField }
                        .first { $0.accessibilityIdentifier() == "hover-copy-feedback" })
                    #expect(feedback.stringValue == "Copied" && feedback.accessibilityValue() == "Copied")
                    let drawing = feedback.alignmentRect(forFrame: feedback.bounds)
                    #expect(drawing.height > 0 && feedback.visibleRect.contains(drawing))
                    let viewport = try #require(feedback.enclosingScrollView?.contentView)
                    #expect(viewport.bounds.contains(viewport.convert(drawing, from: feedback)))
                    let bitmap = try capture(hosting)
                    #expect(bitmap.pixelsWide == Int(width) * 2 && bitmap.pixelsHigh == Int(height + 70) * 2)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    let destination = folder.appendingPathComponent(
                        "pinned46-\(dark ? "dark" : "light")-\(Int(width))x\(Int(height)).png"
                    )
                    try png.write(to: destination)
                    let text = try SidebarRenderingEvidence.recognizedNativeLines(in: destination)
                    #expect(text.contains { $0.contains("Verified agent") },
                            "\(destination.lastPathComponent): \(text)")
                    #expect(text.contains("verified-model"),
                            "\(destination.lastPathComponent): \(text)")
                    #expect(text.contains("Copied"),
                            "\(destination.lastPathComponent): \(text)")
                    for scroll in views(hosting).compactMap({ $0 as? NSScrollView }) {
                        let document = try #require(scroll.documentView)
                        #expect(document.bounds.width <= scroll.contentView.bounds.width + 0.5)
                    }
                }
            }
        }
        #expect(!copies.isEmpty && inspections == 0)
    }

    @Test(arguments: [false, true])
    func footerRenderEvidenceRejectsWrongMissingHiddenAndClippedModels(dark: Bool) async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for control in ["visible", "wrong", "missing", "hidden", "clipped"] {
            var content = pinned(nodes: [managed()])
            if control == "wrong" || control == "missing" {
                content.lines.removeAll { $0.title == "Model" }
                if control == "wrong" { content.lines.append(.init(title: "Model", value: "verifled-model")) }
            }
            let frame = NSRect(x: 0, y: 0, width: 240, height: 214)
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: VStack {
                SidebarPinnedFooter(content: content, maximumHeight: 144,
                                    inspect: { Issue.record("Rendering must not inspect") },
                                    copySessionID: { _ in Issue.record("Rendering must not copy"); return false })
                    .frame(height: control == "clipped" ? 60 : nil, alignment: .top)
                    .clipped()
                    .opacity(control == "hidden" ? 0 : 1)
                Spacer(minLength: 50)
            }
            .padding(10)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = hosting
            defer { window.contentView = nil; window.close() }
            try await settle(hosting)
            #expect(!window.isVisible)
            let bitmap = try capture(hosting)
            let destination = folder.appendingPathComponent(
                "pinned46-control-\(dark ? "dark" : "light")-\(control).png"
            )
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination)
            let text = try SidebarRenderingEvidence.recognizedNativeLines(in: destination)
            #expect(text.contains("verified-model") == (control == "visible"),
                    "\(destination.lastPathComponent): \(text)")
            #expect(!text.contains("Copied"), "\(destination.lastPathComponent): \(text)")
            if control != "hidden" {
                #expect(text.contains("Verified agent"), "\(destination.lastPathComponent): \(text)")
            }
        }
    }

    private func capture(_ view: NSView) throws -> NSBitmapImageRep {
        // Match the layout/copy renderers: unchanged point geometry, actual 2x native glyphs.
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width) * 2, pixelsHigh: Int(view.bounds.height) * 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func views(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { views($0) }
    }

    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        view.layoutSubtreeIfNeeded()
    }
}
