import AppKit
import Testing

// Actual AppKit menu tracking with app-queued input, not OS/HID or installed-CMUX evidence.
// Non-hosted runs skip before touching AppKit. A two-second tracking timeout fails and cancels
// the exact menu; a ten-second hard timeout crashes this test process rather than hanging CI.
@MainActor
@Suite(SidebarAppKitTestScope())
struct SidebarRowLiftNativeInputTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
                   && ProcessInfo.processInfo.environment["RUNNER_ENVIRONMENT"] == "github-hosted"),
          arguments: [Completion.escape, .ownerPointerCancel, .foreignPointerCancel])
    func keyboardOpenedMenuConsumesNativeInput(_ completion: Completion) throws {
        // Keep the gate inside the body too: no local window ordering, even under direct invocation.
        try #require(ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true")
        try #require(ProcessInfo.processInfo.environment["RUNNER_ENVIRONMENT"] == "github-hosted")
        let application = NSApplication.shared
        let fixture = Fixture()
        defer { fixture.close() }
        application.activate()
        fixture.owner.makeKeyAndOrderFront(nil)
        try #require(fixture.owner.isKeyWindow)
        try #require(fixture.owner.makeFirstResponder(fixture.title))
        let frames = fixture.root.subviews.map(\.frame)
        let tracking = Tracking(fixture: fixture, completion: completion)
        defer { tracking.stop() }
        tracking.start()
        let f10 = try #require(UnicodeScalar(NSF10FunctionKey))

        // This is the production title's Shift-F10 route, including the application's local monitors.
        let open = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .shift,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.owner.windowNumber,
            context: nil, characters: String(f10), charactersIgnoringModifiers: String(f10),
            isARepeat: false, keyCode: 109
        ))
        application.sendEvent(open)
        #expect(!tracking.takeBackUnconsumedInput(),
                "A posted event left in the application queue is not native-menu input consumption")

        #expect(tracking.began == 1 && tracking.ended == 1,
                "The real presenter must enter and leave exactly one native root-menu tracking session")
        #expect(tracking.postedInput, "Input must be posted from the native event-tracking run-loop mode")
        #expect(!tracking.timedOut, "Deadline cancellation is a failure, never native-input acceptance")
        #expect(tracking.liftAtOpen, "Shift-F10 must start with legitimate keyboard-visible row focus")
        #expect(fixture.previewDismissals == 1 && fixture.activations == 0 && fixture.actions == 0)
        #expect(fixture.root.subviews.map(\.frame) == frames)
        #expect(fixture.owner.firstResponder === fixture.title)
        #expect(fixture.title.focusRingType == .exterior && !fixture.title.isBordered)
        #expect(!fixture.foreignAnchor.keyboardInteraction, "Owner keyboard input must not alter the foreign window")
        if completion == .ownerPointerCancel {
            #expect(!fixture.anchor.keyboardInteraction && !fixture.anchor.keyboardFocused)
            #expect(!fixture.sibling.keyboardInteraction,
                    "Pointer cancellation invalidates the owning window's other row too")
        } else {
            #expect(fixture.anchor.keyboardInteraction && fixture.sibling.keyboardInteraction,
                    "Escape and foreign-window input must not erase the owner's keyboard modality")
            if completion == .escape {
                #expect(fixture.owner.isKeyWindow && fixture.anchor.keyboardFocused)
            }
        }
        print("row-lift-native-input: \(completion); begin=\(tracking.began); end=\(tracking.ended); "
              + "posted=\(tracking.postedInput); timeout=\(tracking.timedOut); "
              + "localCompletionEvents=\(tracking.localCompletionEvents); "
              + "currentEvent=\(tracking.returnedEvent); keyboard=\(fixture.anchor.keyboardInteraction); "
              + "focused=\(fixture.anchor.keyboardFocused)")
    }

    enum Completion: String, Sendable {
        case escape, ownerPointerCancel, foreignPointerCancel
    }

    @MainActor
    private final class Fixture {
        let owner = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 260),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let foreign = NSWindow(contentRect: NSRect(x: 600, y: 100, width: 360, height: 260),
                               styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 260))
        let anchor = SidebarRowMenuAnchorView(frame: NSRect(x: 10, y: 190, width: 330, height: 46))
        let sibling = SidebarRowMenuAnchorView(frame: NSRect(x: 10, y: 110, width: 330, height: 46))
        let foreignAnchor = SidebarRowMenuAnchorView(frame: NSRect(x: 10, y: 190, width: 330, height: 46))
        let title = SidebarTitleNativeButton(frame: NSRect(x: 40, y: 198, width: 180, height: 30))
        let presenter = SidebarRowMenuPresenter()
        let siblingPresenter = SidebarRowMenuPresenter()
        let foreignPresenter = SidebarRowMenuPresenter()
        var previewDismissals = 0
        var activations = 0
        var actions = 0

        init() {
            owner.isReleasedWhenClosed = false
            foreign.isReleasedWhenClosed = false
            for (anchor, presenter) in [(anchor, presenter), (sibling, siblingPresenter),
                                         (foreignAnchor, foreignPresenter)] {
                anchor.presenter = presenter
                presenter.anchor = anchor
                presenter.liftEligible = true
            }
            root.addSubview(anchor)
            root.addSubview(sibling)
            root.addSubview(title)
            owner.contentView = root
            let foreignRoot = NSView(frame: root.frame)
            foreignRoot.addSubview(foreignAnchor)
            foreign.contentView = foreignRoot
            // The foreign fixture is visible without becoming key; all event IDs belong to fixtures.
            foreign.orderFront(nil)
            presenter.groups = [.init(title: "Fixture actions", actions: [
                .init(title: "Count action", perform: { [weak self] in self?.actions += 1 })
            ])]
            presenter.dismissPreview = { [weak self] in self?.previewDismissals += 1 }
            title.activate = { [weak self] in self?.activations += 1 }
            title.showActions = { [weak self] in self?.presenter.show() }
        }

        func close() {
            title.showActions = nil
            title.activate = {}
            anchor.detach()
            sibling.detach()
            foreignAnchor.detach()
            owner.contentView = nil
            foreign.contentView = nil
            owner.close()
            foreign.close()
        }
    }

    @MainActor
    private final class Tracking: NSObject {
        let fixture: Fixture
        let completion: Completion
        private var menu: NSMenu?
        private var inputTimer: Timer?
        private var deadline: Timer?
        // A native nested loop cannot be interrupted by Swift Testing task cancellation.
        private var hardDeadline: DispatchSourceTimer?
        private var postedEvent: NSEvent?
        private var monitor: Any?
        private(set) var began = 0
        private(set) var ended = 0
        private(set) var postedInput = false
        private(set) var timedOut = false
        private(set) var liftAtOpen = false
        private(set) var returnedEvent = "none"
        private(set) var localCompletionEvents = 0

        init(fixture: Fixture, completion: Completion) {
            self.fixture = fixture
            self.completion = completion
        }

        func start() {
            let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            watchdog.schedule(deadline: .now() + 10)
            watchdog.setEventHandler {
                fatalError("Hosted row-lift native menu exceeded its ten-second hard deadline")
            }
            hardDeadline = watchdog
            watchdog.resume()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
                if let self, event === self.postedEvent { self.localCompletionEvents += 1 }
                return event
            }
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(didBegin(_:)),
                               name: NSMenu.didBeginTrackingNotification, object: nil)
            center.addObserver(self, selector: #selector(didEnd(_:)),
                               name: NSMenu.didEndTrackingNotification, object: nil)
        }

        @objc private func didBegin(_ notification: Notification) {
            guard let candidate = notification.object as? NSMenu,
                  candidate.items.contains(where: {
                      $0.submenu?.items.contains(where: { $0.target === fixture.presenter }) == true
                  }) else { return }
            began += 1
            guard menu == nil else {
                Issue.record("Unexpected overlapping native root-menu tracking")
                candidate.cancelTrackingWithoutAnimation()
                return
            }
            menu = candidate
            liftAtOpen = fixture.anchor.keyboardFocused && fixture.anchor.keyboardInteraction
            // AppKit documents eventTracking mode for timers used during native menu tracking.
            let input = Timer(timeInterval: 0, target: self, selector: #selector(postInput),
                              userInfo: nil, repeats: false)
            let timeout = Timer(timeInterval: 2, target: self, selector: #selector(expire),
                                userInfo: nil, repeats: false)
            inputTimer = input
            deadline = timeout
            RunLoop.main.add(input, forMode: .eventTracking)
            RunLoop.main.add(timeout, forMode: .eventTracking)
        }

        @objc private func postInput() {
            guard RunLoop.current.currentMode == .eventTracking, let menu else {
                Issue.record("Native menu event-tracking mode was not reached")
                return
            }
            let event: NSEvent?
            switch completion {
            case .escape:
                event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.owner.windowNumber,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53
                )
            case .ownerPointerCancel, .foreignPointerCancel:
                let window = completion == .ownerPointerCancel ? fixture.owner : fixture.foreign
                // Inspect only this actual NSMenu's public accessibility geometry, not its window.
                let menuFrame = menu.accessibilityFrame()
                guard !menuFrame.isEmpty else {
                    Issue.record("The native menu exposes no public screen frame for outside-click proof")
                    menu.cancelTrackingWithoutAnimation()
                    return
                }
                let point = NSPoint(x: 350, y: 250)
                let screenPoint = window.convertPoint(toScreen: point)
                guard let screen = window.screen, screen.visibleFrame.contains(screenPoint),
                      !menuFrame.contains(screenPoint) else {
                    Issue.record("The fixture pointer coordinate is not verifiably outside the native menu")
                    menu.cancelTrackingWithoutAnimation()
                    return
                }
                // The actual destination is fixture content, never a fabricated menu window.
                event = NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                )
            }
            guard let event else {
                Issue.record("Could not construct fixture-owned menu input")
                menu.cancelTrackingWithoutAnimation()
                return
            }
            postedInput = true
            postedEvent = event
            NSApp.postEvent(event, atStart: false)
        }

        func takeBackUnconsumedInput() -> Bool {
            guard let postedEvent else { return false }
            var retained: [NSEvent] = []
            var found = false
            defer {
                for event in retained.reversed() { NSApp.postEvent(event, atStart: true) }
                self.postedEvent = nil
            }
            // No dispatch: preserve every unrelated queued event, in order.
            for _ in 0..<128 {
                guard let event = NSApp.nextEvent(matching: .any, until: .distantPast,
                                                 inMode: .default, dequeue: true) else { return found }
                if event === postedEvent { found = true }
                else { retained.append(event) }
            }
            fatalError("Hosted native input queue exceeded cleanup bound; refusing to leave queued fixture input")
        }

        @objc private func didEnd(_ notification: Notification) {
            guard let candidate = notification.object as? NSMenu, candidate === menu else { return }
            ended += 1
            deadline?.invalidate()
            inputTimer?.invalidate()
            if let event = NSApp.currentEvent {
                let owner = event.window === fixture.owner ? "owner"
                    : event.window === fixture.foreign ? "foreign" : "other-or-nil"
                returnedEvent = "\(event.type.rawValue)/\(owner)"
            }
        }

        @objc private func expire() {
            timedOut = true
            Issue.record("Native NSMenu did not consume \(completion) within two seconds")
            menu?.cancelTrackingWithoutAnimation()
        }

        func stop() {
            if postedEvent != nil { _ = takeBackUnconsumedInput() }
            inputTimer?.invalidate()
            deadline?.invalidate()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            NotificationCenter.default.removeObserver(self)
            if ended == 0 { menu?.cancelTrackingWithoutAnimation() }
            menu = nil
            hardDeadline?.cancel()
            hardDeadline = nil
        }
    }
}
