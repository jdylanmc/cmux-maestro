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
    private(set) var summaries = SidebarBeatSummaries.empty {
        didSet { updateIndicators() }
    }
    /// Row icon state. Assigned only when it changes, so unrelated sidebar updates leave icons alone.
    private(set) var indicators = SidebarBeatIndicators()
    /// Whether the Beats panel is open, the session it is scoped to, and the sidebar window
    /// that opened it (nil outside a multi-window host). Presentation only.
    private(set) var isPresented = false
    private(set) var scopedSession: UUID?
    private(set) var presenter: ObjectIdentifier?
    private(set) var notice: String?
    private let file: SidebarBeatsFile?
    private let now: () -> Date
    /// One tree per sidebar window; a session lives in exactly one window's tree.
    private var trees: [ObjectIdentifier?: SidebarCopilotTree] = [:]

    init(file: SidebarBeatsFile? = .standard(), now: @escaping () -> Date = { Date() }) {
        self.file = file
        self.now = now
        refresh()
    }

    /// Opens the panel, or rescopes it in place when it is already open, so a second row's click
    /// never races a dismissal. `nil` shows every Beat.
    func present(scope: UUID?, from presenter: ObjectIdentifier? = nil) {
        if self.presenter != presenter { self.presenter = presenter }
        if scopedSession != scope { scopedSession = scope }
        if !isPresented { isPresented = true }
    }

    /// Whether the panel is open in the sidebar window identified by `presenter`.
    func isPresented(in presenter: ObjectIdentifier?) -> Bool {
        isPresented && self.presenter == presenter
    }

    func showAll() { scopedSession = nil }

    func dismiss() {
        isPresented = false
        scopedSession = nil
        presenter = nil
    }

    /// Closes the panel only if `presenter`'s window opened it.
    func dismiss(from presenter: ObjectIdentifier?) {
        guard self.presenter == presenter else { return }
        dismiss()
    }

    /// Liveness for row icons. Called on every tree change; re-evaluated against the clock on each refresh.
    func updateLiveness(_ tree: SidebarCopilotTree, from window: ObjectIdentifier? = nil) {
        trees[window] = tree
        updateIndicators()
    }

    /// Forgets a closed sidebar window's liveness.
    func removeLiveness(from window: ObjectIdentifier?) {
        guard trees.removeValue(forKey: window) != nil else { return }
        updateIndicators()
    }

    private func updateIndicators() {
        let now = now()
        let next = trees.values.reduce(into: SidebarBeatIndicators(summaries: summaries)) { result, tree in
            let window = SidebarBeatIndicators(summaries: summaries, tree: tree, now: now)
            result.running.formUnion(window.running)
            result.ended.formUnion(window.ended)
        }
        let merged = SidebarBeatIndicators(summaries: summaries, running: next.running,
                                           ended: next.ended.subtracting(next.running))
        if merged != indicators { indicators = merged }
    }

    func refresh() {
        defer { updateIndicators() }
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

enum SidebarBeatsMode: Equatable {
    case list
    case form(SidebarBeat?)

    /// "Show all" leaves a scoped list; a form keeps its draft, so it has none.
    var offersShowAll: Bool { self == .list }

    /// A new scope returns a list to its top but never discards an open form's draft.
    func afterScopeChange() -> Self {
        if case .form = self { return self }
        return .list
    }
}

/// Beats panel copy. Visible text stays terse; the honesty facts (On/Off, estimates, fires only
/// while the session runs, Copilot decides timing) live in tooltips and accessibility.
enum SidebarBeatsCopy {
    static let newBeat = "New Beat"
    static let empty = "No Beats"
    static let notRunning = "Session not running"
    static let firesOnlyWhileRunning = "Beats fire only while the session runs."
    static let timing = "Local time. Runs roughly on schedule while the session is running; Copilot decides exact timing."
    static let toggle = "Beat on/off"
    static let changedElsewhere = "Changed elsewhere"
    static let loadLatestHelp = "Base your draft on the current version; your typed changes stay."
    static let latestLoaded = "Latest loaded — Save to apply"
    static let latestLoadedHelp = "Loaded the latest version; your edits are kept. Save again to apply them."
    static let deleted = "Beat deleted"
    static let invalidCron = "Invalid cron"
    static let lockedHelp = "Locked to this agent's session. Cancel, then Show all, to target another session."

    static let presets: [(label: String, cron: String)] = [
        ("Every 15 min", "*/15 * * * *"), ("Hourly", "0 * * * *"), ("Daily 9:00", "0 9 * * *"),
        ("Weekdays 9:00", "0 9 * * 1-5"), ("Mondays 9:00", "0 9 * * 1")
    ]

    /// A preset's name, or nil when the cron is custom and shown as written.
    static func presetLabel(_ cron: String) -> String? {
        let normalized = cron.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return presets.first { $0.cron == normalized }?.label
    }

    static func sessionTitle(_ sessionId: String) -> String { "Session \(sessionId.prefix(8))" }

    /// The next run, short: a time today, weekday and time within 6 days, otherwise month, day and time.
    static func nextShort(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? .max
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        if days == 0 { return date.formatted(style) }
        return date.formatted(days > 0 && days <= 6 ? style.weekday(.abbreviated) : style.month(.abbreviated).day())
    }

    static func nextLong(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    /// Row VoiceOver value: On/Off, the estimated next run and when it can fire.
    static func rowStatus(enabled: Bool, running: Bool, next: Date?) -> String {
        var parts = [enabled ? "On." : "Off."]
        if !running {
            parts += ["\(notRunning).", firesOnlyWhileRunning]
        } else if enabled, let next {
            parts += ["Next run estimate: \(nextLong(next)).", "Copilot decides exact timing.", firesOnlyWhileRunning]
        }
        return parts.joined(separator: " ")
    }

    /// Row tooltip: the cron, then the same facts as the VoiceOver value.
    static func rowDetail(cron: String, enabled: Bool, running: Bool, next: Date?) -> String {
        "Cron \(cron). \(rowStatus(enabled: enabled, running: running, next: next))"
    }

    /// The form's next-run caption and its detail.
    static func preview(_ times: [Date], now: Date = Date()) -> (caption: String, detail: String)? {
        guard let first = times.first else { return nil }
        let all = times.map(nextLong).joined(separator: " · ")
        return ("Next ≈ \(nextShort(first, now: now))", "Next runs (estimate, local time): \(all). \(timing)")
    }

    /// Prompt size, shown only near or over the limit.
    static func byteCounter(_ bytes: Int, limit: Int = BeatsLimits.maximumPromptBytes) -> String? {
        bytes * 4 >= limit * 3 ? "\(bytes)/\(limit) B" : nil
    }
}

/// What one Beat row shows, and the labels that tell rows apart for VoiceOver.
struct SidebarBeatRowModel: Equatable {
    let schedule: String
    let isPreset: Bool
    let session: String?
    let running: Bool
    let prompt: String
    let detail: String
    let status: String
    /// Schedule and a short prompt prefix, appended to each control's label.
    let identity: String

    init(beat: SidebarBeat, target: SidebarBeatTarget?, scoped: Bool, next: Date?) {
        let preset = SidebarBeatsCopy.presetLabel(beat.cron)
        schedule = preset ?? beat.cron
        isPreset = preset != nil
        session = scoped ? nil : (target?.title ?? SidebarBeatsCopy.sessionTitle(beat.sessionId))
        running = target != nil
        prompt = beat.prompt
        detail = SidebarBeatsCopy.rowDetail(cron: beat.cron, enabled: beat.enabled, running: running, next: next)
        status = SidebarBeatsCopy.rowStatus(enabled: beat.enabled, running: running, next: next)
        let line = beat.prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let prefix = line.count > 24 ? "\(line.prefix(24))…" : line
        identity = [schedule, prefix].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var summary: String { [identity, session].compactMap { $0 }.joined(separator: ", ") }
    var toggleLabel: String { "\(SidebarBeatsCopy.toggle), \(identity)" }
    var editLabel: String { "Edit Beat, \(identity)" }
    var deleteLabel: String { "Delete Beat, \(identity)" }
    var confirmDeleteLabel: String { "Confirm delete, \(identity)" }
    var keepLabel: String { "Keep Beat, \(identity)" }
}

struct SidebarBeatsPanel: View {
    let controller: SidebarBeatsController
    let targets: [SidebarBeatTarget]
    let close: () -> Void
    @State private var mode: SidebarBeatsMode

    init(controller: SidebarBeatsController, targets: [SidebarBeatTarget], mode: SidebarBeatsMode = .list,
         close: @escaping () -> Void) {
        self.controller = controller; self.targets = targets; self.close = close
        _mode = State(initialValue: mode)
    }
    @State private var pendingDelete: String?
    @State private var actionError: String?
    @Environment(SidebarPreferences.self) private var preferences: SidebarPreferences?

    private var scope: UUID? { controller.scopedSession }
    private var scopeRunning: Bool { scope.map { id in targets.contains { $0.id == id } } ?? true }
    private var scopeTitle: String? {
        scope.map { id in targets.first { $0.id == id }?.title ?? SidebarBeatsCopy.sessionTitle(id.uuidString.lowercased()) }
    }
    private var visibleBeats: [SidebarBeat] {
        guard let scope else { return controller.beats }
        let id = scope.uuidString.lowercased()
        return controller.beats.filter { $0.sessionId == id }
    }
    /// A scoped panel creates Beats only for its own session, which must be running to be a target.
    static func newBeatUnavailable(scope: UUID?, targets: [SidebarBeatTarget]) -> String? {
        if let scope { return targets.contains { $0.id == scope } ? nil : "Start this agent's session to add a Beat." }
        return targets.isEmpty ? "Open an agent session to target it." : nil
    }
    private var newBeatUnavailable: String? { Self.newBeatUnavailable(scope: scope, targets: targets) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                Text("Beats").font(.headline)
                Spacer()
                if mode == .list {
                    Button { mode = .form(nil) } label: {
                        Image(systemName: "plus").font(.callout.weight(.medium))
                            .frame(width: SidebarPresentation.minimumControlSize, height: SidebarPresentation.minimumControlSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(newBeatUnavailable != nil)
                    .help(newBeatUnavailable ?? SidebarBeatsCopy.newBeat)
                    .accessibilityLabel(SidebarBeatsCopy.newBeat)
                    .accessibilityHint(newBeatUnavailable ?? "")
                    .accessibilityIdentifier("sidebar-beats-new")
                }
                SidebarCloseButton(label: "Close Beats", id: "sidebar-close-beats", action: close)
            }
            if let scopeTitle {
                HStack(spacing: 4) {
                    Text("For \(scopeTitle)").font(.caption.weight(.semibold)).lineLimit(1)
                        .accessibilityIdentifier("sidebar-beats-scope")
                    if !scopeRunning { SidebarBeatNotRunning() }
                    Spacer(minLength: 0)
                    if mode.offersShowAll {
                        Button("Show all") { controller.showAll() }
                            .buttonStyle(.borderless).font(.caption)
                            .help("Show Beats for every session.")
                            .accessibilityIdentifier("sidebar-beats-show-all")
                    }
                }
                if let preferences, let scope { SidebarTagList(tags: preferences.tags(for: scope)) }
            }
            if let notice = controller.notice ?? actionError {
                Text(notice).font(.caption).foregroundStyle(SidebarTone.attention.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch mode {
            case .list:
                BeatsList(controller: controller, beats: visibleBeats, targets: targets, scoped: scope != nil,
                          pendingDelete: $pendingDelete, actionError: $actionError, edit: { mode = .form($0) })
            case .form(let existing):
                BeatsForm(controller: controller, targets: targets, existing: existing, preferred: scope) { mode = .list }
            }
        }
        .padding(12)
        .frame(width: 340)
        .onChange(of: scope) { _, _ in mode = mode.afterScopeChange(); pendingDelete = nil }
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

/// Hollow slashed circle for a session that is not running; the fact is in its tooltip and label.
struct SidebarBeatNotRunning: View {
    var body: some View {
        Image(systemName: "circle.slash").font(.caption2).foregroundStyle(.secondary)
            .help("\(SidebarBeatsCopy.notRunning). \(SidebarBeatsCopy.firesOnlyWhileRunning)")
            .accessibilityLabel(SidebarBeatsCopy.notRunning)
    }
}

private struct BeatsList: View {
    let controller: SidebarBeatsController
    let beats: [SidebarBeat]
    let targets: [SidebarBeatTarget]
    let scoped: Bool
    @Binding var pendingDelete: String?
    @Binding var actionError: String?
    let edit: (SidebarBeat) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                if beats.isEmpty {
                    Text(SidebarBeatsCopy.empty).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                ForEach(beats) { beat in
                    BeatRow(controller: controller, beat: beat, target: targets.first { $0.id.uuidString.lowercased() == beat.sessionId },
                            scoped: scoped, pendingDelete: $pendingDelete, actionError: $actionError, edit: edit)
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
    let scoped: Bool
    @Binding var pendingDelete: String?
    @Binding var actionError: String?
    let edit: (SidebarBeat) -> Void

    // No estimate for a session that is not running: the Beat cannot fire there.
    private var nextFire: Date? {
        guard beat.enabled, target != nil, let spec = try? BeatsCron(beat.cron) else { return nil }
        return spec.nextTimes(after: Date(), count: 1).first
    }

    private var model: SidebarBeatRowModel { .init(beat: beat, target: target, scoped: scoped, next: nextFire) }

    private var isOn: Binding<Bool> {
        Binding(get: { beat.enabled }, set: { on in
            actionError = controller.perform { on ? try $0.enable(id: beat.id) : try $0.disable(id: beat.id) }
        })
    }

    private static let target = SidebarPresentation.minimumControlSize

    var body: some View {
        let model = model
        HStack(spacing: 4) {
            Toggle(SidebarBeatsCopy.toggle, isOn: isOn)
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .frame(minWidth: Self.target, minHeight: Self.target).contentShape(Rectangle())
                .help(beat.enabled ? "On" : "Off")
                .accessibilityLabel(model.toggleLabel)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Group {
                        if model.isPreset {
                            Text(model.schedule).font(.caption.weight(.semibold))
                        } else {
                            Text(model.schedule).font(.system(.caption, design: .monospaced))
                        }
                    }
                    .layoutPriority(1)
                    if let session = model.session {
                        Text(session).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    if !model.running { SidebarBeatNotRunning() }
                }
                .lineLimit(1)
                Text(model.prompt).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            .padding(.leading, 4)
            .opacity(beat.enabled ? 1 : 0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(model.summary)
            .accessibilityValue(model.status)
            .help(model.detail)
            if pendingDelete == beat.id {
                Button("Delete", role: .destructive) {
                    actionError = controller.perform { try $0.delete(id: beat.id) }
                    pendingDelete = nil
                }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(SidebarTone.attention.color)
                .frame(minHeight: Self.target).contentShape(Rectangle())
                .help("Delete this Beat")
                .accessibilityLabel(model.confirmDeleteLabel)
                Button("Keep") { pendingDelete = nil }.buttonStyle(.borderless).font(.caption)
                    .frame(minHeight: Self.target).contentShape(Rectangle())
                    .accessibilityLabel(model.keepLabel)
            } else {
                Button { edit(beat) } label: {
                    Image(systemName: "pencil").frame(width: Self.target, height: Self.target).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).help("Edit").accessibilityLabel(model.editLabel)
                Button { pendingDelete = beat.id } label: {
                    Image(systemName: "trash").frame(width: Self.target, height: Self.target).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).help("Delete").accessibilityLabel(model.deleteLabel)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        .contextMenu {
            Button("Edit") { edit(beat) }
            Button(beat.enabled ? "Disable" : "Enable") { isOn.wrappedValue.toggle() }
            Button("Delete", role: .destructive) { pendingDelete = beat.id }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct BeatsForm: View {
    let controller: SidebarBeatsController
    let targets: [SidebarBeatTarget]
    let existing: SidebarBeat?
    let done: () -> Void
    @State private var session: UUID?
    /// A new Beat from a scoped panel targets only that panel's session.
    private let lockedSession: UUID?
    @State private var cron: String
    @State private var prompt: String
    @State private var error: String?
    @State private var note: (text: String, help: String)?
    /// The stored Beat this edit is based on; "Load latest" moves it forward and keeps the draft.
    @State private var base: SidebarBeat?
    @State private var conflict = false

    init(controller: SidebarBeatsController, targets: [SidebarBeatTarget], existing: SidebarBeat?, preferred: UUID? = nil,
         done: @escaping () -> Void) {
        self.controller = controller; self.targets = targets; self.existing = existing; self.done = done
        _base = State(initialValue: existing)
        let preferredTarget = preferred.flatMap { id in targets.first { $0.id == id }?.id }
        lockedSession = existing == nil ? preferredTarget : nil
        _session = State(initialValue: existing.flatMap { UUID(uuidString: $0.sessionId) } ?? preferredTarget ?? targets.first?.id)
        _cron = State(initialValue: existing?.cron ?? "0 9 * * 1-5")
        _prompt = State(initialValue: existing?.prompt ?? "")
    }

    private var parsed: Result<BeatsCron, BeatsError> {
        do { return .success(try BeatsCron(cron)) } catch let error as BeatsError { return .failure(error) } catch { return .failure(BeatsError("Invalid cron.")) }
    }

    private var preview: (caption: String, detail: String)? {
        guard case .success(let spec) = parsed else { return nil }
        return SidebarBeatsCopy.preview(spec.nextTimes(after: Date(), count: 3))
    }

    private var targetOptions: [SidebarBeatTarget] {
        if let lockedSession { return targets.filter { $0.id == lockedSession } }
        var options = targets
        if let existing, let id = UUID(uuidString: existing.sessionId), !options.contains(where: { $0.id == id }) {
            options.append(.init(id: id, title: SidebarBeatsCopy.sessionTitle(existing.sessionId), live: false))
        }
        return options
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(existing == nil ? "New Beat" : "Edit Beat").font(.subheadline.weight(.semibold))
            Picker("Session", selection: $session) {
                ForEach(targetOptions) { option in
                    Group {
                        if option.live { Text(option.title) } else { Label(option.title, systemImage: "circle.slash") }
                    }
                    .accessibilityLabel(option.live ? option.title : "\(option.title), \(SidebarBeatsCopy.notRunning)")
                    .tag(Optional(option.id))
                }
            }
            .disabled(lockedSession != nil)
            .help(lockedSession != nil ? SidebarBeatsCopy.lockedHelp : "")
            .accessibilityIdentifier("sidebar-beats-target")
            HStack {
                TextField("Cron", text: $cron, prompt: Text("min hour day month weekday"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced))
                    .help(SidebarBeatsCopy.timing)
                    .accessibilityLabel("Cron")
                    .accessibilityHint(SidebarBeatsCopy.timing)
                    .accessibilityIdentifier("sidebar-beats-cron")
                Menu("Presets") {
                    ForEach(SidebarBeatsCopy.presets, id: \.cron) { preset in Button(preset.label) { cron = preset.cron } }
                }
                .fixedSize()
            }
            if case .failure(let failure) = parsed {
                Text(SidebarBeatsCopy.invalidCron).font(.caption2).foregroundStyle(SidebarTone.attention.color)
                    .help(failure.message).accessibilityLabel(failure.message)
            } else if let preview {
                Text(preview.caption).font(.caption2).foregroundStyle(.secondary)
                    .help(preview.detail).accessibilityLabel(preview.detail)
            }
            TextEditor(text: $prompt)
                .font(.caption).frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
                .accessibilityLabel("Prompt")
                .accessibilityIdentifier("sidebar-beats-prompt")
            if let counter = SidebarBeatsCopy.byteCounter(prompt.utf8.count) {
                Text(counter).font(.caption2).monospacedDigit()
                    .foregroundStyle(prompt.utf8.count > BeatsLimits.maximumPromptBytes ? SidebarTone.attention.color : .secondary)
                    .help("Prompt size in bytes; the limit is \(BeatsLimits.maximumPromptBytes).")
                    .accessibilityLabel("Prompt \(prompt.utf8.count) of \(BeatsLimits.maximumPromptBytes) bytes")
            }
            if conflict {
                HStack(spacing: 6) {
                    Text(SidebarBeatsCopy.changedElsewhere).font(.caption).foregroundStyle(SidebarTone.attention.color)
                        .help(BeatsError.changedElsewhere.message).accessibilityLabel(BeatsError.changedElsewhere.message)
                    Button("Load latest") { loadLatest() }
                        .help(SidebarBeatsCopy.loadLatestHelp)
                        .accessibilityHint(SidebarBeatsCopy.loadLatestHelp)
                        .accessibilityIdentifier("sidebar-beats-load-latest")
                }
            } else if let error {
                Text(error).font(.caption).foregroundStyle(SidebarTone.attention.color)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let note {
                Text(note.text).font(.caption).foregroundStyle(.secondary)
                    .help(note.help).accessibilityLabel(note.help)
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
        note = nil
        if let failure { error = failure } else { done() }
    }

    private func loadLatest() {
        controller.refresh()
        guard let latest = controller.beats.first(where: { $0.id == existing?.id }) else {
            error = SidebarBeatsCopy.deleted
            conflict = false
            return
        }
        base = latest
        error = nil
        note = (SidebarBeatsCopy.latestLoaded, SidebarBeatsCopy.latestLoadedHelp)
        conflict = false
    }
}

// MARK: - Agent row Beat indicator

enum SidebarBeatIndicatorState: Equatable {
    /// No enabled Beat targets the session.
    case none
    /// Enabled Beats, but the session is not known to be running, so none can fire (ADR 0007).
    case dim
    /// Enabled Beats on a session currently observed running.
    case lit
}

/// Row-facing Beat state: the store summary joined with current liveness. Equatable, so it is
/// republished only when something a row shows changes.
struct SidebarBeatIndicators: Equatable {
    var summaries = SidebarBeatSummaries.empty
    var running: Set<UUID> = []
    var ended: Set<UUID> = []

    init(summaries: SidebarBeatSummaries = .empty, running: Set<UUID> = [], ended: Set<UUID> = []) {
        self.summaries = summaries; self.running = running; self.ended = ended
    }

    /// Running means alive (the Beats panel's target liveness) in a current observation
    /// (`SidebarCopilotTree.isCurrent`, as hover cards use). Stale, hidden or disconnected trees
    /// leave every session "not known to be running".
    init(summaries: SidebarBeatSummaries, tree: SidebarCopilotTree, now: Date) {
        let current = tree.sessions.filter { summaries.sessions[$0.id] != nil && tree.isCurrent($0, now: now) }
        self.init(summaries: summaries,
                  running: Set(current.filter { $0.liveness == .alive }.map(\.id)),
                  ended: Set(current.filter { $0.liveness == .dead }.map(\.id)))
    }

    /// The sessions the Beats panel offers as targets.
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

/// The lit icon's glow: a Core Animation opacity pulse in the render server, about 1 second each way.
enum SidebarBeatGlow {
    static let animationKey = "sidebar-beat-glow"
    static let halfPeriod: CFTimeInterval = 1
    static let dimmest: Float = 0.35
    static let brightest: Float = 1
    static let staticIntensity: Float = 0.8

    static func animates(_ state: SidebarBeatIndicatorState, reduceMotion: Bool, visible: Bool) -> Bool {
        state == .lit && !reduceMotion && visible
    }
}

private struct SidebarBeatsControllerKey: EnvironmentKey {
    static let defaultValue: SidebarBeatsController? = nil
}

extension EnvironmentValues {
    /// The Beats store controller, for row icons. Nil (no icons) where Beats are not shown, such as previews.
    var sidebarBeats: SidebarBeatsController? {
        get { self[SidebarBeatsControllerKey.self] }
        set { self[SidebarBeatsControllerKey.self] = newValue }
    }

    /// The sidebar window a row's Beat icon opens the panel in.
    var sidebarBeatsPresenter: ObjectIdentifier? {
        get { self[SidebarBeatsPresenterKey.self] }
        set { self[SidebarBeatsPresenterKey.self] = newValue }
    }
}

private struct SidebarBeatsPresenterKey: EnvironmentKey {
    static let defaultValue: ObjectIdentifier? = nil
}

/// Trailing Beat icon on a row that represents exactly one Copilot session.
struct SidebarBeatIndicator: View {
    static let symbol = SidebarHeaderAction.beats.symbol
    static let accessibilityLabel = "Beats for this agent"
    static let width: CGFloat = 20
    let session: UUID?
    let titleHeight: CGFloat
    /// Space under the title line, so the icon centres on the title rather than the whole row.
    var belowTitle: CGFloat = 0
    @Environment(\.sidebarBeats) private var controller
    @Environment(\.sidebarBeatsPresenter) private var presenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @MainActor private static var titleHeights: [Double: CGFloat] = [:]

    /// One semibold system-font line, measured once per size.
    @MainActor static func titleHeight(fontSize: Double) -> CGFloat {
        if let height = titleHeights[fontSize] { return height }
        let height = ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: fontSize, weight: .semibold)))
        titleHeights[fontSize] = height
        return height
    }

    var body: some View {
        if let controller, let session {
            let indicators = controller.indicators
            let state = indicators.state(for: session)
            if state != .none {
                SidebarBeatButton(
                    state: state, reduceMotion: reduceMotion, titleHeight: titleHeight,
                    value: indicators.accessibilityValue(for: session), help: indicators.help(for: session),
                    action: { [weak controller, presenter] in controller?.present(scope: session, from: presenter) }
                )
                .frame(width: Self.width, height: titleHeight + belowTitle)
            }
        }
    }
}

/// Layer-hosting view for the glow, so its layer tree is ours and AppKit never redraws it.
final class SidebarBeatGlowView: NSView {
    let glowLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        layer = root
        wantsLayer = true
        glowLayer.shadowOffset = .zero
        glowLayer.shadowRadius = 3
        glowLayer.shadowOpacity = 1
        // The blurred shadow is rasterized once; the pulse only changes the layer's opacity.
        glowLayer.shouldRasterize = true
        glowLayer.opacity = 0
        root.addSublayer(glowLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Vertically centred in this view, which spans only the title line, so layer flipping cannot move it.
    func place(x: CGFloat, size: CGSize) {
        glowLayer.frame = CGRect(x: x, y: ((bounds.height - size.height) / 2).rounded(),
                                 width: size.width, height: size.height)
    }
}

/// Draws the Beat glyph and drives its glow. The pulse is one `CABasicAnimation` on the glow
/// layer's opacity, run by the render server and attached only while lit, motion is allowed and
/// the view is in a window and not hidden.
final class SidebarBeatGlyphView: NSView {
    let glowView = SidebarBeatGlowView()
    var glowLayer: CALayer { glowView.glowLayer }
    var state = SidebarBeatIndicatorState.none {
        didSet { if state != oldValue { needsDisplay = true; refreshGlow() } }
    }
    var reduceMotion = false { didSet { if reduceMotion != oldValue { updateAnimation() } } }
    var titleHeight: CGFloat = 14 { didSet { if titleHeight != oldValue { needsLayout = true; needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var animates: Bool {
        SidebarBeatGlow.animates(state, reduceMotion: reduceMotion, visible: window != nil && !isHiddenOrHasHiddenAncestor)
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshGlow() }
    override func viewDidHide() { super.viewDidHide(); updateAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateAnimation() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); refreshGlow() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshGlow() }

    var glyphRect: CGRect {
        let size = Self.symbolSize
        // Inset from the row's trailing content edge (owner pilot: flush was too tight).
        return CGRect(x: max(0, bounds.width - size.width - Self.trailingInset).rounded(.down),
                      y: ((titleHeight - size.height) / 2).rounded(),
                      width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard state != .none else { return }
        let color = state == .lit ? NSColor.controlAccentColor : NSColor.secondaryLabelColor.withAlphaComponent(0.55)
        Self.symbol(color)?.draw(in: glyphRect)
    }

    override func layout() {
        super.layout()
        if let superview {
            glowView.frame = convert(CGRect(x: 0, y: 0, width: bounds.width, height: titleHeight), to: superview)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowView.place(x: glyphRect.minX, size: Self.symbolSize)
        CATransaction.commit()
    }

    private func refreshGlow() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        var glow: CGImage?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            glow = state == .lit ? Self.image(.controlAccentColor, scale: scale) : nil
            glowLayer.shadowColor = NSColor.controlAccentColor.cgColor
        }
        glowLayer.contents = glow
        glowLayer.contentsScale = scale
        glowLayer.rasterizationScale = scale
        glowView.place(x: glyphRect.minX, size: Self.symbolSize)
        CATransaction.commit()
        updateAnimation()
    }

    private func updateAnimation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animates {
            if glowLayer.animation(forKey: SidebarBeatGlow.animationKey) == nil {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = SidebarBeatGlow.dimmest
                pulse.toValue = SidebarBeatGlow.brightest
                pulse.duration = SidebarBeatGlow.halfPeriod
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                glowLayer.add(pulse, forKey: SidebarBeatGlow.animationKey)
            }
            glowLayer.opacity = SidebarBeatGlow.dimmest
        } else {
            glowLayer.removeAnimation(forKey: SidebarBeatGlow.animationKey)
            glowLayer.opacity = state == .lit ? SidebarBeatGlow.staticIntensity : 0
        }
        CATransaction.commit()
    }

    private static let symbolSize = symbol(.black)?.size ?? .zero
    static let trailingInset: CGFloat = 8

    private static func symbol(_ color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: SidebarBeatIndicator.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    private static func image(_ color: NSColor, scale: CGFloat) -> CGImage? {
        guard let symbol = symbol(color) else { return nil }
        let size = symbol.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        symbol.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}

/// Native button over the glyph, so a click never reaches the row's title button.
final class SidebarBeatNativeButton: NSButton {
    var activate: (() -> Void)?
    let glyph = SidebarBeatGlyphView()

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        imagePosition = .noImage
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        target = self
        action = #selector(press)
        // The glow sits behind the drawn glyph.
        addSubview(glyph.glowView)
        addSubview(glyph)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        glyph.frame = bounds
    }

    @objc private func press() { activate?() }

    // Without a title or image AppKit reports an unknown role; this is a button.
    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let activate else { return false }
        activate()
        return true
    }
}

struct SidebarBeatButton: NSViewRepresentable {
    let state: SidebarBeatIndicatorState
    let reduceMotion: Bool
    let titleHeight: CGFloat
    let value: String
    let help: String
    let action: () -> Void

    func makeNSView(context: Context) -> SidebarBeatNativeButton { SidebarBeatNativeButton() }

    func updateNSView(_ button: SidebarBeatNativeButton, context: Context) {
        button.activate = action
        button.glyph.titleHeight = titleHeight
        button.glyph.state = state
        button.glyph.reduceMotion = reduceMotion
        button.toolTip = help
        button.setAccessibilityLabel(SidebarBeatIndicator.accessibilityLabel)
        button.setAccessibilityValue(value)
        button.setAccessibilityHelp(help)
        button.setAccessibilityIdentifier("sidebar-beat-indicator")
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SidebarBeatNativeButton, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: SidebarBeatIndicator.width, height: 20))
    }
}
