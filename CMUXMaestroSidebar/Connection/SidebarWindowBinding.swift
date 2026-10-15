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
    private let preferences: SidebarPreferences
    private var observation: CmuxSidebarSceneObservation?
    private weak var scene: CmuxSidebarScene?
    private var hasBound = false
    private var lastConnection: CmuxSidebarConnectionID?
    private var lastSnapshot: CmuxSidebarSnapshot?

    init(preferences: SidebarPreferences, model: SidebarConnectionModel? = nil) {
        self.preferences = preferences
        self.model = model ?? SidebarConnectionModel()
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

    func apply(_ state: CmuxSidebarSceneState) {
        switch state {
        case .waitingForHost:
            model.connectionStatusDidChange(.waitingForHost)
        case .unpaired:
            lastConnection = nil
            lastSnapshot = nil
            model.showUnpaired()
        case .bound(let connection, let status, let context):
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
            .onAppear { binding.bind(to: scene) }
            .onChange(of: scene.map(ObjectIdentifier.init)) { _, _ in binding.bind(to: scene) }
    }
}
