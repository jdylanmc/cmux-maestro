import CryptoKit
import SwiftUI

@MainActor
final class RowInputFixture: NSObject, NSApplicationDelegate {
    private let caseID: UUID
    private var owner: RowInputWindow!
    private var foreign: RowInputWindow!
    private var hosts: [(id: String, view: NSView)] = []
    private var ownerReceiver: RowInputReceiver!
    private var foreignReceiver: RowInputReceiver!
    private var evidenceView: RowInputEvidenceView!
    private var menu: NSMenu?
    private var opens = 0
    private var closes = 0
    private var actions = 0
    private var activations = 0
    private var dismissals = 0
    private var inputs: [RowInputEvidence.Input] = []
    private var overflow = false
    private var invalidated = false
    private var firstInvalidation: RowInputEvidence.Invalidation?
    private var setupComplete = false
    private var displaysAtSetup: RowInputEvidence.DisplayState?

    init(caseID: UUID) { self.caseID = caseID }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Placement derives from the hosted display; input always uses named AX elements.
        guard let screen = NSScreen.screens.first, screen.visibleFrame.width >= 820,
              screen.visibleFrame.height >= 460 else {
            fatalError("Hosted display cannot contain both isolated fixture windows")
        }
        let visible = screen.visibleFrame
        owner = makeWindow(id: "row-input-owner", origin: CGPoint(x: visible.minX + 10, y: visible.minY + 40))
        foreign = makeWindow(id: "row-input-foreign", origin: CGPoint(x: visible.maxX - 410, y: visible.minY + 40))
        addRow("owner", to: owner, y: 270)
        addRow("sibling", to: owner, y: 190)
        addRow("foreign", to: foreign, y: 270)
        ownerReceiver = addReceiver("owner-click", to: owner)
        foreignReceiver = addReceiver("foreign-click", to: foreign)
        evidenceView = RowInputEvidenceView(frame: NSRect(x: 10, y: 10, width: 370, height: 24))
        evidenceView.isEditable = false
        evidenceView.isSelectable = false
        evidenceView.isBordered = false
        evidenceView.stringValue = "Validation fixture evidence"
        evidenceView.setAccessibilityIdentifier("row-input-evidence")
        evidenceView.observe = { [weak self] in self?.snapshot() ?? "fixture-released" }
        owner.contentView?.addSubview(evidenceView)
        NotificationCenter.default.addObserver(self, selector: #selector(menuBegan(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEnded(_:)),
                                               name: NSMenu.didEndTrackingNotification, object: nil)
        for window in [owner!, foreign!] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowClosed(_:)),
                                                   name: NSWindow.willCloseNotification, object: window)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(lifetimeEnded(_:)),
                                               name: NSApplication.didResignActiveNotification, object: NSApp)
        NotificationCenter.default.addObserver(self, selector: #selector(lifetimeEnded(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        NSApp.setActivationPolicy(.regular)
        foreign.orderFront(nil)
        owner.makeKeyAndOrderFront(nil)
        NSApp.activate()
        owner.contentView?.layoutSubtreeIfNeeded()
        foreign.contentView?.layoutSubtreeIfNeeded()
        guard let title = controls(in: hosts[0].view).titles.first,
              owner.makeFirstResponder(title) else {
            fatalError("Production fixture title was not attached as a native responder")
        }
        displaysAtSetup = displayState()
        setupComplete = true
    }

    private func makeWindow(id: String, origin: CGPoint) -> RowInputWindow {
        let window = RowInputWindow(contentRect: CGRect(origin: origin, size: CGSize(width: 400, height: 360)),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        window.title = id
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.setAccessibilityIdentifier(id)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 360))
        window.observe = { [weak self, weak window] event in
            guard let self, let window, event.window === window else { return }
            guard [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp].contains(event.type) else { return }
            guard self.inputs.count < 64 else { self.overflow = true; return }
            let mouse = event.type == .leftMouseDown || event.type == .leftMouseUp
            self.inputs.append(.init(window: id, type: event.type.rawValue, timestamp: event.timestamp,
                                     point: mouse ? event.locationInWindow : nil))
        }
        return window
    }

    private func addRow(_ id: String, to window: NSWindow, y: CGFloat) {
        let row = SidebarRowActions(title: id, groups: [
            .init(title: "Fixture actions", actions: [
                .init(title: "Count action", perform: { [weak self] in self?.actions += 1 })
            ])
        ], liftEligible: true) {
            SidebarTitleButton(label: "\(id)-title", hint: "Validation row",
                               action: { [weak self] in self?.activations += 1 }) {
                Text(verbatim: "\(id) production row").frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .environment(\.sidebarPreviewInteraction, SidebarPreviewInteraction(
            dismiss: { [weak self] in self?.dismissals += 1 }
        ))
        let host = NSHostingView(rootView: row)
        host.frame = NSRect(x: 20, y: y, width: 350, height: 46)
        window.contentView?.addSubview(host)
        hosts.append((id, host))
    }

    private func addReceiver(_ id: String, to window: NSWindow) -> RowInputReceiver {
        let receiver = RowInputReceiver(frame: NSRect(x: 260, y: 55, width: 100, height: 55))
        receiver.wantsLayer = true
        receiver.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        receiver.setAccessibilityElement(true)
        receiver.setAccessibilityRole(.button)
        receiver.setAccessibilityLabel(id)
        receiver.setAccessibilityIdentifier(id)
        window.contentView?.addSubview(receiver)
        return receiver
    }

    private func controls(in view: NSView) -> (anchors: [SidebarRowMenuAnchorView], titles: [SidebarTitleNativeButton]) {
        var anchors: [SidebarRowMenuAnchorView] = []
        var titles: [SidebarTitleNativeButton] = []
        func visit(_ view: NSView) {
            if let anchor = view as? SidebarRowMenuAnchorView { anchors.append(anchor) }
            if let title = view as? SidebarTitleNativeButton { titles.append(title) }
            for child in view.subviews { visit(child) }
        }
        visit(view)
        return (anchors, titles)
    }

    @objc private func menuBegan(_ notification: Notification) {
        guard let candidate = notification.object as? NSMenu,
              let presenter = controls(in: hosts[0].view).anchors.first?.presenter,
              candidate.items.contains(where: { item in
                  item.submenu?.items.contains(where: { $0.target === presenter }) == true
              }) else { return }
        guard menu == nil else { invalidate(.overlappingMenu); return }
        menu = candidate
        opens += 1
    }

    @objc private func menuEnded(_ notification: Notification) {
        guard let candidate = notification.object as? NSMenu, candidate === menu else { return }
        closes += 1
        menu = nil
    }

    private func invalidate(_ reason: RowInputEvidence.Invalidation.Reason) {
        invalidated = true
        if firstInvalidation == nil {
            firstInvalidation = .init(reason: reason, uptime: ProcessInfo.processInfo.systemUptime,
                                      setupComplete: setupComplete, applicationActive: NSApp.isActive,
                                      ownerKey: owner.isKeyWindow, displays: displayState())
        }
    }

    private func screenNumber(_ screen: NSScreen?) -> UInt32? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func displayState() -> RowInputEvidence.DisplayState {
        let screens = NSScreen.screens
        if screens.count > 8 { overflow = true }
        let values = screens.prefix(8).map { screen -> RowInputEvidence.Display in
            var profileHash: String?
            if let profile = screen.colorSpace?.iccProfileData {
                if profile.count > 1_048_576 {
                    overflow = true
                } else {
                    profileHash = SHA256.hash(data: profile).map { String(format: "%02x", $0) }.joined()
                }
            }
            return .init(number: screenNumber(screen), frame: screen.frame, visibleFrame: screen.visibleFrame,
                         backingScaleFactor: screen.backingScaleFactor, colorProfileSHA256: profileHash)
        }
        return .init(uptime: ProcessInfo.processInfo.systemUptime, screens: values,
                     ownerScreenNumber: screenNumber(owner.screen), foreignScreenNumber: screenNumber(foreign.screen),
                     ownerBackingScaleFactor: owner.backingScaleFactor,
                     foreignBackingScaleFactor: foreign.backingScaleFactor)
    }

    @objc private func windowClosed(_ notification: Notification) { invalidate(.windowClosed) }
    @objc private func lifetimeEnded(_ notification: Notification) {
        invalidate(notification.name == NSApplication.didResignActiveNotification
                   ? .applicationResigned : .screenParametersChanged)
    }

    private func snapshot() -> String {
        var live = !invalidated && NSApp.isActive && owner.isVisible && foreign.isVisible
            && ownerReceiver.superview === owner.contentView && foreignReceiver.superview === foreign.contentView
            && evidenceView.window === owner
        var failedRowIDs: [String] = []
        let rows = hosts.compactMap { entry -> RowInputEvidence.Row? in
            let found = controls(in: entry.view)
            guard found.anchors.count == 1, found.titles.count == 1,
                  let anchor = found.anchors.first, let title = found.titles.first,
                  let presenter = anchor.presenter, presenter.anchor === anchor,
                  let window = entry.view.window, anchor.window === window, title.window === window,
                  window === (entry.id == "foreign" ? foreign : owner),
                  entry.view.superview === window.contentView,
                  !anchor.visibleRect.isEmpty, !title.visibleRect.isEmpty else {
                live = false
                failedRowIDs.append(entry.id)
                return nil
            }
            return .init(id: entry.id, windowNumber: window.windowNumber,
                         keyboard: anchor.keyboardInteraction, focused: anchor.keyboardFocused,
                         eligible: presenter.liftEligible, focusedControls: presenter.focusedControls.count,
                         titleIsResponder: window.firstResponder === title,
                         exteriorFocusRing: title.focusRingType == .exterior, bordered: title.isBordered,
                         frame: anchor.convert(anchor.bounds, to: nil), titleFrame: title.convert(title.bounds, to: nil))
        }
        let evidence = RowInputEvidence(
            version: 3, caseID: caseID, live: live && rows.count == 3,
            lifetime: .init(invalidated: invalidated, firstInvalidation: firstInvalidation,
                            applicationActive: NSApp.isActive, ownerVisible: owner.isVisible,
                            foreignVisible: foreign.isVisible,
                            ownerReceiverAttached: ownerReceiver.superview === owner.contentView,
                            foreignReceiverAttached: foreignReceiver.superview === foreign.contentView,
                            evidenceAttached: evidenceView.window === owner, failedRowIDs: failedRowIDs,
                            displaysAtSetup: displaysAtSetup, displaysAtSample: displayState()),
            rows: rows,
            ownerFrame: owner.frame, foreignFrame: foreign.frame, ownerKey: owner.isKeyWindow,
            opens: opens, closes: closes, tracking: menu != nil, actions: actions,
            activations: activations, dismissals: dismissals,
            ownerDown: ownerReceiver.downs, ownerUp: ownerReceiver.ups,
            foreignDown: foreignReceiver.downs, foreignUp: foreignReceiver.ups,
            inputs: inputs, overflow: overflow
        )
        do {
            let data = try JSONEncoder().encode(evidence)
            guard data.count <= 32_768, let text = String(data: data, encoding: .utf8) else {
                return "invalid-evidence-size"
            }
            return text
        } catch {
            return "evidence-encoding-failed: \(error)"
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        menu?.cancelTrackingWithoutAnimation()
        menu = nil
        for entry in hosts {
            for anchor in controls(in: entry.view).anchors { anchor.detach() }
        }
        owner?.observe = { _ in }
        foreign?.observe = { _ in }
        evidenceView?.observe = { "fixture-stopped" }
    }

    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool { false }
}
