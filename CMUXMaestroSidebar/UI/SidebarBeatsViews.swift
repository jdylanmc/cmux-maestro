import Observation
import SwiftUI

struct SidebarBeatTarget: Identifiable, Equatable {
    let id: UUID
    let title: String
    let live: Bool
}

/// Human management of the shared Beats store. The sidebar is the human actor: it may
/// reassign a target and clear the recovery gate, which agents cannot.
@Observable
@MainActor
final class SidebarBeatsController {
    static let shared = SidebarBeatsController()

    private(set) var beats: [SidebarBeat] = []
    private(set) var notice: String?
    private let file: SidebarBeatsFile?

    init(file: SidebarBeatsFile? = .standard()) {
        self.file = file
        refresh()
    }

    func refresh() {
        guard let file else { notice = "The Beats store location is unavailable."; return }
        do {
            let state = try file.read()
            if state.beats != beats { beats = state.beats }
            notice = nil
        } catch let error as BeatsError {
            notice = error.message
        } catch {
            notice = "The Beats store could not be read."
        }
    }

    @discardableResult
    func perform(_ operation: (inout SidebarBeatsState) throws -> Void) -> String? {
        guard let file else { return "The Beats store location is unavailable." }
        do {
            try file.mutate(operation)
            refresh()
            return nil
        } catch let error as BeatsError {
            return error.message
        } catch {
            return "The Beats store could not be written."
        }
    }
}

private enum BeatsMode: Equatable {
    case list
    case form(SidebarBeat?)
}

struct SidebarBeatsPanel: View {
    let targets: [SidebarBeatTarget]
    let close: () -> Void
    @State private var mode = BeatsMode.list
    @State private var pendingDelete: String?
    @State private var actionError: String?

    var body: some View {
        let controller = SidebarBeatsController.shared
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Beats").font(.headline)
                Spacer()
                SidebarCloseButton(label: "Close Beats", id: "sidebar-close-beats", action: close)
            }
            Text("Recurring prompts for exact agent sessions. Each session schedules its own through Copilot, so the session must be running.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let notice = controller.notice ?? actionError {
                Text(notice).font(.caption).foregroundStyle(SidebarTone.attention.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch mode {
            case .list:
                BeatsList(controller: controller, targets: targets, pendingDelete: $pendingDelete,
                          actionError: $actionError, edit: { mode = .form($0) })
                Button { mode = .form(nil) } label: { Label("New Beat", systemImage: "plus") }
                    .disabled(targets.isEmpty)
                    .help(targets.isEmpty ? "Open an agent session to target it." : "Create a recurring prompt.")
                    .accessibilityIdentifier("sidebar-beats-new")
            case .form(let existing):
                BeatsForm(controller: controller, targets: targets, existing: existing) { mode = .list }
            }
        }
        .padding(14)
        .frame(width: 340)
        .task {
            // Agents and the orchestrator write the same store; pick up their changes while open.
            while !Task.isCancelled {
                controller.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-beats-panel")
    }
}

private struct BeatsList: View {
    let controller: SidebarBeatsController
    let targets: [SidebarBeatTarget]
    @Binding var pendingDelete: String?
    @Binding var actionError: String?
    let edit: (SidebarBeat) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if controller.beats.isEmpty {
                    Text("No Beats yet.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 12)
                }
                ForEach(controller.beats) { beat in
                    BeatRow(beat: beat, target: targets.first { $0.id.uuidString.lowercased() == beat.sessionId },
                            pendingDelete: $pendingDelete, actionError: $actionError, edit: edit)
                }
            }
        }
        .frame(maxHeight: 320)
    }
}

private struct BeatRow: View {
    let beat: SidebarBeat
    let target: SidebarBeatTarget?
    @Binding var pendingDelete: String?
    @Binding var actionError: String?
    let edit: (SidebarBeat) -> Void

    private var tone: Color {
        switch beat.status {
        case .active: SidebarQuestionGlow.lightBlue
        case .paused: .secondary
        case .needsRecovery, .targetEnded: SidebarTone.attention.color
        }
    }

