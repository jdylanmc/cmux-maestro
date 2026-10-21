@_spi(CmuxHostTransport) @_spi(CmuxExtensionTransport) import CmuxExtensionKit
import Foundation
import Testing
@testable import CMUXMaestroPreview

/// Several CMUX windows share one extension process (ADR 0023). These tests drive the real
/// patched SDK scene over real in-process XPC connections, one synthetic host per window.
@MainActor
@Suite
struct SidebarMultiWindowTests {
    /// ExtensionKit evaluates the scene per host view: one CmuxSidebarScene per window.
    @Test func separateScenesKeepEachWindowsOwnHierarchyActionsAndLifetime() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let (sceneA, sceneB) = (Self.scene(), Self.scene())
        let (bindingA, bindingB) = (SidebarWindowBinding(preferences: preferences),
                                    SidebarWindowBinding(preferences: preferences))
        bindingA.bind(to: sceneA)
        bindingB.bind(to: sceneB)
        sceneA.viewDidAppear(UUID())
        sceneB.viewDidAppear(UUID())

        let windowA = try SyntheticCmuxWindow(scene: sceneA, title: "Alpha")
        defer { windowA.close() }
        windowA.send(sequence: 1)
        await sidebarEventually { bindingA.model.hierarchy.workspaces.map(\.id) == [windowA.workspaceID] }

        let windowB = try SyntheticCmuxWindow(scene: sceneB, title: "Beta")
        windowB.send(sequence: 1)
        await sidebarEventually { bindingB.model.hierarchy.workspaces.map(\.id) == [windowB.workspaceID] }
        windowA.send(sequence: 2)
        windowB.send(sequence: 2)
        await sidebarEventually {
            bindingA.model.hierarchy.sequence == 2 && bindingB.model.hierarchy.sequence == 2
        }

