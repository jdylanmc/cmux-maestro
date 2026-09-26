import SwiftUI

struct SidebarHoverCardData: Equatable {
    let id: String
    let category: String
    let title: String
    var subtitle: String? = nil
    var lines: [SidebarDetailLine] = []
    var notice: String? = nil
}

struct SidebarHoverCard: View {
    let data: SidebarHoverCardData
    let close: () -> Void
    let copySessionID: (UUID) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(data.category).font(.caption).foregroundStyle(.secondary)
                    Text(data.title).font(.headline).lineLimit(3)
                }
                Spacer(minLength: 0)
                SidebarPreviewCloseButton(close: close).frame(width: 24, height: 24)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let subtitle = data.subtitle {
                        Text(subtitle).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(data.lines) { line in
                        if let sessionID = line.copyableSessionID {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.title).font(.caption).foregroundStyle(.secondary)
                                SidebarCopyableValue(value: line.value, label: line.title) {
                                    copySessionID(sessionID)
                                }
                                .id(sessionID)
                            }
                            .accessibilityElement(children: .contain)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.title).foregroundStyle(.secondary)
                                Text(line.value).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.caption)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    if let notice = data.notice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Preview only").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hover-card-\(data.id)")
    }
}

private struct SidebarPreviewCloseButton: NSViewRepresentable {
    let close: () -> Void
    func makeNSView(context: Context) -> SidebarPreviewCloseNativeButton { SidebarPreviewCloseNativeButton() }
    func updateNSView(_ button: SidebarPreviewCloseNativeButton, context: Context) { button.closePreview = close }
}

private final class SidebarPreviewCloseNativeButton: NSButton {
    var closePreview: () -> Void = {}
    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        target = self
        action = #selector(closeCard)
        toolTip = "Close preview"
        setAccessibilityLabel("Close preview")
        setAccessibilityIdentifier("hover-close")
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor && window != nil }
    @objc private func closeCard() { closePreview() }
}

enum SidebarHoverPlacement {
    static func frame(anchor: CGRect, visible: CGRect, preferred: CGSize) -> CGRect {
        let area = visible.insetBy(dx: 8, dy: 8)
        let size = CGSize(width: min(preferred.width, max(1, area.width)),
                          height: min(preferred.height, max(1, area.height)))
        let right = anchor.maxX + 6
        let left = anchor.minX - size.width - 6
        let x = right + size.width <= area.maxX ? right : left
        return CGRect(
            x: min(max(x, area.minX), area.maxX - size.width),
            y: min(max(anchor.maxY - size.height, area.minY), area.maxY - size.height),
            width: size.width, height: size.height
        )
    }
}

struct SidebarHoverState {
    enum Mode { case hidden, hover, keyboard, explicit }
    private(set) var mode: Mode = .hidden
    private(set) var overAnchor = false
    private(set) var overCard = false
    private var suppressed = false

    mutating func anchor(_ inside: Bool) {
        overAnchor = inside
        if !inside { suppressed = false }
    }
    mutating func card(_ inside: Bool) { overCard = inside }
    var shouldOpen: Bool { mode == .hidden && overAnchor && !suppressed }
    var shouldClose: Bool { mode == .hover && !overAnchor && !overCard }
    mutating func open(explicit: Bool) { mode = explicit ? .explicit : .hover }
    mutating func keyboard() { mode = .keyboard }
    mutating func dismiss() {
        mode = .hidden
        overCard = false
        suppressed = overAnchor
    }
}

@MainActor
final class SidebarHoverGroup {
    private weak var active: SidebarHoverPresenter?

    func claim(_ presenter: SidebarHoverPresenter, explicit: Bool) -> Bool {
        if let active, active !== presenter {
            guard explicit || active.state.mode != .explicit else { return false }
            active.dismiss(restoreFocus: false)
        }
        active = presenter
        return true
    }
}

private struct SidebarHoverGroupKey: EnvironmentKey {
    static let defaultValue: SidebarHoverGroup? = nil
}

private struct SidebarHoverConnectedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var sidebarHoverConnected: Bool {
        get { self[SidebarHoverConnectedKey.self] }
        set { self[SidebarHoverConnectedKey.self] = newValue }
    }
    var sidebarHoverGroup: SidebarHoverGroup? {
        get { self[SidebarHoverGroupKey.self] }
        set { self[SidebarHoverGroupKey.self] = newValue }
    }
}

final class SidebarHoverPanel: NSPanel {
    var allowsKeyboard = false
    override var canBecomeKey: Bool { allowsKeyboard }
    override var canBecomeMain: Bool { false }

    @discardableResult
    func focusControls() -> Bool {
        contentView?.layoutSubtreeIfNeeded()
        guard allowsKeyboard, let first = keyboardControls.first else { return false }
        return makeFirstResponder(first)
    }

