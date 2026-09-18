import Foundation
import Testing
@testable import CMUXMaestroPreview

@MainActor
struct SidebarOrchestrationTests {
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
        let poll = SidebarOrchestrationPolling(
            read: { snapshot },
            pause: { try await Task.sleep(for: .seconds(60)) }
        )
        poll.update(
            topology: topology(
                workspace: workspace, surfaces: [coordinatorSurface, workerSurface]
            ),
            connected: true
        )
        poll.setVisible(true)
        for _ in 0..<100 where poll.snapshot.nodes.isEmpty { await Task.yield() }

        #expect(poll.availability == .ready)
        #expect(poll.snapshot.nodes.map(\.id) == [root.id, child.id])
        #expect(poll.snapshot.omittedCount == 0)
        #expect(poll.roots.map(\.id) == [root.id])
        #expect(poll.children(of: root.id).map(\.id) == [child.id])
        poll.setVisible(false)
    }

    @Test func filteredCoordinatorDoesNotPromoteChildToProvenRoot() async {
        let workspace = UUID()
        let run = UUID()
        let root = node(run: run, role: "coordinator", parent: nil, workspace: workspace)
        let child = node(run: run, role: "worker", parent: root.id, workspace: workspace)
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date(), complete: true, omittedCount: 0,
            nodes: [root, child]
        )
        let poll = SidebarOrchestrationPolling(
            read: { snapshot },
            pause: { try await Task.sleep(for: .seconds(60)) }
        )
        poll.update(
            topology: topology(workspace: workspace, surfaces: [child.surfaceId]),
            connected: true
        )
        poll.setVisible(true)
        for _ in 0..<100 where poll.availability == .loading { await Task.yield() }
        #expect(poll.availability == .ready)
        #expect(poll.snapshot.nodes.isEmpty)
        #expect(poll.snapshot.omittedCount == 0)
        poll.setVisible(false)
    }

    @Test func staleSnapshotIsQualifiedWithoutDiscardingValidatedNodes() async {
        let workspace = UUID()
        let root = node(run: UUID(), role: "coordinator", parent: nil, workspace: workspace)
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: Date().addingTimeInterval(-120),
            complete: true, omittedCount: 0, nodes: [root]
        )
        let poll = SidebarOrchestrationPolling(
            read: { snapshot },
            pause: { try await Task.sleep(for: .seconds(60)) }
        )
        poll.update(
            topology: topology(workspace: workspace, surfaces: [root.surfaceId]),
            connected: true
        )
        poll.setVisible(true)
        for _ in 0..<100 where poll.availability == .loading { await Task.yield() }
        #expect(poll.availability == .stale)
        #expect(poll.snapshot.nodes == [root])
        poll.setVisible(false)
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
        try await Task.sleep(for: .seconds(60))
    }

    func cancelPending() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}
