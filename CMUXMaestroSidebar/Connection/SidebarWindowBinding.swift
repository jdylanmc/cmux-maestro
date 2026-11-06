import AppKit
import CmuxExtensionKit
import Combine
import SwiftUI

/// Binds one hosted sidebar view's own model to its own CMUX window's sidebar scene (ADR 0023).
///
/// The extension process is shared by every CMUX window, so window-scoped state lives
/// here, one instance per hosted view. Process-wide stores (preferences, Beats, pets)
/// are injected and stay shared.
@MainActor
final class SidebarWindowBinding: ObservableObject {
    let model: SidebarConnectionModel
    let focusRefresh: SidebarHostFocusRefresh
    private let preferences: SidebarPreferences
    private var observation: CmuxSidebarSceneObservation?
    private weak var scene: CmuxSidebarScene?
    private var hasBound = false
    private var lastConnection: CmuxSidebarConnectionID?
    private var lastSnapshot: CmuxSidebarSnapshot?

    init(
        preferences: SidebarPreferences, model: SidebarConnectionModel? = nil,
        focusRefresh: SidebarHostFocusRefresh? = nil
    ) {
        self.preferences = preferences
        self.focusRefresh = focusRefresh ?? SidebarHostFocusRefresh()
        self.model = model ?? SidebarConnectionModel(copilot: SidebarCopilotPolling(
            tailWindowMiB: { preferences.eventTailWindowMiB }
        ))
        if model == nil, let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            self.model.notificationClicks = SidebarNotificationClicks(
                root: support.appendingPathComponent("CMUXMaestroPreview/NotificationClicks", isDirectory: true)
            )
        }
    }

    /// Follows `scene`; without one this view has no exact window and shows nothing.
    func bind(to scene: CmuxSidebarScene?) {
        if hasBound, scene === self.scene { return }
        hasBound = true
        observation?.cancel()
        observation = nil
        self.scene = scene
        guard let scene else {
            apply(.unpaired)
            return
        }
        observation = scene.observe { [weak self] state in
            self?.apply(state)
        }
    }

    /// This window's sidebar view is mounted; only then may it pull host snapshots.
    func setVisible(_ visible: Bool) {
        focusRefresh.setVisible(visible)
    }

    func apply(_ state: CmuxSidebarSceneState) {
        switch state {
        case .waitingForHost:
            focusRefresh.setHost(nil)
            model.connectionStatusDidChange(.waitingForHost)
        case .unpaired:
            focusRefresh.setHost(nil)
            lastConnection = nil
            lastSnapshot = nil
            model.showUnpaired()
        case .bound(let connection, let status, let context):
            // Any publication from this window's own connection answers an outstanding pull.
            focusRefresh.didReceive()
            focusRefresh.setHost(status == .connected ? context?.host : nil)
            if lastConnection != connection {
                // A different connection may belong to a different window; drop the old one's facts.
                if lastConnection != nil { model.resetWindow() }
                lastConnection = connection
                lastSnapshot = nil
            }
            if let context, context.snapshot != lastSnapshot || !isConnected {
                lastSnapshot = context.snapshot
                model.update(context: context)
                model.setReorderBackend(SidebarReorderBackends.make(
                    grantedActionScopes: context.grantedActionScopes, host: context.host, store: preferences
                ))
            }
            model.connectionStatusDidChange(status)
        }
    }

    private var isConnected: Bool {
        if case .connected = model.state { return true }
        return false
    }
}

/// Root of one hosted sidebar: one binding per view, bound to the scene CMUX injected.
struct SidebarWindowView: View {
    @Environment(\.cmuxSidebarScene) private var scene
    @StateObject private var binding: SidebarWindowBinding
    private let preferences: SidebarPreferences
    private let beats: SidebarBeatsController
    private let pets: SidebarPetStore

    init(preferences: SidebarPreferences, beats: SidebarBeatsController, pets: SidebarPetStore) {
        _binding = StateObject(wrappedValue: SidebarWindowBinding(preferences: preferences))
        self.preferences = preferences
        self.beats = beats
        self.pets = pets
    }

    var body: some View {
        SidebarView(model: binding.model, preferences: preferences, beats: beats, pets: pets)
            .modifier(SidebarWindowLifecycle(binding: binding, scene: scene))
    }
}

/// Binds on mount and gates refreshing on the hosted view being mounted. SwiftUI's
/// appear/disappear track mounting, not occlusion or minimising.
struct SidebarWindowLifecycle: ViewModifier {
    let binding: SidebarWindowBinding
    let scene: CmuxSidebarScene?

    func body(content: Content) -> some View {
        content
            .onAppear {
                binding.bind(to: scene)
                binding.setVisible(true)
            }
            .onDisappear { binding.setVisible(false) }
            .onChange(of: scene.map(ObjectIdentifier.init)) { _, _ in binding.bind(to: scene) }
    }
}

