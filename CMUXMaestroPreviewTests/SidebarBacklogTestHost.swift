import AppKit
import SwiftUI
import Testing

/// Hosted-only presentation calibration for the two backlog acceptance suites.
@MainActor
final class SidebarBacklogTestHost {
    let window: NSWindow
    private let container: NSViewController
    private let sidebar: HostingController
    private let minimal: HostingController
    private let originalPolicy: NSApplication.ActivationPolicy
    private let wasActive: Bool
    private let minimalPressCount: () -> Int
    private var attemptedMinimalPress = false
    private var closed = false
    private(set) var minimalActionPassed = false

    var content: NSView { sidebar.view }

    init<Content: View>(root: Content, width: CGFloat) throws {
        #if CMUX_VALIDATION
        let validationBuild = true
        #else
        let validationBuild = false
        #endif
        let environment = ProcessInfo.processInfo.environment
        let app = NSApplication.shared
        try #require(validationBuild, "Backlog calibration requires CMUX_VALIDATION.")
        try #require(Bundle.main.bundleIdentifier == "com.jdylanmc.CMUXMaestroPreview.Validation.Tests",
                     "Backlog calibration requires the exact isolated validation app.")
        try #require(environment["GITHUB_ACTIONS"] == "true"
                     && environment["RUNNER_ENVIRONMENT"] == "github-hosted",
                     "Backlog calibration requires the existing GitHub-hosted venue.")
        try #require(app.isRunning, "Backlog calibration requires a running public app lifecycle.")
        originalPolicy = app.activationPolicy()
        wasActive = app.isActive
        sidebar = HostingController(root: root.environment(\.accessibilityEnabled, true))
        var presses = 0
        minimalPressCount = { presses }
        minimal = HostingController(root:
            Button("Synthetic backlog host calibration") { presses += 1 }
                .accessibilityIdentifier("backlog-calibration-minimal")
                .frame(width: width, height: 64)
                .environment(\.accessibilityEnabled, true))
        container = NSViewController()
        container.view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 714))
        for (controller, frame) in [
            (sidebar, NSRect(x: 0, y: 0, width: width, height: 650)),
            (minimal, NSRect(x: 0, y: 650, width: width, height: 64))
        ] {
            container.addChild(controller)
            controller.view.frame = frame
            container.view.addSubview(controller.view)
        }
        window = NSWindow(contentRect: container.view.frame, styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Synthetic backlog host calibration"
        window.contentViewController = container
        window.center()
        do {
            if app.activationPolicy() != .regular {
                try #require(app.setActivationPolicy(.regular),
                             "Could not set the validation app's public activation policy.")
            }
            try #require(app.activationPolicy() == .regular)
        } catch {
            close()
            throw error
        }
        window.makeKeyAndOrderFront(nil)
        app.activate()
    }

    var isPresented: Bool {
        let app = NSApplication.shared
        return app.isRunning && app.isActive && app.activationPolicy() == .regular
            && window.isVisible && window.isKeyWindow && window.occlusionState.contains(.visible)
            && window.contentViewController === container && window.contentView === container.view
            && sidebar.parent === container && minimal.parent === container
            && sidebar.view.window === window && minimal.view.window === window
            && sidebar.appeared && minimal.appeared
    }

    // Shares the caller's existing bounded readiness wait; never retries a press.
    func sampleReadiness() -> Bool {
        container.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let actions = elements(in: minimal.view).filter { $0.identifier == "backlog-calibration-minimal" }
        if !attemptedMinimalPress, isPresented, actions.count == 1,
           actions[0].role == NSAccessibility.Role.button.rawValue, actions[0].enabled,
           let frame = actions[0].frame, frame.width > 0, frame.height > 0 {
            let viewport = window.convertToScreen(minimal.view.convert(minimal.view.bounds, to: nil))
            let intersection = viewport.intersection(frame)
            if intersection.width > 0 && intersection.height > 0 {
                attemptedMinimalPress = true
                let pressed = actions[0].press()
                #expect(pressed)
                #expect(minimalPressCount() == 1)
                minimalActionPassed = pressed && minimalPressCount() == 1
            }
        }
        return isPresented && minimalActionPassed
    }

    func diagnose(stage: String) {
        let app = NSApplication.shared
        print("Backlog calibration \(stage): running=\(app.isRunning) active=\(app.isActive) "
              + "policy=\(app.activationPolicy().rawValue) visible=\(window.isVisible) key=\(window.isKeyWindow) "
              + "occlusion=\(window.occlusionState.rawValue) presented=\(isPresented) "
              + "minimalAttempted=\(attemptedMinimalPress) minimalPassed=\(minimalActionPassed) "
              + "minimalPresses=\(minimalPressCount())")
        print("Backlog controller sidebar: \(sidebar.observation); minimal: \(minimal.observation)")
        for (name, view) in [("sidebar", sidebar.view), ("minimal", minimal.view)] {
            let nodes = elements(in: view)
            print("Backlog \(name) exposed AX: \(nodes.count) nodes, showing \(min(nodes.count, 100))")
            for node in nodes.prefix(100) {
                print("\(Swift.type(of: node.object)) id=\(node.identifier ?? "-") "
                      + "role=\(node.role ?? "-") label=\(node.label ?? "-")")
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        window.orderOut(nil)
        window.contentViewController = nil
        window.contentView = nil
        window.close()
        sidebar.removeFromParent()
        minimal.removeFromParent()
        let app = NSApplication.shared
        if !wasActive { app.deactivate() }
        if app.activationPolicy() != originalPolicy {
            #expect(app.setActivationPolicy(originalPolicy),
                    "Could not restore the validation app's activation policy.")
        }
        #expect(app.activationPolicy() == originalPolicy)
        #expect(!window.isVisible)
    }

    private struct Element {
        let object: NSObject
        var identifier: String? { (object as AnyObject).accessibilityIdentifier?() ?? nil }
        var label: String? { (object as AnyObject).accessibilityLabel?() ?? nil }
        var role: String? { (object as AnyObject).accessibilityRole?()?.rawValue }
        var enabled: Bool { (object as AnyObject).isAccessibilityEnabled?() ?? false }
        var frame: NSRect? { (object as AnyObject).accessibilityFrame?() }
        func press() -> Bool { (object as AnyObject).accessibilityPerformPress?() ?? false }
    }

    private func elements(in view: NSView) -> [Element] {
        var pending: [NSObject] = [view]
        var visited = Set<ObjectIdentifier>()
        var result: [Element] = []
        while result.count < 2_048, let object = pending.popLast() {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            result.append(.init(object: object))
            let children = (object as AnyObject).accessibilityChildren?() ?? []
            pending += NSAccessibility.unignoredChildren(from: children).compactMap { $0 as? NSObject }
        }
        #expect(pending.isEmpty, "Backlog calibration exceeded its exposed-tree inspection bound.")
        return result
    }

    @MainActor
    private final class HostingController: NSHostingController<AnyView> {
        private(set) var appeared = false

        init<Content: View>(root: Content) { super.init(rootView: AnyView(root)) }
        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidAppear() {
            super.viewDidAppear()
            appeared = true
        }

        override func viewDidDisappear() {
            super.viewDidDisappear()
            appeared = false
        }

        var observation: String {
            "controller=\(ObjectIdentifier(self)) view=\(ObjectIdentifier(view)) appeared=\(appeared) "
                + "frame=\(view.frame) hidden=\(view.isHiddenOrHasHiddenAncestor) "
                + "window=\(String(describing: view.window?.windowNumber))"
        }
    }
}
