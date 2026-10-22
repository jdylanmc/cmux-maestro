import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One animated Codex pet cell sequence. Reduce Motion shows a single still frame.
struct SidebarPetView: View {
    let store: SidebarPetStore
    let petID: String
    var session: UUID? = nil
    let state: SidebarPetState
    var width: CGFloat = 46
    var animated = true
    /// Transparent top band (fraction of cell height) excluded from layout; only empty pixels overflow.
    var topTrim: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var height: CGFloat { width * CGFloat(SidebarPetSheet.cellHeight) / CGFloat(SidebarPetSheet.cellWidth) }

    static func animates(_ animated: Bool, reduceMotion: Bool) -> Bool { animated && !reduceMotion }

    var body: some View {
        Group {
            if Self.animates(animated, reduceMotion: reduceMotion) {
                let frames = (0..<state.frameCount).compactMap {
                    store.frame(petID: petID, session: session, state: state, index: $0)
                }
                if frames.count == state.frameCount {
                    SidebarPetAnimation(frames: frames)
                } else {
                    cell(frames.first)
                }
            } else {
                cell(store.frame(petID: petID, session: session, state: state, index: 0))
            }
        }
        .frame(width: width, height: height)
        .frame(width: width, height: height * (1 - topTrim), alignment: .bottom)
    }

    @ViewBuilder private func cell(_ frame: CGImage?) -> some View {
        if let frame {
            Image(decorative: frame, scale: 1).resizable().interpolation(.high).scaledToFit()
        } else {
            Image(systemName: "questionmark.square.dashed").foregroundStyle(.secondary)
        }
    }
}

/// Footer pet sizing: grows with a user-sized footer, keeping the cell aspect ratio within the visible
/// body height and a 64pt box. Half the footer width is a hard cap that wins over the baseline floor.
enum SidebarFooterPetSize {
    static let baselineWidth: CGFloat = 38
    static let maximumWidthFraction: CGFloat = 0.5
    /// The full sprite cell fits this square, so width <= 64 * 192 / 208.
    static let maximumBox: CGFloat = 64
    static var aspect: CGFloat { CGFloat(SidebarPetSheet.cellHeight) / CGFloat(SidebarPetSheet.cellWidth) }

    /// `topInset` is the sheet's measured transparent top band (`SidebarPetStore.topInset`).
    static func width(bodyHeight: CGFloat, footerWidth: CGFloat, userSized: Bool, topInset: CGFloat) -> CGFloat {
        guard footerWidth > 0, footerWidth.isFinite else { return baselineWidth }
        let grown = userSized && bodyHeight.isFinite ? bodyHeight / height(forWidth: 1, topInset: topInset) : baselineWidth
        let boxed = min(grown, maximumBox, maximumBox / aspect)
        return min(max(baselineWidth, boxed), footerWidth * maximumWidthFraction).rounded(.down)
    }

    /// Laid-out footer pet height: the full cell height less the sheet's transparent top band.
    static func height(forWidth width: CGFloat, topInset: CGFloat) -> CGFloat {
        width * aspect * (1 - min(max(topInset, 0), SidebarPetSheet.maximumTopInset))
    }
}

/// The active/hovered agent's pet. Click to choose a different pet for this agent session.
struct SidebarPetButton: View {
    let store: SidebarPetStore
    let content: SidebarDetailContent
    var width: CGFloat = SidebarFooterPetSize.baselineWidth
    var topInset: CGFloat = 0
    @State private var showingPicker = false
    @State private var hovering = false
    @State private var captured = false

