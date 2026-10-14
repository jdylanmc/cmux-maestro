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
    /// Whether the Beats panel is open, and the session it is scoped to. Presentation only.
    private(set) var isPresented = false
    private(set) var scopedSession: UUID?
    private(set) var notice: String?
    private let file: SidebarBeatsFile?
    private let now: () -> Date
    private var tree = SidebarCopilotTree.waiting

    init(file: SidebarBeatsFile? = .standard(), now: @escaping () -> Date = { Date() }) {
        self.file = file
        self.now = now
        refresh()
    }

    /// Opens the panel, or rescopes it in place when it is already open, so a second row's click
    /// never races a dismissal. `nil` shows every Beat.
    func present(scope: UUID?) {
        if scopedSession != scope { scopedSession = scope }
        if !isPresented { isPresented = true }
    }

    func showAll() { scopedSession = nil }

    func dismiss() {
        isPresented = false
        scopedSession = nil
    }

    /// Liveness for row icons. Called on every tree change; re-evaluated against the clock on each refresh.
    func updateLiveness(_ tree: SidebarCopilotTree) {
        self.tree = tree
        updateIndicators()
    }

    private func updateIndicators() {
        let next = SidebarBeatIndicators(summaries: summaries, tree: tree, now: now())
        if next != indicators { indicators = next }
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
    static func newBeatUnavailable(scope: UUID?, targets: [SidebarBeatTarget]) -> String? {
        if let scope { return targets.contains { $0.id == scope } ? nil : "Start this agent's session to add a Beat." }
        return targets.isEmpty ? "Open an agent session to target it." : nil
    }
    private var newBeatUnavailable: String? { Self.newBeatUnavailable(scope: scope, targets: targets) }

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
                    if mode.offersShowAll {
                        Button("Show all") { controller.showAll() }
                            .buttonStyle(.borderless).font(.caption)
                            .help("Show Beats for every session.")
                            .accessibilityIdentifier("sidebar-beats-show-all")
                    }
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
    /// A new Beat from a scoped panel targets only that panel's session.
    private let lockedSession: UUID?
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
        lockedSession = existing == nil ? preferredTarget : nil
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
        if let lockedSession { return targets.filter { $0.id == lockedSession } }
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
            .disabled(lockedSession != nil)
            .help(lockedSession != nil ? "This Beat is for this agent. Show all to target another session." : "")
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
                    action: { [weak controller] in controller?.present(scope: session) }
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