        #expect(bindingA.model.hierarchy.workspaces.map(\.id) == [windowA.workspaceID],
                "A new window's connection must not replace an existing window's data")
        #expect(bindingB.model.hierarchy.workspaces.map(\.id) == [windowB.workspaceID])
        #expect(bindingA.model.hierarchy.windowID == windowA.windowID)
        #expect(bindingB.model.hierarchy.windowID == windowB.windowID)
        #expect(!windowA.wasInvalidated, "Accepting window B must not invalidate window A")

        bindingA.model.navigation.select(.workspace(windowA.workspaceID))
        await sidebarEventually { windowA.selectedWorkspaces == [windowA.workspaceID] }
        #expect(windowA.selectedWorkspaces == [windowA.workspaceID])
        #expect(windowB.selectedWorkspaces.isEmpty, "Window A's actions target only window A's connection")

        windowB.close()
        await sidebarEventually { if case .waitingForHost = sceneB.state { true } else { false } }
        windowA.send(sequence: 3)
        await sidebarEventually { bindingA.model.hierarchy.sequence == 3 }
        #expect(bindingA.model.hierarchy.workspaces.map(\.id) == [windowA.workspaceID],
                "Closing one window leaves the other window's sidebar correct")
        #expect(bindingA.model.state == .connected(workspaceCount: 1, surfaceCount: 0))
    }

    /// ExtensionKit shares one scene across windows: no view can be paired exactly, so none
    /// shows host data until only one window remains.
    @Test func sharedSceneNeverShowsAnotherWindowsDataAndRecoversWhenOneWindowRemains() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let scene = Self.scene()
        let (bindingA, bindingB) = (SidebarWindowBinding(preferences: preferences),
                                    SidebarWindowBinding(preferences: preferences))
        let (viewA, viewB) = (UUID(), UUID())
        bindingA.bind(to: scene)
        scene.viewDidAppear(viewA)

        let windowA = try SyntheticCmuxWindow(scene: scene, title: "Alpha")
        defer { windowA.close() }
        windowA.send(sequence: 1)
        await sidebarEventually { bindingA.model.hierarchy.workspaces.map(\.id) == [windowA.workspaceID] }

        // Window B's view appears before its connection: window A's data must vanish, not leak into B.
        bindingB.bind(to: scene)
        scene.viewDidAppear(viewB)
        #expect(bindingA.model.state == .unpaired && bindingB.model.state == .unpaired)
        #expect(bindingA.model.hierarchy.workspaces.isEmpty && bindingB.model.hierarchy.workspaces.isEmpty)

        // Each snapshot publishes context and status in one MainActor turn.
        // Connection acceptance alone does not prove either snapshot arrived.
        var publications = -1
        var disclosedWhileUnpaired = false
        let observation = scene.observe { state in
            publications += 1
            if case .unpaired = state {} else { disclosedWhileUnpaired = true }
        }
        defer { observation.cancel() }
        let windowB = try SyntheticCmuxWindow(scene: scene, title: "Beta")
        defer { windowB.close() }
        windowB.send(sequence: 5)
        windowA.send(sequence: 6)
        await sidebarEventually { publications >= 4 }
        #expect(!disclosedWhileUnpaired, "Delivered snapshots must not disclose either window")
        observation.cancel()
        for binding in [bindingA, bindingB] {
            #expect(binding.model.state == .unpaired)
            #expect(binding.model.hierarchy.workspaces.isEmpty, "Unpaired views show no window's data")
            #expect(binding.model.openWorkspaceAtPath == nil)
        }
        #expect(!windowA.wasInvalidated, "A second connection must not invalidate the first")

        windowB.close()
        scene.viewDidDisappear(viewB)
        // Preserve the regression's update-during-teardown interleaving.
        windowA.send(sequence: 7)
        await sidebarEventually {
            if case .bound(_, _, let context) = scene.state {
                return context?.snapshot.windowID == windowA.windowID
            }
            return false
        }
        #expect(!windowA.wasInvalidated)
        await sidebarEventually { bindingA.model.hierarchy.sequence == 7 }
        #expect(bindingA.model.hierarchy.workspaces.map(\.id) == [windowA.workspaceID])
        #expect(bindingA.model.hierarchy.windowID == windowA.windowID)
    }

    /// A second window's connection unpairs the shared scene before any snapshot or view from it.
    @Test func secondConnectionUnpairsBeforeItsFirstSnapshot() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let scene = Self.scene()
        let binding = SidebarWindowBinding(preferences: fixture.preferences())
        binding.bind(to: scene)
        scene.viewDidAppear(UUID())
        let windowA = try SyntheticCmuxWindow(scene: scene, title: "Alpha")
        defer { windowA.close() }
        windowA.send(sequence: 1)
        await sidebarEventually { binding.model.hierarchy.workspaces.map(\.id) == [windowA.workspaceID] }

        let windowB = try SyntheticCmuxWindow(scene: scene, title: "Beta")
        defer { windowB.close() }
        windowB.ping()
        await sidebarEventually { binding.model.state == .unpaired }
        #expect(binding.model.hierarchy.workspaces.isEmpty)
    }

    @Test func viewWithoutSceneShowsNoWindowData() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let binding = SidebarWindowBinding(preferences: fixture.preferences())
        binding.bind(to: nil)
        #expect(binding.model.state == .unpaired)
        #expect(binding.model.hierarchy.workspaces.isEmpty)
    }

    @Test func rebindingToADifferentConnectionDropsThePreviousConnectionsFacts() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let binding = SidebarWindowBinding(preferences: fixture.preferences())
        let first = UUID(), second = UUID()
        binding.apply(.bound(connection: .init(rawValue: 1), status: .connected,
                             context: Self.context(sequence: 9, workspace: first)))
        #expect(binding.model.hierarchy.workspaces.map(\.id) == [first])
        binding.apply(.bound(connection: .init(rawValue: 2), status: .waitingForHost, context: nil))
        #expect(binding.model.hierarchy.workspaces.isEmpty, "A different connection may be a different window")
        binding.apply(.bound(connection: .init(rawValue: 2), status: .connected,
                             context: Self.context(sequence: 1, workspace: second)))
        #expect(binding.model.hierarchy.workspaces.map(\.id) == [second],
                "The new connection's lower sequence is not rejected by the old one's ordering")
    }

    @Test func beatLivenessIsKeptPerWindowAndPanelOpensOnlyWhereRequested() {
        let stores = SidebarStoreFixture()
        defer { stores.cleanup() }
        let beats = stores.beats
        let (modelA, modelB) = (SidebarConnectionModel(), SidebarConnectionModel())
        let (a, b) = (ObjectIdentifier(modelA), ObjectIdentifier(modelB))
        let (inA, inB) = (UUID(), UUID())
        for id in [inA, inB] {
            #expect(beats.perform { _ = try $0.create(session: id, cron: "0 9 * * *", prompt: "Synthetic") } == nil)
        }
        beats.updateLiveness(Self.tree(alive: inA), from: a)
        beats.updateLiveness(Self.tree(alive: inB), from: b)
        #expect(beats.indicators.state(for: inA) == .lit && beats.indicators.state(for: inB) == .lit,
                "Window B's tree must not overwrite window A's liveness")
        beats.removeLiveness(from: b)
        #expect(beats.indicators.state(for: inA) == .lit && beats.indicators.state(for: inB) == .dim)

        beats.present(scope: nil, from: a)
        #expect(beats.isPresented(in: a) && !beats.isPresented(in: b))
        beats.dismiss(from: b)
        #expect(beats.isPresented(in: a), "Another window cannot close this window's panel")
        beats.dismiss(from: a)
        #expect(!beats.isPresented(in: a))
        withExtendedLifetime((modelA, modelB)) {}
    }

    private static func tree(alive id: UUID) -> SidebarCopilotTree {
        let f = SidebarTreeFixtures()
        let session = SidebarCopilotSession(
            id: id, workspaceID: f.workspaceA, surfaceID: f.surfaceA, liveness: .alive, state: .idle, model: nil,
            observedAt: Date(), nodes: [], childrenComplete: true, treeDegraded: false,
            omittedChildrenCount: 0, omittedActiveChildrenCount: 0
        )
        return SidebarCopilotTree(availability: .ready, sessions: [session], issues: [], generatedAt: Date())
    }

    private static func scene() -> CmuxSidebarScene {
        CmuxSidebarScene(manifest: CmuxExtensionManifest(
            id: "com.example.multiwindow", displayName: "Multi-window test",
            readScopes: [.workspaceMetadata], actionScopes: [.selectWorkspace]
        ))
    }

    private static func context(sequence: UInt64, workspace: UUID) -> CmuxSidebarContext {
        CmuxSidebarContext(
            snapshot: CmuxSidebarSnapshot(
                sequence: sequence, windowID: UUID(), selectedWorkspaceID: nil, grantedReadScopes: [.workspaceMetadata],
                workspaces: [CmuxSidebarWorkspace(id: workspace, title: "Synthetic")]
            ),
            host: CmuxSidebarHost(performAction: { _, _ in })
        )
    }
}

