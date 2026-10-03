import AppKit
import Foundation
import Testing
@_spi(CmuxHostTransport) import CmuxExtensionKit

@MainActor
struct SidebarAgentHoverTests {
    private let fixtures = SidebarTreeFixtures()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(
        id: UUID? = nil, surface: UUID? = nil, name: String = "model",
        liveness: AgentProcessLiveness = .alive
    ) -> SidebarCopilotSession {
        .init(
            id: id ?? fixtures.sessionID, workspaceID: fixtures.workspaceA,
            surfaceID: surface ?? fixtures.surfaceA, liveness: liveness, state: .working, model: name,
            observedAt: now, nodes: [], childrenComplete: true, treeDegraded: false,
            omittedChildrenCount: 0, omittedActiveChildrenCount: 0
        )
    }

    private func card(
        _ target: SidebarAgentHoverTarget, sessions: [SidebarCopilotSession],
        hierarchy: HierarchySnapshot? = nil, connected: Bool = true,
        generatedAt: Date? = nil, nodes: [SidebarOrchestrationNode] = [],
        availability: SidebarOrchestrationAvailability = .ready
    ) -> SidebarHoverCardData? {
        SidebarAgentHoverContent.card(
            for: target, hierarchy: hierarchy ?? fixtures.hierarchy(), connected: connected,
            tree: .init(availability: .ready, sessions: sessions, issues: [], generatedAt: generatedAt ?? now),
            managed: .init(version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: nodes),
            availability: availability, now: now
        )
    }

    private func directoryHierarchy(
        _ directory: String?, granted: Bool = true, moved: Bool = false, sequence: UInt64 = 1
    ) -> HierarchySnapshot {
        let surface = CmuxSidebarSurface(
            id: fixtures.surfaceA, title: "Same title", kind: .terminal, isFocused: true, workingDirectory: directory
        )
        let raw = CmuxSidebarSnapshot(
            sequence: sequence, windowID: fixtures.windowID,
            selectedWorkspaceID: moved ? fixtures.workspaceB : fixtures.workspaceA,
            workspaces: [
                .init(id: fixtures.workspaceA, title: "Same workspace", rootPath: "/synthetic/workspace",
                      projectRootPath: "/synthetic/project", surfaces: moved ? [] : [surface]),
                .init(id: fixtures.workspaceB, title: "Same workspace", rootPath: "/synthetic/moved",
                      projectRootPath: "/synthetic/project", surfaces: (moved ? [surface] : []) + [
                        .init(id: fixtures.surfaceB, title: "Same title", kind: .terminal,
                              workingDirectory: "/synthetic/peer-only")
                      ])
            ]
        )
        let scopes: Set<CmuxExtensionScope> = granted
            ? [.workspaceMetadata, .surfaceMetadata, .workspacePaths] : [.workspaceMetadata, .surfaceMetadata]
        let model = SidebarConnectionModel()
        model.update(context: .init(snapshot: raw.filtered(for: scopes), host: .init(performAction: { _, _ in
            Issue.record("Directory projection must not navigate")
        })))
        return model.hierarchy
    }

    private func directoryNode(_ session: SidebarCopilotSession) -> SidebarOrchestrationNode {
        .init(
            id: fixtures.surfaceB, runId: fixtures.workspaceB, parentId: nil, role: "worker", label: "Same title",
            workspaceId: session.workspaceID, surfaceId: session.surfaceID, generation: 2,
            phase: "turn-running", availability: "busy", copilotSessionId: session.id,
            executionMode: .interactive, worktreeLabel: "/synthetic/assigned-git-label", branchLabel: "assigned-branch",
            gitEvidenceStatus: "verified", gitEvidenceAt: now, createdAt: now, updatedAt: now
        )
    }