/// Pulls this window's own CMUX snapshot on a bounded cadence (ADR 0032).
///
/// CMUX pushes a snapshot when titles, panels, paths or metadata change, but not when only
/// tab, pane or workspace focus changes. Pulling keeps the focus bar and Active window footer
/// on the host's focused surface. It runs only while this window's sidebar view is mounted, its
/// connection is connected and CMUX is the active app. At most one request is outstanding, also
/// across a stop and restart; it is abandoned only after `unansweredTickLimit - 1` skipped ticks
/// or when the connection is lost. It only reads: it never moves CMUX focus, sends input or marks
/// anything read.
@MainActor
final class SidebarHostFocusRefresh {
    typealias Pause = @MainActor () async throws -> Void

    /// Average added focus latency is half this; see ADR 0032 for the measured cost.
    static let interval: Duration = .milliseconds(500)
    /// The tick that re-sends an unanswered request; the ticks before it are skipped.
    static let unansweredTickLimit = 4

    private let pause: Pause
    private var activity: SidebarHostActivity?
    private var visible = false
    private var active = false
    private var host: CmuxSidebarHost?
    private var worker: Task<Void, Never>?
    private var inFlight = false
    private var skippedTicks = 0

    /// `hostActivity` nil leaves activity to `setActive` alone.
    init(
        pause: @escaping Pause = { try await Task.sleep(for: SidebarHostFocusRefresh.interval, tolerance: .milliseconds(100)) },
        hostActivity: SidebarHostActivity.Source? = .live
    ) {
        self.pause = pause
        guard let hostActivity else { return }
        let activity = SidebarHostActivity(source: hostActivity) { [weak self] in self?.setActive($0) }
        self.activity = activity
        active = activity.isHostActive
    }

    deinit { worker?.cancel() }

    var isRunning: Bool { worker != nil }
    var isActive: Bool { active }
    /// A request was sent and neither answered nor abandoned.
    var isAwaitingReply: Bool { inFlight }

    func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        reconcile()
    }

    func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        reconcile()
    }

    /// The connected host of this window's own connection, or nil while not connected.
    func setHost(_ host: CmuxSidebarHost?) {
        let wasConnected = self.host != nil
        self.host = host
        // A lost connection never answers its outstanding request.
        if host == nil { didReceive() }
        if wasConnected != (host != nil) { reconcile() }
    }

    func didReceive() {
        inFlight = false
        skippedTicks = 0
    }

    private func reconcile() {
        guard visible, active, host != nil else {
            // An outstanding request stays outstanding, so a quick restart cannot overlap it.
            worker?.cancel()
            worker = nil
            return
        }
        guard worker == nil else { return }
        // The first tick runs at once: becoming visible, active or connected refreshes immediately.
        worker = Task { [weak self, pause] in
            while !Task.isCancelled {
                guard self?.tick() != nil else { return }
                do { try await pause() } catch { return }
            }
        }
    }

    private func tick() {
        guard visible, active, let host else { return }
        if inFlight {
            skippedTicks += 1
            guard skippedTicks >= Self.unansweredTickLimit else { return }
        }
        inFlight = true
        skippedTicks = 0
        host.refresh()
    }
}

/// Whether CMUX is the active app. A power gate for refreshing only; never identity,
/// window pairing or focus evidence (ADR 0002, ADR 0023).
@MainActor
final class SidebarHostActivity {
    static let hostBundleIdentifier = "com.cmuxterm.app"

    /// Where activation is read from. Production uses `live`; tests inject their own.
    struct Source {
        var frontmostBundleIdentifier: @MainActor () -> String?
        var isAppActive: @MainActor () -> Bool
        var changes: [(center: NotificationCenter, name: Notification.Name)]

        static var live: Source {
            let local = NotificationCenter.default
            return Source(
                frontmostBundleIdentifier: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
                isAppActive: { NSApp?.isActive == true },
                changes: [
                    (NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification),
                    (local, NSApplication.didBecomeActiveNotification),
                    (local, NSApplication.didResignActiveNotification),
                ]
            )
        }
    }

    private let source: Source
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(source: Source = .live, changed: @escaping @MainActor (Bool) -> Void) {
        self.source = source
        for (center, name) in source.changes {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    changed(self.isHostActive)
                }
            }))
        }
    }

    deinit {
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    /// The hosted sidebar's process may or may not mirror CMUX activation, so either counts.
    var isHostActive: Bool {
        source.isAppActive() || Self.isHost(source.frontmostBundleIdentifier())
    }

    static func isHost(_ bundleIdentifier: String?) -> Bool {
        guard let id = bundleIdentifier else { return false }
        return id == hostBundleIdentifier || id.hasPrefix(hostBundleIdentifier + ".")
    }
}