    override func selectNextKeyView(_ sender: Any?) {
        let controls = keyboardControls
        guard allowsKeyboard, !controls.isEmpty else { super.selectNextKeyView(sender); return }
        let index = controls.firstIndex { $0 === firstResponder }.map { ($0 + 1) % controls.count } ?? 0
        controls[index].scrollToVisible(controls[index].bounds)
        makeFirstResponder(controls[index])
    }

    private var keyboardControls: [NSButton] {
        func visit(_ view: NSView) -> [NSButton] {
            if let button = view as? NSButton,
               ["hover-close", "hover-copy-value"].contains(button.accessibilityIdentifier()),
               button.canBecomeKeyView { return [button] }
            return view.subviews.flatMap(visit)
        }
        return contentView.map(visit) ?? []
    }
}

enum SidebarSessionCopy {
    static func copy(_ id: UUID, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(id.uuidString, forType: .string)
    }
}

@MainActor
final class SidebarHoverPresenter {
    private(set) var state = SidebarHoverState()
    private(set) var panel: SidebarHoverPanel?
    private weak var anchor: NSView?
    private weak var originalResponder: NSResponder?
    private weak var keyboardOrigin: NSResponder?
    private weak var parentWindow: NSWindow?
    private var data: SidebarHoverCardData?
    private var group: SidebarHoverGroup?
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var eventMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []
    private var hosting: NSHostingView<AnyView>?
    private let copySessionID: (UUID) -> Bool
    private let showPanel: (NSWindow, SidebarHoverPanel, Bool) -> Void
    var isMonitoring: Bool { eventMonitor != nil || !windowObservers.isEmpty }

    init(copySessionID: @escaping (UUID) -> Bool = { SidebarSessionCopy.copy($0) },
         showPanel: @escaping (NSWindow, SidebarHoverPanel, Bool) -> Void = { window, panel, explicit in
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        if explicit { panel.makeKey() }
    }) {
        self.copySessionID = copySessionID
        self.showPanel = showPanel
    }

    func update(anchor: NSView, data: SidebarHoverCardData?, group: SidebarHoverGroup?) {
        self.anchor = anchor
        self.group = group
        if self.data?.id != data?.id { dismiss(restoreFocus: false) }
        let changed = self.data != data
        self.data = data
        guard data != nil else { dismiss(restoreFocus: true); return }
        if state.mode != .hidden {
            if changed { updateContent() }
            position()
        }
    }

