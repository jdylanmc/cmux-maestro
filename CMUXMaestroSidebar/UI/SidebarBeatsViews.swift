import AppKit
import Observation
import SwiftUI

struct SidebarBeatTarget: Identifiable, Equatable {
    let id: UUID
    let title: String
    let live: Bool
}

/// Human management of the shared Beats store. The sidebar is the human actor: it may
/// move a Beat to another session, which agents cannot.
@Observable
@MainActor
final class SidebarBeatsController {
    private(set) var beats: [SidebarBeat] = [] {
        didSet { if beats != oldValue { summaries = SidebarBeatSummaries(beats: beats) } }
    }
    /// Enabled Beats per exact session, recomputed only when the store's Beats change.
    private(set) var summaries = SidebarBeatSummaries.empty
    /// Session the open Beats panel is scoped to, set by an agent row's Beat icon. Presentation only.
    var scopedSession: UUID?
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
    let controller: SidebarBeatsController
    let targets: [SidebarBeatTarget]
    let close: () -> Void
    @State private var mode = BeatsMode.list
    @State private var pendingDelete: String?
    @State private var actionError: String?

    private var scope: UUID? { controller.scopedSession }
    private var scopeTitle: String? {
        scope.map { id in targets.first { $0.id == id }?.title ?? SidebarBeatsPanel.notRunningTitle(id.uuidString.lowercased()) }
    }
    private var visibleBeats: [SidebarBeat] {
        guard let scope else { return controller.beats }
        let id = scope.uuidString.lowercased()
        return controller.beats.filter { $0.sessionId == id }
    }
    /// A scoped panel creates Beats only for its own session, which must be running to be a target.
    private var newBeatUnavailable: String? {
        if let scope { return targets.contains { $0.id == scope } ? nil : "Start this agent's session to add a Beat." }
        return targets.isEmpty ? "Open an agent session to target it." : nil
    }

    static func notRunningTitle(_ sessionId: String) -> String { "Session \(sessionId.prefix(8)) (not running)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Beats").font(.headline)
                Spacer()
                SidebarCloseButton(label: "Close Beats", id: "sidebar-close-beats", action: close)
            }
            Text("Recurring prompts for agent sessions. The session must be running.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let scopeTitle {
                HStack(spacing: 6) {
                    Text("For \(scopeTitle)").font(.caption.weight(.semibold)).lineLimit(1)
                        .accessibilityIdentifier("sidebar-beats-scope")
                    Spacer(minLength: 0)
                    Button("Show all") { controller.scopedSession = nil; mode = .list }
                        .buttonStyle(.borderless).font(.caption)
                        .help("Show Beats for every session.")
                        .accessibilityIdentifier("sidebar-beats-show-all")
                }
            }
            if let notice = controller.notice ?? actionError {
                Text(notice).font(.caption).foregroundStyle(SidebarTone.attention.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch mode {
            case .list:
                BeatsList(controller: controller, beats: visibleBeats, targets: targets, pendingDelete: $pendingDelete,
                          actionError: $actionError, edit: { mode = .form($0) })
                Button { mode = .form(nil) } label: { Label("New Beat", systemImage: "plus") }
                    .disabled(newBeatUnavailable != nil)
                    .help(newBeatUnavailable ?? "Create a recurring prompt.")
                    .accessibilityIdentifier("sidebar-beats-new")
            case .form(let existing):
                BeatsForm(controller: controller, targets: targets, existing: existing, preferred: scope) { mode = .list }
            }
        }
        .padding(14)
        .frame(width: 340)
        .onChange(of: scope) { _, _ in mode = .list; pendingDelete = nil }
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
    let beats: [SidebarBeat]
    let targets: [SidebarBeatTarget]
    @Binding var pendingDelete: String?
    @Binding var actionError: String?
    let edit: (SidebarBeat) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if beats.isEmpty {
                    Text("No beats.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 12)
                }
                ForEach(beats) { beat in
                    BeatRow(controller: controller, beat: beat, target: targets.first { $0.id.uuidString.lowercased() == beat.sessionId },
                            pendingDelete: $pendingDelete, actionError: $actionError, edit: edit)
                }
            }
        }
        .frame(maxHeight: 320)
    }
}

