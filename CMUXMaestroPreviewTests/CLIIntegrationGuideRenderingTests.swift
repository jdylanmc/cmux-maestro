import AppKit
import CryptoKit
import Observation
import SwiftUI
import Testing
@testable import CMUXMaestroPreview

/// Hosted synthetic evidence only. Never reads installed guides or the general pasteboard.
@MainActor
@Suite(SidebarAppKitTestScope())
struct CLIIntegrationGuideRenderingTests {
    @Test func builtReferenceMatchesCanonicalSourceWithoutBundlingGlobalGuide() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let reference = try #require(Bundle.main.url(forResource: "maestro-guide", withExtension: "sha256"))
        let canonical = try Data(contentsOf: root.appendingPathComponent("skills/maestro/SKILL.md"))
        let expected = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined() + "\n"
        #expect(try String(contentsOf: reference, encoding: .utf8) == expected)
        #expect(Bundle.main.url(forResource: "SKILL", withExtension: "md", subdirectory: "maestro") == nil)
        #expect(Bundle.main.url(forResource: "SKILL", withExtension: "md", subdirectory: "skills/maestro") == nil)
    }

    @Test func syntheticStatusesRetainNativeSizeScrollingAndAccessibleActions() async throws {
        try await withNativeActionDeadline { try await exerciseSyntheticStatuses() }
    }

    private func exerciseSyntheticStatuses() async throws {
        let cases: [(String, CLIIntegrationGuideReader.Result, String, String)] = [
            ("missing", result(.missing), "Missing", "No guide found at this location."),
            ("unreadable", result(.unreadable(.permissionDenied)), "Unreadable",
             "Permission denied. Check access, then Re-check."),
            ("different", result(.different), "Different from this build",
             "Content may be newer or customized; different does not mean outdated."),
            ("matching", result(.matching), "Matches this build",
             "Guide bytes match this build, not necessarily the latest upstream guide."),
            ("reference-unavailable", .referenceUnavailable, "Build reference unavailable.",
             "Guide content could not be compared. Nothing was changed.")
        ]
        for (name, result, title, detail) in cases {
            for dark in [false, true] {
                let model = CLIIntegrationGuideModel(read: { result })
                await model.recheck()
                var copies = 0
                var copySucceeds = false
                let presentation = try GuideCalibrationHost(guide: CLIIntegrationSettingsView(model: model, copyCommand: {
                    copies += 1
                    return copySucceeds
                }), dark: dark)
                let host = presentation.guide.view
                let window = presentation.window
                defer { presentation.close() }
                let prefix = "cli-guide-\(name)-\(dark ? "dark" : "light")"
                try await renderTurn(host, window: window)
                try capture(host, named: prefix)
                try await waitForPresentedGuide(presentation, status: result, context: prefix)
                try capture(host, named: prefix)
                #expect(host.fittingSize == NSSize(width: 600, height: 350))
                #expect(copies == 0)
                let recheck = try element("cli-integration-recheck", in: host, window: window)
                #expect(recheck.role == NSAccessibility.Role.button.rawValue)
                #expect(recheck.enabled)
                try assertStatus(result, title: title, detail: detail, host: host, window: window)
                let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
                let document = try #require(scroll.documentView)
                #expect(document.bounds.width <= scroll.contentView.bounds.width + 1)
                #expect(document.bounds.height > scroll.contentView.bounds.height)
                let before = scroll.contentView.bounds.origin
                try scrollToBottom(scroll)
                try await renderTurn(host, window: window)
                #expect(scroll.contentView.bounds.origin != before)
                try capture(host, named: prefix + "-scrolled")

                for succeeds in [false, true] {
                    copySucceeds = succeeds
                    let copy = try element("cli-integration-copy-command", in: host, window: window)
                    #expect(copy.role == NSAccessibility.Role.button.rawValue)
                    #expect(copy.enabled)
                    try assertVisible(copy, in: scroll, window: window)
                    #expect(copy.press())
                    try await renderTurn(host, window: window)
                    #expect(copies == (succeeds ? 2 : 1))
                    let notice = succeeds
                        ? "Copied. Run the command in your terminal when ready."
                        : "Could not copy the command. Select and copy the text above."
                    try scrollToBottom(scroll)
                    try await renderTurn(host, window: window)
                    let feedback = try element("cli-integration-copy-feedback", in: host, window: window)
                    #expect(feedback.text.contains(notice))
                    try assertVisible(feedback, in: scroll, window: window)
                    let updatedCopy = try element("cli-integration-copy-command", in: host, window: window)
                    #expect(updatedCopy.value == notice)
                    try assertVisible(updatedCopy, in: scroll, window: window)
                    try capture(host, named: prefix + (succeeds ? "-copy-success" : "-copy-failure"))
                }
            }
        }
    }

    @Test func nativeRecheckDrivesCheckingChangedStatusAndRetry() async throws {
        // The same 180-second action deadline starts after the AppKit scope is acquired.
        // A test-level TimeLimitTrait also counts time queued behind unrelated native tests.
        try await withNativeActionDeadline { try await exerciseNativeRecheck() }
    }

    private func withNativeActionDeadline(
        waitForDeadline: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(180))
        },
        operation: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await waitForDeadline()
                throw NativeActionDeadlineExceeded()
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private struct NativeActionDeadlineExceeded: Error, CustomStringConvertible {
        var description: String { "Native guide case exceeded 180 seconds after acquiring the AppKit scope" }
    }

    @Test func noOpRecheckFailsAtDeadlineAndCancelsItsReadStartWait() async throws {
        let reader = ControlledReader(initial: result(.missing))
        let host = ExposureFixtureView(frame: NSRect(x: 0, y: 0, width: 600, height: 350))
        host.setAccessibilityElement(true)
        host.setAccessibilityRole(.group)
        let button = ExposureFixtureButton(frame: NSRect(x: 20, y: 20, width: 180, height: 28))
        button.title = "Re-check"
        button.setAccessibilityIdentifier("cli-integration-recheck")
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        host.addSubview(button)
        host.exposedChildren = [button]
        let window = makeWindow(host: host, dark: false)
        defer { window.contentView = nil; window.close() }
        let action = try element("cli-integration-recheck", in: host, window: window)
        let (waiting, waiterInstalled) = AsyncStream<Void>.makeStream()
        defer { waiterInstalled.finish() }

        await #expect(throws: NativeActionDeadlineExceeded.self) {
            try await withNativeActionDeadline(waitForDeadline: {
                // Expire only once the read-start observer is installed, without wall-clock waiting.
                for await _ in waiting { return }
                throw CancellationError()
            }, operation: {
                try #require(action.press())
                try await reader.waitUntilReading {
                    waiterInstalled.yield()
                    waiterInstalled.finish()
                }
                Issue.record("A no-op Re-check must not pass the read-start boundary")
            })
        }
        #expect(button.presses == 1)
        #expect(await reader.calls == 0)
        #expect(await !reader.isWaitingForRead)
    }

    private func exerciseNativeRecheck() async throws {
        for dark in [false, true] {
            let reader = ControlledReader(initial: result(.missing))
            let model = CLIIntegrationGuideModel(read: { await reader.read() })
            await model.recheck()
            let presentation = try GuideCalibrationHost(guide: CLIIntegrationSettingsView(model: model, copyCommand: {
                Issue.record("Re-check must never invoke Copy")
                return false
            }), dark: dark)
            let host = presentation.guide.view
            let window = presentation.window
            defer { presentation.close() }
            try await waitForPresentedGuide(presentation, status: result(.missing),
                                            context: "recheck-\(dark ? "dark" : "light")")
            try assertStatus(result(.missing), title: "Missing", detail: "No guide found at this location.",
                             host: host, window: window)
            let outcomes: [(CLIIntegrationGuideReader.Result, String, String, String)] = [
                (result(.unreadable(.permissionDenied)), "Unreadable",
                 "Permission denied. Check access, then Re-check.", "unreadable"),
                (result(.matching), "Matches this build",
                 "Guide bytes match this build, not necessarily the latest upstream guide.", "matching")
            ]
            do {
                for (index, outcome) in outcomes.enumerated() {
                    let (next, title, detail, name) = outcome
                    let prefix = "cli-guide-recheck-\(name)-\(dark ? "dark" : "light")"
                    let button = try element("cli-integration-recheck", in: host, window: window)
                    #expect(button.enabled)
                    try #require(button.press())
                    try await reader.waitUntilReading()
                    #expect(await reader.calls == index + 2)
                    try await renderTurn(host, window: window)
                    let checking = try element("cli-integration-checking", in: host, window: window)
                    #expect(checking.text.contains("Checking guide content..."))
                    #expect(try !element("cli-integration-recheck", in: host, window: window).enabled)
                    #expect(!accessibilityNodes(from: host).contains {
                        $0.identifier?.hasPrefix("cli-integration-status-") == true
                    })
                    try capture(host, named: prefix + "-checking")

                    // Observe completion from the actual view-started model task, not a second recheck().
                    let completed = AsyncStream<Void> { continuation in
                        withObservationTracking {
                            _ = model.isChecking
                        } onChange: {
                            continuation.yield()
                            continuation.finish()
                        }
                    }
                    await reader.complete(next)
                    for await _ in completed { break }
                    try Task.checkCancellation()
                    try await renderTurn(host, window: window)
                    #expect(try element("cli-integration-recheck", in: host, window: window).enabled)
                    try assertStatus(next, title: title, detail: detail, host: host, window: window)
                    try capture(host, named: prefix + "-completed")
                }
            } catch {
                await reader.cancel()
                throw error
            }
        }
    }

    private actor ControlledReader {
        let initial: CLIIntegrationGuideReader.Result
        private(set) var calls = 0
        private var pending: CheckedContinuation<CLIIntegrationGuideReader.Result, Never>?
        private var reading: AsyncStream<Void>.Continuation?
        private var cancelled = false
        var isWaitingForRead: Bool { reading != nil }

        init(initial: CLIIntegrationGuideReader.Result) { self.initial = initial }

        func read() async -> CLIIntegrationGuideReader.Result {
            if cancelled { return .referenceUnavailable }
            calls += 1
            if calls == 1 { return initial }
            return await withCheckedContinuation {
                pending = $0
                reading?.yield()
                reading?.finish()
                reading = nil
            }
        }

        func waitUntilReading(observingWait: @Sendable () -> Void = {}) async throws {
            if pending != nil { return }
            let events = AsyncStream<Void> { reading = $0 }
            defer { reading = nil }
            observingWait()
            for await _ in events { break }
            try Task.checkCancellation()
            try #require(pending != nil, "Native Re-check did not start a read")
        }

        func complete(_ result: CLIIntegrationGuideReader.Result) {
            guard let pending else {
                Issue.record("No native Re-check read is pending")
                return
            }
            self.pending = nil
            pending.resume(returning: result)
        }

        func cancel() {
            cancelled = true
            reading?.finish()
            reading = nil
            pending?.resume(returning: .referenceUnavailable)
            pending = nil
        }
    }

    private func result(_ content: CLIIntegrationGuideReader.Content) -> CLIIntegrationGuideReader.Result {
        .checked(CLIIntegrationGuideReader.relativePaths.map { .init(relativePath: $0, content: content) })
    }

    private func makeWindow(host: NSView, dark: Bool) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 350),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        return window
    }

    private func renderTurn(_ host: NSView, window: NSWindow) async throws {
        try Task.checkCancellation()
        // AsyncStream releases a cancelled waiter even if the scheduled run-loop turn has not run.
        let (turns, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        RunLoop.main.perform {
            continuation.yield()
            continuation.finish()
        }
        for await _ in turns { break }
        try Task.checkCancellation()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try Task.checkCancellation()
    }

    /// Two independently queried SwiftUI subjects share one public, CI-only presentation context.
    @MainActor
    private final class GuideCalibrationHost {
        let guide: CalibrationHostingController
        let minimal: CalibrationHostingController
        let container: NSViewController
        let window: NSWindow
        let minimalPressCount: () -> Int
        private let originalActivationPolicy: NSApplication.ActivationPolicy
        private let wasActive: Bool

        init<Content: View>(guide rootView: Content, dark: Bool) throws {
            #if CMUX_VALIDATION
            let validationBuild = true
            #else
            let validationBuild = false
            #endif
            let environment = ProcessInfo.processInfo.environment
            try #require(validationBuild
                         && Bundle.main.bundleIdentifier == "com.jdylanmc.CMUXMaestroPreview.Validation.Tests"
                         && environment["GITHUB_ACTIONS"] == "true"
                         && environment["RUNNER_ENVIRONMENT"] == "github-hosted",
                         "Presented guide calibration requires the isolated GitHub-hosted validation app")
            let app = NSApplication.shared
            try #require(app.isRunning, "Calibration requires the validation app's running public lifecycle")
            originalActivationPolicy = app.activationPolicy()
            wasActive = app.isActive
            guide = CalibrationHostingController(rootView: rootView.environment(\.accessibilityEnabled, true))
            var presses = 0
            minimalPressCount = { presses }
            minimal = CalibrationHostingController(rootView:
                Button("Synthetic host calibration action") { presses += 1 }
                    .accessibilityIdentifier("guide-calibration-minimal-action")
                    .frame(width: 600, height: 64)
                    .environment(\.accessibilityEnabled, true))
            container = NSViewController()
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
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentViewController = container
            window.center()
            print("Guide calibration before presentation: \(observation)")
            let activated = app.setActivationPolicy(.regular)
            if !activated { close() }
            try #require(activated, "Could not apply the validation app's public activation policy")
            window.makeKeyAndOrderFront(nil)
            app.activate()
        }

        var isPresented: Bool {
            NSApplication.shared.isRunning && NSApplication.shared.isActive
                && window.isVisible && window.isKeyWindow && window.occlusionState.contains(.visible)
                && window.contentViewController === container && window.contentView === container.view
                && guide.parent === container && minimal.parent === container
                && guide.view.window === window && minimal.view.window === window
                && guide.appeared && minimal.appeared
        }

        var observation: String {
            let app = NSApplication.shared
            return "bundle=\(Bundle.main.bundleIdentifier ?? "-") appRunning=\(app.isRunning) "
                + "active=\(app.isActive) hidden=\(app.isHidden) policy=\(app.activationPolicy().rawValue) "
                + "window=\(ObjectIdentifier(window)) number=\(window.windowNumber) visible=\(window.isVisible) "
                + "key=\(window.isKeyWindow) main=\(window.isMainWindow) occlusion=\(window.occlusionState.rawValue) "
                + "screen=\(String(describing: window.screen?.frame)) content=\(ObjectIdentifier(container.view)) "
                + "contentControllerExact=\(window.contentViewController === container) "
                + "contentViewExact=\(window.contentView === container.view) "
                + "guide={\(guide.observation)} minimal={\(minimal.observation)} "
                + "parentsExact=\(guide.parent === container && minimal.parent === container) "
                + "windowsExact=\(guide.view.window === window && minimal.view.window === window)"
        }

        func close() {
            window.orderOut(nil)
            window.contentViewController = nil
            window.contentView = nil
            window.close()
            guide.removeFromParent()
            minimal.removeFromParent()
            let app = NSApplication.shared
            if !wasActive { app.deactivate() }
            #expect(app.setActivationPolicy(originalActivationPolicy))
            #expect(!window.isVisible)
        }
    }

    @MainActor
    private final class CalibrationHostingController: NSHostingController<AnyView> {
        private(set) var appeared = false
        private let subjectType: String

        init<Content: View>(rootView: Content) {
            subjectType = String(reflecting: Content.self)
            super.init(rootView: AnyView(rootView))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidAppear() {
            super.viewDidAppear()
            appeared = true
            print("Guide calibration viewDidAppear: \(observation)")
        }

        override func viewDidDisappear() {
            super.viewDidDisappear()
            appeared = false
            print("Guide calibration viewDidDisappear: \(observation)")
        }

        var observation: String {
            "subject=\(subjectType) controller=\(ObjectIdentifier(self)) root=\(ObjectIdentifier(view)) "
                + "appeared=\(appeared) frame=\(view.frame) hidden=\(view.isHiddenOrHasHiddenAncestor)"
        }
    }

    private func waitForPresentedGuide(
        _ presentation: GuideCalibrationHost, status: CLIIntegrationGuideReader.Result, context: String
    ) async throws {
        let requiredIDs: [String]
        switch status {
        case .checked:
            requiredIDs = CLIIntegrationGuideReader.relativePaths.map { "cli-integration-status-" + $0 }
        case .referenceUnavailable:
            requiredIDs = ["cli-integration-reference-error"]
        }
        var minimalNodes: [NativeElement] = []
        var guideNodes: [NativeElement] = []
        var minimalPassed = false
        var guideReady = false
        var previousObservation = ""
        defer {
            print("Guide calibration \(context): minimalActionPassed=\(minimalPassed) guideReady=\(guideReady)")
            print("Guide calibration final host: \(presentation.observation)")
            print("Minimal exposed root AX:\n\(diagnostic(minimalNodes))")
            print("Guide exposed root AX:\n\(diagnostic(guideNodes))")
            if !minimalPassed || !guideReady {
                logAXBoundary([NativeElement(object: presentation.minimal.view)] + minimalNodes)
                logAXBoundary([NativeElement(object: presentation.guide.view)] + guideNodes)
            }
        }
        // No step timeout: presentation, both subjects and all scenarios/actions share the
        // enclosing case's 180-second deadline and cooperative cancellation.
        while true {
            try await renderTurn(presentation.container.view, window: presentation.window)
            minimalNodes = accessibilityNodes(from: presentation.minimal.view)
            guideNodes = accessibilityNodes(from: presentation.guide.view)
            try Task.checkCancellation()
            let minimalActions = minimalNodes.filter { $0.identifier == "guide-calibration-minimal-action" }
            let rechecks = guideNodes.filter { $0.identifier == "cli-integration-recheck" }
            let presented = presentation.isPresented
            guideReady = presented && rechecks.count == 1
                && isReadyButton(rechecks[0], in: presentation.guide.view, window: presentation.window)
                && requiredIDs.allSatisfy { id in guideNodes.filter { $0.identifier == id }.count == 1 }
            if !minimalPassed, presented, minimalActions.count == 1,
               isReadyButton(minimalActions[0], in: presentation.minimal.view, window: presentation.window) {
                try #require(minimalActions[0].press())
                try #require(presentation.minimalPressCount() == 1)
                minimalPassed = true
            }
            let observation = "presented=\(presented) minimalActionPassed=\(minimalPassed) guideReady=\(guideReady)"
            if observation != previousObservation {
                print("Guide calibration \(context): \(observation)")
                previousObservation = observation
            }
            try Task.checkCancellation()
            if minimalPassed && guideReady { return }
        }
    }

    private func isReadyButton(_ node: NativeElement, in host: NSView, window: NSWindow) -> Bool {
        guard node.role == NSAccessibility.Role.button.rawValue, node.enabled,
              let frame = node.frame, frame.width > 0, frame.height > 0 else { return false }
        let viewport = window.convertToScreen(host.convert(host.bounds, to: nil))
        let intersection = viewport.intersection(frame)
        return intersection.width > 0 && intersection.height > 0
    }

    private func capture(_ host: NSView, named name: String) throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: folder.appendingPathComponent(name + ".png"))
    }

    private func assertStatus(
        _ result: CLIIntegrationGuideReader.Result, title: String, detail: String,
        host: NSView, window: NSWindow
    ) throws {
        switch result {
        case .checked:
            for path in [".agents/skills/maestro/SKILL.md", ".copilot/skills/maestro/SKILL.md"] {
                let row = try element("cli-integration-status-" + path, in: host, window: window)
                #expect(row.text.contains(title))
                #expect(row.text.contains("~/" + path))
                #expect(row.text.contains(detail))
            }
        case .referenceUnavailable:
            let error = try element("cli-integration-reference-error", in: host, window: window)
            #expect(error.text.contains(title))
            #expect(error.text.contains(detail))
        }
    }

    private func scrollToBottom(_ scroll: NSScrollView) throws {
        let document = try #require(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped
            ? max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height)
            : document.bounds.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func assertVisible(_ node: NativeElement, in scroll: NSScrollView, window: NSWindow) throws {
        let frame = try #require(node.frame)
        let viewport = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
        #expect(frame.width > 0 && frame.height > 0)
        #expect(viewport.intersection(frame).width > 0 && viewport.intersection(frame).height > 0)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        var views: [NSView] = []
        var pending = view.subviews
        while !pending.isEmpty, views.count < 4_096 {
            let next = pending.removeLast()
            views.append(next)
            pending += next.subviews
        }
        #expect(pending.isEmpty, "Synthetic view hierarchy exceeded the inspection bound")
        return views
    }

    // SwiftUI may expose Objective-C accessibility selectors without declaring the full
    // NSAccessibilityProtocol conformance. Invoke those typed selectors, not a conformance filter.
    private struct NativeElement {
        let object: NSObject
        var identifier: String? { (object as AnyObject).accessibilityIdentifier?() ?? nil }
        var role: String? { (object as AnyObject).accessibilityRole?()?.rawValue }
        var enabled: Bool { (object as AnyObject).isAccessibilityEnabled?() ?? false }
        var frame: NSRect? { (object as AnyObject).accessibilityFrame?() }
        var value: String? {
            let selector = NSSelectorFromString("accessibilityValue")
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue() as? String
        }
        var text: String {
            [(object as AnyObject).accessibilityLabel?() ?? nil,
             (object as AnyObject).accessibilityTitle?() ?? nil, value]
                .compactMap { $0 }.joined(separator: "\n")
        }
        var children: [NSObject] {
            let children = (object as AnyObject).accessibilityChildren?() ?? []
            return NSAccessibility.unignoredChildren(from: children).compactMap { $0 as? NSObject }
        }
        func press() -> Bool { (object as AnyObject).accessibilityPerformPress?() ?? false }
    }

    private func element(_ id: String, in host: NSView, window: NSWindow) throws -> NativeElement {
        try #require(host.window === window)
        let nodes = accessibilityNodes(from: host)
        let match = nodes.first { $0.identifier == id }
        if match == nil {
            print("Exposed host AX tree:\n\(diagnostic(nodes))")
            let raw = ([host] + descendants(host)).map { NativeElement(object: $0) }
            print("Raw views (diagnostics only):\n\(diagnostic(raw))")
            logAXBoundary([NativeElement(object: host)] + nodes)
        }
        return try #require(match, "Missing \(id) from the exposed host AX tree")
    }

    private func diagnostic(_ nodes: [NativeElement]) -> String {
        nodes.map {
            "\(type(of: $0.object)) \(ObjectIdentifier($0.object)): \($0.identifier ?? "-") "
                + "role=\($0.role ?? "-") enabled=\($0.enabled) frame=\(String(describing: $0.frame)) "
                + "\($0.text.prefix(256))"
        }
            .joined(separator: "\n")
    }

    private func logAXBoundary(_ nodes: [NativeElement]) {
        print("Guide AX boundary: inspecting \(min(nodes.count, 64))/\(nodes.count) reached objects")
        for (index, node) in nodes.prefix(64).enumerated() {
            let object = node.object
            let attributesValue = diagnosticGetter("accessibilityAttributeNames", from: object)
            let attributes = attributesValue as? [String]
            let legacySelector = NSSelectorFromString("accessibilityAttributeValue:")
            print("AX[\(index)] type=\(String(reflecting: type(of: object)).prefix(128))")
            print("  bridge identifier=\(diagnosticValue(node.identifier)) role=\(diagnosticValue(node.role))")
            for name in ["accessibilityIdentifier", "accessibilityRole", "accessibilityChildren",
                         "isAccessibilityElement", "isAccessibilityEnabled", "accessibilityFrame",
                         "accessibilityPerformPress", "accessibilityAttributeNames", "accessibilityAttributeValue:"] {
                print("  selector \(name)=\(object.responds(to: NSSelectorFromString(name)))")
            }
            print("  legacy names=\(diagnosticValue(attributesValue)) parsed=\(attributes != nil)")
            let bridgeChildren = (object as AnyObject).accessibilityChildren?() ?? []
            print("  bridge children: \(diagnosticChildren(bridgeChildren))")
            for (attribute, getter): (NSAccessibility.Attribute, String) in [
                (.identifier, "accessibilityIdentifier"), (.role, "accessibilityRole"),
                (.children, "accessibilityChildren")
            ] {
                let modern = diagnosticGetter(getter, from: object)
                let advertised = attributes?.contains(attribute.rawValue) == true
                let readable = advertised && object.responds(to: legacySelector)
                let legacy = readable
                    ? object.perform(legacySelector, with: attribute.rawValue)?.takeUnretainedValue() : nil
                print("  \(attribute.rawValue) modern=\(diagnosticValue(modern)) advertised=\(advertised)")
                print("  \(attribute.rawValue) legacy=\(readable ? diagnosticValue(legacy) : "not read")")
                if attribute == .children {
                    print("  modern children: \(diagnosticChildren(modern))")
                    if readable { print("  legacy children: \(diagnosticChildren(legacy))") }
                }
            }
        }
    }

    private func diagnosticGetter(_ name: String, from object: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private func diagnosticValue(_ value: Any?) -> String {
        guard let value else { return "nil" }
        let type = String(reflecting: Swift.type(of: value)).prefix(128)
        if let string = value as? String {
            return "\(type):\(String(reflecting: String(string.prefix(256))))"
        }
        if let array = value as? [Any] { return "\(type):count=\(array.count)" }
        if let number = value as? NSNumber { return "\(type):\(number.stringValue.prefix(32))" }
        return "\(type):value not expanded"
    }

    private func diagnosticChildren(_ value: Any?) -> String {
        guard let raw = value as? [Any] else { return "not an array: \(diagnosticValue(value))" }
        let rawSample = Array(raw.prefix(256))
        let unignored = NSAccessibility.unignoredChildren(from: rawSample)
        let sample = Array(unignored.prefix(256))
        let retained = sample.compactMap { $0 as? NSObject }
        let rejected = sample.filter { ($0 as? NSObject) == nil }
        let types = rejected.prefix(8).map { String(String(reflecting: type(of: $0)).prefix(128)) }
        return "raw=\(raw.count) inspectedRaw=\(rawSample.count) unignored=\(unignored.count) "
            + "inspectedUnignored=\(sample.count) retainedNSObject=\(retained.count) "
            + "rejected=\(rejected.count) rejectedTypeSample=\(types)"
    }

    private func accessibilityNodes(from root: NSObject) -> [NativeElement] {
        var nodes: [NativeElement] = []
        var pending = NativeElement(object: root).children
        var visited: Set<ObjectIdentifier> = [ObjectIdentifier(root)]
        while !pending.isEmpty, visited.count < 4_096 {
            let object = pending.removeLast()
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            let node = NativeElement(object: object)
            nodes.append(node)
            pending += node.children
        }
        #expect(pending.isEmpty, "Exposed accessibility tree exceeded the inspection bound")
        return nodes
    }

    @Test func accessibilityAcceptanceExcludesOmittedAndIgnoredRawControls() throws {
        let host = ExposureFixtureView(frame: NSRect(x: 0, y: 0, width: 600, height: 350))
        host.setAccessibilityElement(true)
        host.setAccessibilityRole(.group)
        let window = makeWindow(host: host, dark: false)
        defer { window.contentView = nil; window.close() }
        let buttons = (0..<3).map { index in
            let button = ExposureFixtureButton(
                frame: NSRect(x: 20, y: CGFloat(20 + index * 40), width: 180, height: 28)
            )
            button.title = "Synthetic action"
            button.setAccessibilityIdentifier("guide-oracle-action")
            button.setAccessibilityLabel("Synthetic action")
            button.setAccessibilityElement(true)
            button.setAccessibilityRole(.button)
            host.addSubview(button)
            return button
        }
        let omitted = buttons[0], ignored = buttons[1], exposed = buttons[2]
        ignored.setAccessibilityElement(false)
        host.exposedChildren = [ignored]
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(omitted.isAccessibilityElement() && exposed.isAccessibilityElement())
        #expect(!ignored.isAccessibilityElement())

        if buttons.contains(where: { NativeElement(object: $0).role != NSAccessibility.Role.button.rawValue }) {
            for (name, button) in zip(["omitted", "ignored", "exposed"], buttons) {
                let direct = button.accessibilityRole()?.rawValue
                let bridged = NativeElement(object: button).role
                print("Guide role fixture \(name) element=\(button.isAccessibilityElement()) "
                      + "direct=\(diagnosticValue(direct)) bridge=\(diagnosticValue(bridged))")
            }
            logAXBoundary(buttons.map { NativeElement(object: $0) })
        }

        // Correct labels, frames and working actions on raw objects are insufficient.
        for button in [omitted, ignored] {
            let raw = NativeElement(object: button)
            #expect(raw.identifier == "guide-oracle-action")
            #expect(raw.text.contains("Synthetic action"))
            #expect(raw.enabled && raw.role == NSAccessibility.Role.button.rawValue)
            let frame = try #require(raw.frame)
            #expect(frame.width > 0 && frame.height > 0)
            #expect(raw.press())
            #expect(button.presses == 1)
            #expect(descendants(host).contains { $0 === button })
        }
        #expect(!accessibilityNodes(from: host).contains { $0.identifier == "guide-oracle-action" })

        host.exposedChildren = [ignored, exposed]
        let accepted = accessibilityNodes(from: host).filter { $0.identifier == "guide-oracle-action" }
        try #require(accepted.count == 1)
        #expect(accepted[0].object === exposed)
        #expect(accepted[0].press())
        #expect(exposed.presses == 1)
        #expect(omitted.presses == 1 && ignored.presses == 1)
    }

    private final class ExposureFixtureView: NSView {
        var exposedChildren: [NSView] = []
        override func accessibilityChildren() -> [Any]? { exposedChildren }
    }

    private final class ExposureFixtureButton: NSButton {
        var presses = 0
        override func accessibilityPerformPress() -> Bool {
            presses += 1
            return true
        }
    }
}
