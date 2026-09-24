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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(data.category).font(.caption).foregroundStyle(.secondary)
                    Text(data.title).font(.headline).lineLimit(3)
                }
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark").font(.caption)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close preview")
                .accessibilityIdentifier("hover-close")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let subtitle = data.subtitle {
                        Text(subtitle).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(data.lines) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.title).foregroundStyle(.secondary)
                            Text(line.value).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.caption)
                        .accessibilityElement(children: .combine)
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
    enum Mode { case hidden, hover, explicit }
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
}

@MainActor
final class SidebarHoverPresenter {
    private(set) var state = SidebarHoverState()
    private(set) var panel: SidebarHoverPanel?
    private weak var anchor: NSView?
    private weak var originalResponder: NSResponder?
    private weak var parentWindow: NSWindow?
    private var data: SidebarHoverCardData?
    private var group: SidebarHoverGroup?
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var eventMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []
    private var hosting: NSHostingView<AnyView>?

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

    func hoverAnchor(_ inside: Bool) {
        state.anchor(inside)
        openTask?.cancel()
        if state.shouldOpen {
            openTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                guard let self, self.state.shouldOpen else { return }
                self.open(explicit: false)
            }
        }
        scheduleClose()
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
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        if explicit { panel.makeKey() }
        installObservers(window: window)
    }

    private func updateContent() {
        guard let panel, let data else { return }
        let content = SidebarHoverCard(data: data, close: { [weak self] in self?.dismiss(restoreFocus: true) })
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
        let rectangle = window.convertToScreen(anchor.convert(anchor.visibleRect, to: nil))
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
                if event.keyCode == 53 {
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
            parentWindow.makeFirstResponder(originalResponder)
        }
    }

    func detach() {
        dismiss(restoreFocus: false)
        anchor = nil
        data = nil
    }
}

private final class SidebarHoverAnchorView: NSView {
    weak var presenter: SidebarHoverPresenter?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { presenter?.detach() }
    }
    override func layout() { super.layout(); presenter?.position() }
}

private struct SidebarHoverAnchor: NSViewRepresentable {
    let presenter: SidebarHoverPresenter
    let data: SidebarHoverCardData?
    let group: SidebarHoverGroup?

    func makeNSView(context: Context) -> SidebarHoverAnchorView {
        let view = SidebarHoverAnchorView()
        view.presenter = presenter
        return view
    }
    func updateNSView(_ view: SidebarHoverAnchorView, context: Context) {
        presenter.update(anchor: view, data: data, group: group)
    }
    static func dismantleNSView(_ view: SidebarHoverAnchorView, coordinator: ()) { view.presenter?.detach() }
}

struct SidebarHoverRegion<Content: View>: View {
    let data: SidebarHoverCardData?
    @ViewBuilder let content: () -> Content
    @State private var presenter = SidebarHoverPresenter()
    @Environment(\.sidebarHoverGroup) private var group

    var body: some View {
        HStack(spacing: 2) {
            content()
            if let data {
                Button { presenter.open(explicit: true) } label: {
                    Image(systemName: "info.circle").font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Preview \(data.title)")
                .accessibilityHint("Opens a temporary card without selecting or marking work seen")
                .accessibilityIdentifier("hover-preview-\(data.id)")
                .help("Preview \(data.title)")
            }
        }
        .background(SidebarHoverAnchor(presenter: presenter, data: data, group: group))
        .onHover { presenter.hoverAnchor($0) }
        .onDisappear { presenter.detach() }
    }
}