    @Test(arguments: [true, false], [nil, "", "relative/../reported", "/synthetic/reported"] as [String?])
    func directoryConsumersKeepHostSourceAndPermissionDistinct(granted: Bool, directory: String?) throws {
        let hierarchy = directoryHierarchy(directory, granted: granted)
        var session = session()
        session.nodes = [.init(id: "child", parentID: nil, depth: 0, kind: .subagent, name: "Child",
                               state: .working, model: nil, ancestryUnresolved: false, hasChildren: false)]
        let node = directoryNode(session)
        let tree = SidebarCopilotTree(availability: .ready, sessions: [session], issues: [], generatedAt: now)
        let managed = SidebarOrchestrationSnapshot(version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: [node])
        let paths = hierarchy.pathContext(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA)
        var consumers: [(String, [SidebarDetailLine], Bool)] = [("paths", SidebarPresentation.paths(paths), false)]
        for (name, target, parent) in [
            ("session hover", SidebarAgentHoverTarget.session(session.id), false),
            ("managed hover", .managed(node.id, generation: 2), false),
            ("child hover", .child(sessionID: session.id, childID: "child"), true)
        ] {
            let hover = try #require(card(target, sessions: [session], hierarchy: hierarchy, nodes: [node]))
            consumers.append((name, hover.lines, parent))
        }
        for (name, target, parent) in [
            ("surface details", SidebarInspection.Target.unmanaged(.surface(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA)), false),
            ("session details", .unmanaged(.session(session.id)), false),
            ("managed details", .managed(node), false),
            ("child details", .unmanaged(.child(sessionID: session.id, childID: "child")), true)
        ] {
            let subject = try #require(SidebarPresentation.inspection(
                for: target, hierarchy: hierarchy, connected: true, tree: tree, managed: managed, availability: .ready, now: now
            ))
            let detail = try #require(SidebarPresentation.inspectorDetails(
                for: subject, hierarchy: hierarchy, connected: true, tree: tree, managed: managed, availability: .ready, now: now
            ))
            consumers.append((name, detail.lines, parent))
        }
        for (name, observations, nodes) in [
            ("surface pinned", SidebarCopilotTree(availability: .ready, sessions: [], issues: [], generatedAt: now), SidebarOrchestrationSnapshot.empty),
            ("session pinned", tree, .empty), ("managed pinned", tree, managed)
        ] {
            let pinned = SidebarPresentation.pinnedDetails(
                hierarchy: hierarchy, connected: true, tree: observations, managed: nodes, availability: .ready, now: now
            )
            consumers.append((name, pinned.lines, false))
        }
        let sharedValue = directory.flatMap { $0.isEmpty ? nil : $0 } ?? "No path shared"
        let expectedValue = granted ? sharedValue : "Path unavailable"
        for (name, lines, parent) in consumers {
            let fields = lines.filter { $0.title.lowercased().contains("directory") }
            #expect(fields == [.init(
                title: parent ? "Parent surface directory" : "Surface directory", value: expectedValue,
                help: parent
                    ? "Reported by CMUX for the parent surface; no report time supplied. Not an independently reported child directory."
                    : "Reported by CMUX for this surface; no report time supplied. Not a verified agent or tool working directory."
            )], "\(name) must retain exactly its source-qualified directory field, including grant/nil state")
            #expect(!lines.contains { $0.value == "/synthetic/peer-only" })
        }
        #expect(paths.workingDirectory == (granted ? .available(directory) : .unavailable))
        #expect(paths.accessibilityDescription ==
            "Workspace: \(granted ? "/synthetic/workspace" : "Path unavailable"). Project: \(granted ? "/synthetic/project" : "Path unavailable"). Surface directory: \(expectedValue). Reported by CMUX for this surface; no report time supplied. Not a verified agent or tool working directory.")
        #expect(consumers.first { $0.0 == "managed hover" }?.1.contains(
            .init(title: "Worktree", value: "Assigned directory: /synthetic/assigned-git-label",
                  help: SidebarPresentation.assignedGitHelp)
        ) == true, "Assigned Git evidence stays separate, never used as the directory")
    }

    @Test(arguments: ["fresh", "stale", "unavailable", "absent", "stale-counts", "detached"])
    func managedGitConsumersQualifyAssignedDirectoryWithoutChangingFreshness(_ evidence: String) throws {
        let session = session()
        let captured = now.addingTimeInterval(evidence == "stale" ? -61 : 0)
        let verified = !["unavailable", "absent"].contains(evidence)
        let changes = SidebarGitChanges(files: 3, insertions: 24, deletions: 2, untrackedFiles: 1, binaryFiles: 1)
        let node = SidebarOrchestrationNode(
            id: fixtures.surfaceB, runId: fixtures.workspaceB, parentId: nil, role: "worker", label: "Assigned Git",
            workspaceId: session.workspaceID, surfaceId: session.surfaceID, generation: 2,
            phase: "turn-running", availability: "busy", copilotSessionId: session.id, executionMode: .interactive,
            worktreeLabel: verified ? "assigned-worktree" : nil,
            branchLabel: verified && evidence != "detached" ? "assigned-branch" : nil,
            gitEvidenceStatus: evidence == "absent" ? nil : verified ? "verified" : "unavailable",
            gitEvidenceAt: evidence == "absent" ? nil : captured,
            gitChangesStatus: evidence == "absent" ? nil : verified ? "verified" : "unavailable",
            gitChanges: verified ? changes : nil,
            gitChangesAt: evidence == "absent" ? nil : evidence == "stale-counts" ? now.addingTimeInterval(-61) : captured,
            createdAt: now, updatedAt: now
        )
        let hierarchy = directoryHierarchy("/synthetic/independent-host-report")
        let tree = SidebarCopilotTree(availability: .ready, sessions: [session], issues: [], generatedAt: now)
        let managed = SidebarOrchestrationSnapshot(version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: [node])
        let hover = try #require(card(.managed(node.id, generation: 2), sessions: [session], hierarchy: hierarchy, nodes: [node]))
        let pinned = SidebarPresentation.pinnedDetails(
            hierarchy: hierarchy, connected: true, tree: tree, managed: managed, availability: .ready, now: now
        )
        let subject = try #require(pinned.inspection)
        let details = try #require(SidebarPresentation.inspectorDetails(
            for: subject, hierarchy: hierarchy, connected: true, tree: tree, managed: managed, availability: .ready, now: now
        ))
        let tooltip = SidebarPresentation.managedGitMetadataHelp(node, now: now)
        let expectedHelp = "Git is probed at the directory assigned to this managed session, not Copilot's current /cwd or a tool's working directory."
        let currentCounts = ["fresh", "detached"].contains(evidence)
        let expectedCounts = currentCounts
            ? "Assigned directory: 3 changed files · +24 / −2 lines vs HEAD. Includes 1 untracked and 1 binary files; their lines and submodule contents are excluded."
            : "Assigned directory: Current counts unavailable"
        #expect(pinned.gitChanges == (currentCounts ? changes : nil))
        #expect(SidebarPresentation.assignedGitTitle == "Assigned directory")
        #expect(SidebarPresentation.assignedGitChangesDescription(pinned.gitChanges) == expectedCounts)
        #expect(tooltip.contains(expectedHelp))
        for lines in [hover.lines, pinned.lines, details.lines] {
            let git = lines.filter { ["Branch", "Worktree", "Git evidence", "Last verified location", "Git changes"].contains($0.title) }
            #expect(!git.isEmpty)
            #expect(git.allSatisfy { $0.value.hasPrefix("Assigned directory: ") && $0.help == expectedHelp })
            #expect(git.allSatisfy { tooltip.contains("\($0.title): \($0.value)") })
            #expect(git.first { $0.title == "Git changes" }?.value == expectedCounts)
            #expect(lines.first { $0.title == "Surface directory" } == .init(
                title: "Surface directory", value: "/synthetic/independent-host-report",
                help: "Reported by CMUX for this surface; no report time supplied. Not a verified agent or tool working directory."
            ))
            if verified && evidence != "stale" {
                #expect(git.first { $0.title == "Worktree" }?.value == "Assigned directory: assigned-worktree")
                #expect(git.first { $0.title == "Branch" }?.value ==
                    (evidence == "detached" ? nil : "Assigned directory: assigned-branch"))
                #expect(git.first { $0.title == "Git evidence" }?.value.hasPrefix("Assigned directory: Verified ") == true)
            } else {
                #expect(!git.contains { ["Branch", "Worktree"].contains($0.title) })
                if evidence == "absent" {
                    #expect(!git.contains { $0.title == "Git evidence" })
                } else {
                    let status = evidence == "stale" ? "Stale" : "Unavailable"
                    #expect(git.first { $0.title == "Git evidence" }?.value.hasPrefix("Assigned directory: \(status) · ") == true)
                }
            }
            #expect(!git.contains { $0.value.contains("/synthetic/independent-host-report") })
        }
        if evidence == "stale" {
            let expectedLocation = "Assigned directory: Not current Git state: assigned-branch · assigned-worktree"
            for lines in [hover.lines, details.lines] {
                #expect(lines.first { $0.title == "Last verified location" }?.value == expectedLocation)
            }
            #expect(tooltip.contains("Last verified location: \(expectedLocation)"))
        } else {
            #expect(!tooltip.contains("Last verified location"))
        }
    }

    @Test func directoryUpdatesFollowExactMovedSurfaceWithoutReusingCapturedPlacement() throws {
        let original = directoryHierarchy("/synthetic/original")
        let updated = directoryHierarchy("/synthetic/updated", sequence: 2)
        let moved = directoryHierarchy("/synthetic/moved-report", moved: true, sequence: 3)
        let observed = fixtures.snapshot(sessions: [fixtures.session(now: now)], now: now)
        let originalTree = SidebarCopilotTree.project(observed, onto: SidebarTopology(original), now: now)
        let captured = try #require(SidebarPresentation.inspection(
            for: .unmanaged(.session(fixtures.sessionID)), hierarchy: original, connected: true,
            tree: originalTree, managed: .empty, availability: .ready, now: now
        ))
        for (hierarchy, expected) in [(original, "/synthetic/original"), (updated, "/synthetic/updated"), (moved, "/synthetic/moved-report")] {
            let tree = SidebarCopilotTree.project(observed, onto: SidebarTopology(hierarchy), now: now)
            let hover = try #require(card(.session(fixtures.sessionID), sessions: tree.sessions, hierarchy: hierarchy))
            #expect(hover.lines.first { $0.title == "Surface directory" }?.value == expected)
            #expect(!hover.lines.contains { $0.value == "/synthetic/peer-only" })
            let detail = SidebarPresentation.inspectorDetails(
                for: captured, hierarchy: hierarchy, connected: true, tree: tree, managed: .empty, availability: .ready, now: now
            )
            if hierarchy.sequence == 3 {
                #expect(detail == nil, "An already-captured inspection cannot silently change workspace")
                #expect(tree.sessions.first?.workspaceID == fixtures.workspaceB)
                #expect(hierarchy.pathContext(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA) == .unavailable)
            } else {
                #expect(detail?.lines.first { $0.title == "Surface directory" }?.value == expected)
            }
            let pinned = SidebarPresentation.pinnedDetails(
                hierarchy: hierarchy, connected: true, tree: tree, managed: .empty, availability: .ready, now: now
            )
            #expect(pinned.inspection?.sessionID == fixtures.sessionID)
            #expect(pinned.lines.first { $0.title == "Surface directory" }?.value == expected)
        }
        #expect(card(.session(fixtures.sessionID), sessions: originalTree.sessions, hierarchy: .empty) == nil)
    }

    @Test func retainedOriginalNeverBorrowsReplacementDirectoryButNativeContextSurvives() throws {
        let hierarchy = directoryHierarchy("/synthetic/replacement-report")
        var old = session(liveness: .dead)
        old.nodes = [.init(id: "child", parentID: nil, depth: 0, kind: .subagent, name: "Child",
                          state: .blocked, model: nil, ancestryUnresolved: false, hasChildren: false)]
        let replacement = session(id: fixtures.otherSessionID, name: "replacement-model")
        let node = directoryNode(old)
        let sessions = [old, replacement]
        let tree = SidebarCopilotTree(availability: .ready, sessions: sessions, issues: [], generatedAt: now)
        let managed = SidebarOrchestrationSnapshot(version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: [node])
        let oldHover = try #require(card(.session(old.id), sessions: sessions, hierarchy: hierarchy, nodes: [node]))
        #expect(oldHover.category == "Session context" && oldHover.notice != nil)
        #expect(!oldHover.lines.contains { $0.title.lowercased().contains("directory") || $0.value.contains("/synthetic/") })
        for target in [SidebarAgentHoverTarget.managed(node.id, generation: 2), .child(sessionID: old.id, childID: "child")] {
            let retained = try #require(card(target, sessions: sessions, hierarchy: hierarchy, nodes: [node]))
            let field = try #require(retained.lines.first { $0.title.lowercased().contains("directory") })
            #expect(field.value == "Not current for this original session")
            #expect(field.help?.contains("Reported by CMUX") == true)
            #expect(!retained.lines.contains { $0.value == "/synthetic/replacement-report" })
        }
        for target in [SidebarInspection.Target.unmanaged(.session(old.id)), .unmanaged(.child(sessionID: old.id, childID: "child")), .managed(node)] {
            let subject = try #require(SidebarPresentation.inspection(
                for: target, hierarchy: hierarchy, connected: true, tree: tree, managed: managed, availability: .ready, now: now
            ))
            #expect(subject.surfaceID == nil)
            let detail = try #require(SidebarPresentation.inspectorDetails(
                for: subject, hierarchy: hierarchy, connected: true, tree: tree, managed: managed, availability: .ready, now: now
            ))
            #expect(!detail.lines.contains { $0.value == "/synthetic/replacement-report" })
        }
        let pinned = SidebarPresentation.pinnedDetails(
            hierarchy: hierarchy, connected: true, tree: tree, managed: managed, availability: .ready, now: now
        )
        #expect(pinned.inspection?.sessionID == replacement.id)
        #expect(pinned.lines.first { $0.title == "Surface directory" }?.value == "/synthetic/replacement-report")
        #expect(pinned.lines.contains(.init(title: "Model", value: "replacement-model")))
        #expect(card(.session(old.id), sessions: [replacement], hierarchy: hierarchy, nodes: [node]) == nil)
    }

    @Test func directoryRevocationRevalidatesOpenSubjectsWithoutCollapsingGrantedNil() throws {
        let session = session()
        let node = directoryNode(session)
        let tree = SidebarCopilotTree(availability: .ready, sessions: [session], issues: [], generatedAt: now)
        let managed = SidebarOrchestrationSnapshot(version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: [node])
        let initial = directoryHierarchy("/synthetic/before-revocation")
        let subjects = try [
            SidebarInspection.Target.unmanaged(.session(session.id)), .managed(node),
            .unmanaged(.surface(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA))
        ].map { target in
            try #require(SidebarPresentation.inspection(
                for: target, hierarchy: initial, connected: true, tree: tree, managed: managed, availability: .ready, now: now
            ))
        }
        for (hierarchy, expected) in [
            (initial, "/synthetic/before-revocation"),
            (directoryHierarchy("/synthetic/must-be-redacted", granted: false, sequence: 2), "Path unavailable"),
            (directoryHierarchy(nil, sequence: 3), "No path shared")
        ] {
            for subject in subjects {
                let details = try #require(SidebarPresentation.inspectorDetails(
                    for: subject, hierarchy: hierarchy, connected: true, tree: tree, managed: managed, availability: .ready, now: now
                ))
                #expect(details.lines.first { $0.title == "Surface directory" }?.value == expected)
                #expect(!details.lines.contains { $0.value == "/synthetic/must-be-redacted" })
            }
            let hover = try #require(card(.session(session.id), sessions: [session], hierarchy: hierarchy))
            #expect(hover.id == "session-\(session.id)")
            #expect(hover.lines.first { $0.title == "Surface directory" }?.value == expected)
            let pinned = SidebarPresentation.pinnedDetails(
                hierarchy: hierarchy, connected: true, tree: tree, managed: managed, availability: .ready, now: now
            )
            #expect(pinned.inspection?.sessionID == session.id)
            #expect(pinned.lines.first { $0.title == "Surface directory" }?.value == expected)
        }
    }

    @Test func endedAndStaleObservationsDoNotTurnHostContextIntoAgentCurrentDirectory() throws {
        let hierarchy = directoryHierarchy("/synthetic/host-report")
        let ended = session(liveness: .dead)
        let hover = try #require(card(.session(ended.id), sessions: [ended], hierarchy: hierarchy))
        #expect(hover.notice == "Live session ownership is not confirmed.")
        #expect(hover.lines.first { $0.title == "Surface directory" } == .init(
            title: "Surface directory", value: "/synthetic/host-report",
            help: "Reported by CMUX for this surface; no report time supplied. Not a verified agent or tool working directory."
        ))
        let node = directoryNode(ended)
        let stale = try #require(card(.managed(node.id, generation: 2), sessions: [ended], hierarchy: hierarchy,
                                     nodes: [node], availability: .stale))
        #expect(stale.notice == "Managed observation is stale or unavailable. Last-known metadata is not live state.")
        #expect(stale.lines.first { $0.title == "Surface directory" } == hover.lines.first { $0.title == "Surface directory" })
        #expect(card(.managed(node.id, generation: 1), sessions: [ended], hierarchy: hierarchy, nodes: [node]) == nil)
        let expired = try #require(card(.session(ended.id), sessions: [ended], hierarchy: hierarchy,
                                       generatedAt: now.addingTimeInterval(-9)))
        #expect(expired.lines.isEmpty)
    }

    @Test func sessionPreviewUsesItsExactSubjectAndDoesNotBorrowFromSameNamedPeers() throws {
        let a = session()
        let b = session(id: fixtures.otherSessionID, name: "different-model")
        let result = try #require(card(.session(a.id), sessions: [a, b]))
        #expect(result.lines.contains(.init(title: "Model", value: "model")))
        #expect(!result.lines.contains { $0.value == "different-model" })
        #expect(result.id == "session-\(a.id)")
        #expect(result.lines.filter { $0.copyableSessionID != nil } == [.sessionID(a.id)])
        #expect(card(.session(a.id), sessions: [a, a]) == nil)
        #expect(card(.session(a.id), sessions: [a], connected: false) == nil)
        #expect(card(.session(a.id), sessions: [a], hierarchy: fixtures.hierarchy(granted: false)) == nil)
        #expect(card(.session(a.id), sessions: [a], hierarchy: fixtures.hierarchy(moved: true)) == nil)
        #expect(card(.session(UUID()), sessions: [a]) == nil)
    }

    @Test func staleOrMissingAgentEvidenceCannotAdvertiseCurrentMetrics() throws {
        let a = session()
        let result = try #require(card(.session(a.id), sessions: [a], generatedAt: now.addingTimeInterval(-9)))
        #expect(result.notice == "Session observation is no longer current.")
        #expect(result.lines.isEmpty && result.subtitle == nil)
        let current = try #require(card(.session(a.id), sessions: [a]))
        #expect(!current.lines.contains { ["Context", "Elapsed", "Git changes", "Pet"].contains($0.title) })
    }

    @Test func observedChildKeepsParentPlacementAndItsOwnModel() throws {
        var a = session()
        a.nodes = [.init(id: "child", parentID: nil, depth: 0, kind: .subagent, name: "Review agent",
                         state: .blocked, model: "child-model", ancestryUnresolved: true, hasChildren: false)]
        let result = try #require(card(.child(sessionID: a.id, childID: "child"), sessions: [a]))
        #expect(result.title == "Review agent")
        #expect(result.lines.contains(.init(title: "Model", value: "child-model")))
        #expect(result.lines.contains(.init(title: "Placement", value: "Observed child; native placement belongs to its parent session")))
        #expect(!result.lines.contains { $0.title == "Surface ID" || $0.title == "Session glyph" })
        #expect(result.lines.filter { $0.copyableSessionID != nil } == [.sessionID(a.id, isParent: true)])
        #expect(result.lines.contains { $0.title == "Parent session ID" && $0.value == a.id.uuidString })
        a.nodes.append(a.nodes[0])
        #expect(card(.child(sessionID: a.id, childID: "child"), sessions: [a]) == nil)
        #expect(card(.child(sessionID: UUID(), childID: "child"), sessions: [a]) == nil)
    }

    @Test func managedPreviewRejectsAReplacedGenerationAndShowsOnlyVerifiedMetrics() throws {
        let node = SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: nil, role: "worker", label: "Managed agent",
            workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceA, generation: 2,
            phase: "turn-running", availability: "busy", copilotSessionId: fixtures.sessionID,
            executionMode: .interactive, worktreeLabel: "not-current", branchLabel: "old-branch",
            gitEvidenceStatus: "verified", gitEvidenceAt: now.addingTimeInterval(-3_600),
            createdAt: now.addingTimeInterval(-100), updatedAt: now
        )
        let result = try #require(card(.managed(node.id, generation: 2), sessions: [session()], nodes: [node]))
        #expect(result.title == node.label)
        #expect(result.lines.contains(.init(title: "Model", value: "model")))
        #expect(!result.lines.contains { $0.value == "old-branch" || $0.value == "not-current" })
        #expect(result.lines.contains(.init(title: "Last verified location",
                                           value: "Assigned directory: Not current Git state: old-branch · not-current",
                                           help: SidebarPresentation.assignedGitHelp)))
        #expect(result.lines.contains { $0.title == "Git evidence" && $0.value.hasPrefix("Assigned directory: Stale") })
        #expect(result.lines.filter { $0.copyableSessionID != nil } == [.sessionID(fixtures.sessionID)])
        #expect(!result.lines.contains { $0.copyableSessionID == node.id || $0.copyableSessionID == node.runId })
        let withoutObservedSession = try #require(card(.managed(node.id, generation: 2), sessions: [], nodes: [node]))
        #expect(withoutObservedSession.lines.filter { $0.copyableSessionID != nil } == [.sessionID(fixtures.sessionID)])
        #expect(card(.managed(node.id, generation: 3), sessions: [session()], nodes: [node]) == nil)
        #expect(card(.managed(node.id, generation: 2), sessions: [session()], nodes: [node, node]) == nil)
        let stale = try #require(card(
            .managed(node.id, generation: 2), sessions: [], nodes: [node], availability: .stale
        ))
        #expect(stale.notice == "Managed observation is stale or unavailable. Last-known metadata is not live state.")
        let line = try #require(stale.lines.first { $0.copyableSessionID != nil })
        let sessionID = try #require(line.copyableSessionID)
        #expect(sessionID == node.copilotSessionId)
        #expect(line.value == fixtures.sessionID.uuidString)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(SidebarSessionCopy.copy(sessionID, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == line.value)
        #expect(card(.managed(node.id, generation: 2), sessions: [], nodes: [node, node], availability: .stale) == nil)
        for availability in [SidebarOrchestrationAvailability.unavailable, .hidden, .disconnected, .waiting, .loading] {
            let unavailable = try #require(card(
                .managed(node.id, generation: 2), sessions: [], nodes: [node], availability: availability
            ))
            #expect(unavailable.lines.allSatisfy { $0.copyableSessionID == nil })
        }
    }

    @Test func unavailableAndAmbiguousSessionIdentitiesHaveNoCopyAction() throws {
        for liveness in [AgentProcessLiveness.ambiguous, .unknown] {
            var a = session(liveness: liveness)
            a.nodes = [.init(id: "child", parentID: nil, depth: 0, kind: .subagent, name: "Child",
                             state: .working, model: nil, ancestryUnresolved: false, hasChildren: false)]
            for target in [SidebarAgentHoverTarget.session(a.id), .child(sessionID: a.id, childID: "child")] {
                let result = try #require(card(target, sessions: [a]))
                #expect(result.lines.contains { $0.value == a.id.uuidString })
                #expect(result.lines.allSatisfy { $0.copyableSessionID == nil })
            }
        }
        let node = SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: nil, role: "worker", label: "Starting",
            workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceA, generation: 1,
            phase: "launching", availability: "busy", createdAt: now, updatedAt: now
        )
        for availability in [SidebarOrchestrationAvailability.ready, .stale] {
            let missing = try #require(card(
                .managed(node.id, generation: 1), sessions: [session()], nodes: [node], availability: availability
            ))
            #expect(missing.lines.allSatisfy { $0.copyableSessionID == nil })
            #expect(!missing.lines.contains { $0.title == "Session ID" })
        }
        #expect(SidebarDetailLine(title: "Session ID", value: fixtures.sessionID.uuidString).copyableSessionID == nil)
    }

    @Test func generatingAllPreviewSubjectsLeavesEvidenceAndPreferencesUnchanged() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let state = (preferences.history, preferences.attention, preferences.layout, preferences.icons)
        var a = session()
        a.nodes = [.init(id: "child", parentID: nil, depth: 0, kind: .subagent, name: "Child",
                         state: .working, model: nil, ancestryUnresolved: false, hasChildren: false)]
        let before = a
        _ = card(.session(a.id), sessions: [a])
        _ = card(.child(sessionID: a.id, childID: "child"), sessions: [a])
        #expect(a == before)
        #expect(preferences.history == state.0 && preferences.attention == state.1)
        #expect(preferences.layout == state.2 && preferences.icons == state.3)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("CMUXMaestroSidebar/UI/SidebarAgentHoverContent.swift"), encoding: .utf8)
        for forbidden in ["SidebarPreferences", "SidebarNavigation", "markSeen(", "acknowledge(", "inspect(", "context.host"] {
            #expect(!source.contains(forbidden))
        }
    }
}