    private var nextFire: String? {
        guard beat.status == .active, let spec = try? BeatsCron(beat.cron),
              let next = spec.nextTimes(after: Date(), count: 1).first else { return nil }
        return next.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    var body: some View {
        let controller = SidebarBeatsController.shared
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(tone).frame(width: 7, height: 7)
                Text(target?.title ?? "Session \(beat.sessionId.prefix(8)) (not open)")
                    .font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Text(beat.status.title).font(.caption2).foregroundStyle(tone)
            }
            Text(beat.cron).font(.system(.caption, design: .monospaced))
            if let nextFire { Text("Next: \(nextFire)").font(.caption2).foregroundStyle(.secondary) }
            Text(beat.prompt).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 8) {
                primaryAction(controller)
                Button("Edit") { edit(beat) }.buttonStyle(.borderless)
                Spacer(minLength: 0)
                if pendingDelete == beat.id {
                    Button("Delete?", role: .destructive) {
                        actionError = controller.perform { try $0.delete(id: beat.id) }
                        pendingDelete = nil
                    }
                    .buttonStyle(.borderless)
                    Button("Keep") { pendingDelete = nil }.buttonStyle(.borderless)
                } else {
                    Button("Delete", role: .destructive) { pendingDelete = beat.id }.buttonStyle(.borderless)
                }
            }
            .font(.caption)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func primaryAction(_ controller: SidebarBeatsController) -> some View {
        switch beat.status {
        case .active:
            Button("Pause") { actionError = controller.perform { try $0.pause(id: beat.id) } }.buttonStyle(.borderless)
        case .paused:
            Button("Resume") { actionError = controller.perform { try $0.enable(id: beat.id) } }.buttonStyle(.borderless)
        case .needsRecovery:
            Button("Re-enable") { actionError = controller.perform { try $0.enable(id: beat.id) } }
                .buttonStyle(.borderless)
                .help("Restored after a relaunch or repair. A human re-enables recurrence.")
        case .targetEnded:
            Text("Choose a session in Edit").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct BeatsForm: View {
    let controller: SidebarBeatsController
    let targets: [SidebarBeatTarget]
    let existing: SidebarBeat?
    let done: () -> Void
    @State private var session: UUID?
    @State private var cron: String
    @State private var prompt: String
    @State private var error: String?

    init(controller: SidebarBeatsController, targets: [SidebarBeatTarget], existing: SidebarBeat?, done: @escaping () -> Void) {
        self.controller = controller; self.targets = targets; self.existing = existing; self.done = done
        _session = State(initialValue: existing.flatMap { UUID(uuidString: $0.sessionId) } ?? targets.first?.id)
        _cron = State(initialValue: existing?.cron ?? "0 9 * * 1-5")
        _prompt = State(initialValue: existing?.prompt ?? "")
    }

    private static let presets: [(String, String)] = [
        ("Every 15 minutes", "*/15 * * * *"), ("Hourly", "0 * * * *"), ("Daily at 9:00", "0 9 * * *"),
        ("Weekdays at 9:00", "0 9 * * 1-5"), ("Mondays at 9:00", "0 9 * * 1")
    ]

    private var parsed: Result<BeatsCron, BeatsError> {
        do { return .success(try BeatsCron(cron)) } catch let error as BeatsError { return .failure(error) } catch { return .failure(BeatsError("Invalid cron.")) }
    }

    private var preview: String {
        guard case .success(let spec) = parsed else { return "" }
        let formatter = Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day().hour().minute()
        return spec.nextTimes(after: Date(), count: 3).map { $0.formatted(formatter) }.joined(separator: " · ")
    }

    private var targetOptions: [SidebarBeatTarget] {
        var options = targets
        if let existing, let id = UUID(uuidString: existing.sessionId), !options.contains(where: { $0.id == id }) {
            options.append(.init(id: id, title: "Session \(existing.sessionId.prefix(8)) (not open)", live: false))
        }
        return options
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(existing == nil ? "New Beat" : "Edit Beat").font(.subheadline.weight(.semibold))
            Picker("Session", selection: $session) {
                ForEach(targetOptions) { Text($0.title).tag(Optional($0.id)) }
            }
            .accessibilityIdentifier("sidebar-beats-target")
            if let existing, existing.targetEnded || session.map({ $0.uuidString.lowercased() != existing.sessionId }) == true {
                Text("Choosing another session leaves this Beat paused until you re-enable it.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Cron (minute hour day month weekday)", text: $cron)
                    .textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced))
                    .accessibilityIdentifier("sidebar-beats-cron")
                Menu("Presets") {
                    ForEach(Self.presets, id: \.1) { preset in Button(preset.0) { cron = preset.1 } }
                }
                .fixedSize()
            }
            if case .failure(let failure) = parsed {
                Text(failure.message).font(.caption2).foregroundStyle(SidebarTone.attention.color)
            } else if !preview.isEmpty {
                Text("Next: \(preview)").font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Local time. Missed times are not replayed; one attempt per occurrence.")
                .font(.caption2).foregroundStyle(.secondary)
            TextEditor(text: $prompt)
                .font(.caption).frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
                .accessibilityLabel("Prompt")
                .accessibilityIdentifier("sidebar-beats-prompt")
            Text("\(prompt.utf8.count) / \(BeatsLimits.maximumPromptBytes) bytes").font(.caption2)
                .foregroundStyle(prompt.utf8.count > BeatsLimits.maximumPromptBytes ? SidebarTone.attention.color : .secondary)
            if let error { Text(error).font(.caption).foregroundStyle(SidebarTone.attention.color) }
            HStack {
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(session == nil)
                    .accessibilityIdentifier("sidebar-beats-save")
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
            }
        }
    }

    private func save() {
        guard let session else { return }
        let failure: String?
        if let existing {
            let current = existing.sessionId == session.uuidString.lowercased()
            failure = controller.perform {
                try $0.edit(id: existing.id, cron: cron, prompt: prompt, session: current ? nil : session)
            }
        } else {
            failure = controller.perform { _ = try $0.create(session: session, cron: cron, prompt: prompt) }
        }
        if let failure { error = failure } else { done() }
    }
}
