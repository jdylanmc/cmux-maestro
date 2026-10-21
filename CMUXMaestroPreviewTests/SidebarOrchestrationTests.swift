import Foundation
import Testing
@testable import CMUXMaestroPreview

private func publicationArrived(_ stream: AsyncStream<Void>) async -> Bool {
    await bounded {
        for await _ in stream { return true }
        return false
    } == true
}

@MainActor
struct SidebarOrchestrationTests {
    /// The controller's projected phases, read by executing it, must each decode into the typed sidebar vocabulary.
    @Test func controllerProjectedPhasesDecodeExactlyIntoTypedPhases() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", "-c",
            "import json, runpy, sys; api = runpy.run_path(sys.argv[1]); print(json.dumps(sorted(api['PROJECTED_PHASES'])))",
            root.appendingPathComponent("scripts/cmux-maestro-orchestrator.py").path
        ]
        process.currentDirectoryURL = root
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(4_096), as: UTF8.self)
        try #require(process.terminationStatus == 0, Comment(rawValue: detail))
        let projected = try JSONDecoder().decode([String].self, from: data)
        try #require(!projected.isEmpty)
        let decoded = projected.compactMap(SidebarOrchestrationPhase.init(rawValue:))
        #expect(decoded.count == projected.count, "Undecodable projected phases: \(projected)")
        #expect(Set(decoded) == Set(SidebarOrchestrationPhase.allCases), "Typed phases the controller never projects")
    }

    @Test func projectionKeepsExplicitAncestryWithoutDisclosingOffWindowCount() async throws {
        let workspace = UUID()
        let run = UUID()
        let coordinatorSurface = UUID()
        let workerSurface = UUID()
        let offWindowSurface = UUID()
        let root = node(
            run: run, role: "coordinator", parent: nil,
            workspace: workspace, surface: coordinatorSurface
        )
        let child = node(
            run: run, role: "worker", parent: root.id,
            workspace: workspace, surface: workerSurface
        )
        let omitted = node(
            run: run, role: "worker", parent: root.id,
            workspace: workspace, surface: offWindowSurface
        )
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date(), complete: true, omittedCount: 0,
            nodes: [root, child, omitted]
        )
        let published = AsyncStream<Void>.makeStream()
        let poll = SidebarOrchestrationPolling(
            read: { snapshot },
            pause: {
                published.continuation.yield(())
                try await sidebarFrozenExpiry(0)
            },
            now: { snapshot.generatedAt }
        )
        poll.update(
            topology: topology(
                workspace: workspace, surfaces: [coordinatorSurface, workerSurface]
            ),
            connected: true
        )
        poll.setVisible(true)
        defer {
            poll.setVisible(false)
            published.continuation.finish()
        }
        try #require(await publicationArrived(published.stream))

        #expect(poll.availability == .ready)
        #expect(poll.snapshot.nodes.map(\.id) == [root.id, child.id])
        #expect(poll.snapshot.omittedCount == 0)
        #expect(poll.roots.map(\.id) == [root.id])
        #expect(poll.children(of: root.id).map(\.id) == [child.id])
    }

    @Test func resumedInteractiveCoordinatorKeepsTheSnapshotReadable() throws {
        // A relaunch resume records the next generation of the same root (ADR 0024).
        for generation in [1, 2, 7] {
            let root = SidebarOrchestrationNode(
                id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: "Coordinator",
                workspaceId: UUID(), surfaceId: UUID(), generation: generation, phase: "turn-running",
                availability: "busy", copilotSessionId: UUID(), executionMode: .interactive,
                createdAt: Date(), updatedAt: Date())
            try SidebarOrchestrationReader.validate(
                .init(version: 1, generatedAt: Date(), complete: true, omittedCount: 0, nodes: [root]))
        }
    }

    @Test func filteredCoordinatorDoesNotPromoteChildToProvenRoot() async throws {
        let workspace = UUID()
        let run = UUID()
        let root = node(run: run, role: "coordinator", parent: nil, workspace: workspace)
        let child = node(run: run, role: "worker", parent: root.id, workspace: workspace)
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date(), complete: true, omittedCount: 0,
            nodes: [root, child]
        )
        let published = AsyncStream<Void>.makeStream()
        let poll = SidebarOrchestrationPolling(
            read: { snapshot },
            pause: {
                published.continuation.yield(())
                try await sidebarFrozenExpiry(0)
            },
            now: { snapshot.generatedAt }
        )
        poll.update(
            topology: topology(workspace: workspace, surfaces: [child.surfaceId]),
            connected: true
        )
        poll.setVisible(true)
        defer {
            poll.setVisible(false)
            published.continuation.finish()
        }
        try #require(await publicationArrived(published.stream))
        #expect(poll.availability == .ready)
        #expect(poll.snapshot.nodes.isEmpty)
        #expect(poll.snapshot.omittedCount == 0)
    }

    @Test func staleSnapshotIsQualifiedWithoutDiscardingValidatedNodes() async throws {
        let workspace = UUID()
        let root = node(run: UUID(), role: "coordinator", parent: nil, workspace: workspace)
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date().addingTimeInterval(-120),
            complete: true, omittedCount: 0, nodes: [root]
        )
        let published = AsyncStream<Void>.makeStream()
        let poll = SidebarOrchestrationPolling(
            read: { snapshot },
            pause: {
                published.continuation.yield(())
                try await sidebarFrozenExpiry(0)
            },
            now: { snapshot.generatedAt.addingTimeInterval(120) }
        )
        poll.update(
            topology: topology(workspace: workspace, surfaces: [root.surfaceId]),
            connected: true
        )
        poll.setVisible(true)
        defer {
            poll.setVisible(false)
            published.continuation.finish()
        }
        try #require(await publicationArrived(published.stream))
        #expect(poll.availability == .stale)
        #expect(poll.snapshot.nodes == [root])
    }

    @Test(arguments: ["success", "missing", "unsafe"])
    func obsoleteReadCannotEraseCurrentStateOrDuplicatePolling(completion: String) async throws {
        let workspace = UUID()
        let previous = node(run: UUID(), role: "coordinator", parent: nil, workspace: workspace)
        let current = node(run: UUID(), role: "coordinator", parent: nil, workspace: workspace)
        let previousSnapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date(), complete: true, omittedCount: 0, nodes: [previous]
        )
        let currentSnapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date(), complete: true, omittedCount: 0, nodes: [current]
        )
        let gate = OrchestrationReadGate()
        let poll = SidebarOrchestrationPolling(
            read: { try await gate.read() },
            pause: { try await gate.pause() },
            now: { currentSnapshot.generatedAt },
            taskFinished: { gate.finished.append($0) }
        )
        defer {
            poll.setVisible(false)
            gate.cancelPending()
        }
        poll.update(
            topology: topology(workspace: workspace, surfaces: [previous.surfaceId]),
            connected: true
        )
        poll.setVisible(true)
        await sidebarEventually { gate.readCount == 1 }
        poll.update(
            topology: topology(workspace: workspace, surfaces: [current.surfaceId]),
            connected: true
        )
        await sidebarEventually { gate.readCount == 2 }
        try gate.resolve(2, with: .success(currentSnapshot))
        await sidebarEventually { poll.snapshot.nodes == [current] && gate.pauseCount == 1 }

        switch completion {
        case "success": try gate.resolve(1, with: .success(previousSnapshot))
        case "missing": try gate.resolve(1, with: .failure(CopilotFileError.missing))
        default: try gate.resolve(1, with: .failure(CopilotFileError.unsafePath))
        }
        await sidebarEventually { gate.finished.count == 1 }
        #expect(poll.snapshot.nodes == [current])
        #expect(poll.availability == .ready)
        #expect(gate.readCount == 2)

        poll.setVisible(false)
        await sidebarEventually { gate.finished.count == 2 }
        #expect(gate.finishedPauses.contains(1))
        #expect(poll.availability == .hidden)
        #expect(gate.readCount == 2)
        poll.setVisible(true)
        await sidebarEventually { gate.readCount == 3 }
        try gate.resolve(3, with: .success(currentSnapshot))
        await sidebarEventually { poll.snapshot.nodes == [current] }
        poll.setVisible(false)
        await sidebarEventually { gate.finished.count == 3 }
        #expect(gate.readCount == 3)
    }

    @Test func validationRejectsCyclesDuplicateSurfacesAndFutureEvidence() {
        let workspace = UUID()
        let run = UUID()
        let root = node(run: run, role: "coordinator", parent: nil, workspace: workspace)
        let child = node(run: run, role: "worker", parent: root.id, workspace: workspace)
        let duplicateSurface = node(
            run: run, role: "worker", parent: root.id,
            workspace: workspace, surface: child.surfaceId
        )
        let future = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date().addingTimeInterval(600),
            complete: true, omittedCount: 0, nodes: [root]
        )
        #expect(throws: CopilotFileError.self) {
            try SidebarOrchestrationReader.validate(
                .init(
                    version: 1, generatedAt: Date(), complete: true, omittedCount: 0,
                    nodes: [root, child, duplicateSurface]
                )
            )
        }

        #expect(throws: CopilotFileError.self) {
            try SidebarOrchestrationReader.validate(future)
        }

        let firstID = UUID()
        let secondID = UUID()
        let first = node(
            id: firstID, run: run, role: "worker", parent: secondID, workspace: workspace
        )
        let second = node(
            id: secondID, run: run, role: "worker", parent: firstID, workspace: workspace
        )
        #expect(throws: CopilotFileError.self) {
            try SidebarOrchestrationReader.validate(
                .init(
                    version: 1, generatedAt: Date(), complete: true, omittedCount: 0,
                    nodes: [first, second]
                )
            )
        }
    }

    @Test func validationRejectsCrossRunAncestryAndInvalidLifecycleShape() {
        let workspace = UUID()
        let root = node(run: UUID(), role: "coordinator", parent: nil, workspace: workspace)
        let crossRun = node(
            run: UUID(), role: "worker", parent: root.id, workspace: workspace
        )
        let invalid = node(
            run: root.runId, role: "worker", parent: root.id, workspace: workspace,
            phase: "reported-completed", availability: "busy"
        )
        for nodes in [[root, crossRun], [root, invalid]] {
            #expect(throws: CopilotFileError.self) {
                try SidebarOrchestrationReader.validate(
                    .init(
                        version: 1, generatedAt: Date(), complete: true,
                        omittedCount: 0, nodes: nodes
                    )
                )
            }
        }
    }

    @Test func workspaceNodeAllowancesAreIndependentWithinBoundedHostProjection() throws {
        let now = Date()
        let first = UUID(), second = UUID()
        let nodes = [first, second].flatMap { workspace in
            (0..<128).map { _ in
                node(run: UUID(), role: "coordinator", parent: nil, workspace: workspace)
            }
        }
        try SidebarOrchestrationReader.validate(.init(
            version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: nodes
        ))
        let excess = node(run: UUID(), role: "coordinator", parent: nil, workspace: first)
        #expect(throws: CopilotFileError.self) {
            try SidebarOrchestrationReader.validate(.init(
                version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: nodes + [excess]
            ))
        }
        let hostOverflow = (0..<1025).map { _ in
            node(run: UUID(), role: "coordinator", parent: nil, workspace: UUID())
        }
        #expect(throws: CopilotFileError.self) {
            try SidebarOrchestrationReader.validate(.init(
                version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: hostOverflow
            ))
        }
    }

    @Test func legacyWorkspaceUUIDSpellingsShareOneDecodedObserverAllowance() throws {
        let spelling = "abcdefab-1234-4234-8234-abcdefabcdef"
        let workspace = try #require(UUID(uuidString: spelling))
        let nodes = (0..<128).map { _ in
            node(run: UUID(), role: "coordinator", parent: nil, workspace: workspace)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date(), complete: true, omittedCount: 0, nodes: nodes
        ))
        var wire = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var entries = try #require(wire["nodes"] as? [[String: Any]])
        for index in entries.indices {
            entries[index]["workspaceId"] = index == 127 ? spelling.uppercased() : spelling
        }
        wire["nodes"] = entries
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let accepted = try decoder.decode(
            SidebarOrchestrationSnapshot.self, from: JSONSerialization.data(withJSONObject: wire)
        )
        #expect(accepted.nodes.allSatisfy { $0.workspaceId == workspace })
        try SidebarOrchestrationReader.validate(accepted)
        var excess = entries[127]
        excess["id"] = UUID().uuidString
        excess["runId"] = UUID().uuidString
        excess["surfaceId"] = UUID().uuidString
        wire["nodes"] = entries + [excess]
        let refused = try decoder.decode(
            SidebarOrchestrationSnapshot.self, from: JSONSerialization.data(withJSONObject: wire)
        )
        #expect(throws: CopilotFileError.self) {
            try SidebarOrchestrationReader.validate(refused)
        }
    }

    @Test func managedCoordinatorRequiresExactInteractiveSessionIdentity() throws {
        let now = Date()
        let root = SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: nil, role: "coordinator",
            label: "Managed coordinator", workspaceId: UUID(), surfaceId: UUID(),
            generation: 1, phase: "turn-running", availability: "busy",
            copilotSessionId: UUID(), executionMode: .interactive,
            createdAt: now, updatedAt: now
        )
        try SidebarOrchestrationReader.validate(.init(
            version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: [root]
        ))
        let missingIdentity = SidebarOrchestrationNode(
            id: root.id, runId: root.runId, parentId: nil, role: root.role,
            label: root.label, workspaceId: root.workspaceId, surfaceId: root.surfaceId,
            generation: 1, phase: root.phase, availability: root.availability,
            executionMode: .interactive, createdAt: now, updatedAt: now
        )
        #expect(throws: CopilotFileError.self) {
            try SidebarOrchestrationReader.validate(.init(
                version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: [missingIdentity]
            ))
        }
    }

    @Test func displayMetadataIsOptionalBoundedAndControlCharacterFree() throws {
        let workspace = UUID()
        let run = UUID()
        let captured = Date()
        let valid = node(
            run: run, role: "coordinator", parent: nil, workspace: workspace,
            worktreeLabel: "cmux-maestro", branchLabel: "feat/hierarchy-first",
            gitEvidenceStatus: "verified", gitEvidenceAt: captured
        )
        try SidebarOrchestrationReader.validate(.init(
            version: 1, generatedAt: Date(), complete: true, omittedCount: 0, nodes: [valid]
        ))
        for invalid in [
            node(run: run, role: "coordinator", parent: nil, workspace: workspace,
                 worktreeLabel: String(repeating: "x", count: 121),
                 gitEvidenceStatus: "verified", gitEvidenceAt: captured),
            node(run: run, role: "coordinator", parent: nil, workspace: workspace,
                 worktreeLabel: "worktree", branchLabel: "feat/unsafe\nbranch",
                 gitEvidenceStatus: "verified", gitEvidenceAt: captured),
            node(run: run, role: "coordinator", parent: nil, workspace: workspace,
                 worktreeLabel: "", gitEvidenceStatus: "verified", gitEvidenceAt: captured),
            node(run: run, role: "coordinator", parent: nil, workspace: workspace,
                 worktreeLabel: "retained", gitEvidenceStatus: "unavailable",
                 gitEvidenceAt: captured),
            node(run: run, role: "coordinator", parent: nil, workspace: workspace,
                 worktreeLabel: nil, gitEvidenceStatus: "verified", gitEvidenceAt: captured),
            node(run: run, role: "coordinator", parent: nil, workspace: workspace,
                 gitEvidenceStatus: "unexpected", gitEvidenceAt: captured)
        ] {
            #expect(throws: CopilotFileError.self) {
                try SidebarOrchestrationReader.validate(.init(
                    version: 1, generatedAt: Date(), complete: true,
                    omittedCount: 0, nodes: [invalid]
                ))
            }
        }
    }

    @Test func everyAcceptedPhaseHasAnExplicitVisibleTitle() {
        let expected: [SidebarOrchestrationPhase: String] = [
            .registered: "Registered",
            .launching: "Launching",
            .turnQueued: "Queued",
            .turnRunning: "Working",
            .reportedBlocked: "Blocked",
            .reportedCompleted: "Completed · available",
            .reportedFailed: "Failed · available",
            .reportMissing: "Report missing",
            .permissionDenied: "Permission denied · available",
            .turnFailed: "Turn failed",
            .processDisappeared: "Process disappeared",
            .terminalDisappeared: "Terminal disappeared",
            .launchFailed: "Launch failed",
            .startupFailed: "Startup failed",
            .resourceRetired: "Resource retired"
        ]
        #expect(Set(expected.keys) == Set(SidebarOrchestrationPhase.allCases))
        for phase in SidebarOrchestrationPhase.allCases {
            let title = phase.title(availability: phase == .registered ? "active" : "idle")
            #expect(title == expected[phase])
            #expect(!phase.symbolName(role: "worker").isEmpty)
            #expect(title != "Unknown state")
        }
    }

    @Test func iconOverridesMatchExactIdentityWithoutRefreshingStateOrGitEvidence() throws {
        let current = node(run: UUID(), role: "coordinator", parent: nil, workspace: UUID())
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date(), complete: true, omittedCount: 0, nodes: [current]
        )
        let entry = SidebarIconOverrides.Entry(
            nodeId: current.id, runId: current.runId, workspaceId: current.workspaceId,
            surfaceId: current.surfaceId, iconId: "md-duck", iconColor: .purple
        )
        let updated = try SidebarIconOverrides(version: 1, icons: [entry]).applying(to: snapshot)
        #expect(updated.nodes[0].iconId == "md-duck")
        #expect(updated.nodes[0].iconColor == .purple)
        #expect(updated.nodes[0].updatedAt == current.updatedAt)
        #expect(updated.nodes[0].phase == current.phase)
        #expect(updated.nodes[0].gitEvidenceAt == current.gitEvidenceAt)
        let wrongRun = SidebarIconOverrides.Entry(
            nodeId: current.id, runId: UUID(), workspaceId: current.workspaceId,
            surfaceId: current.surfaceId, iconId: "md-duck", iconColor: .purple
        )
        #expect(try SidebarIconOverrides(version: 1, icons: [wrongRun]).applying(to: snapshot) == snapshot)
        #expect(throws: CopilotFileError.self) {
            try SidebarIconOverrides(version: 1, icons: [entry, entry]).applying(to: snapshot)
        }
        let invalid = SidebarIconOverrides.Entry(
            nodeId: current.id, runId: current.runId, workspaceId: current.workspaceId,
            surfaceId: current.surfaceId, iconId: "../image.png", iconColor: nil
        )
        #expect(throws: CopilotFileError.self) {
            try SidebarIconOverrides(version: 1, icons: [invalid]).applying(to: snapshot)
        }
    }

    @Test func corruptIconOverlayLeavesManagedHierarchyIntact() {
        let current = node(run: UUID(), role: "coordinator", parent: nil, workspace: UUID())
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date(), complete: true, omittedCount: 0, nodes: [current]
        )
        #expect(SidebarIconOverrides.overlaid(Data("not json".utf8), onto: snapshot) == snapshot)
        let invalid = SidebarIconOverrides.Entry(
            nodeId: current.id, runId: current.runId, workspaceId: current.workspaceId,
            surfaceId: current.surfaceId, iconId: "../image.png", iconColor: nil
        )
        let data = try? JSONEncoder().encode(SidebarIconOverrides(version: 1, icons: [invalid]))
        #expect(SidebarIconOverrides.overlaid(data ?? Data(), onto: snapshot) == snapshot)
    }

    @Test func gitChangeCountsRequireValidFreshEvidenceAndRemainBackwardCompatible() throws {
        let captured = Date()
        let changes = SidebarGitChanges(files: 3, insertions: 42, deletions: 7, untrackedFiles: 1, binaryFiles: 1)
        let valid = node(
            run: UUID(), role: "coordinator", parent: nil, workspace: UUID(),
            worktreeLabel: "feature-tree", gitEvidenceStatus: "verified", gitEvidenceAt: captured,
            gitChangesStatus: "verified", gitChanges: changes, gitChangesAt: captured
        )
        try SidebarOrchestrationReader.validate(.init(
            version: 1, generatedAt: captured, complete: true, omittedCount: 0, nodes: [valid]
        ))
        #expect(valid.currentGitChanges(at: captured) == changes)
        #expect(valid.currentGitChanges(at: captured.addingTimeInterval(61)) == nil)
        #expect(valid.currentGitChanges(at: captured.addingTimeInterval(-2)) == nil)
        let oldCounts = node(
            run: UUID(), role: "coordinator", parent: nil, workspace: UUID(),
            worktreeLabel: "feature-tree", gitEvidenceStatus: "verified", gitEvidenceAt: captured,
            gitChangesStatus: "verified", gitChanges: changes, gitChangesAt: captured.addingTimeInterval(-61)
        )
        #expect(oldCounts.currentGitChanges(at: captured) == nil)
        for invalidChanges in [
            SidebarGitChanges(files: -1, insertions: 0, deletions: 0, untrackedFiles: 0, binaryFiles: 0),
            SidebarGitChanges(files: 1, insertions: 1_000_000_001, deletions: 0, untrackedFiles: 0, binaryFiles: 0),
            SidebarGitChanges(files: 1, insertions: 0, deletions: 0, untrackedFiles: 2, binaryFiles: 0),
            SidebarGitChanges(files: 0, insertions: 1, deletions: 0, untrackedFiles: 0, binaryFiles: 0)
        ] {
            #expect(!invalidChanges.isValid)
        }
        for (status, payload): (String?, SidebarGitChanges?) in [
            ("verified", nil), ("unavailable", changes), (nil, changes), ("unexpected", nil)
        ] {
            let invalid = node(
                run: UUID(), role: "coordinator", parent: nil, workspace: UUID(),
                worktreeLabel: "feature-tree", gitEvidenceStatus: "verified", gitEvidenceAt: captured,
                gitChangesStatus: status, gitChanges: payload
            )
            #expect(throws: CopilotFileError.self) {
                try SidebarOrchestrationReader.validate(.init(
                    version: 1, generatedAt: captured, complete: true, omittedCount: 0, nodes: [invalid]
                ))
            }
        }
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        legacy.removeValue(forKey: "gitChanges")
        legacy.removeValue(forKey: "gitChangesStatus")
        legacy.removeValue(forKey: "gitChangesAt")
        let decoded = try JSONDecoder().decode(
            SidebarOrchestrationNode.self, from: JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(decoded.currentGitChanges(at: captured) == nil)
    }

    private func bornRoot(workspace: UUID, surface: UUID, session: UUID) -> SidebarOrchestrationNode {
        let timestamp = Date()
        var root = SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: "Copilot session",
            workspaceId: workspace, surfaceId: surface, generation: 1, phase: "turn-running",
            availability: "busy", copilotSessionId: session, executionMode: .interactive,
            createdAt: timestamp, updatedAt: timestamp
        )
        root.enrollment = "born"
        return root
    }

    private func observed(
        _ session: UUID, workspace: UUID, surface: UUID, name: String?,
        liveness: AgentProcessLiveness = .alive, observedAt: Date = Date()
    ) -> SidebarCopilotSession {
        var value = SidebarCopilotSession(
            id: session, workspaceID: workspace, surfaceID: surface, liveness: liveness, state: .working,
            model: nil, observedAt: observedAt, nodes: [], childrenComplete: true, treeDegraded: false,
            omittedChildrenCount: 0, omittedActiveChildrenCount: 0
        )
        value.sessionName = name
        return value
    }

    private func tree(
        _ sessions: [SidebarCopilotSession], availability: SidebarCopilotAvailability = .ready,
        issues: [AgentSnapshotIssue] = [], lost: [SidebarCopilotSession] = []
    ) -> SidebarCopilotTree {
        var value = SidebarCopilotTree(availability: availability, sessions: sessions, issues: issues, generatedAt: Date())
        value.statusSessions = lost
        return value
    }

    private func titles(_ snapshot: SidebarOrchestrationSnapshot, _ tree: SidebarCopilotTree) -> [String] {
        snapshot.namingBornRoots(from: tree, now: Date()).nodes.map(\.title)
    }

    @Test func bornRootTakesItsExactSessionNameUnderADR0022Rules() throws {
        let workspace = UUID(), surface = UUID(), session = UUID()
        let born = bornRoot(workspace: workspace, surface: surface, session: session)
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date(), complete: true, omittedCount: 0, nodes: [born])
        try SidebarOrchestrationReader.validate(snapshot)
        let exact = observed(session, workspace: workspace, surface: surface, name: "Synthetic refactor")
        let named = snapshot.namingBornRoots(from: tree([exact]), now: Date())
        #expect(named.nodes.map(\.title) == ["Synthetic refactor"])
        #expect(named.nodes.map(\.label) == ["Copilot session"])  // the projected label is never rewritten
        let unnamed: [SidebarCopilotTree] = [
            tree([observed(UUID(), workspace: workspace, surface: surface, name: "Other session")]),
            tree([observed(session, workspace: workspace, surface: UUID(), name: "Moved surface")]),
            tree([observed(session, workspace: UUID(), surface: surface, name: "Other workspace")]),
            tree([observed(session, workspace: workspace, surface: surface, name: nil)]),
            tree([observed(session, workspace: workspace, surface: surface, name: "Dead", liveness: .dead)]),
            tree([observed(session, workspace: workspace, surface: surface, name: "Stale",
                           observedAt: Date().addingTimeInterval(-60))]),
            // The same UUID observed on another surface too: ambiguous.
            tree([exact, observed(session, workspace: workspace, surface: UUID(), name: "Twin")]),
            tree([exact], issues: [.permissionDenied]),
            tree([exact], availability: .unavailable),
        ]
        for evidence in unnamed {
            #expect(titles(snapshot, evidence) == ["Copilot session"])
        }
    }

    /// #261: after a relaunch, Copilot defers a resumed session's hooks and lock until its first
    /// prompt, so the observer has no evidence of it. The row must not stay generic until then.
    @Test func resumedBornRootIsNamedBeforeItsFirstPrompt() {
        let workspace = UUID(), surface = UUID(), session = UUID()
        let born = bornRoot(workspace: workspace, surface: surface, session: session)
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date(), complete: true, omittedCount: 0, nodes: [born])
        let details = CopilotManagedSessionDetails(sessionName: "Synthetic refactor", petId: "synthetic-pet",
                                                   readAt: Date())
        var unbound = tree([])
        unbound.managedDetails = [session: details]
        #expect(titles(snapshot, unbound) == ["Synthetic refactor"])
        let pet = SidebarPresentation.managedPet(born, tree: unbound, now: Date())
        #expect(pet?.session == session && pet?.choice == "synthetic-pet")

        // Any observation of that session decides instead; stale, denied or ended nodes name nothing.
        var observedDead = tree([observed(session, workspace: workspace, surface: surface, name: "Dead",
                                          liveness: .dead)])
        observedDead.managedDetails = [session: details]
        var stale = tree([])
        stale.managedDetails = [session: CopilotManagedSessionDetails(
            sessionName: "Stale", readAt: Date().addingTimeInterval(-60))]
        var denied = tree([], issues: [.permissionDenied])
        denied.managedDetails = [session: details]
        var other = tree([])
        other.managedDetails = [UUID(): details]
        for evidence in [observedDead, stale, denied, other] {
            #expect(titles(snapshot, evidence) == ["Copilot session"])
        }
        var ended = born
        ended = SidebarOrchestrationNode(
            id: born.id, runId: born.runId, parentId: nil, role: "coordinator", label: "Copilot session",
            workspaceId: workspace, surfaceId: surface, generation: 1, phase: "process-disappeared",
            availability: "unavailable", copilotSessionId: session, executionMode: .interactive,
            createdAt: born.createdAt, updatedAt: born.updatedAt)
        ended.enrollment = "born"
        let endedSnapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date(), complete: true, omittedCount: 0, nodes: [ended])
        #expect(titles(endedSnapshot, unbound) == ["Copilot session"])
        #expect(SidebarPresentation.managedPet(ended, tree: unbound, now: Date()) == nil)
    }

    /// #261 wiring: copilot polling reads details for the managed subjects' exact sessions and
    /// carries them on the tree it publishes.
    @Test func pollingCarriesManagedDetailsForManagedSessions() async throws {
        let workspace = UUID(), surface = UUID(), session = UUID()
        let requested = ManagedRequests()
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let published = AsyncStream<Void>.makeStream()
        let polling = SidebarCopilotPolling(
            read: neutralRead { _ in CopilotSnapshot(generatedAt: timestamp, sessions: [], issues: [], isComplete: true) },
            readManaged: { ids in
                await requested.append(ids)
                return [session: CopilotManagedSessionDetails(sessionName: "Synthetic refactor", readAt: timestamp)]
            },
            pause: {
                published.continuation.yield(())
                try await sidebarFrozenExpiry(0)
            },
            expiryPause: sidebarFrozenExpiry,
            now: { timestamp }
        )
        defer {
            polling.setVisible(false)
            published.continuation.finish()
        }
        polling.update(topology: topology(workspace: workspace, surfaces: [surface]), connected: true)
        polling.updateManagedSubjects(SidebarOrchestrationSnapshot(
            version: 1, generatedAt: timestamp, complete: true, omittedCount: 0,
            nodes: [bornRoot(workspace: workspace, surface: surface, session: session)]))
        polling.setVisible(true)
        try #require(await publicationArrived(published.stream))
        #expect(polling.tree.managedDetails[session]?.sessionName == "Synthetic refactor")
        #expect(await requested.values.first == [session])
    }

    @Test func bornRootKeepsItsNameDuringObservationLossOnlyWithinTheGrace() {
        let workspace = UUID(), surface = UUID(), session = UUID()
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date(), complete: true, omittedCount: 0,
            nodes: [bornRoot(workspace: workspace, surface: surface, session: session)])
        let last = observed(session, workspace: workspace, surface: surface, name: "Last read name")
        let retained = SidebarCopilotTree.statusOnly(last, retainingStatus: true)
        let expired = SidebarCopilotTree.statusOnly(last, retainingStatus: false)
        #expect(titles(snapshot, tree([], availability: .partial, lost: [retained])) == ["Last read name"])
        #expect(titles(snapshot, tree([], availability: .partial, lost: [expired])) == ["Copilot session"])
        #expect(titles(snapshot, tree([], issues: [.permissionDenied], lost: [retained])) == ["Copilot session"])
        #expect(titles(snapshot, tree([], lost: [retained, retained])) == ["Copilot session"])
        for misplaced in [observed(session, workspace: UUID(), surface: surface, name: "Other workspace"),
                          observed(session, workspace: workspace, surface: UUID(), name: "Other surface")] {
            let lost = SidebarCopilotTree.statusOnly(misplaced, retainingStatus: true)
            #expect(titles(snapshot, tree([], availability: .partial, lost: [lost])) == ["Copilot session"])
        }
    }

    @Test func bornRootNameFollowsTheSameTwoHundredCharacterRuleAsUnmanagedRows() {
        let workspace = UUID(), surface = UUID(), session = UUID()
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date(), complete: true, omittedCount: 0,
            nodes: [bornRoot(workspace: workspace, surface: surface, session: session)])
        let name = String(repeating: "é", count: 200)
        let exact = observed(session, workspace: workspace, surface: surface, name: name)
        #expect(titles(snapshot, tree([exact])) == [name])
        #expect(SidebarPresentation.agentTitle(for: exact, in: .empty) == name)
    }

    @Test func onlyTheBornRootIsRenamedInAMixedRun() {
        let workspace = UUID(), surface = UUID(), session = UUID(), childSession = UUID()
        let born = bornRoot(workspace: workspace, surface: surface, session: session)
        let child = node(run: born.runId, role: "worker", parent: born.id, workspace: workspace,
                         copilotSessionId: childSession)
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date(), complete: true, omittedCount: 0, nodes: [born, child])
        let evidence = tree([observed(session, workspace: workspace, surface: surface, name: "Root name"),
                             observed(childSession, workspace: workspace, surface: child.surfaceId, name: "Child name")])
        #expect(titles(snapshot, evidence) == ["Root name", "Implementation"])
    }

    @Test func pollingRetitlesBornRootsAsObservationsChange() async throws {
        let workspace = UUID(), surface = UUID(), session = UUID()
        let born = bornRoot(workspace: workspace, surface: surface, session: session)
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date(), complete: true, omittedCount: 0, nodes: [born])
        let published = AsyncStream<Void>.makeStream()
        let poll = SidebarOrchestrationPolling(read: { snapshot }, pause: {
            published.continuation.yield(())
            try await sidebarFrozenExpiry(0)
        }, now: { snapshot.generatedAt })
        func evidence(_ name: String?) -> SidebarCopilotTree {
            var value = tree(name.map {
                [observed(session, workspace: workspace, surface: surface, name: $0,
                          observedAt: snapshot.generatedAt)]
            } ?? [])
            value.generatedAt = snapshot.generatedAt
            return value
        }
        poll.update(topology: topology(workspace: workspace, surfaces: [surface]), connected: true)
        poll.updateObservedSessions(evidence("Before poll"))
        poll.setVisible(true)
        defer {
            poll.setVisible(false)
            published.continuation.finish()
        }
        try #require(await publicationArrived(published.stream))
        #expect(poll.snapshot.nodes.map(\.title) == ["Before poll"])
        poll.updateObservedSessions(evidence("Renamed"))
        #expect(poll.snapshot.nodes.map(\.title) == ["Renamed"])
        poll.updateObservedSessions(evidence(nil))
        #expect(poll.snapshot.nodes.map(\.title) == ["Copilot session"])
    }

    @Test func enrollmentDecodesAndOnlyBornRootsMayCarryIt() throws {
        let workspace = UUID(), surface = UUID(), session = UUID()
        let born = bornRoot(workspace: workspace, surface: surface, session: session)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SidebarOrchestrationNode.self, from: encoder.encode(born))
        #expect(decoded.enrollment == "born")
        var worker = node(run: born.runId, role: "worker", parent: born.id, workspace: workspace)
        worker.enrollment = "born"
        var invented = born
        invented.enrollment = "adopted"
        // Each clause alone: a worker, a non-interactive root, a root without a session.
        func bornVariant(role: String = "coordinator", mode: SidebarWorkerMode? = .interactive,
                         session: UUID? = UUID(), phase: String = "turn-running", run: UUID = UUID(),
                         parent: UUID? = nil, enrollment: String? = "born", generation: Int = 1,
                         availability: String = "busy") -> SidebarOrchestrationNode {
            var value = SidebarOrchestrationNode(
                id: UUID(), runId: run, parentId: parent, role: role, label: "Copilot session",
                workspaceId: workspace, surfaceId: UUID(), generation: generation, phase: phase,
                availability: availability, copilotSessionId: session, executionMode: mode,
                createdAt: Date(), updatedAt: Date())
            value.enrollment = enrollment
            return value
        }
        func snapshot(_ nodes: [SidebarOrchestrationNode]) -> SidebarOrchestrationSnapshot {
            .init(version: 1, generatedAt: Date(), complete: true, omittedCount: 0, nodes: nodes)
        }
        // Each case differs from an accepted one only by the born clause under test.
        let launchedRoot = bornVariant(enrollment: nil)
        let interactiveChild = bornVariant(role: "worker", run: launchedRoot.runId, parent: launchedRoot.id,
                                           enrollment: nil)
        let registered = bornVariant(mode: nil, session: nil, phase: "registered", enrollment: nil,
                                     generation: 0, availability: "active")
        for nodes in [[bornVariant()], [launchedRoot, interactiveChild], [registered]] {
            try SidebarOrchestrationReader.validate(snapshot(nodes))
        }
        var bornChild = interactiveChild
        bornChild.enrollment = "born"
        var bornRegistered = registered
        bornRegistered.enrollment = "born"
        for nodes in [[born, worker], [invented], [launchedRoot, bornChild], [bornRegistered]] {
            #expect(throws: CopilotFileError.self) {
                try SidebarOrchestrationReader.validate(
                    .init(version: 1, generatedAt: Date(), complete: true, omittedCount: 0, nodes: nodes))
            }
        }
    }

    private func node(
        id: UUID = UUID(),
        run: UUID,
        role: String,
        parent: UUID?,
        workspace: UUID,
        surface: UUID = UUID(),
        phase: String? = nil,
        availability: String? = nil,
        copilotSessionId: UUID? = nil,
        worktreeLabel: String? = nil,
        branchLabel: String? = nil,
        gitEvidenceStatus: String? = nil,
        gitEvidenceAt: Date? = nil,
        gitChangesStatus: String? = nil,
        gitChanges: SidebarGitChanges? = nil,
        gitChangesAt: Date? = nil
    ) -> SidebarOrchestrationNode {
        let timestamp = Date()
        return SidebarOrchestrationNode(
            id: id, runId: run, parentId: parent, role: role,
            label: role == "worker" ? "Implementation" : "Coordinator",
            workspaceId: workspace, surfaceId: surface, generation: role == "worker" ? 1 : 0,
            phase: phase ?? (role == "worker" ? "turn-running" : "registered"),
            availability: availability ?? (role == "worker" ? "busy" : "active"),
            copilotSessionId: copilotSessionId,
            worktreeLabel: worktreeLabel, branchLabel: branchLabel,
            gitEvidenceStatus: gitEvidenceStatus, gitEvidenceAt: gitEvidenceAt,
            gitChangesStatus: gitChangesStatus, gitChanges: gitChanges,
            gitChangesAt: gitChangesAt,
            createdAt: timestamp, updatedAt: timestamp
        )
    }

    private func topology(workspace: UUID, surfaces: [UUID]) -> SidebarTopology {
        SidebarTopology(HierarchySnapshot(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true,
            workspaceMetadataAvailable: true, surfaceMetadataAvailable: true,
            workspacePathsAvailable: false,
            workspaces: [HierarchyWorkspace(
                id: workspace, title: .available("Work"), detail: .available(nil),
                isSelected: .available(true), isPinned: .available(false),
                unreadCount: .available(0), rootPath: .unavailable,
                projectRootPath: .unavailable,
                surfaces: .available(surfaces.map(surface))
            )],
            windowID: UUID()
        ))
    }

    private func surface(_ id: UUID) -> HierarchySurface {
        HierarchySurface(
            id: id, title: "Terminal", kind: .terminal, isFocused: false,
            isPinned: false, unreadCount: 0, workingDirectory: .unavailable
        )
    }
}

@MainActor
private final class OrchestrationReadGate {
    private(set) var readCount = 0
    private(set) var pauseCount = 0
    private(set) var finishedPauses: Set<Int> = []
    var finished: [UInt64] = []
    private var pending: [Int: CheckedContinuation<SidebarOrchestrationSnapshot, Error>] = [:]

    func read() async throws -> SidebarOrchestrationSnapshot {
        readCount += 1
        let index = readCount
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func resolve(_ index: Int, with result: Result<SidebarOrchestrationSnapshot, Error>) throws {
        let pendingContinuation = pending.removeValue(forKey: index)
        let continuation = try #require(pendingContinuation)
        continuation.resume(with: result)
    }

    func pause() async throws {
        pauseCount += 1
        let index = pauseCount
        defer { finishedPauses.insert(index) }
        try await sidebarFrozenExpiry(0)
    }

    func cancelPending() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}

private actor ManagedRequests {
    private(set) var values: [Set<UUID>] = []
    func append(_ ids: Set<UUID>) { values.append(ids) }
}
