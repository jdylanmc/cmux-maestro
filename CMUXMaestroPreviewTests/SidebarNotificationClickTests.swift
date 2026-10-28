import Darwin
import Foundation
import Testing
@testable import CMUXMaestroPreview

@MainActor
struct SidebarNotificationClickTests {
    private let fixtures = SidebarTreeFixtures()

    private func root() throws -> URL {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/notification-click-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    private var target: MaestroNotificationTarget {
        .init(nodeId: UUID(), sessionId: fixtures.sessionID, workspaceId: fixtures.workspaceA,
              surfaceId: fixtures.surfaceA, generation: 1)
    }

    @Test(arguments: [false, true])
    func registryReleaseDoesNotWaitForDuplicatedDescriptor(throwing: Bool) throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try CopilotFileAccess.openDirectory(root, owner: getuid())
        defer { close(directory) }
        var duplicate: Int32 = -1
        defer { if duplicate >= 0 { close(duplicate) } }
        do {
            try MaestroClickChannel.withRegistry(at: directory) { descriptor in
                duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
                try #require(duplicate >= 0)
                #expect(throws: CopilotFileError.changed) {
                    try MaestroClickChannel(root: root, window: UUID(), serving: true)
                }
                if throwing { throw CopilotFileError.io }
            }
            #expect(!throwing)
        } catch CopilotFileError.io {
            #expect(throwing)
        }
        let stamp = try CopilotFileAccess.statEntry(at: directory, name: ".registry")
        let channel = try MaestroClickChannel(root: root, window: UUID(), serving: true)
        #expect(try CopilotFileAccess.statEntry(at: directory, name: ".registry") == stamp)
        withExtendedLifetime(channel) {}
    }

    @Test func retiredWindowChurnPreservesLiveLeaseAndBusyInodes() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = try MaestroClickChannel(root: root, window: UUID(), serving: true)
        let busy = try MaestroClickChannel(root: root, window: live.window, serving: false)
        let lease = MaestroClickChannel.Lease(nonce: UUID(), workspaces: [fixtures.workspaceA])
        try live.publish(lease)
        let directory = try CopilotFileAccess.openDirectory(root, owner: getuid())
        defer { close(directory) }
        let leaseName = live.window.uuidString.lowercased() + ".lease"
        let busyName = live.window.uuidString.lowercased() + ".busy"
        let leaseStamp = try CopilotFileAccess.statEntry(at: directory, name: leaseName)
        let busyStamp = try CopilotFileAccess.statEntry(at: directory, name: busyName)
        for _ in 0..<300 {
            let retired = try MaestroClickChannel(root: root, window: UUID(), serving: true)
            let sender = try MaestroClickChannel(root: root, window: retired.window, serving: false)
            try retired.publish(.init(nonce: UUID(), workspaces: [UUID()]))
            withExtendedLifetime((retired, sender)) {}
        }
        let found = try MaestroClickChannel.destination(root: root, workspace: fixtures.workspaceA)
        #expect(found.0 == live.window && found.1 == lease)
        #expect(try CopilotFileAccess.statEntry(at: directory, name: leaseName) == leaseStamp)
        #expect(try CopilotFileAccess.statEntry(at: directory, name: busyName) == busyStamp)
        #expect(throws: (any Error).self) { try MaestroClickChannel(root: root, window: live.window, serving: true) }
        #expect(throws: (any Error).self) { try MaestroClickChannel(root: root, window: live.window, serving: false) }
        #expect(try !CopilotFileAccess.names(at: directory, limit: 256).limited)
        withExtendedLifetime(busy) {}
    }

    @Test func boundedSweepsRecoverHistoricalOrphansWithoutReplacingActiveLocks() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0..<300 {
            let window = UUID().uuidString.lowercased()
            for suffix in ["lease", "busy"] {
                let file = root.appendingPathComponent(window + "." + suffix)
                try Data().write(to: file)
                #expect(chmod(file.path, 0o600) == 0)
            }
        }
        let live = try MaestroClickChannel(root: root, window: UUID(), serving: true)
        try live.publish(.init(nonce: UUID(), workspaces: [fixtures.workspaceA]))
        #expect(try MaestroClickChannel.destination(root: root, workspace: fixtures.workspaceA).0 == live.window)
        let directory = try CopilotFileAccess.openDirectory(root, owner: getuid())
        defer { close(directory) }
        #expect(try !CopilotFileAccess.names(at: directory, limit: 256).limited)
        let registry = try CopilotFileAccess.openRegular(at: directory, name: ".registry", owner: getuid(), permissions: 0o600)
        defer { close(registry) }
        #expect(flock(registry, LOCK_EX | LOCK_NB) == 0)
        let stamp = try CopilotFileAccess.statEntry(at: directory, name: ".registry")
        #expect(throws: (any Error).self) { try MaestroClickChannel(root: root, window: UUID(), serving: true) }
        #expect(throws: (any Error).self) { try MaestroClickChannel.destination(root: root, workspace: fixtures.workspaceA) }
        #expect(try CopilotFileAccess.statEntry(at: directory, name: ".registry") == stamp)
        #expect(flock(registry, LOCK_UN) == 0)
        #expect(try MaestroClickChannel.destination(root: root, workspace: fixtures.workspaceA).0 == live.window)
    }

    @Test func connectedClickUsesTypedNavigationOnceAndReturnsResult() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = target
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let (processed, continuation) = AsyncStream<Void>.makeStream()
        let navigation = SidebarNavigation(timeout: { try await sidebarFrozenExpiry(0) },
                                           responseProcessed: { continuation.yield(()) })
        var calls: [SidebarNavigationTarget] = []
        navigation.update(topology: fixtures.topology(), connected: true, workspaceAllowed: true, surfaceAllowed: true) {
            calls.append($0)
        }
        let clicks = SidebarNotificationClicks(root: root, now: { date }, verify: { #expect($0 == target) })
        clicks.update(topology: fixtures.topology(), navigation: navigation)
        defer { clicks.stop(); continuation.finish() }
        let (window, lease) = try MaestroClickChannel.destination(root: root, workspace: target.workspaceId)
        let writer = try MaestroClickChannel(root: root, window: window, serving: false)
        let request = MaestroClickChannel.Request(id: UUID(), nonce: lease.nonce, target: target, createdAt: date)
        try writer.write(request, slot: "request")
        clicks.consume()
        clicks.consume()
        var iterator = processed.makeAsyncIterator()
        _ = await iterator.next()
        #expect(calls == [.surface(workspaceID: target.workspaceId, surfaceID: target.surfaceId)])
        let result = try #require(try writer.read(MaestroClickChannel.Response.self, slot: "result"))
        #expect(result.id == request.id && result.focused)
        #expect(try writer.read(MaestroClickChannel.Request.self, slot: "request") == nil)
        try writer.write(request, slot: "request")
        clicks.consume()
        #expect(try writer.read(MaestroClickChannel.Response.self, slot: "result")?.focused == false)
        #expect(calls.count == 1)
    }

    @Test(arguments: ["expired", "future", "nonce", "surface", "generation"])
    func staleRequestNeverNavigates(_ scenario: String) throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let navigation = SidebarNavigation(timeout: { try await sidebarFrozenExpiry(0) })
        var calls = 0
        navigation.update(topology: fixtures.topology(), connected: true, workspaceAllowed: true, surfaceAllowed: true) { _ in calls += 1 }
        let clicks = SidebarNotificationClicks(root: root, now: { date }, verify: { _ in
            if scenario == "generation" { throw CopilotFileError.changed }
        })
        clicks.update(topology: fixtures.topology(), navigation: navigation)
        defer { clicks.stop() }
        let (window, lease) = try MaestroClickChannel.destination(root: root, workspace: fixtures.workspaceA)
        let writer = try MaestroClickChannel(root: root, window: window, serving: false)
        var target = target
        if scenario == "surface" {
            target = .init(nodeId: target.nodeId, sessionId: target.sessionId, workspaceId: target.workspaceId,
                           surfaceId: UUID(), generation: 1)
        }
        let request = MaestroClickChannel.Request(
            id: UUID(), nonce: scenario == "nonce" ? UUID() : lease.nonce, target: target,
            createdAt: date.addingTimeInterval(scenario == "expired" ? -5 : scenario == "future" ? 1 : 0)
        )
        try writer.write(request, slot: "request")
        clicks.consume()
        let response = try #require(try writer.read(MaestroClickChannel.Response.self, slot: "result"))
        #expect(!response.focused && response.id == request.id)
        #expect(calls == 0)
    }

    @Test func disconnectedAndAmbiguousWindowsRefuseWithoutQueueing() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) { try MaestroClickChannel.destination(root: root, workspace: fixtures.workspaceA) }
        let first = try MaestroClickChannel(root: root, window: UUID(), serving: true)
        let second = try MaestroClickChannel(root: root, window: UUID(), serving: true)
        try first.publish(.init(nonce: UUID(), workspaces: [fixtures.workspaceA]))
        try second.publish(.init(nonce: UUID(), workspaces: [fixtures.workspaceA]))
        #expect(throws: (any Error).self) { try MaestroClickChannel.destination(root: root, workspace: fixtures.workspaceA) }
        #expect(throws: (any Error).self) { try MaestroClickChannel(root: root, window: first.window, serving: true) }
        #expect(try first.read(MaestroClickChannel.Request.self, slot: "request") == nil)
    }

    @Test func appToSidebarRoundTripUsesFileEventsAndStopsOnDisconnect() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = target
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let navigation = SidebarNavigation(timeout: { try await sidebarFrozenExpiry(0) })
        var calls = 0
        navigation.update(topology: fixtures.topology(), connected: true, workspaceAllowed: true, surfaceAllowed: true) { _ in calls += 1 }
        let clicks = SidebarNotificationClicks(root: root, now: { date }, verify: { _ in })
        clicks.update(topology: fixtures.topology(), navigation: navigation)
        let appTarget = CMUXMaestroPreview.MaestroNotificationTarget(
            nodeId: target.nodeId, sessionId: target.sessionId, workspaceId: target.workspaceId,
            surfaceId: target.surfaceId, generation: target.generation
        )
        let sender = MaestroNotificationClick(root: root, now: { date }, timeout: { try await sidebarFrozenExpiry(0) })
        try await sender.focus(appTarget)
        #expect(calls == 1)
        clicks.stop()
        await #expect(throws: (any Error).self) { try await sender.focus(appTarget) }
        #expect(calls == 1)
    }

    @Test func targetGenerationAndFreshSnapshotAreMandatory() {
        let target = target
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let node = SidebarOrchestrationNode(
            id: target.nodeId, runId: UUID(), parentId: nil, role: "coordinator", label: "Synthetic",
            workspaceId: target.workspaceId, surfaceId: target.surfaceId, generation: target.generation,
            phase: "turn-running", availability: "busy", copilotSessionId: target.sessionId,
            executionMode: .interactive, createdAt: date, updatedAt: date
        )
        let snapshot = SidebarOrchestrationSnapshot(version: 1, generatedAt: date, complete: true, omittedCount: 0, nodes: [node])
        #expect(SidebarNotificationTargetVerifier.matches(target, snapshot: snapshot, now: date))
        #expect(!SidebarNotificationTargetVerifier.matches(target, snapshot: snapshot, now: date.addingTimeInterval(61)))
        let replaced = MaestroNotificationTarget(nodeId: target.nodeId, sessionId: target.sessionId, workspaceId: target.workspaceId,
                                                surfaceId: target.surfaceId, generation: 2)
        #expect(!SidebarNotificationTargetVerifier.matches(replaced, snapshot: snapshot, now: date))
    }

    @Test func explicitClickDeadlineReturnsUnavailableAndRemovesRequest() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = target
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let lease = try MaestroClickChannel(root: root, window: UUID(), serving: true)
        try lease.publish(.init(nonce: UUID(), workspaces: [target.workspaceId]))
        let (started, ready) = AsyncStream<Void>.makeStream()
        let (deadline, fire) = AsyncStream<Void>.makeStream()
        defer { ready.finish(); fire.finish() }
        let sender = MaestroNotificationClick(root: root, now: { date }, timeout: {
            ready.yield(())
            for await _ in deadline { return }
            throw CancellationError()
        })
        let appTarget = CMUXMaestroPreview.MaestroNotificationTarget(
            nodeId: target.nodeId, sessionId: target.sessionId, workspaceId: target.workspaceId,
            surfaceId: target.surfaceId, generation: target.generation
        )
        let pending = Task { try await sender.focus(appTarget) }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        #expect(try lease.read(MaestroClickChannel.Request.self, slot: "request") != nil)
        fire.yield(())
        await #expect(throws: MaestroNotificationFailure.unavailable) { try await pending.value }
        #expect(try lease.read(MaestroClickChannel.Request.self, slot: "request") == nil)
        #expect(try lease.read(MaestroClickChannel.Response.self, slot: "result") == nil)
    }

    @Test func disconnectedBeforeDispatchCannotNavigate() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let navigation = SidebarNavigation(timeout: { try await sidebarFrozenExpiry(0) })
        var calls = 0
        navigation.update(topology: fixtures.topology(), connected: true, workspaceAllowed: true, surfaceAllowed: true) { _ in calls += 1 }
        let clicks = SidebarNotificationClicks(root: root, now: { date }, verify: { _ in })
        clicks.update(topology: fixtures.topology(), navigation: navigation)
        let (window, lease) = try MaestroClickChannel.destination(root: root, workspace: fixtures.workspaceA)
        let writer = try MaestroClickChannel(root: root, window: window, serving: false)
        let request = MaestroClickChannel.Request(id: UUID(), nonce: lease.nonce, target: target, createdAt: date)
        try writer.write(request, slot: "request")
        clicks.consume()
        navigation.disconnect()
        clicks.stop()
        let result = try #require(try writer.read(MaestroClickChannel.Response.self, slot: "result"))
        #expect(!result.focused)
        #expect(calls == 0)
    }

    @Test func replacementBetweenConsumeAndDispatchRefuses() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let (processed, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let navigation = SidebarNavigation(timeout: { try await sidebarFrozenExpiry(0) },
                                           responseProcessed: { continuation.yield(()) })
        var replaced = false
        var calls = 0
        navigation.update(topology: fixtures.topology(), connected: true, workspaceAllowed: true, surfaceAllowed: true) { _ in calls += 1 }
        let clicks = SidebarNotificationClicks(root: root, now: { date }, verify: { _ in
            if replaced { throw CopilotFileError.changed }
        })
        clicks.update(topology: fixtures.topology(), navigation: navigation)
        defer { clicks.stop() }
        let (window, lease) = try MaestroClickChannel.destination(root: root, workspace: fixtures.workspaceA)
        let writer = try MaestroClickChannel(root: root, window: window, serving: false)
        try writer.write(MaestroClickChannel.Request(id: UUID(), nonce: lease.nonce, target: target, createdAt: date), slot: "request")
        clicks.consume()
        replaced = true
        var iterator = processed.makeAsyncIterator()
        _ = await iterator.next()
        #expect(calls == 0)
        #expect(try writer.read(MaestroClickChannel.Response.self, slot: "result")?.focused == false)
    }

    @Test func realBindingReadRequiresLiveSoleCustodyAndExactSurface() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = target
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let session = root.appendingPathComponent(target.sessionId.uuidString.lowercased())
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
        let binding = root.appendingPathComponent(target.sessionId.uuidString.lowercased() + ".json")
        let record = CopilotIdentityRecord(
            sessionID: target.sessionId, surfaceID: target.surfaceId, launchWorkspaceID: target.workspaceId,
            ownerPID: 42, ownerStartSeconds: 1, ownerStartMicroseconds: 0, recordedAt: date
        )
        try CopilotIdentityJSON.encode(record).write(to: binding)
        #expect(chmod(binding.path, 0o600) == 0)
        let marker = session.appendingPathComponent("inuse.42.lock")
        try Data().write(to: marker)
        let node = SidebarOrchestrationNode(
            id: target.nodeId, runId: UUID(), parentId: nil, role: "coordinator", label: "Synthetic",
            workspaceId: target.workspaceId, surfaceId: target.surfaceId, generation: 1,
            phase: "turn-running", availability: "busy", copilotSessionId: target.sessionId,
            executionMode: .interactive, createdAt: date, updatedAt: date
        )
        let snapshot = SidebarOrchestrationSnapshot(version: 1, generatedAt: date, complete: true, omittedCount: 0, nodes: [node])
        let verifier = SidebarNotificationTargetVerifier(verifier: CopilotIdentityVerifier(lookup: { pid in
            .found(.init(pid: pid, parentPID: 1, uid: getuid(), startSeconds: 1, startMicroseconds: 0))
        }))
        try verifier.verify(target, snapshot: snapshot, bindings: root, sessions: root, now: date)
        let competing = session.appendingPathComponent("inuse.43.lock")
        try Data().write(to: competing)
        #expect(throws: (any Error).self) {
            try verifier.verify(target, snapshot: snapshot, bindings: root, sessions: root, now: date)
        }
        try FileManager.default.removeItem(at: competing)
        try FileManager.default.removeItem(at: marker)
        #expect(throws: (any Error).self) {
            try verifier.verify(target, snapshot: snapshot, bindings: root, sessions: root, now: date)
        }
    }
}