private struct BeatRow: View {
    let controller: SidebarBeatsController
    let beat: SidebarBeat
    let target: SidebarBeatTarget?
    @Binding var pendingDelete: String?
    @Binding var actionError: String?
    let edit: (SidebarBeat) -> Void

    private var tone: Color { beat.enabled ? SidebarQuestionGlow.lightBlue : .secondary }

    // No estimate for a session that is not running: the Beat cannot fire there.
    private var nextFire: String? {
        guard beat.enabled, target != nil, let spec = try? BeatsCron(beat.cron),
              let next = spec.nextTimes(after: Date(), count: 1).first else { return nil }
        return next.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(tone).frame(width: 7, height: 7)
                Text(target?.title ?? SidebarBeatsPanel.notRunningTitle(beat.sessionId))
                    .font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Text(beat.enabled ? "On" : "Off").font(.caption2).foregroundStyle(tone)
                    .accessibilityLabel(beat.enabled ? "Beat on" : "Beat off")
            }
            Text(beat.cron).font(.system(.caption, design: .monospaced))
            if let nextFire { Text("Next (estimate): \(nextFire)").font(.caption2).foregroundStyle(.secondary) }
            Text(beat.prompt).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 8) {
                primaryAction
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

    @ViewBuilder private var primaryAction: some View {
        if beat.enabled {
            Button("Disable") { actionError = controller.perform { try $0.disable(id: beat.id) } }.buttonStyle(.borderless)
        } else {
            Button("Enable") { actionError = controller.perform { try $0.enable(id: beat.id) } }.buttonStyle(.borderless)
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
    /// The stored Beat this edit is based on; "Load latest" moves it forward and keeps the draft.
    @State private var base: SidebarBeat?
    @State private var conflict = false

    init(controller: SidebarBeatsController, targets: [SidebarBeatTarget], existing: SidebarBeat?, preferred: UUID? = nil,
         done: @escaping () -> Void) {
        self.controller = controller; self.targets = targets; self.existing = existing; self.done = done
        _base = State(initialValue: existing)
        let preferredTarget = preferred.flatMap { id in targets.first { $0.id == id }?.id }
        _session = State(initialValue: existing.flatMap { UUID(uuidString: $0.sessionId) } ?? preferredTarget ?? targets.first?.id)
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
            options.append(.init(id: id, title: SidebarBeatsPanel.notRunningTitle(existing.sessionId), live: false))
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
                Text("Next (estimate): \(preview)").font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Local time. Runs roughly on schedule while the session is running; Copilot decides exact timing.")
                .font(.caption2).foregroundStyle(.secondary)
            TextEditor(text: $prompt)
                .font(.caption).frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
                .accessibilityLabel("Prompt")
                .accessibilityIdentifier("sidebar-beats-prompt")
            Text("\(prompt.utf8.count) / \(BeatsLimits.maximumPromptBytes) bytes").font(.caption2)
                .foregroundStyle(prompt.utf8.count > BeatsLimits.maximumPromptBytes ? SidebarTone.attention.color : .secondary)
            if let error { Text(error).font(.caption).foregroundStyle(SidebarTone.attention.color) }
            if conflict {
                Button("Load latest") { loadLatest() }
                    .help("Base your draft on the current version; your typed changes stay.")
                    .accessibilityIdentifier("sidebar-beats-load-latest")
            }
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
                try $0.edit(id: existing.id, cron: cron, prompt: prompt, session: current ? nil : session, basedOn: base)
            }
            conflict = failure == BeatsError.changedElsewhere.message
        } else {
            failure = controller.perform { _ = try $0.create(session: session, cron: cron, prompt: prompt) }
        }
        if let failure { error = failure } else { done() }
    }

    private func loadLatest() {
        controller.refresh()
        guard let latest = controller.beats.first(where: { $0.id == existing?.id }) else {
            error = "This Beat was deleted."
            conflict = false
            return
        }
        base = latest
        error = "Loaded the latest version; your edits are kept. Save again to apply them."
        conflict = false
    }
}