    func hoverAnchor(_ inside: Bool, nameOnly: Bool = false) {
        state.anchor(inside)
        openTask?.cancel()
        if !inside && state.mode == .hidden {
            dismiss(restoreFocus: false)
            return
        }
        if !inside && nameOnly && state.mode == .hover {
            dismiss(restoreFocus: false)
            return
        }
        if state.shouldOpen {
            if data != nil, let window = anchor?.window { installObservers(window: window) }
            openTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                guard let self, self.state.shouldOpen else { return }
                self.open(explicit: false)
            }
        }
        scheduleClose()
    }

    func rememberKeyboardOrigin(_ responder: NSResponder) { keyboardOrigin = responder }

    func keyboardFocus(_ focused: Bool) {
        if focused {
            open(explicit: false)
            if state.mode == .hover { state.keyboard() }
        } else if state.mode == .keyboard {
            dismiss(restoreFocus: false)
        }
    }

    func enterFromKeyboard() -> Bool {
        guard data != nil else { return false }
        open(explicit: true)
        guard state.mode == .explicit else { return false }
        return panel?.focusControls() == true
    }

    func hoverCard(_ inside: Bool) {
        state.card(inside)
        scheduleClose()
    }

    private func scheduleClose() {
        closeTask?.cancel()
        guard state.shouldClose else { return }
        closeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, self.state.shouldClose else { return }
            self.dismiss(restoreFocus: false)
        }
    }

    func open(explicit: Bool) {
        guard data != nil, let anchor, let window = anchor.window,
              !anchor.visibleRect.isEmpty, window.screen != nil,
              group?.claim(self, explicit: explicit) != false else { return }
        openTask?.cancel()
        closeTask?.cancel()
        if state.mode == .hidden {
            parentWindow = window
            originalResponder = window.firstResponder
        }
        if explicit { originalResponder = keyboardOrigin ?? window.firstResponder }
        state.open(explicit: explicit)
        let panel = panel ?? SidebarHoverPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        self.panel = panel
        panel.allowsKeyboard = explicit
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = anchor.effectiveAppearance
        updateContent()
        position()
        showPanel(window, panel, explicit)
        installObservers(window: window)
    }

    private func updateContent() {
        guard let panel, let data else { return }
        let content = SidebarHoverCard(
            data: data, close: { [weak self] in self?.dismiss(restoreFocus: true) },
            copySessionID: copySessionID
        )
            .onHover { [weak self] in self?.hoverCard($0) }
        if let hosting {
            hosting.rootView = AnyView(content)
            return
        }
        let hosting = NSHostingView(rootView: AnyView(content))
        self.hosting = hosting
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        panel.contentView = effect
    }

    func position() {
        guard state.mode != .hidden, let anchor, let window = anchor.window,
              window === parentWindow, let screen = window.screen,
              !anchor.visibleRect.isEmpty else {
            if state.mode != .hidden { dismiss(restoreFocus: false) }
            return
        }
        let rectangle = window.convertToScreen(anchor.convert(anchor.bounds.intersection(anchor.visibleRect), to: nil))
        panel?.appearance = anchor.effectiveAppearance
        panel?.setFrame(SidebarHoverPlacement.frame(
            anchor: rectangle, visible: screen.visibleFrame,
            preferred: CGSize(width: 300, height: (data?.lines.count ?? 0) > 3 ? 360 : 260)
        ), display: true)
    }

    private func installObservers(window: NSWindow) {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 || (event.keyCode == 48 && event.modifierFlags.contains(.shift)
                                          && self.state.mode == .explicit && event.window === self.panel) {
                    let owned = self.state.mode == .explicit && event.window === self.panel
                    self.dismiss(restoreFocus: owned)
                    return owned ? nil : event
                }
                if self.state.mode == .hover { self.dismiss(restoreFocus: false) }
            } else if event.window !== self.panel {
                self.dismiss(restoreFocus: false)
            }
            return event
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.position() }
            })
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss(restoreFocus: false) }
            })
        }
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restoreFocus: false) }
        })
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restoreFocus: false) }
        })
    }

    func dismiss(restoreFocus: Bool) {
        let restore = restoreFocus && state.mode == .explicit && panel?.isKeyWindow == true
        openTask?.cancel()
        closeTask?.cancel()
        state.dismiss()
        if let panel {
            parentWindow?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
            hosting = nil
        }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        if restore, let originalResponder, let parentWindow {
            parentWindow.makeKey()
            parentWindow.makeFirstResponder(originalResponder)
        }
        keyboardOrigin = nil
    }

    func detach() {
        dismiss(restoreFocus: false)
        anchor = nil
        data = nil
    }
}

final class SidebarHoverAnchorView: NSView {
    weak var presenter: SidebarHoverPresenter?
    var tracksName = false { didSet { updateTrackingAreas() } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        if tracksName {
            addTrackingArea(NSTrackingArea(
                rect: bounds.intersection(visibleRect), options: [.activeInActiveApp, .mouseEnteredAndExited],
                owner: self
            ))
        }
    }
    override func mouseEntered(with event: NSEvent) { presenter?.hoverAnchor(true, nameOnly: true) }
    override func mouseExited(with event: NSEvent) { presenter?.hoverAnchor(false, nameOnly: true) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { presenter?.detach() }
    }
    override func layout() { super.layout(); updateTrackingAreas(); presenter?.position() }
}

private struct SidebarHoverAnchor: NSViewRepresentable {
    let presenter: SidebarHoverPresenter
    let data: SidebarHoverCardData?
    let group: SidebarHoverGroup?
    var tracksName = false

    func makeNSView(context: Context) -> SidebarHoverAnchorView {
        let view = SidebarHoverAnchorView()
        view.presenter = presenter
        return view
    }
    func updateNSView(_ view: SidebarHoverAnchorView, context: Context) {
        view.tracksName = tracksName
        presenter.update(anchor: view, data: data, group: group)
    }
    static func dismantleNSView(_ view: SidebarHoverAnchorView, coordinator: ()) { view.presenter?.detach() }
}

struct SidebarHoverRegion<Content: View>: View {
    let data: SidebarHoverCardData?
    var nameOnly = false
    @ViewBuilder let content: () -> Content
    @State private var presenter = SidebarHoverPresenter()
    @Environment(\.sidebarHoverGroup) private var group

    var body: some View {
        content()
            .environment(\.sidebarPreviewInteraction, .init(
                available: data != nil,
                focus: { presenter.keyboardFocus($0) },
                enter: { presenter.enterFromKeyboard() },
                origin: { presenter.rememberKeyboardOrigin($0) },
                dismiss: { presenter.dismiss(restoreFocus: false) }
            ))
            .environment(\.sidebarNamePreview, nameOnly ? .init(presenter: presenter, data: data, group: group) : nil)
            .background {
                if !nameOnly { SidebarHoverAnchor(presenter: presenter, data: data, group: group) }
            }
            .onHover { if !nameOnly { presenter.hoverAnchor($0) } }
            .onDisappear { presenter.detach() }
    }
}

