import AppKit
import Testing
import os

// Hosted causal probe only: a test-owned panel, not an integrated NSMenu replacement or parity proof.
@MainActor
@Suite(SidebarAppKitTestScope())
struct SidebarRowMenuPanelProbeTests {
    @Test(.enabled(if: SidebarRowMenuPanelProbeTests.hostedInputEnabled),
          arguments: [Completion.ownerPointerCancel, .foreignPointerCancel, .escape])
    func keyboardOpenedPanelObservesDispatchedInput(_ completion: Completion) async throws {
        let environment = ProcessInfo.processInfo.environment
        print("row-menu-panel-probe body: \(completion.rawValue); "
              + "GITHUB_ACTIONS=\(environment["GITHUB_ACTIONS"] ?? "<unset>"); "
              + "RUNNER_ENVIRONMENT=\(environment["RUNNER_ENVIRONMENT"] ?? "<unset>")")
        try #require(environment["GITHUB_ACTIONS"] == "true")
        try #require(environment["RUNNER_ENVIRONMENT"] == "github-hosted")
        let application = NSApplication.shared
        let fixture = Fixture()
        let probe = Probe(fixture: fixture)
        defer {
            probe.stop()
            probe.report(completion)
            fixture.close()
        }
        fixture.title.showActions = { [weak probe] in probe?.show() }
        application.activate()
        fixture.foreign.orderFront(nil)
        fixture.owner.makeKeyAndOrderFront(nil)
        try #require(fixture.owner.isKeyWindow)
        try #require(fixture.owner.makeFirstResponder(fixture.title))
        let responder = try #require(fixture.owner.firstResponder)
        let geometry = fixture.geometry
        let foreignBefore = fixture.foreignAnchor.keyboardInteraction
        try #require(!fixture.anchor.keyboardInteraction && !fixture.sibling.keyboardInteraction)
        try #require(!foreignBefore)
        let f10 = try #require(UnicodeScalar(NSF10FunctionKey))
        let opening = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .shift,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.owner.windowNumber,
            context: nil, characters: String(f10), charactersIgnoringModifiers: String(f10),
            isARepeat: false, keyCode: 109
        ))
        // Only the opening is sent synchronously; completion must reach the ordinary app event loop.
        probe.sendOpening(opening)
        try #require(probe.opens == 1 && probe.active && probe.showReturned)
        try #require(probe.panel.isVisible && probe.panel.parent === fixture.owner)
        try #require(fixture.owner.childWindows?.contains(where: { $0 === probe.panel }) == true)
        try #require(!probe.panel.canBecomeKey && !probe.panel.canBecomeMain)
        try #require(!probe.panel.isKeyWindow && !probe.panel.isMainWindow)
        try #require(fixture.owner.isKeyWindow && fixture.owner.firstResponder === responder)
        try #require(fixture.anchor.keyboardInteraction && fixture.sibling.keyboardInteraction)
        try #require(fixture.anchor.keyboardFocused)
        try #require(fixture.previewDismissals == 1)
        let dismissalsAfterOpening = fixture.previewDismissals
        let input = try fixture.completionEvent(completion, outside: probe.panel)
        await probe.postAndAwait(input)

        #expect(probe.completionObserved && !probe.timedOut && !probe.failed)
        #expect(probe.opens == 1 && probe.closes == 1 && probe.posts == 1)
        #expect(probe.completionCallbacks == 1 && !probe.overflowed)
        #expect(probe.trace.count <= 64)
        let observed = try #require(probe.trace.first(where: \.postedObject))
        #expect(probe.trace.filter(\.postedObject).count == 1 && observed.ownedVisible)
        #expect(observed.after != nil)
        #expect(observed.event == ObjectIdentifier(input))
        #expect(observed.window == input.window.map { ObjectIdentifier($0) })
        #expect(observed.windowNumber == input.windowNumber && observed.type == input.type.rawValue)
        #expect(probe.observedSequence > 0 && probe.observedSequence < probe.closeSequence)
        #expect(!probe.active && !probe.panel.isVisible && probe.panel.parent == nil)
        #expect(fixture.owner.childWindows?.contains(where: { $0 === probe.panel }) != true)
        #expect(!probe.panel.isKeyWindow && !probe.panel.isMainWindow)
        #expect(fixture.owner.firstResponder === responder, "Do not repair focus before observing it")
        #expect(fixture.geometry == geometry)
        #expect(fixture.title.focusRingType == .exterior && !fixture.title.isBordered)
        #expect(fixture.presenter.liftEligible && fixture.siblingPresenter.liftEligible
                && fixture.foreignPresenter.liftEligible)
        #expect(fixture.activations == 0 && fixture.actions == 0 && fixture.previewOpenings == 0)
        #expect(fixture.previewDismissals == dismissalsAfterOpening,
                "The real title dismisses preview once on opening, not again on panel cancellation")
        #expect(fixture.foreignAnchor.keyboardInteraction == foreignBefore)
        if completion == .ownerPointerCancel {
            #expect(probe.closeReason == "owner-pointer" && observed.target == "owner")
            #expect(probe.broadcasts == 1)
            #expect(probe.observedSequence < probe.broadcastSequence
                    && probe.broadcastSequence < probe.closeSequence)
            #expect(!fixture.anchor.keyboardInteraction && !fixture.sibling.keyboardInteraction)
            #expect(!fixture.anchor.keyboardFocused && fixture.owner.isKeyWindow)
        } else {
            #expect(probe.broadcasts == 0 && probe.broadcastSequence == 0)
            #expect(fixture.anchor.keyboardInteraction && fixture.sibling.keyboardInteraction)
            if completion == .escape {
                #expect(probe.closeReason == "escape" && observed.target == "owner" && observed.keyCode == 53)
                #expect(fixture.owner.isKeyWindow && fixture.anchor.keyboardFocused)
            } else {
                #expect(probe.closeReason == "foreign-pointer" && observed.target == "foreign")
            }
        }
        #expect(!probe.takeBackInput(), "Queued input is not a normally dispatched completion")
    }

    enum Completion: String, Sendable {
        case ownerPointerCancel, foreignPointerCancel, escape
    }

    nonisolated private static var hostedInputEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        let actions = environment["GITHUB_ACTIONS"]
        let runner = environment["RUNNER_ENVIRONMENT"]
        let enabled = actions == "true" && runner == "github-hosted"
        print("row-menu-panel-probe gate: GITHUB_ACTIONS=\(actions ?? "<unset>"); "
              + "RUNNER_ENVIRONMENT=\(runner ?? "<unset>"); enabled=\(enabled)")
        return enabled
    }

    @MainActor
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
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
        var previewOpenings = 0
        var activations = 0
        var actions = 0

        var geometry: [NSRect] {
            [owner.frame, foreign.frame, root.frame, root.bounds,
             anchor.frame, anchor.bounds, sibling.frame, sibling.bounds,
             foreignAnchor.frame, foreignAnchor.bounds, title.frame, title.bounds]
        }

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
            presenter.groups = [.init(title: "Fixture actions", actions: [
                .init(title: "Count action", perform: { [weak self] in self?.actions += 1 })
            ])]
            presenter.preview = { [weak self] in self?.previewOpenings += 1; return true }
            title.activate = { [weak self] in self?.activations += 1 }
            title.preview.dismiss = { [weak self] in self?.previewDismissals += 1 }
            title.preview.enter = { [weak self] in self?.previewOpenings += 1; return true }
        }

        func completionEvent(_ completion: Completion, outside panel: Panel) throws -> NSEvent {
            if completion == .escape {
                return try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: owner.windowNumber,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53
                ))
            }
            let window = completion == .ownerPointerCancel ? owner : foreign
            let point = NSPoint(x: 350, y: 250)
            let screenPoint = window.convertPoint(toScreen: point)
            let content = try #require(window.contentView)
            let screen = try #require(window.screen)
            try #require(content.bounds.contains(content.convert(point, from: nil)))
            try #require(screen.visibleFrame.contains(screenPoint) && !panel.frame.contains(screenPoint))
            for row in [anchor, sibling, foreignAnchor] where row.window === window {
                try #require(!row.bounds.contains(row.convert(point, from: nil)))
            }
            return try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }

        func close() {
            title.showActions = nil
            title.activate = {}
            title.preview = SidebarPreviewInteraction()
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
    private final class Probe {
        struct State {
            let ownerKeyboard: Bool
            let siblingKeyboard: Bool
            let foreignKeyboard: Bool
            let ownerFocused: Bool
            let ownerKey: Bool
            let titleResponder: Bool

            init(_ fixture: Fixture) {
                ownerKeyboard = fixture.anchor.keyboardInteraction
                siblingKeyboard = fixture.sibling.keyboardInteraction
                foreignKeyboard = fixture.foreignAnchor.keyboardInteraction
                ownerFocused = fixture.anchor.keyboardFocused
                ownerKey = fixture.owner.isKeyWindow
                titleResponder = fixture.owner.firstResponder === fixture.title
            }
        }

        struct Record {
            let sequence: Int
            let event: ObjectIdentifier
            let type: UInt
            let window: ObjectIdentifier?
            let windowNumber: Int
            let target: String
            let timestamp: TimeInterval
            let location: NSPoint
            let keyCode: UInt16?
            let postedObject: Bool
            let panel: ObjectIdentifier
            let ownedVisible: Bool
            let before: State
            var after: State?
            var route = "pass"
        }

        let fixture: Fixture
        let panel = Panel(contentRect: NSRect(x: 130, y: 135, width: 180, height: 60),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var postedEvent: NSEvent?
        private var continuation: CheckedContinuation<Void, Never>?
        private var deadlineTask: Task<Void, Never>?
        private var dispatchCompletionTask: Task<Void, Never>?
        private var completionDeadline: ContinuousClock.Instant?
        private var shownAt: TimeInterval?
        private var sequence = 0
        private(set) var active = false
        private(set) var showReturned = false
        private(set) var opens = 0
        private(set) var closes = 0
        private(set) var posts = 0
        private(set) var broadcasts = 0
        private(set) var completionCallbacks = 0
        private(set) var completionObserved = false
        private(set) var timedOut = false
        private(set) var failed = false
        private(set) var overflowed = false
        private(set) var observedSequence = 0
        private(set) var broadcastSequence = 0
        private(set) var closeSequence = 0
        private(set) var trace: [Record] = []
        private(set) var closeReason = "none"

        init(fixture: Fixture) {
            self.fixture = fixture
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 60))
        }

        func show() {
            guard opens == 0, !active, fixture.anchor.window === fixture.owner,
                  fixture.owner.firstResponder === fixture.title else {
                fail("Opening lacked the exact original row/window/responder")
                return
            }
            opens += 1
            active = true
            shownAt = ProcessInfo.processInfo.systemUptime
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                           .leftMouseUp, .rightMouseUp, .otherMouseUp]
            ) { [weak self] event in
                guard let self else { return event }
                return self.observe(event)
            }
            let center = NotificationCenter.default
            for window in [fixture.owner, panel] {
                observers.append(center.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.lifecycleEnded("owned-window-close") }
                })
            }
            observers.append(center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.lifecycleEnded("application-resigned") }
            })
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
                observers.append(center.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.lifecycleEnded("panel-took-focus") }
                })
            }
            fixture.owner.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            showReturned = true
        }

        private enum DeadlineState { case armed, disarmed, expired }

        func sendOpening(_ event: NSEvent) {
            // Short synchronous CAS only: contain this actual sendEvent, never scope serialization.
            let state = OSAllocatedUnfairLock(initialState: DeadlineState.armed)
            let limit = DispatchTime.now() + 10
            let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            watchdog.schedule(deadline: limit)
            watchdog.setEventHandler {
                let expired = state.withLock { value in
                    guard value == .armed else { return false }
                    value = .expired
                    return true
                }
                if expired {
                    fatalError("Hosted panel probe opening exceeded its ten-second hard deadline; proof unavailable")
                }
            }
            watchdog.resume()
            defer {
                let disarmed = state.withLock { value in
                    guard value != .expired, DispatchTime.now().uptimeNanoseconds < limit.uptimeNanoseconds else {
                        value = .expired
                        return false
                    }
                    value = .disarmed
                    return true
                }
                watchdog.cancel()
                if !disarmed {
                    fatalError("Hosted panel probe opening returned after its hard deadline; proof unavailable")
                }
            }
            NSApp.sendEvent(event)
        }

        func postAndAwait(_ event: NSEvent) async {
            guard active, showReturned, posts == 0, !failed else {
                fail("Cannot post completion without one successfully opened live panel")
                return
            }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                postedEvent = event
                posts += 1
                NSApp.postEvent(event, atStart: false)
                let limit = ContinuousClock.now.advanced(by: .seconds(2))
                completionDeadline = limit
                deadlineTask = Task { @MainActor [weak self] in
                    do {
                        try await ContinuousClock().sleep(until: limit)
                    } catch is CancellationError {
                        return
                    } catch {
                        self?.fail("Completion deadline failed: \(error)")
                        self?.close("deadline-error")
                        self?.finish()
                        return
                    }
                    guard let self else { return }
                    self.timedOut = true
                    self.fail("Normal app dispatch did not complete within two seconds; no dispatch substitute")
                    self.close("deadline")
                    self.finish()
                }
            }
        }

        private func observe(_ event: NSEvent) -> NSEvent? {
            guard active else { return event }
            guard trace.count < 64 else {
                if !overflowed { fail("Panel lifetime input trace exceeded 64 records") }
                overflowed = true
                return event
            }
            sequence += 1
            let index = trace.count
            let window = event.window
            let ownedVisible = panel.parent === fixture.owner && panel.isVisible
                && fixture.owner.childWindows?.contains(where: { $0 === panel }) == true
            trace.append(Record(
                sequence: sequence, event: ObjectIdentifier(event), type: event.type.rawValue,
                window: window.map { ObjectIdentifier($0) }, windowNumber: event.windowNumber,
                target: window === fixture.owner ? "owner" : window === fixture.foreign ? "foreign"
                    : window === panel ? "panel" : "other-or-nil",
                timestamp: event.timestamp, location: event.locationInWindow,
                keyCode: event.type == .keyDown || event.type == .keyUp ? event.keyCode : nil,
                postedObject: event === postedEvent, panel: ObjectIdentifier(panel),
                ownedVisible: ownedVisible, before: State(fixture)
            ))
            defer { trace[index].after = State(fixture) }
            guard event === postedEvent else {
                if window === fixture.owner || window === fixture.foreign || window === panel {
                    fail("Unexpected fixture input during the one-posted-event panel lifetime")
                }
                return event
            }
            completionCallbacks += 1
            observedSequence = sequence
            guard completionCallbacks == 1, ownedVisible, !panel.isKeyWindow, !panel.isMainWindow,
                  fixture.anchor.window === fixture.owner, let shownAt, event.timestamp >= shownAt,
                  let window, event.windowNumber == window.windowNumber,
                  let completionDeadline, ContinuousClock.now < completionDeadline else {
                fail("Completion lacked exact live panel/event/window/deadline provenance")
                return event
            }
            if event.type == .leftMouseDown,
               window === fixture.owner || window === fixture.foreign {
                let point = event.locationInWindow
                guard !panel.frame.contains(window.convertPoint(toScreen: point)),
                      let content = window.contentView,
                      content.bounds.contains(content.convert(point, from: nil)),
                      ![fixture.anchor, fixture.sibling, fixture.foreignAnchor].contains(where: {
                          $0.window === window && $0.bounds.contains($0.convert(point, from: nil))
                      }) else {
                    fail("Observed pointer is not outside the exact panel and row hit regions")
                    return event
                }
                if window === fixture.owner {
                    trace[index].route = "owner-pointer/broadcast/consume"
                    sequence += 1
                    broadcastSequence = sequence
                    broadcasts += 1
                    fixture.anchor.observeInput(event)
                    completionObserved = true
                    close("owner-pointer")
                    finishAfterDispatch()
                    return nil
                }
                trace[index].route = "foreign-pointer/pass"
                completionObserved = true
                close("foreign-pointer")
                finishAfterDispatch()
                return event
            }
            if event.type == .keyDown, event.keyCode == 53, window === fixture.owner {
                trace[index].route = "owner-escape/consume"
                completionObserved = true
                close("escape")
                finishAfterDispatch()
                return nil
            }
            fail("The actual completion event did not match any permitted causal route")
            return event
        }

        private func finishAfterDispatch() {
            // Resume after the monitor returns, allowing the foreign event's ordinary dispatch.
            dispatchCompletionTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled, let self else { return }
                self.dispatchCompletionTask = nil
                if let limit = self.completionDeadline, ContinuousClock.now >= limit {
                    self.timedOut = true
                    self.fail("Completion returned after the two-second monotonic budget")
                }
                self.finish()
            }
        }

        private func finish() {
            deadlineTask?.cancel()
            deadlineTask = nil
            let waiting = continuation
            continuation = nil
            waiting?.resume()
        }

        private func lifecycleEnded(_ reason: String) {
            guard active else { return }
            fail("Panel lifetime ended without completion input: \(reason)")
            close(reason)
            finishAfterDispatch()
        }

        private func close(_ reason: String) {
            guard active else { return }
            sequence += 1
            closeSequence = sequence
            closeReason = reason
            closes += 1
            active = false
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            if panel.parent === fixture.owner {
                fixture.owner.removeChildWindow(panel)
            } else {
                fail("Exact panel lost its recorded parent; no replacement ownership inferred")
            }
            panel.orderOut(nil)
            panel.close()
        }

        private func fail(_ message: String) {
            failed = true
            Issue.record("\(message)")
        }

        func takeBackInput() -> Bool {
            guard let postedEvent else { return false }
            var retained: [NSEvent] = []
            var found = false
            defer {
                for event in retained.reversed() { NSApp.postEvent(event, atStart: true) }
                self.postedEvent = nil
            }
            // Cleanup only, after observation: remove exact identity, preserve unrelated queue order.
            for _ in 0..<128 {
                guard let event = NSApp.nextEvent(matching: .any, until: .distantPast,
                                                 inMode: .default, dequeue: true) else { return found }
                if event === postedEvent {
                    found = true
                } else {
                    retained.append(event)
                    if event.type == postedEvent.type && event.window === postedEvent.window {
                        fail("Ambiguous queued fixture input retained; identity was not the posted object")
                    }
                }
            }
            fatalError("Hosted panel probe queue exceeded 128-event cleanup bound; proof unavailable")
        }

        func stop() {
            if active { close("fixture-cleanup") }
            dispatchCompletionTask?.cancel()
            dispatchCompletionTask = nil
            finish()
            if takeBackInput() { fail("Fixture cleanup recovered unconsumed posted input") }
            panel.contentView = nil
        }

        func report(_ completion: Completion) {
            for record in trace {
                print("row-menu-panel-probe trace: \(completion.rawValue); \(record)")
            }
            print("row-menu-panel-probe result: \(completion.rawValue); opens=\(opens); closes=\(closes); "
                  + "posts=\(posts); completionCallbacks=\(completionCallbacks); observed=\(completionObserved); "
                  + "broadcasts=\(broadcasts); observation/broadcast/close="
                  + "\(observedSequence)/\(broadcastSequence)/\(closeSequence); reason=\(closeReason); "
                  + "timeout=\(timedOut); failed=\(failed); traceCount=\(trace.count); overflow=\(overflowed); "
                  + "state=\(State(fixture)); activations=\(fixture.activations); actions=\(fixture.actions); "
                  + "previewOpenings=\(fixture.previewOpenings); previewDismissals=\(fixture.previewDismissals)")
        }
    }
}