// MARK: - Agent row Beat indicator

enum SidebarBeatIndicatorState: Equatable {
    /// No enabled Beat targets the session.
    case none
    /// Enabled Beats, but the session is not known to be running, so none can fire (ADR 0007).
    case dim
    /// Enabled Beats on a running session.
    case lit
}

/// Row-facing Beat state: the store summary joined with the liveness the Beats panel uses for targets.
struct SidebarBeatIndicators: Equatable {
    var summaries = SidebarBeatSummaries.empty
    var running: Set<UUID> = []
    var ended: Set<UUID> = []

    init(summaries: SidebarBeatSummaries = .empty, running: Set<UUID> = [], ended: Set<UUID> = []) {
        self.summaries = summaries; self.running = running; self.ended = ended
    }

    init(summaries: SidebarBeatSummaries, tree: SidebarCopilotTree) {
        self.init(summaries: summaries, running: Set(Self.runningSessions(in: tree).map(\.id)),
                  ended: Set(tree.sessions.filter { $0.liveness == .dead }.map(\.id)))
    }

    /// The sessions a Beat can currently fire in; the Beats panel's targets and "Next (estimate)".
    static func runningSessions(in tree: SidebarCopilotTree) -> [SidebarCopilotSession] {
        tree.sessions.filter { $0.liveness == .alive }
    }

    func state(for session: UUID?) -> SidebarBeatIndicatorState {
        guard let session, summaries.summary(for: session) != nil else { return .none }
        return running.contains(session) ? .lit : .dim
    }

    func accessibilityValue(for session: UUID?) -> String {
        guard let session, let summary = summaries.summary(for: session) else { return "" }
        let liveness = running.contains(session) ? "running"
            : ended.contains(session) ? "not running" : "not known to be running"
        return "\(summary.enabledCount) on, \(liveness)"
    }

    func help(for session: UUID?) -> String {
        guard let session, let summary = summaries.summary(for: session) else { return "" }
        let count = summary.enabledCount == 1 ? "1 Beat on" : "\(summary.enabledCount) Beats on"
        let shown = summary.schedules.prefix(4).joined(separator: "; ")
        let more = summary.schedules.count > 4 ? "; +\(summary.schedules.count - 4) more" : ""
        let note = running.contains(session) ? "Session running."
            : "Session not known to be running; Beats fire only while it runs."
        return "\(count): \(shown)\(more). \(note) Click to edit this agent's Beats."
    }
}

/// The breathing glow of a lit Beat icon. One opacity value per icon; no model updates.
enum SidebarBeatGlow {
    static let period: TimeInterval = 2
    static let staticIntensity = 0.8

    static func animates(_ state: SidebarBeatIndicatorState, reduceMotion: Bool) -> Bool {
        state == .lit && !reduceMotion
    }

    static func intensity(_ state: SidebarBeatIndicatorState, at date: Date, reduceMotion: Bool) -> Double {
        guard state == .lit else { return 0 }
        guard !reduceMotion else { return staticIntensity }
        let phase = date.timeIntervalSinceReferenceDate * 2 * .pi / period
        return 0.35 + 0.65 * (0.5 + 0.5 * sin(phase))
    }
}

private struct SidebarBeatIndicatorsKey: EnvironmentKey {
    static let defaultValue = SidebarBeatIndicators()
}

private struct SidebarOpenBeatsKey: EnvironmentKey {
    static let defaultValue: ((UUID) -> Void)? = nil
}

