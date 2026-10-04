import AppKit
import Observation
import SwiftUI

/// Closed synthetic exercise. Only this fixture's Next button advances the fixed matrix.
@MainActor
final class GuideAcceptanceFixture {
    typealias Evidence = GuideAcceptanceEvidence
    let caseName: String
    let invocation: String
    let head: String
    let tree: String
    let directory: URL
    let started: Double
    let deadline: Double
    private var presentation: Presentation?
    private var model: CLIIntegrationGuideModel?
    private var reader: ControlledReader?
    private var copies = 0
    private var copyResults: [Bool] = []
    private var copySucceeds = false
    private var ordinal = 0
    private var scenarioIndex = 0
    private var stageIndex = 0
    private var actions: [Evidence.Action] = []
    private var observationInstalled = false
    private var observationFired = false
    private var cleanups: [Evidence.Cleanup] = []
    private var operation: Task<Void, Never>?
    private let diagnostic = NSTextField(labelWithString: "Starting")
    private let next = NSButton(title: "Next", target: nil, action: nil)
    private let abort = NSButton(title: "Abort", target: nil, action: nil)

    init(environment: [String: String]) throws {
        guard let mode = environment["CMUX_GUIDE_ACCEPTANCE_CASE"], Evidence.producers[mode] != nil,
              let id = environment["CMUX_GUIDE_ACCEPTANCE_INVOCATION"], UUID(uuidString: id) != nil,
              let head = environment["CMUX_GUIDE_ACCEPTANCE_HEAD"], head.count == 40,
              let tree = environment["CMUX_GUIDE_ACCEPTANCE_TREE"], tree.count == 40,
              let path = environment["CMUX_GUIDE_ACCEPTANCE_DIRECTORY"],
              let start = environment["CMUX_GUIDE_ACCEPTANCE_STARTED"].flatMap(Double.init), start.isFinite else {
            throw Evidence.Failure(description: "Missing fixed acceptance launch context")
        }
        caseName = mode; invocation = id; self.head = head; self.tree = tree
        directory = URL(fileURLWithPath: path)
        started = start; deadline = start + 180
        try Evidence.require(directory.path == directory.standardizedFileURL.resolvingSymlinksInPath().path
                             && directory.lastPathComponent == "guide-acceptance"
                             && directory.deletingLastPathComponent().lastPathComponent == "scopes-" + id
                             && FileManager.default.fileExists(atPath: directory.appendingPathComponent("images").path),
                             "Host output must be the runner-owned fresh acceptance directory")
        diagnostic.setAccessibilityIdentifier("guide-acceptance-observation")
        diagnostic.frame = NSRect(x: 490, y: 362, width: 105, height: 40)
        diagnostic.lineBreakMode = .byClipping
        next.frame = NSRect(x: 5, y: 367, width: 75, height: 28)
        next.setAccessibilityIdentifier("guide-acceptance-next")
        next.target = self
        next.action = #selector(advance)
        abort.frame = NSRect(x: 412, y: 367, width: 72, height: 28)
        abort.setAccessibilityIdentifier("guide-acceptance-abort")
        abort.target = self
        abort.action = #selector(abortExercise)
    }

    private var scenarios: [(String, String)] {
        (caseName == "statuses" ? Evidence.scenarios : ["recheck"]).flatMap { name in
            Evidence.appearances.map { (name, $0) }
        }
    }
    private var phases: [String] { caseName == "statuses" ? Evidence.statusStages : Evidence.recheckStages }
    private var producer: String { Evidence.producers[caseName]! }

    func start() { advance() }

    @objc private func abortExercise() {
        abort.isEnabled = false
        let active = operation
        active?.cancel()
        Task {
            await active?.value
            do { try await closePresentation() }
            catch { print("Acceptance abort cleanup failed: \(error)") }
        }
    }