    var body: some View {
        let petID = store.resolvedID(session: content.petSessionID, agentChoice: content.petChoice)
        let state = SidebarPetState.resolve(visual: content.visual, needsInput: content.needsInput)
        let descriptor = store.descriptor(petID, session: content.petSessionID)
        let name = descriptor?.displayName ?? "Maestro"
        // An agent-made pet in use can be captured into the shared collection.
        let capturable = descriptor?.source == .session && content.petSessionID != nil
        let hidden = content.petSessionID.map(store.isHidden) ?? false
        Button { showingPicker = true } label: {
            if hidden {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                    .frame(width: width, height: SidebarFooterPetSize.height(forWidth: width, topInset: topInset))
            } else {
                SidebarPetView(store: store, petID: petID, session: content.petSessionID, state: state, width: width,
                               topTrim: topInset)
            }
        }
        .buttonStyle(.plain)
        .help(hidden ? "Choose pet" : "\(name) · \(state.title). Click to choose a pet.")
        .accessibilityLabel(hidden ? "Pet hidden" : "Pet \(name), \(state.title)")
        .accessibilityHint("Opens the pet picker")
        .accessibilityIdentifier("sidebar-pet-button")
        .overlay(alignment: .center) {
            if !hidden, (capturable && hovering) || captured, let session = content.petSessionID {
                Button {
                    if store.saveToRepository(petID, session: session) != nil {
                        captured = true
                        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); captured = false }
                    }
                } label: {
                    Image(systemName: captured ? "checkmark.circle.fill" : "plus.circle.fill")
                        .font(.system(size: 20, weight: .bold)).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, captured ? SidebarTone.green.color : SidebarQuestionGlow.lightBlue)
                        .background(Circle().fill(Color.black.opacity(0.35)).padding(1))
                }
                .buttonStyle(.plain)
                .help("Save \(name) to my pets so every agent can use it.")
                .accessibilityLabel("Save \(name) to my pets")
                .accessibilityIdentifier("sidebar-pet-capture")
            }
        }
        // Hover is tracked on the whole pet including the badge, or the badge would steal it and flicker.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .popover(isPresented: $showingPicker, arrowEdge: .trailing) {
            SidebarPetPicker(store: store, sessionID: content.petSessionID, agentChoice: content.petChoice, state: state) {
                showingPicker = false
            }
        }
    }
}

struct SidebarPetPicker: View {
    let store: SidebarPetStore
    let sessionID: UUID?
    let agentChoice: String?
    let state: SidebarPetState
    let close: () -> Void
    @State private var refreshToken = 0
    @State private var pendingRemoval: SidebarPetDescriptor?

    var body: some View {
        let current = store.resolvedID(session: sessionID, agentChoice: agentChoice)
        let collected = store.installed.filter { $0.source == .uploaded }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Choose a pet").font(.headline)
                    Text(collected == 1 ? "1 pet collected" : "\(collected) pets collected")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                    ForEach(store.available(for: sessionID)) { pet in
                        SidebarPetCell(
                            store: store, pet: pet, session: sessionID, selected: current == pet.id, state: state,
                            choose: { if let sessionID { store.choose(pet.id, session: sessionID) } },
                            save: pet.source == .session && sessionID != nil
                                ? { if let sessionID { store.saveToRepository(pet.id, session: sessionID); refreshToken += 1 } } : nil,
                            remove: pet.source == .uploaded ? { pendingRemoval = pet } : nil
                        )
                        .contextMenu { cellMenu(pet) }
                    }
                }
                .padding(2)
            }
            .frame(height: 210)
            HStack {
                Button("Upload pet…") { upload() }
                    .help("Choose a Codex pet folder or spritesheet.")
                    .accessibilityIdentifier("sidebar-pet-upload")
                if let sessionID, let pet = store.descriptor(current, session: sessionID), pet.source == .session {
                    Button("Save to my pets") { store.saveToRepository(pet.id, session: sessionID); refreshToken += 1 }
                        .help("Save this pet for all agents.")
                        .accessibilityIdentifier("sidebar-pet-save")
                }
            }
            HStack {
                Button("Reset to default") { if let sessionID { store.resetToDefault(session: sessionID) } }
                    .disabled(sessionID.map(store.isDefaultChoice) ?? true)
                    .accessibilityIdentifier("sidebar-pet-reset-default")
                Button("Reset to agent's pet") { if let sessionID { store.clearChoice(session: sessionID) } }
                    .disabled(sessionID.map { !store.hasOverride(session: $0) } ?? true)
                    .accessibilityIdentifier("sidebar-pet-reset-agent")
                if let sessionID {
                    let hidden = store.isHidden(session: sessionID)
                    Button(hidden ? "Show pet" : "Hide pet") { store.setHidden(!hidden, session: sessionID) }
                        .accessibilityIdentifier("sidebar-pet-visibility")
                }
            }
            .controlSize(.small)
            if let notice = store.notice {
                Text(notice).font(.caption).foregroundStyle(SidebarTone.attention.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Link("Codex Pets gallery", destination: SidebarPetStore.galleryURL)
                Link("Create a pet", destination: SidebarPetStore.generatorURL)
            }
            .font(.caption2)
        }
        .padding(14)
        .frame(width: 320)
        .id(refreshToken)
        .onAppear { store.refresh() }
        .confirmationDialog(
            pendingRemoval.map { "Remove \($0.displayName) from my pets?" } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let pet = pendingRemoval { store.removeUpload(pet.id); refreshToken += 1 }
                pendingRemoval = nil
            }
            Button("Keep", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Agents using it fall back to their own pet or Maestro. You can upload it again later.")
        }
    }

    @ViewBuilder private func cellMenu(_ pet: SidebarPetDescriptor) -> some View {
        if pet.source == .session, let sessionID {
            Button("Save to my pets") { store.saveToRepository(pet.id, session: sessionID); refreshToken += 1 }
        }
        if pet.source == .uploaded {
            Button("Remove from my pets…", role: .destructive) { pendingRemoval = pet }
        }
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder, .png, .webP]
        panel.prompt = "Upload"
        panel.message = "Choose a Codex pet folder or a PNG/WebP spritesheet (8 columns × 9+ rows; standard 1536×1872)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let id = store.upload(from: url), let sessionID { store.choose(id, session: sessionID) }
        refreshToken += 1
    }
}

