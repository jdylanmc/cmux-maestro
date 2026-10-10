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

    var body: some View {
        let store = SidebarPetStore.shared
        let petID = store.resolvedID(session: content.petSessionID, agentChoice: content.petChoice)
        let state = SidebarPetState.resolve(visual: content.visual, needsInput: content.needsInput)
        let name = store.descriptor(petID, session: content.petSessionID)?.displayName ?? "Maestro"
        Button { showingPicker = true } label: {
            SidebarPetView(petID: petID, session: content.petSessionID, state: state, width: 46)
        }
        .buttonStyle(.plain)
        .help("\(name) · \(state.title). Click to choose a pet.")
        .accessibilityLabel("Pet \(name), \(state.title)")
        .accessibilityHint("Opens the pet picker")
        .accessibilityIdentifier("sidebar-pet-button")
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

    var body: some View {
        let store = SidebarPetStore.shared
        let current = store.resolvedID(session: sessionID, agentChoice: agentChoice)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Choose a pet").font(.headline)
                Spacer(minLength: 0)
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                    ForEach(store.available(for: sessionID)) { pet in
                        Button {
                            if let sessionID { store.choose(pet.id, session: sessionID) }
                        } label: {
                            SidebarPetCell(pet: pet, session: sessionID, selected: current == pet.id, state: state)
                        }
                        .buttonStyle(.plain)
                        .disabled(sessionID == nil)
                        .accessibilityLabel("\(pet.displayName)\(current == pet.id ? ", selected" : "")")
                        .contextMenu { cellMenu(pet, store) }
                    }
                }
                .padding(2)
            }
            .frame(height: 210)
            if sessionID == nil {
                Text("This item has no agent session to choose a pet for.").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button("Upload pet…") { upload(store) }
                    .help("Choose a Codex pet folder (pet.json + spritesheet) or a 1536×1872 PNG/WebP spritesheet.")
                    .accessibilityIdentifier("sidebar-pet-upload")
                if let sessionID, let pet = store.descriptor(current, session: sessionID), pet.source == .session {
                    Button("Save to my pets") { store.saveToRepository(pet.id, session: sessionID); refreshToken += 1 }
                        .help("Keep this agent-made pet so any agent can use it. Otherwise it only works for this session.")
                        .accessibilityIdentifier("sidebar-pet-save")
                }
                Button("Reset to agent's pet") { if let sessionID { store.clearChoice(session: sessionID) } }
                    .disabled(sessionID.map { !store.hasOverride(session: $0) } ?? true)
                    .help("Remove your choice: show the pet this agent chose for itself, or Maestro if it chose none.")
            }
            if let notice = store.notice {
                Text(notice).font(.caption).foregroundStyle(SidebarTone.attention.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Find more Codex pets, unzip, then Upload pet…").font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Link("Codex Pets gallery", destination: SidebarPetStore.galleryURL)
                    Link("Create a pet", destination: SidebarPetStore.generatorURL)
                }
                .font(.caption2)
            }
            Text("Agents can make and pick their own with the maestro-pet skill; an agent-made pet is only for its session until you save it.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
        .id(refreshToken)
        .onAppear { store.refresh() }
    }

    @ViewBuilder private func cellMenu(_ pet: SidebarPetDescriptor, _ store: SidebarPetStore) -> some View {
        if pet.source == .session, let sessionID {
            Button("Save to my pets") { store.saveToRepository(pet.id, session: sessionID); refreshToken += 1 }
        }
        if pet.source == .uploaded {
            Button("Remove saved pet", role: .destructive) { store.removeUpload(pet.id); refreshToken += 1 }
        }
    }

    private func upload(_ store: SidebarPetStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder, .png, .webP]
        panel.prompt = "Upload"
        panel.message = "Choose a Codex pet folder or a 1536×1872 PNG/WebP spritesheet"
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

    var body: some View {
        VStack(spacing: 2) {
            SidebarPetView(petID: pet.id, session: session, state: selected ? state : .idle, width: 56)
            Text(pet.displayName).font(.caption2).lineLimit(1).truncationMode(.tail)
            if pet.source != .bundled {
                Text(pet.source == .session ? "agent-made · this session" : "saved")
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