    @objc private func advance() {
        guard operation == nil else {
            diagnostic.stringValue = "ERROR|Overlapping fixed fixture operation"
            return
        }
        next.isEnabled = false
        diagnostic.stringValue = "BUSY"
        operation = Task {
            do {
                let perform: @MainActor @Sendable () async throws -> Void = { try await self.performNext() }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await perform() }
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    try Evidence.require(remaining > 0, "180-second whole-case deadline")
                    group.addTask {
                        try await Task.sleep(for: .seconds(remaining))
                        throw Evidence.Failure(description: "180-second whole-case deadline")
                    }
                    defer { group.cancelAll() }
                    try await group.next()
                }
                try checkTime()
                next.isEnabled = true
            } catch {
                diagnostic.stringValue = "ERROR|\(error)"
                do {
                    try String(describing: error).write(to: directory.appendingPathComponent(caseName + "-failure.txt"),
                                                       atomically: true, encoding: .utf8)
                } catch {
                    print("Acceptance failure evidence could not be written: \(error)")
                }
                do { try await closePresentation() }
                catch { print("Acceptance failure cleanup: \(error)") }
            }
            operation = nil
        }
    }

    private func checkTime() throws {
        try Task.checkCancellation()
        try Evidence.require(ProcessInfo.processInfo.systemUptime < deadline, "180-second whole-case deadline")
    }

    private func result(_ name: String) throws -> CLIIntegrationGuideReader.Result {
        let content: CLIIntegrationGuideReader.Content
        switch name {
        case "missing", "recheck": content = .missing
        case "unreadable": content = .unreadable(.permissionDenied)
        case "different": content = .different
        case "matching": content = .matching
        case "reference-unavailable": return .referenceUnavailable
        default: throw Evidence.Failure(description: "Unknown fixture scenario")
        }
        return .checked(CLIIntegrationGuideReader.relativePaths.map { .init(relativePath: $0, content: content) })
    }

    private func performNext() async throws {
        try checkTime()
        if stageIndex == phases.count {
            try await closePresentation()
            scenarioIndex += 1
            stageIndex = 0
        }
        if scenarioIndex == scenarios.count {
            let completion = Evidence.Completion(invocation: invocation, producer: producer, cleanups: cleanups,
                                                  elapsed: ProcessInfo.processInfo.systemUptime - started)
            try JSONEncoder().encode(completion).write(to: directory.appendingPathComponent(caseName + "-completion.json"),
                                                       options: .atomic)
            try checkTime()
            return
        }
        let (scenario, appearance) = scenarios[scenarioIndex]
        let stage = phases[stageIndex]
        actions = []
        observationInstalled = false
        observationFired = false
        if stageIndex == 0 {
            copies = 0; copyResults = []; copySucceeds = false
            let reader = ControlledReader(initial: try result(scenario), controlled: caseName == "recheck")
            self.reader = reader
            let model = CLIIntegrationGuideModel(read: { await reader.read() })
            self.model = model
            await model.recheck()
            try checkTime()
            let guide = CLIIntegrationSettingsView(model: model, copyCommand: { [self] in
                self.copies += 1
                let result = self.copySucceeds
                self.copyResults.append(result)
                return result
            })
            let presentation = try Presentation(guide: guide, dark: appearance == "dark")
            self.presentation = presentation
            presentation.container.view.addSubview(next)
            presentation.container.view.addSubview(abort)
            presentation.container.view.addSubview(diagnostic)
            try await presentation.exerciseControls()
        }
        guard let presentation, let model, let reader else {
            throw Evidence.Failure(description: "Missing fixture presentation/model/reader")
        }
        try await render(presentation)
        if stageIndex == 1 {
            let node = try presentation.element("guide-calibration-minimal-action", minimal: true)
            let record = node.record
            let before = presentation.minimalPresses
            let viewport = presentation.screenRect(presentation.minimal.view)
            try Evidence.ready(node.record, viewport: viewport)
            let returned = node.press()
            actions = [.init(identifier: record.identifier, node: record, viewport: viewport,
                             returned: returned, before: before, after: presentation.minimalPresses,
                             sinkResult: nil, pendingRead: false)]
            try Evidence.assertAction(actions[0], id: "guide-calibration-minimal-action", before: 0, after: 1)
        } else if stage == "scrolled-bottom" {
            try presentation.scrollToBottom()
        } else if stage == "copy-failure" || stage == "copy-success" {
            copySucceeds = stage == "copy-success"
            let node = try presentation.element("cli-integration-copy-command")
            let record = node.record
            let viewport = presentation.screenRect(try presentation.scroll().contentView)
            try Evidence.ready(node.record, viewport: viewport)
            let before = copies
            let returned = node.press()
            try Evidence.require(returned, "Real exposed Copy AXPress returned false")
            try await render(presentation)
            actions = [.init(identifier: record.identifier, node: record, viewport: viewport,
                             returned: returned, before: before, after: copies,
                             sinkResult: copyResults.last, pendingRead: false)]
            try Evidence.assertAction(actions[0], id: "cli-integration-copy-command",
                                      before: copySucceeds ? 1 : 0, after: copySucceeds ? 2 : 1)
            try presentation.scrollToBottom()
        } else if stage.hasSuffix("-checking") {
            let node = try presentation.element("cli-integration-recheck")
            let record = node.record
            let viewport = presentation.screenRect(try presentation.scroll().contentView)
            try Evidence.ready(node.record, viewport: viewport)
            let before = await reader.calls
            let returned = node.press()
            try Evidence.require(returned, "Real exposed Re-check AXPress returned false")
            try checkTime()
            try await reader.waitUntilReading()
            actions = [.init(identifier: record.identifier, node: record, viewport: viewport,
                             returned: returned, before: before, after: await reader.calls,
                             sinkResult: nil, pendingRead: await reader.hasPending)]
        } else if stage.hasSuffix("-completed") {
            let (changes, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            withObservationTracking { _ = model.isChecking } onChange: {
                continuation.yield()
                continuation.finish()
            }
            observationInstalled = true
            try await reader.complete(result(stage.hasPrefix("unreadable") ? "unreadable" : "matching"))
            for await _ in changes { observationFired = true; break }
            try checkTime()
        }
        try await render(presentation)
        let image: Evidence.Image?
        if let name = Evidence.imageName(caseName: caseName, scenario: scenario, appearance: appearance, stage: stage) {
            image = try capture(presentation, name: name)
        } else { image = nil }
        // Keep the pre-readiness capture before readiness; no real AX traversal until the consumer has observed it.
        while !presentation.isPresented { try await render(presentation) }
        let host = Evidence.HostStage(
            invocation: invocation, producer: producer, sourceHead: head, sourceTree: tree,
            scenario: scenario, appearance: appearance, stage: stage,
            elapsed: ProcessInfo.processInfo.systemUptime - started,
            presentation: try presentation.measure(model: model, appearance: appearance),
            copies: copies, minimalPresses: presentation.minimalPresses,
            readerCalls: await reader.calls, pendingRead: await reader.hasPending, checking: model.isChecking,
            observationInstalled: observationInstalled, observationFired: observationFired, actions: actions,
            recheck: stageIndex == 1 || (caseName == "recheck" && stageIndex > 0)
                ? try presentation.element("cli-integration-recheck").record : nil,
            controls: try presentation.controlObservation(), image: image)
        try checkTime()
        let data = try JSONEncoder().encode(host)
        diagnostic.stringValue = "\(ordinal)|" + data.base64EncodedString()
        ordinal += 1
        stageIndex += 1
    }

    private func render(_ presentation: Presentation) async throws {
        try checkTime()
        let (turns, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        RunLoop.main.perform { continuation.yield(); continuation.finish() }
        for await _ in turns { break }
        try checkTime()
        presentation.container.view.layoutSubtreeIfNeeded()
        presentation.window.displayIfNeeded()
        try checkTime()
    }

    private func capture(_ presentation: Presentation, name: String) throws -> Evidence.Image {
        let host = presentation.guide.view
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw Evidence.Failure(description: "Missing cacheDisplay bitmap")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw Evidence.Failure(description: "Missing cacheDisplay PNG")
        }
        try checkTime()
        try data.write(to: directory.appendingPathComponent("images").appendingPathComponent(name))
        try checkTime()
        return .init(name: name, sha256: Evidence.digest(data), bytes: data.count,
                     pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh, points: .init(host.bounds),
                     backingScale: presentation.window.backingScaleFactor,
                     capturedAt: ProcessInfo.processInfo.systemUptime - started)
    }

    private func closePresentation() async throws {
        guard let presentation else { return }
        if let reader { await reader.cancel() }
        let pending = await reader?.hasPending ?? false
        let waiting = await reader?.isWaiting ?? false
        let (scenario, appearance) = scenarios[scenarioIndex]
        next.removeFromSuperview()
        abort.removeFromSuperview()
        diagnostic.removeFromSuperview()
        var cleanup = presentation.close(scenario: scenario, appearance: appearance)
        cleanup.readerPending = pending
        cleanup.readerWaiting = waiting
        cleanup.elapsed = ProcessInfo.processInfo.systemUptime - started
        cleanups.append(cleanup)
        self.presentation = nil; model = nil; reader = nil
        try Evidence.require(!cleanup.windowVisible && cleanup.originalPolicy == cleanup.restoredPolicy
                             && cleanup.policyRestoreReturned != false, "Fixture cleanup failed")
    }

    private actor ControlledReader {
        let initial: CLIIntegrationGuideReader.Result
        let controlled: Bool
        private(set) var calls = 0
        private var pending: CheckedContinuation<CLIIntegrationGuideReader.Result, Never>?
        private var waiting: AsyncStream<Void>.Continuation?
        private var cancelled = false
        var hasPending: Bool { pending != nil }
        var isWaiting: Bool { waiting != nil }

        init(initial: CLIIntegrationGuideReader.Result, controlled: Bool) {
            self.initial = initial; self.controlled = controlled
        }
        func read() async -> CLIIntegrationGuideReader.Result {
            if cancelled { return .referenceUnavailable }
            calls += 1
            if calls == 1 || !controlled { return initial }
            return await withCheckedContinuation {
                pending = $0; waiting?.yield(); waiting?.finish(); waiting = nil
            }
        }
        func waitUntilReading(observingWait: @Sendable () -> Void = {}) async throws {
            if pending != nil { return }
            let events = AsyncStream<Void> { waiting = $0 }
            defer { waiting = nil }
            observingWait()
            for await _ in events { break }
            try Task.checkCancellation()
            try Evidence.require(pending != nil, "AXPress did not start the view's read")
        }
        func complete(_ result: CLIIntegrationGuideReader.Result) throws {
            guard let pending else { throw Evidence.Failure(description: "No existing pending read to release") }
            self.pending = nil
            pending.resume(returning: result)
        }
        func cancel() {
            cancelled = true
            waiting?.finish(); waiting = nil
            pending?.resume(returning: .referenceUnavailable); pending = nil
        }
    }

    private final class Hosting: NSHostingController<AnyView> {
        private(set) var appeared = false
        init<V: View>(_ view: V) { super.init(rootView: AnyView(view)) }
        @available(*, unavailable) required init?(coder: NSCoder) { nil }
        override func viewDidAppear() { super.viewDidAppear(); appeared = true }
        override func viewDidDisappear() { super.viewDidDisappear(); appeared = false }
    }

    private final class Presentation {
        let guide: Hosting
        let minimal: Hosting
        let container = NSViewController()
        let window: NSWindow
        private var count = 0
        var minimalPresses: Int { count }
        private let originalPolicy: NSApplication.ActivationPolicy
        private let wasActive: Bool
        private var policyChange: Bool?
        private let exposure = ExposureView(frame: NSRect(x: 85, y: 360, width: 100, height: 48))
        private let omitted = ExposureButton(frame: NSRect(x: 0, y: 0, width: 90, height: 22))
        private let ignored = ExposureButton(frame: NSRect(x: 0, y: 0, width: 90, height: 22))
        private let exposed = ExposureButton(frame: NSRect(x: 0, y: 0, width: 90, height: 22))
        private var controls: Evidence.Controls?

        init<V: View>(guide root: V, dark: Bool) throws {
            let app = NSApplication.shared
            try Evidence.require(app.isRunning, "Host public application lifecycle not running")
            originalPolicy = app.activationPolicy(); wasActive = app.isActive
            guide = Hosting(root.accessibilityIdentifier("guide-validation-real-guide-root")
                .environment(\.accessibilityEnabled, true))
            // The action remains centered in the original 600x64 subject; controls occupy unused strip space.
            var action: () -> Void = {}
            minimal = Hosting(VStack {
                Button(action: { action() }) { Text(verbatim: "Synthetic host calibration action") }
                    .accessibilityIdentifier("guide-calibration-minimal-action")
            }.frame(width: 600, height: 64)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("guide-validation-minimal-root")
                .environment(\.accessibilityEnabled, true))
            container.view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 414))
            for (controller, frame) in [
                (guide, NSRect(x: 0, y: 0, width: 600, height: 350)),
                (minimal, NSRect(x: 0, y: 350, width: 600, height: 64))
            ] {
                container.addChild(controller)
                controller.view.frame = frame
                container.view.addSubview(controller.view)
            }
            window = NSWindow(contentRect: container.view.frame, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Synthetic CLI guide host calibration"
            window.setAccessibilityIdentifier("guide-acceptance-window")
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentViewController = container
            exposure.setAccessibilityElement(true)
            exposure.setAccessibilityRole(.group)
            exposure.setAccessibilityIdentifier("guide-acceptance-controls")
            for (button, title) in [(omitted, "Omitted"), (ignored, "Ignored"), (exposed, "Exposed")] {
                button.title = title
                button.setAccessibilityLabel(title)
                button.setAccessibilityIdentifier("guide-acceptance-oracle-action")
                button.setAccessibilityElement(true)
                button.setAccessibilityRole(.button)
                exposure.addSubview(button)
            }
            ignored.setAccessibilityElement(false)
            exposure.exposed = [ignored]
            container.view.addSubview(exposure)
            window.center()
            action = { [weak self] in self?.count += 1 }
            if app.activationPolicy() != .regular { policyChange = app.setActivationPolicy(.regular) }
            try Evidence.require(policyChange != false && app.activationPolicy() == .regular,
                                 "Could not apply regular validation activation policy")
            window.makeKeyAndOrderFront(nil)
            app.activate()
        }

        func exerciseControls() async throws {
            let rawOmitted = NativeNode(object: omitted), rawIgnored = NativeNode(object: ignored)
            let omittedReturned = rawOmitted.press(), ignoredReturned = rawIgnored.press()
            let before = try NativeNode.nodes(from: exposure).filter {
                $0.record.identifier == "guide-acceptance-oracle-action"
            }.count
            exposure.exposed = [ignored, exposed]
            let after = try NativeNode.nodes(from: exposure).filter {
                $0.record.identifier == "guide-acceptance-oracle-action"
            }
            try Evidence.require(after.count == 1 && after[0].object === exposed, "Fixture exposure boundary differs")
            let record = after[0].record
            let callsBefore = exposed.effects
            let returned = after[0].press()
            let noOp = Evidence.Action(identifier: record.identifier, node: record, viewport: screenRect(exposure),
                                       returned: returned, before: callsBefore, after: exposed.effects,
                                       sinkResult: nil, pendingRead: false)
            let reader = ControlledReader(initial: .referenceUnavailable, controlled: true)
            let (events, installed) = AsyncStream<Void>.makeStream()
            defer { installed.finish() }
            var waitInstalled = false
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await reader.waitUntilReading { installed.yield(); installed.finish() }
                        throw Evidence.Failure(description: "No-op unexpectedly started a read")
                    }
                    group.addTask {
                        for await _ in events { throw CancellationError() }
                        throw Evidence.Failure(description: "No read-start waiter installed")
                    }
                    defer { group.cancelAll() }
                    try await group.next()
                }
            } catch is CancellationError {
                waitInstalled = true
            }
            controls = .init(
                omitted: rawOmitted.record, ignored: rawIgnored.record,
                omittedIsElement: omitted.isAccessibilityElement(), ignoredIsElement: ignored.isAccessibilityElement(),
                omittedInRawTree: exposure.subviews.contains { $0 === omitted },
                ignoredInRawTree: exposure.subviews.contains { $0 === ignored },
                omittedReturned: omittedReturned, ignoredReturned: ignoredReturned,
                omittedPresses: omitted.presses, ignoredPresses: ignored.presses,
                exposedCountBefore: before, exposedCountAfter: after.count, noOp: noOp, noOpPresses: exposed.presses,
                noOpReaderCalls: await reader.calls, noOpReaderPending: await reader.hasPending,
                noOpWaitInstalled: waitInstalled, noOpWaitRemaining: await reader.isWaiting)
            await reader.cancel()
        }

        func controlObservation() throws -> Evidence.Controls {
            guard let controls else { throw Evidence.Failure(description: "Missing fixture controls") }
            return controls
        }

        func screenRect(_ view: NSView) -> Evidence.Rect {
            .init(window.convertToScreen(view.convert(view.bounds, to: nil)))
        }

        var isPresented: Bool {
            let app = NSApplication.shared
            return app.isRunning && app.isActive && app.activationPolicy() == .regular
                && window.isVisible && window.isKeyWindow && window.occlusionState.contains(.visible)
                && window.contentViewController === container && window.contentView === container.view
                && guide.parent === container && minimal.parent === container
                && guide.view.window === window && minimal.view.window === window
                && guide.appeared && minimal.appeared
        }

        func scroll() throws -> NSScrollView {
            var pending = guide.view.subviews
            var count = 0
            var result: NSScrollView?
            while !pending.isEmpty && count < 4_096 {
                let next = pending.removeLast()
                if result == nil { result = next as? NSScrollView }
                pending += next.subviews
                count += 1
            }
            try Evidence.require(pending.isEmpty, "Raw geometry traversal exceeded 4096")
            guard let result, result.documentView != nil else {
                throw Evidence.Failure(description: "Missing actual scroll/document view")
            }
            return result
        }

        func scrollToBottom() throws {
            let scroll = try scroll()
            guard let document = scroll.documentView else { throw Evidence.Failure(description: "Missing document") }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped
                ? max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height)
                : document.bounds.minY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func measure(model: CLIIntegrationGuideModel, appearance: String) throws -> Evidence.Presentation {
            let app = NSApplication.shared
            let scroll = try scroll()
            guard let document = scroll.documentView, let screen = NSScreen.screens.first else {
                throw Evidence.Failure(description: "Missing actual document/screen")
            }
            let fitting = guide.view.fittingSize
            let actualAppearance = window.appearance?.bestMatch(from: [.aqua, .darkAqua])
            try Evidence.require(actualAppearance != nil, "Missing actual appearance")
            return .init(
                running: app.isRunning, active: app.isActive, policy: app.activationPolicy().rawValue,
                visible: window.isVisible, key: window.isKeyWindow, unoccluded: window.occlusionState.contains(.visible),
                exactContentController: window.contentViewController === container,
                exactContentView: window.contentView === container.view,
                exactGuideParent: guide.parent === container, exactMinimalParent: minimal.parent === container,
                exactGuideWindow: guide.view.window === window, exactMinimalWindow: minimal.view.window === window,
                guideAppeared: guide.appeared, minimalAppeared: minimal.appeared,
                guideFrame: .init(guide.view.frame), minimalFrame: .init(minimal.view.frame),
                containerFrame: .init(container.view.frame), fittingWidth: fitting.width, fittingHeight: fitting.height,
                document: .init(document.bounds), clip: .init(scroll.contentView.bounds), flipped: document.isFlipped,
                clipScreen: screenRect(scroll.contentView), minimalScreen: screenRect(minimal.view),
                screenTop: screen.frame.maxY, windowNumber: window.windowNumber,
                modelIdentity: String(describing: ObjectIdentifier(model)),
                appearance: actualAppearance == .darkAqua ? "dark" : "light")
        }

        func element(_ id: String, minimal: Bool = false) throws -> NativeNode {
            let host = minimal ? self.minimal.view : guide.view
            try Evidence.require(host.window === window, "Exact hosted window lost")
            let nodes = try NativeNode.nodes(from: host)
            let matches = nodes.filter { $0.record.identifier == id }
            if matches.count != 1 {
                print("Exposed-only AX failure \(id): \(nodes.prefix(64).map { $0.record })")
            }
            try Evidence.require(matches.count == 1, "Missing/duplicate real exposed AX node: \(id)")
            return matches[0]
        }

        func close(scenario: String, appearance: String) -> Evidence.Cleanup {
            window.orderOut(nil)
            window.contentViewController = nil; window.contentView = nil
            window.close()
            guide.removeFromParent(); minimal.removeFromParent()
            let app = NSApplication.shared
            if !wasActive { app.deactivate() }
            let restored = app.activationPolicy() != originalPolicy ? app.setActivationPolicy(originalPolicy) : nil
            return .init(scenario: scenario, appearance: appearance, originalPolicy: originalPolicy.rawValue,
                         restoredPolicy: app.activationPolicy().rawValue, policyChangeReturned: policyChange,
                         policyRestoreReturned: restored, windowVisible: window.isVisible,
                         guideHasParent: guide.parent != nil, minimalHasParent: minimal.parent != nil,
                         readerPending: false, readerWaiting: false, elapsed: 0)
        }
    }

    private struct NativeNode {
        let object: NSObject
        var children: [NSObject] {
            NSAccessibility.unignoredChildren(from: (object as AnyObject).accessibilityChildren?() ?? [])
                .compactMap { $0 as? NSObject }
        }
        var record: Evidence.Node {
            let selector = NSSelectorFromString("accessibilityValue")
            let value = object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? String : nil
            return .init(identifier: (object as AnyObject).accessibilityIdentifier?() ?? "",
                         role: (object as AnyObject).accessibilityRole?()?.rawValue ?? "",
                         enabled: (object as AnyObject).isAccessibilityEnabled?() ?? false,
                         label: (object as AnyObject).accessibilityLabel?() ?? "",
                         title: (object as AnyObject).accessibilityTitle?() ?? "", value: value,
                         frame: .init((object as AnyObject).accessibilityFrame?() ?? .zero), hittable: nil)
        }
        func press() -> Bool { (object as AnyObject).accessibilityPerformPress?() ?? false }
        static func nodes(from root: NSObject) throws -> [NativeNode] {
            var pending = NativeNode(object: root).children
            var visited: Set<ObjectIdentifier> = [ObjectIdentifier(root)]
            var nodes: [NativeNode] = []
            while !pending.isEmpty && visited.count < 4_096 {
                let object = pending.removeLast()
                guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
                let node = NativeNode(object: object)
                nodes.append(node); pending += node.children
            }
            try Evidence.require(pending.isEmpty, "Exposed AX traversal exceeded 4096")
            return nodes
        }

    }

    private final class ExposureView: NSView {
        var exposed: [NSView] = []
        override func accessibilityChildren() -> [Any]? { exposed }
    }

    private final class ExposureButton: NSButton {
        private(set) var presses = 0
        private(set) var effects = 0
        override func accessibilityPerformPress() -> Bool { presses += 1; return true }
    }
}