private struct SidebarPetCell: View {
    let store: SidebarPetStore
    let pet: SidebarPetDescriptor
    let session: UUID?
    let selected: Bool
    let state: SidebarPetState
    let choose: () -> Void
    var save: (() -> Void)? = nil
    var remove: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: choose) { content }
                .buttonStyle(.plain)
                .disabled(session == nil)
                .accessibilityLabel("\(pet.displayName)\(selected ? ", selected" : "")")
            if hovering {
                if let save {
                    cornerButton("plus.circle.fill", SidebarQuestionGlow.lightBlue, "Save \(pet.displayName) to my pets", save)
                } else if let remove {
                    cornerButton("xmark.circle.fill", SidebarTone.red.color, "Remove \(pet.displayName) from my pets", remove)
                }
            }
        }
        .onHover { hovering = $0 }
    }

    private func cornerButton(_ symbol: String, _ tint: Color, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15)).symbolRenderingMode(.palette)
                .foregroundStyle(.white, tint)
        }
        .buttonStyle(.plain)
        .padding(2)
        .help(label)
        .accessibilityLabel(label)
    }

    private var content: some View {
        VStack(spacing: 2) {
            SidebarPetView(store: store, petID: pet.id, session: session, state: selected ? state : .idle, width: 56)
            Text(pet.displayName).font(.caption2).lineLimit(1).truncationMode(.tail)
            if pet.source != .bundled {
                Text(pet.source == .session ? "agent-made · not saved" : "collected")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? SidebarQuestionGlow.lightBlue.opacity(0.18) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(selected ? SidebarQuestionGlow.lightBlue : Color.secondary.opacity(0.25), lineWidth: 1))
    }
}

private struct SidebarPetStoreKey: EnvironmentKey {
    static let defaultValue: SidebarPetStore? = nil
}

extension EnvironmentValues {
    var sidebarPetStore: SidebarPetStore? {
        get { self[SidebarPetStoreKey.self] }
        set { self[SidebarPetStoreKey.self] = newValue }
    }
}

/// The exact agent session whose pet a hover card shows, independent of the active/pinned agent.
struct SidebarHoverPet: Equatable {
    let session: UUID
    var choice: String? = nil
    var state: SidebarPetState = .idle
}

/// A hover card's pet: the hovered session's own preference, including its hidden state.
struct SidebarHoverPetView: View {
    let store: SidebarPetStore
    let pet: SidebarHoverPet

    var body: some View {
        if let id = store.visibleID(session: pet.session, agentChoice: pet.choice) {
            let name = store.descriptor(id, session: pet.session)?.displayName ?? "Maestro"
            SidebarPetView(store: store, petID: id, session: pet.session, state: pet.state, width: 36,
                           topTrim: store.topInset(petID: id, session: pet.session))
                .accessibilityElement()
                .accessibilityLabel("Pet \(name), \(pet.state.title)")
                .accessibilityIdentifier("hover-pet")
        }
    }
}

/// Opens the pet picker for one exact agent session from a row action.
private struct SidebarRowPetPicker: ViewModifier {
    @Binding var session: UUID?
    let agentChoice: String?
    @Environment(\.sidebarPetStore) private var store

    func body(content: Content) -> some View {
        content.popover(isPresented: Binding(get: { session != nil && store != nil },
                                             set: { if !$0 { session = nil } }), arrowEdge: .trailing) {
            if let store, let session {
                SidebarPetPicker(store: store, sessionID: session, agentChoice: agentChoice, state: .idle) {
                    self.session = nil
                }
            }
        }
    }
}

extension View {
    func sidebarPetPicker(session: Binding<UUID?>, agentChoice: String?) -> some View {
        modifier(SidebarRowPetPicker(session: session, agentChoice: agentChoice))
    }
}