extension EnvironmentValues {
    var sidebarBeatIndicators: SidebarBeatIndicators {
        get { self[SidebarBeatIndicatorsKey.self] }
        set { self[SidebarBeatIndicatorsKey.self] = newValue }
    }
    /// Opens the Beats panel scoped to one exact session. Nil where the panel cannot open, such as previews.
    var sidebarOpenBeats: ((UUID) -> Void)? {
        get { self[SidebarOpenBeatsKey.self] }
        set { self[SidebarOpenBeatsKey.self] = newValue }
    }
}

/// Trailing Beat icon on a row that represents exactly one Copilot session.
struct SidebarBeatIndicator: View {
    static let symbol = SidebarHeaderAction.beats.symbol
    static let accessibilityLabel = "Beats for this agent"
    let session: UUID?
    let titleHeight: CGFloat
    /// Space under the title line, so the icon centres on the title rather than the whole row.
    var belowTitle: CGFloat = 0
    @Environment(\.sidebarBeatIndicators) private var indicators
    @Environment(\.sidebarOpenBeats) private var openBeats
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func titleHeight(fontSize: Double) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: fontSize, weight: .semibold)))
    }

    var body: some View {
        let state = indicators.state(for: session)
        if state != .none, let session {
            VStack(spacing: 0) {
                SidebarBeatGlyph(state: state, reduceMotion: reduceMotion)
                    .frame(width: 20, height: titleHeight)
                if belowTitle > 0 { Color.clear.frame(width: 20, height: belowTitle) }
            }
            .overlay {
                SidebarBeatButton(
                    value: indicators.accessibilityValue(for: session), help: indicators.help(for: session),
                    action: openBeats.map { open in { open(session) } }
                )
            }
            .fixedSize()
        }
    }
}

struct SidebarBeatGlyph: View {
    let state: SidebarBeatIndicatorState
    let reduceMotion: Bool

    var body: some View {
        if SidebarBeatGlow.animates(state, reduceMotion: reduceMotion) {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                glyph(glow: SidebarBeatGlow.intensity(state, at: context.date, reduceMotion: false))
            }
        } else {
            glyph(glow: SidebarBeatGlow.intensity(state, at: .distantPast, reduceMotion: true))
        }
    }

    private var image: some View {
        Image(systemName: SidebarBeatIndicator.symbol).font(.system(size: 11, weight: .semibold))
    }

    // The glow is a pre-blurred copy whose opacity alone changes, so a tick does not re-render the blur.
    private func glyph(glow: Double) -> some View {
        image
            .foregroundStyle(state == .lit ? Color.accentColor : Color.secondary.opacity(0.55))
            .background {
                if state == .lit {
                    image.foregroundStyle(Color.accentColor).blur(radius: 3).opacity(glow)
                }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// Native, transparent hit target over the glyph, so a click never reaches the row's title button.
final class SidebarBeatNativeButton: NSButton {
    var activate: (() -> Void)?

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        imagePosition = .noImage
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        target = self
        action = #selector(press)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func press() { activate?() }

    // Without a title or image AppKit reports an unknown role; this is a button.
    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let activate else { return false }
        activate()
        return true
    }
}

private struct SidebarBeatButton: NSViewRepresentable {
    let value: String
    let help: String
    let action: (() -> Void)?

    func makeNSView(context: Context) -> SidebarBeatNativeButton { SidebarBeatNativeButton() }

    func updateNSView(_ button: SidebarBeatNativeButton, context: Context) {
        button.activate = action
        button.isEnabled = action != nil
        button.toolTip = help
        button.setAccessibilityLabel(SidebarBeatIndicator.accessibilityLabel)
        button.setAccessibilityValue(value)
        button.setAccessibilityHelp(help)
        button.setAccessibilityIdentifier("sidebar-beat-indicator")
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SidebarBeatNativeButton, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 20, height: 20))
    }
}
