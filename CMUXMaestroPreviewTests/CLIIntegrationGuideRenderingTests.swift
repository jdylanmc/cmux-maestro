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
                // Enable assistive output in this synthetic host, not in system preferences.
                let host = NSHostingView(rootView: CLIIntegrationSettingsView(model: model, copyCommand: {
                    copies += 1
                    return copySucceeds
                }).environment(\.accessibilityEnabled, true))
                let window = makeWindow(host: host, dark: dark)
                defer { window.contentView = nil; window.close() }
                let prefix = "cli-guide-\(name)-\(dark ? "dark" : "light")"
                await renderTurn(host, window: window)
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
                await renderTurn(host, window: window)
                #expect(scroll.contentView.bounds.origin != before)
                try capture(host, named: prefix + "-scrolled")

                for succeeds in [false, true] {
                    copySucceeds = succeeds
                    let copy = try element("cli-integration-copy-command", in: host, window: window)
                    #expect(copy.role == NSAccessibility.Role.button.rawValue)
                    #expect(copy.enabled)
                    try assertVisible(copy, in: scroll, window: window)
                    #expect(copy.press())
                    await renderTurn(host, window: window)
                    #expect(copies == (succeeds ? 2 : 1))
                    let notice = succeeds
                        ? "Copied. Run the command in your terminal when ready."
                        : "Could not copy the command. Select and copy the text above."
                    try scrollToBottom(scroll)
                    await renderTurn(host, window: window)
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
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await exerciseNativeRecheck() }
            group.addTask {
                try await Task.sleep(for: .seconds(180))
                throw NativeActionDeadlineExceeded()
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private struct NativeActionDeadlineExceeded: Error, CustomStringConvertible {
        var description: String { "Native Re-check exceeded 180 seconds after acquiring the AppKit scope" }
    }

    private func exerciseNativeRecheck() async throws {
        for dark in [false, true] {
            let reader = ControlledReader(initial: result(.missing))
            let model = CLIIntegrationGuideModel(read: { await reader.read() })
            await model.recheck()
            let host = NSHostingView(rootView: CLIIntegrationSettingsView(model: model, copyCommand: {
                Issue.record("Re-check must never invoke Copy")
                return false
            }).environment(\.accessibilityEnabled, true))
            let window = makeWindow(host: host, dark: dark)
            defer { window.contentView = nil; window.close() }
            await renderTurn(host, window: window)
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
                    await renderTurn(host, window: window)
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
                    await renderTurn(host, window: window)
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

        func waitUntilReading() async throws {
            if pending != nil { return }
            let events = AsyncStream<Void> { reading = $0 }
            for await _ in events { break }
            try Task.checkCancellation()
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

    private func renderTurn(_ host: NSView, window: NSWindow) async {
        // Commit pending SwiftUI work on the host run loop, without a delay or condition-polling loop.
        await withCheckedContinuation { continuation in
            RunLoop.main.perform { continuation.resume() }
        }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
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
        }
        return try #require(match, "Missing \(id) from the exposed host AX tree")
    }

    private func diagnostic(_ nodes: [NativeElement]) -> String {
        nodes.map { "\(type(of: $0.object)): \($0.identifier ?? "-") \($0.text.prefix(256))" }
            .joined(separator: "\n")
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
            host.addSubview(button)
            return button
        }
        let omitted = buttons[0], ignored = buttons[1], exposed = buttons[2]
        ignored.setAccessibilityElement(false)
        host.exposedChildren = [ignored]
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(omitted.isAccessibilityElement() && exposed.isAccessibilityElement())
        #expect(!ignored.isAccessibilityElement())

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