/// One synthetic CMUX window: a host-side XPC connection to an extension-side listener that
/// hands its accepted connection to the scene, as ExtensionKit's `onConnection` does.
@MainActor
private final class SyntheticCmuxWindow {
    let windowID = UUID()
    let workspaceID = UUID()
    let title: String
    private let extensionSide: ExtensionSideListener
    private let host: SyntheticHostObject
    private let connection: NSXPCConnection

    var wasInvalidated: Bool { host.invalidated }
    var isAccepted: Bool { extensionSide.accepted }
    var selectedWorkspaces: [UUID] { host.selectedWorkspaces }

    init(scene: CmuxSidebarScene, title: String) throws {
        self.title = title
        extensionSide = ExtensionSideListener(scene: scene)
        host = SyntheticHostObject()
        connection = NSXPCConnection(listenerEndpoint: extensionSide.listener.endpoint)
        connection.exportedInterface = NSXPCInterface(with: CMUXSidebarHostXPC.self)
        connection.exportedObject = host
        connection.remoteObjectInterface = NSXPCInterface(with: CMUXSidebarExtensionXPC.self)
        connection.invalidationHandler = { [host] in host.markInvalidated() }
        connection.resume()
    }

    func send(sequence: UInt64) {
        let snapshot = CmuxSidebarSnapshot(
            sequence: sequence, windowID: windowID, selectedWorkspaceID: nil,
            grantedReadScopes: [.workspaceMetadata], grantedActionScopes: [.selectWorkspace],
            workspaces: [CmuxSidebarWorkspace(id: workspaceID, title: title)]
        )
        guard let payload = try? CmuxSidebarXPCCodec.encodeSnapshot(snapshot) else { return }
        (connection.remoteObjectProxy as? CMUXSidebarExtensionXPC)?.sidebarSnapshotDidChange(payload)
    }

    /// Opens the connection without a snapshot, as a host does while it requests the manifest.
    func ping() {
        (connection.remoteObjectProxy as? CMUXSidebarExtensionXPC)?.requestExtensionManifest? { _, _ in }
    }

    func close() {
        connection.invalidate()
        extensionSide.listener.invalidate()
    }
}

private final class ExtensionSideListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    private let scene: CmuxSidebarScene
    private let lock = NSLock()
    private var didAccept = false
    var accepted: Bool { lock.withLock { didAccept } }

    init(scene: CmuxSidebarScene) {
        self.scene = scene
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let accepted = scene.accept(connection)
        lock.withLock { didAccept = accepted }
        return accepted
    }
}

private final class SyntheticHostObject: NSObject, CMUXSidebarHostXPC, @unchecked Sendable {
    private let lock = NSLock()
    private var selected: [UUID] = []
    private var isInvalidated = false

    var selectedWorkspaces: [UUID] { lock.withLock { selected } }
    var invalidated: Bool { lock.withLock { isInvalidated } }

    func markInvalidated() { lock.withLock { isInvalidated = true } }

    func requestSidebarSnapshot(reply: @escaping (NSData?, NSString?) -> Void) {
        reply(nil, "unsupported" as NSString)
    }

    func performSidebarAction(_ payload: NSData, reply: @escaping (NSData?, NSString?) -> Void) {
        if case .selectWorkspace(let id)? = try? CmuxSidebarXPCCodec.decodeAction(payload) {
            lock.withLock { selected.append(id) }
        }
        reply(try? CmuxSidebarXPCCodec.encodeActionResult(.accepted), nil)
    }
}