struct SidebarPreviewInteraction {
    var available = false
    var focus: (Bool) -> Void = { _ in }
    var enter: () -> Bool = { false }
    var origin: (NSResponder) -> Void = { _ in }
    var dismiss: () -> Void = {}
}

private struct SidebarPreviewInteractionKey: EnvironmentKey {
    static let defaultValue = SidebarPreviewInteraction()
}

private struct SidebarNamePreview {
    let presenter: SidebarHoverPresenter
    let data: SidebarHoverCardData?
    let group: SidebarHoverGroup?
}

private struct SidebarNamePreviewKey: EnvironmentKey {
    static let defaultValue: SidebarNamePreview? = nil
}

extension EnvironmentValues {
    var sidebarPreviewInteraction: SidebarPreviewInteraction {
        get { self[SidebarPreviewInteractionKey.self] }
        set { self[SidebarPreviewInteractionKey.self] = newValue }
    }
    fileprivate var sidebarNamePreview: SidebarNamePreview? {
        get { self[SidebarNamePreviewKey.self] }
        set { self[SidebarNamePreviewKey.self] = newValue }
    }
}

private struct SidebarNameHoverModifier: ViewModifier {
    @Environment(\.sidebarNamePreview) private var preview
    func body(content: Content) -> some View {
        content.background {
            if let preview {
                SidebarHoverAnchor(presenter: preview.presenter, data: preview.data, group: preview.group, tracksName: true)
            }
        }
    }
}

extension View {
    func sidebarNameHover() -> some View { modifier(SidebarNameHoverModifier()) }
}

/// The title is one native keyboard target; entering its preview never presses it.
final class SidebarTitleNativeButton: NSButton {
    let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    var labelContent = AnyView(EmptyView())
    var activate: () -> Void = {}
    var preview = SidebarPreviewInteraction()
    var showActions: (() -> Void)?
    var focusChanged: (Bool) -> Void = { _ in }
    private var returningFromPreview = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        target = self
        action = #selector(pressTitle)
        focusRingType = .exterior
        addSubview(hosting)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func pressTitle() { preview.dismiss(); activate() }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor && window != nil }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            focusChanged(true)
            if !returningFromPreview { preview.focus(true) }
            returningFromPreview = false
            needsDisplay = true
        }
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { preview.focus(false); focusChanged(false); needsDisplay = true }
        return result
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 && !event.modifierFlags.contains(.shift), enterPreview() { return }
        if event.keyCode == 53 { preview.dismiss(); return }
        if event.keyCode == 109 && event.modifierFlags.contains(.shift), let showActions {
            preview.dismiss()
            showActions()
            return
        }
        if event.keyCode == 36 || event.keyCode == 49 { performClick(nil); return }
        super.keyDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {}
    func enterPreview() -> Bool {
        preview.origin(self)
        returningFromPreview = preview.enter()
        return returningFromPreview
    }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func layout() {
        super.layout()
        hosting.frame = bounds
    }
    func measure(width proposedWidth: CGFloat?) -> CGSize {
        let width = proposedWidth.flatMap { $0.isFinite ? max(0, $0) : nil }
        hosting.rootView = AnyView(labelContent.frame(width: width, alignment: .leading))
        let size = hosting.fittingSize
        return CGSize(width: width ?? size.width, height: max(24, size.height))
    }
}

struct SidebarTitleButton<Label: View>: NSViewRepresentable {
    let label: String
    let hint: String
    var value = ""
    let action: () -> Void
    @ViewBuilder var content: Label
    @Environment(\.sidebarPreviewInteraction) private var preview
    @Environment(\.sidebarRowMenu) private var rowMenu

    func makeNSView(context: Context) -> SidebarTitleNativeButton { SidebarTitleNativeButton() }
    func updateNSView(_ button: SidebarTitleNativeButton, context: Context) {
        button.labelContent = AnyView(content.environment(\.self, context.environment))
        button.activate = action
        button.preview = preview
        button.showActions = rowMenu.map { menu in { menu.show() } }
        button.focusChanged = { rowMenu?.focusChanged($0) }
        rowMenu?.dismissPreview = preview.dismiss
        rowMenu?.preview = preview.available ? { [weak button] in button?.enterPreview() ?? false } : nil
        button.setAccessibilityLabel(label)
        button.setAccessibilityValue(value)
        button.setAccessibilityHelp(preview.available ? "\(hint). Tab enters preview controls; Escape or Shift-Tab returns. Shift-F10 opens actions." : hint)
        button.toolTip = hint
        _ = button.measure(width: button.bounds.width > 0 ? button.bounds.width : nil)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SidebarTitleNativeButton, context: Context) -> CGSize? {
        nsView.measure(width: proposal.width)
    }
}
