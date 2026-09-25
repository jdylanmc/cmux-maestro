import AppKit
import SwiftUI
import Testing
import Carbon.HIToolbox

@MainActor
@Suite(.serialized)
struct SidebarSessionCopyTests {
    private let ownID = UUID(uuidString: "12345678-1234-5678-ABCD-1234567890AB")!
    private let parentID = UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")!

    private func views(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

    private func copyButton(in view: NSView) throws -> NSButton {
        try #require(views(in: view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "hover-copy-value" })
    }

    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        view.layoutSubtreeIfNeeded()
    }

    @Test func nativeCopyWritesOnlyExactGUIDAndSupportsRepeatedCopies() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("synthetic previous value", forType: .string)
        for id in [ownID, ownID, parentID] {
            #expect(SidebarSessionCopy.copy(id, to: pasteboard))
            #expect(pasteboard.string(forType: .string) == id.uuidString)
            #expect(pasteboard.pasteboardItems?.count == 1)
            #expect(pasteboard.pasteboardItems?.first?.types == [.string])
        }
    }

    @Test func cardCopiesOwnAndParentValuesAndResetsFeedbackOnIdentityChange() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var copies: [UUID] = []
        var succeeds = true
        func card(_ id: UUID, parent: Bool = false) -> SidebarHoverCard {
            SidebarHoverCard(
                data: .init(id: "same-card", category: "Agent preview", title: "Synthetic agent",
                            lines: [.sessionID(id, isParent: parent)]),
                close: { Issue.record("Copy must not close the preview") },
                copySessionID: {
                    copies.append($0)
                    return succeeds && SidebarSessionCopy.copy($0, to: pasteboard)
                }
            )
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: card(ownID))
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        let originalResponder = window.firstResponder
        try await settle(hosting)
        #expect(copies.isEmpty)
        var button = try copyButton(in: hosting)
        #expect(button.accessibilityRole() == .button)
        #expect(button.isAccessibilityElement())
        #expect(button.isAccessibilityEnabled())
        #expect(button.acceptsFirstResponder)
        #expect(button.accessibilityLabel() == "Copy session ID")
        #expect(button.accessibilityValue() as? String == "Not copied")
        for keyboard in [false, true] {
            if keyboard {
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                    isARepeat: false, keyCode: UInt16(kVK_Space)
                ))
                button.keyDown(with: event)
                let release = try #require(NSEvent.keyEvent(
                    with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                    isARepeat: false, keyCode: UInt16(kVK_Space)
                ))
                button.keyUp(with: release)
            } else {
                button.performClick(nil)
            }
            try await settle(hosting)
            button = try copyButton(in: hosting)
            #expect(button.accessibilityValue() as? String == "Copied")
            #expect(pasteboard.string(forType: .string) == ownID.uuidString)
        }
        #expect(copies == [ownID, ownID])
        hosting.rootView = card(ownID)
        try await settle(hosting)
        #expect(try copyButton(in: hosting).accessibilityValue() as? String == "Copied")
        #expect(copies == [ownID, ownID])
        succeeds = false
        #expect(button.accessibilityPerformPress())
        try await settle(hosting)
        button = try copyButton(in: hosting)
        #expect(button.accessibilityValue() as? String == "Could not copy. Try again.")
        succeeds = true
        #expect(button.accessibilityPerformPress())
        try await settle(hosting)
        #expect(try copyButton(in: hosting).accessibilityValue() as? String == "Copied")
        hosting.rootView = card(parentID, parent: true)
        try await settle(hosting)
        button = try copyButton(in: hosting)
        #expect(button.accessibilityLabel() == "Copy parent session ID")
        #expect(button.accessibilityValue() as? String == "Not copied")
        #expect(copies == [ownID, ownID, ownID, ownID])
        #expect(button.accessibilityPerformPress())
        try await settle(hosting)
        #expect(copies.last == parentID)
        #expect(pasteboard.string(forType: .string) == parentID.uuidString)
        button.isEnabled = false
        #expect(!button.accessibilityPerformPress())
        #expect(!button.acceptsFirstResponder)
        #expect(copies.count == 5)
        #expect(window.firstResponder === originalResponder)
        #expect(!window.isVisible)
    }

    @Test func standaloneControlResetsFeedbackWithoutIdentityOrSidebarDependencies() async throws {
        var copies = 0
        func value(_ text: String) -> SidebarCopyableValue {
            SidebarCopyableValue(value: text, label: "Example value", copy: { copies += 1; return true })
        }
        let hosting = NSHostingView(rootView: value("first"))
        hosting.frame = NSRect(x: 0, y: 0, width: 224, height: 100)
        try await settle(hosting)
        let button = try copyButton(in: hosting)
        #expect(button.accessibilityPerformPress())
        try await settle(hosting)
        #expect(button.accessibilityValue() as? String == "Copied")
        hosting.rootView = value("second")
        try await settle(hosting)
        #expect(try copyButton(in: hosting).accessibilityValue() as? String == "Not copied")
        #expect(copies == 1)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "CMUXMaestroSidebar/UI/SidebarCopyableValue.swift"
        ), encoding: .utf8)
        for forbidden in ["NSPasteboard", "SidebarPreferences", "SidebarNavigation", "UserDefaults", "SidebarCopilot", "context.host"] {
            #expect(!source.contains(forbidden))
        }
    }

    @Test func openingHoverExplicitPreviewAndRefreshingNeverCopy() throws {
        var copies = 0
        let presenter = SidebarHoverPresenter(copySessionID: { _ in copies += 1; return true },
                                              showPanel: { _, _, _ in })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        window.contentView = anchor
        defer { presenter.detach(); window.contentView = nil; window.close() }
        let originalResponder = window.firstResponder
        for explicit in [false, true] {
            for id in [ownID, parentID] {
                presenter.update(
                    anchor: anchor,
                    data: .init(id: "same-card", category: "Agent preview", title: "Synthetic agent",
                                lines: [.sessionID(id)]), group: nil
                )
                presenter.open(explicit: explicit)
                presenter.hoverCard(true)
                let panel = try #require(presenter.panel)
                #expect(panel.canBecomeKey == explicit && !panel.canBecomeMain)
                #expect(!panel.isVisible)
            }
            presenter.dismiss(restoreFocus: true)
        }
        #expect(copies == 0)
        #expect(window.firstResponder === originalResponder)
    }

    @Test func plainOrUnavailableRowsDoNotExposeCopyControls() async throws {
        let hosting = NSHostingView(rootView: SidebarHoverCard(
            data: .init(id: "unavailable", category: "Agent preview", title: "Synthetic agent", lines: [
                .sessionID(ownID, canCopy: false),
                .init(title: "Worker ID", value: parentID.uuidString)
            ]),
            close: {}, copySessionID: { _ in Issue.record("No copy action is available"); return false }
        ))
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 260)
        try await settle(hosting)
        #expect(!views(in: hosting).contains { $0.accessibilityIdentifier() == "hover-copy-value" })
    }

    @Test(arguments: [false, true])
    func narrowCardKeepsCopyAccessibleAndFeedbackVisible(dark: Bool) async throws {
        for width in [224, 300] {
            let frame = NSRect(x: 0, y: 0, width: width, height: 260)
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            var copies = 0
            var succeeds = true
            let hosting = NSHostingView(rootView: SidebarHoverCard(
                data: .init(id: "synthetic-parent", category: "Agent preview", title: "Synthetic child",
                            lines: [.sessionID(parentID, isParent: true)]),
                close: {}, copySessionID: { _ in copies += 1; return succeeds }
            ).environment(\.colorScheme, dark ? .dark : .light)
                .background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = hosting
            defer { window.contentView = nil; window.close() }
            hosting.frame = frame
            try await settle(hosting)
            #expect(copies == 0)
            for success in [true, false] {
                succeeds = success
                let button = try copyButton(in: hosting)
                let buttonFrame = button.accessibilityFrame()
                #expect(buttonFrame.width >= 24 && buttonFrame.height >= 24)
                #expect(window.frame.contains(buttonFrame))
                #expect(button.accessibilityPerformPress())
                try await settle(hosting)
                #expect(try copyButton(in: hosting).accessibilityValue() as? String
                    == (success ? "Copied" : "Could not copy. Try again."))
                let metrics = SidebarRenderingEvidence.metrics(for: hosting)
                #expect(metrics.documentWidth <= metrics.viewportWidth + 0.5)
                #expect(!window.isVisible)
                // Fix capture density before rasterization, rather than enlarging a display-dependent 1x PNG.
                let captureScale = 2
                let bitmap = try #require(NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(hosting.bounds.width) * captureScale,
                    pixelsHigh: Int(hosting.bounds.height) * captureScale,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                ))
                bitmap.size = hosting.bounds.size
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                #expect(bitmap.pixelsWide == width * 2 && bitmap.pixelsHigh == 520)
                let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent(".build/layout-validation/offscreen")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let image = root.appendingPathComponent(
                    "hover-session-copy-\(width)-\(dark ? "dark" : "light")-\(success ? "success" : "failure").png"
                )
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: image)
                let text = try SidebarRenderingEvidence.recognizedLines(in: image, dark: dark, naturalLanguage: true)
                    .joined(separator: " ")
                #expect(text.localizedCaseInsensitiveContains("Parent session ID"))
                #expect(text.contains(success ? "Copied" : "Could not copy"))
            }
            #expect(copies == 2)
        }
    }
}
