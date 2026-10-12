import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One animated Codex pet cell sequence. Reduce Motion shows a single still frame.
struct SidebarPetView: View {
    let petID: String
    var session: UUID? = nil
    let state: SidebarPetState
    var width: CGFloat = 46
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var height: CGFloat { width * CGFloat(SidebarPetSheet.cellHeight) / CGFloat(SidebarPetSheet.cellWidth) }

    var body: some View {
        let store = SidebarPetStore.shared
        Group {
            if animated && !reduceMotion {
                TimelineView(.periodic(from: .now, by: 1.0 / 7.0)) { context in
                    cell(store.frame(petID: petID, session: session, state: state, index: Int(context.date.timeIntervalSinceReferenceDate * 7)))
                }
            } else {
                cell(store.frame(petID: petID, session: session, state: state, index: 0))
            }
        }
        .frame(width: width, height: height)
    }

    @ViewBuilder private func cell(_ frame: CGImage?) -> some View {
        if let frame {
            Image(decorative: frame, scale: 1).resizable().interpolation(.high).scaledToFit()
        } else {
            Image(systemName: "questionmark.square.dashed").foregroundStyle(.secondary)
        }
    }
}

/// The active/hovered agent's pet. Click to choose a different pet for this agent session.
struct SidebarPetButton: View {
    let content: SidebarDetailContent
    @State private var showingPicker = false
    @State private var hovering = false
    @State private var captured = false

    var body: some View {
        let store = SidebarPetStore.shared
        let petID = store.resolvedID(session: content.petSessionID, agentChoice: content.petChoice)
        let state = SidebarPetState.resolve(visual: content.visual, needsInput: content.needsInput)
        let descriptor = store.descriptor(petID, session: content.petSessionID)
        let name = descriptor?.displayName ?? "Maestro"
        // An agent-made pet in use can be captured into the shared collection.
        let capturable = descriptor?.source == .session && content.petSessionID != nil
        Button { showingPicker = true } label: {
            SidebarPetView(petID: petID, session: content.petSessionID, state: state, width: 38)
        }
        .buttonStyle(.plain)
        .help("\(name) · \(state.title). Click to choose a pet.")
        .accessibilityLabel("Pet \(name), \(state.title)")
        .accessibilityHint("Opens the pet picker")
        .accessibilityIdentifier("sidebar-pet-button")
        .overlay(alignment: .center) {
            if (capturable && hovering) || captured, let session = content.petSessionID {
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
            SidebarPetPicker(sessionID: content.petSessionID, agentChoice: content.petChoice, state: state) {
                showingPicker = false
            }
        }
    }
}

struct SidebarPetPicker: View {
    let sessionID: UUID?
    let agentChoice: String?
    let state: SidebarPetState
    let close: () -> Void
    @State private var refreshToken = 0
    @State private var pendingRemoval: SidebarPetDescriptor?

    var body: some View {
        let store = SidebarPetStore.shared
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
                            pet: pet, session: sessionID, selected: current == pet.id, state: state,
                            choose: { if let sessionID { store.choose(pet.id, session: sessionID) } },
                            save: pet.source == .session && sessionID != nil
                                ? { if let sessionID { store.saveToRepository(pet.id, session: sessionID); refreshToken += 1 } } : nil,
                            remove: pet.source == .uploaded ? { pendingRemoval = pet } : nil
                        )
                        .contextMenu { cellMenu(pet, store) }
                    }
                }
                .padding(2)
            }
            .frame(height: 210)
            if sessionID == nil {
                Text("No agent session selected.").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button("Upload pet…") { upload(store) }
                    .help("Choose a Codex pet folder or spritesheet.")
                    .accessibilityIdentifier("sidebar-pet-upload")
                if let sessionID, let pet = store.descriptor(current, session: sessionID), pet.source == .session {
                    Button("Save to my pets") { store.saveToRepository(pet.id, session: sessionID); refreshToken += 1 }
                        .help("Save this pet for all agents.")
                        .accessibilityIdentifier("sidebar-pet-save")
                }
                Button("Reset to agent's pet") { if let sessionID { store.clearChoice(session: sessionID) } }
                    .disabled(sessionID.map { !store.hasOverride(session: $0) } ?? true)
                    .help("Reset to the agent’s pet.")
            }
            if let notice = store.notice {
                Text(notice).font(.caption).foregroundStyle(SidebarTone.attention.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Download and unzip a pet, then upload it.").font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Link("Codex Pets gallery", destination: SidebarPetStore.galleryURL)
                    Link("Create a pet", destination: SidebarPetStore.generatorURL)
                }
                .font(.caption2)
            }
            Text("Agent-made pets are session-only until saved.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

    @ViewBuilder private func cellMenu(_ pet: SidebarPetDescriptor, _ store: SidebarPetStore) -> some View {
        if pet.source == .session, let sessionID {
            Button("Save to my pets") { store.saveToRepository(pet.id, session: sessionID); refreshToken += 1 }
        }
        if pet.source == .uploaded {
            Button("Remove from my pets…", role: .destructive) { pendingRemoval = pet }
        }
    }

    private func upload(_ store: SidebarPetStore) {
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
            SidebarPetView(petID: pet.id, session: session, state: selected ? state : .idle, width: 56)
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
