import AppKit
import SwiftUI
import Testing
import Carbon.HIToolbox

@MainActor
@Suite(.serialized, SidebarAppKitTestScope())
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

    private func feedbackControl(in view: NSView) -> NSTextField? {
        views(in: view).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "hover-copy-feedback" }
    }

    private func hasVisibleFeedback(_ text: String, in view: NSView) -> Bool {
        guard let label = feedbackControl(in: view),
              label.stringValue == text,
              label.isAccessibilityElement(), label.accessibilityRole() == .staticText,
              label.accessibilityValue() == text else { return false }
        // SwiftUI aligns NSTextField by its content rect, excluding native transparent alignment margins.
        let drawing = label.alignmentRect(forFrame: label.bounds)
        guard drawing.width > 0, drawing.height > 0,
              label.visibleRect.contains(drawing),
              view.bounds.contains(view.convert(drawing, from: label)) else { return false }
        var ancestor: NSView? = label
        while let current = ancestor {
            guard !current.isHidden, current.alphaValue > 0,
                  current.layer?.isHidden != true, current.layer?.opacity != 0 else { return false }
            ancestor = current.superview
        }
        if let viewport = label.enclosingScrollView?.contentView {
            guard viewport.bounds.contains(viewport.convert(drawing, from: label)) else { return false }
        }
        return true
    }

    private func capture(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width) * 2, pixelsHigh: Int(view.bounds.height) * 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func feedbackInk(in bitmap: NSBitmapImageRep, label: NSTextField, view: NSView) throws -> Int {
        let rect = view.convert(label.alignmentRect(forFrame: label.bounds), from: label)
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let minX = Int(ceil(rect.minX * scale)), maxX = Int(floor(rect.maxX * scale))
        let top = view.isFlipped ? rect.minY : view.bounds.height - rect.maxY
        let minY = Int(ceil(top * scale)), maxY = Int(floor((top + rect.height) * scale))
        try #require(minX >= 0 && minY >= 0 && maxX <= bitmap.pixelsWide && maxY <= bitmap.pixelsHigh)
        try #require(minX < maxX && minY < maxY)
        let background = try #require(bitmap.colorAt(x: minX, y: minY)?.usingColorSpace(.deviceRGB))
        var ink = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if max(abs(color.redComponent - background.redComponent),
                       abs(color.greenComponent - background.greenComponent),
                       abs(color.blueComponent - background.blueComponent)) > 0.1 {
                    ink += 1
                }
            }
        }
        return ink
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

    @Test func nativeCopyWritesExactRawStringsAndRejectsEmptyValuesWithoutClearingClipboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let raw = "/Users/example/repository/../workspace"
        pasteboard.setString("previous", forType: .string)
        #expect(SidebarSessionCopy.copy(raw, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == raw)
        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(!SidebarSessionCopy.copy("", to: pasteboard))
        #expect(pasteboard.string(forType: .string) == raw)
    }

    @Test func copyableFieldKeepsActionOnLabelAndCopiesOnlyOnEnter() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let raw = "/synthetic/worktree/../project"
        var writes: [String] = []
        var focus: [Bool] = []
        let frame = NSRect(x: 0, y: 0, width: 260, height: 90)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: SidebarCopyableValue(
            value: "~/project", label: "Workspace path", clipboardValue: raw,
            copy: {
                writes.append($0)
                return SidebarSessionCopy.copy($0, to: pasteboard)
            },
            focusChanged: { focus.append($0) }
        ))
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.frame = frame
        try await settle(hosting)

        let button = try copyButton(in: hosting)
        let buttonRect = hosting.convert(button.bounds, from: button)
        #expect(button.accessibilityLabel() == "Copy workspace path")
        let targetRect = button.accessibilityFrame()
        #expect(targetRect.width >= 24 && targetRect.height >= 24)
        #expect(abs(buttonRect.width - 24) < 0.5)
        #expect(writes.isEmpty && pasteboard.string(forType: .string) == nil)
        let fieldImage = try capture(hosting)
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("copy-field-label-owner.png")
        try #require(fieldImage.representation(using: .png, properties: [:])).write(to: image)
        let lines = try SidebarRenderingEvidence.recognizedLines(in: image, dark: false, naturalLanguage: true)
        let labelIndex = try #require(lines.firstIndex(of: "Workspace path"))
        let valueIndex = try #require(lines.firstIndex {
            $0.localizedCaseInsensitiveContains("project") && !$0.localizedCaseInsensitiveContains("Workspace")
        })
        #expect(labelIndex < valueIndex)

        #expect(window.makeFirstResponder(button))
        try await settle(hosting)
        #expect(focus == [true])
        #expect(button.focusRingType == .exterior)
        #expect(hosting.convert(button.bounds, from: button) == buttonRect)
        #expect(writes.isEmpty)
        let enter = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        button.keyDown(with: enter)
        try await settle(hosting)
        #expect(writes == [raw])
        #expect(pasteboard.string(forType: .string) == raw)
    }

    @Test func nativeLabelHoverUsesOnlyItsFieldHeaderAndDoesNotCopyOrShiftLayout() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("previous", forType: .string)
        let rawValues = ["/synthetic/workspace", "/synthetic/project"]
        var writes: [String] = []
        let frame = NSRect(x: 0, y: 0, width: 260, height: 120)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: VStack(alignment: .leading, spacing: 4) {
            SidebarCopyableValue(
                value: "~/workspace", label: "Workspace path", clipboardValue: rawValues[0],
                copy: {
                    writes.append($0)
                    return SidebarSessionCopy.copy($0, to: pasteboard)
                }
            )
            SidebarCopyableValue(
                value: "~/project", label: "Project path", clipboardValue: rawValues[1],
                copy: {
                    writes.append($0)
                    return SidebarSessionCopy.copy($0, to: pasteboard)
                }
            )
        }.frame(width: frame.width, height: frame.height, alignment: .topLeading))
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.frame = frame
        try await settle(hosting)

        let buttons = views(in: hosting).compactMap { $0 as? NSButton }
            .filter { $0.accessibilityIdentifier() == "hover-copy-value" }
        let workspaceButton = try #require(buttons.first { $0.accessibilityLabel() == "Copy workspace path" })
        let projectButton = try #require(buttons.first { $0.accessibilityLabel() == "Copy project path" })
        let workspaceButtonRect = hosting.convert(workspaceButton.bounds, from: workspaceButton)
        let projectButtonRect = hosting.convert(projectButton.bounds, from: projectButton)
        let hoverViews = views(in: hosting).compactMap { $0 as? SidebarCopyableValueHoverView }
        let workspaceHoverView = try #require(hoverViews.first {
            hosting.convert($0.bounds, from: $0).contains(NSPoint(
                x: workspaceButtonRect.minX - 2, y: workspaceButtonRect.midY
            ))
        })
        let projectHoverView = try #require(hoverViews.first {
            hosting.convert($0.bounds, from: $0).contains(NSPoint(
                x: projectButtonRect.minX - 2, y: projectButtonRect.midY
            ))
        })
        let workspaceTrackingArea = try #require(workspaceHoverView.trackingAreas.first)
        let projectTrackingArea = try #require(projectHoverView.trackingAreas.first)
        let workspaceTrackingRect = hosting.convert(workspaceTrackingArea.rect, from: workspaceHoverView)
        let projectTrackingRect = hosting.convert(projectTrackingArea.rect, from: projectHoverView)
        let workspaceLabelPoint = NSPoint(
            x: (workspaceTrackingRect.minX + workspaceButtonRect.minX) / 2,
            y: workspaceTrackingRect.midY
        )
        let projectLabelPoint = NSPoint(
            x: (projectTrackingRect.minX + projectButtonRect.minX) / 2,
            y: projectTrackingRect.midY
        )
        let workspaceValuePoint = NSPoint(
            x: workspaceTrackingRect.minX + 12,
            y: workspaceTrackingRect.midY + (hosting.isFlipped ? 21 : -21)
        )
        let projectValuePoint = NSPoint(
            x: projectTrackingRect.minX + 12,
            y: projectTrackingRect.midY + (hosting.isFlipped ? 21 : -21)
        )
        let blankPoint = NSPoint(x: hosting.bounds.maxX - 3, y: workspaceTrackingRect.midY)
        let workspaceButtonPoint = NSPoint(x: workspaceButtonRect.midX, y: workspaceButtonRect.midY)

        func isVisiblyPainted(_ view: NSView) -> Bool {
            var ancestor: NSView? = view
            while let current = ancestor {
                if current.isHidden || current.alphaValue <= 0 ||
                    current.layer?.isHidden == true || current.layer?.opacity == 0 {
                    return false
                }
                ancestor = current.superview
            }
            return true
        }

        func enterExitEvent(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.enterExitEvent(
                with: type, location: hosting.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                trackingNumber: 0, userData: nil
            ))
        }

        func movePointer(to point: NSPoint) throws {
            let event = try #require(NSEvent.mouseEvent(
                with: .mouseMoved, location: hosting.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0
            ))
            window.sendEvent(event)
        }

        #expect(workspaceTrackingArea.options.contains(.mouseEnteredAndExited))
        #expect(projectTrackingArea.options.contains(.mouseEnteredAndExited))
        #expect(workspaceTrackingRect.contains(workspaceLabelPoint))
        #expect(workspaceTrackingRect.contains(workspaceButtonPoint))
        #expect(!workspaceTrackingRect.contains(workspaceValuePoint))
        #expect(!projectTrackingRect.contains(projectValuePoint))
        #expect(!workspaceTrackingRect.contains(blankPoint))
        #expect(!workspaceTrackingRect.contains(projectLabelPoint))
        #expect(!projectTrackingRect.contains(workspaceLabelPoint))
        #expect(!isVisiblyPainted(workspaceButton) && !isVisiblyPainted(projectButton))
        #expect(writes.isEmpty && pasteboard.string(forType: .string) == "previous")
        let initialWorkspaceButtonRect = workspaceButtonRect
        let initialProjectButtonRect = projectButtonRect
        let initialWorkspaceHoverRect = workspaceTrackingRect

        workspaceHoverView.mouseEntered(with: try enterExitEvent(.mouseEntered, at: workspaceButtonPoint))
        try await settle(hosting)
        #expect(!isVisiblyPainted(workspaceButton) && !isVisiblyPainted(projectButton))
        workspaceHoverView.mouseExited(with: try enterExitEvent(.mouseExited, at: blankPoint))

        for point in [workspaceValuePoint, projectValuePoint, blankPoint] {
            try movePointer(to: point)
            try await settle(hosting)
            #expect(!isVisiblyPainted(workspaceButton) && !isVisiblyPainted(projectButton))
        }

        workspaceHoverView.mouseEntered(with: try enterExitEvent(.mouseEntered, at: workspaceLabelPoint))
        try await settle(hosting)
        #expect(isVisiblyPainted(workspaceButton) && !isVisiblyPainted(projectButton))
        #expect(hosting.convert(workspaceButton.bounds, from: workspaceButton) == initialWorkspaceButtonRect)
        #expect(hosting.convert(workspaceHoverView.bounds, from: workspaceHoverView) == initialWorkspaceHoverRect)
        #expect(writes.isEmpty && pasteboard.string(forType: .string) == "previous")

        try movePointer(to: workspaceButtonPoint)
        try await settle(hosting)
        #expect(workspaceTrackingRect.contains(workspaceButtonPoint))
        #expect(isVisiblyPainted(workspaceButton) && !isVisiblyPainted(projectButton))
        #expect(hosting.convert(workspaceButton.bounds, from: workspaceButton) == initialWorkspaceButtonRect)

        workspaceHoverView.mouseExited(with: try enterExitEvent(.mouseExited, at: workspaceValuePoint))
        try await settle(hosting)
        #expect(!isVisiblyPainted(workspaceButton) && !isVisiblyPainted(projectButton))
        for point in [workspaceValuePoint, projectValuePoint, blankPoint] {
            try movePointer(to: point)
            try await settle(hosting)
            #expect(!isVisiblyPainted(workspaceButton) && !isVisiblyPainted(projectButton))
        }
        #expect(hosting.convert(projectButton.bounds, from: projectButton) == initialProjectButtonRect)
        #expect(writes.isEmpty && pasteboard.string(forType: .string) == "previous")

        projectHoverView.mouseEntered(with: try enterExitEvent(.mouseEntered, at: projectLabelPoint))
        try await settle(hosting)
        #expect(!isVisiblyPainted(workspaceButton) && isVisiblyPainted(projectButton))
        projectHoverView.mouseExited(with: try enterExitEvent(.mouseExited, at: projectValuePoint))
        try await settle(hosting)
        #expect(!isVisiblyPainted(workspaceButton) && !isVisiblyPainted(projectButton))
        #expect(writes.isEmpty && pasteboard.string(forType: .string) == "previous")
    }

    @Test func previewScrollResetsForANewSubjectButNotSameSubjectRefresh() async throws {
        func card(_ id: String, _ title: String, _ prefix: String) -> SidebarHoverCard {
            SidebarHoverCard(
                data: .init(
                    id: id, category: "Agent preview", title: title,
                    lines: (0..<30).map { .init(title: "Field \($0)", value: "\(prefix)-value-\($0)") }
                ),
                close: {}, copyValue: { _ in false }
            )
        }
        let frame = NSRect(x: 0, y: 0, width: 300, height: 260)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(card("subject-a", "Subject A", "a")))
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.frame = frame
        try await settle(hosting)
        func recognizedText(_ filename: String) throws -> [String] {
            let bitmap = try capture(hosting)
            let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/layout-validation/offscreen")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let image = folder.appendingPathComponent(filename)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: image)
            return try SidebarRenderingEvidence.recognizedLines(in: image, dark: false, naturalLanguage: true)
        }
        func scrollView() throws -> NSScrollView {
            try #require(views(in: hosting).compactMap { $0 as? NSScrollView }.first)
        }
        func scrollToBottom(_ scroll: NSScrollView) throws {
            let document = try #require(scroll.documentView)
            scroll.contentView.scroll(to: NSPoint(
                x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)
            ))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        var scroll = try scrollView()
        try scrollToBottom(scroll)
        #expect(scroll.contentView.bounds.origin.y > 0)
        hosting.rootView = AnyView(card("subject-b", "Subject B", "b"))
        try await settle(hosting)
        scroll = try scrollView()
        #expect(scroll.contentView.bounds.origin.y == 0)
        #expect(try recognizedText("preview-subject-b-top.png").contains("Subject B"))

        try scrollToBottom(scroll)
        #expect(scroll.contentView.bounds.origin.y > 0)
        hosting.rootView = AnyView(card("subject-b", "Subject B", "refreshed"))
        try await settle(hosting)
        scroll = try scrollView()
        #expect(scroll.contentView.bounds.origin.y > 0)
        #expect(try recognizedText("preview-subject-b-refresh-bottom.png").contains("refreshed-value-29"))
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
                    copyValue: {
                        guard let id = UUID(uuidString: $0) else {
                            Issue.record("Session ID copy must preserve the exact UUID")
                            return false
                        }
                        copies.append(id)
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
        #expect(feedbackControl(in: hosting) == nil)
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
            #expect(hasVisibleFeedback("Copied", in: hosting))
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
        #expect(hasVisibleFeedback("Could not copy. Try again.", in: hosting))
        succeeds = true
        #expect(button.accessibilityPerformPress())
        try await settle(hosting)
        #expect(try copyButton(in: hosting).accessibilityValue() as? String == "Copied")
        hosting.rootView = card(parentID, parent: true)
        try await settle(hosting)
        button = try copyButton(in: hosting)
        #expect(button.accessibilityLabel() == "Copy parent session ID")
        #expect(button.accessibilityValue() as? String == "Not copied")
        #expect(feedbackControl(in: hosting) == nil)
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
            SidebarCopyableValue(
                value: text, label: "Example value", clipboardValue: text,
                copy: { _ in copies += 1; return true }
            )
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
        let presenter = SidebarHoverPresenter(copyValue: { _ in copies += 1; return true },
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
            close: {}, copyValue: { _ in Issue.record("No copy action is available"); return false }
        ))
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 260)
        try await settle(hosting)
        #expect(!views(in: hosting).contains { $0.accessibilityIdentifier() == "hover-copy-value" })
    }

    @Test func feedbackInspectionRejectsWrongMissingHiddenClippedAndUnpaintedText() async throws {
        let hosting = NSHostingView(rootView: SidebarHoverCard(
            data: .init(id: "negative-controls", category: "Agent preview", title: "Synthetic agent",
                        lines: [.sessionID(ownID)]),
            close: {}, copyValue: { _ in true }
        ).background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = NSRect(x: 0, y: 0, width: 224, height: 260)
        try await settle(hosting)
        #expect(!hasVisibleFeedback("Copied", in: hosting))
        #expect(try copyButton(in: hosting).accessibilityPerformPress())
        try await settle(hosting)
        let label = try #require(feedbackControl(in: hosting))
        #expect(hasVisibleFeedback("Copied", in: hosting))
        #expect(try feedbackInk(in: capture(hosting), label: label, view: hosting) > 0)
        label.stringValue = "Wrong feedback"
        #expect(try copyButton(in: hosting).accessibilityValue() as? String == "Copied")
        #expect(!hasVisibleFeedback("Copied", in: hosting))
        label.stringValue = "Copied"
        label.isHidden = true
        #expect(!hasVisibleFeedback("Copied", in: hosting))
        label.isHidden = false
        let parent = try #require(label.superview)
        parent.isHidden = true
        #expect(!hasVisibleFeedback("Copied", in: hosting))
        parent.isHidden = false
        label.alphaValue = 0
        #expect(!hasVisibleFeedback("Copied", in: hosting))
        label.alphaValue = 1
        let frame = label.frame
        label.frame = .zero
        #expect(!hasVisibleFeedback("Copied", in: hosting))
        label.frame = frame.offsetBy(dx: 1_000, dy: 0)
        #expect(!hasVisibleFeedback("Copied", in: hosting))
        label.frame = frame
        label.textColor = .clear
        try await settle(hosting)
        #expect(hasVisibleFeedback("Copied", in: hosting))
        #expect(try feedbackInk(in: capture(hosting), label: label, view: hosting) == 0)
        label.textColor = .secondaryLabelColor
        try await settle(hosting)
        #expect(try feedbackInk(in: capture(hosting), label: label, view: hosting) > 0)
        label.removeFromSuperview()
        #expect(!hasVisibleFeedback("Copied", in: hosting))
    }

    @Test func nativeFeedbackWrapsWithoutClippingOrTakingFocus() async throws {
        let hosting = NSHostingView(rootView: SidebarCopyableValue(
            value: "Example", label: "Example value", clipboardValue: "raw-example", copy: { _ in false }
        ).background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        try await settle(hosting)
        #expect(try copyButton(in: hosting).accessibilityPerformPress())
        try await settle(hosting)
        let label = try #require(feedbackControl(in: hosting))
        #expect(hasVisibleFeedback("Could not copy. Try again.", in: hosting))
        #expect(label.bounds.height > NSFont.preferredFont(forTextStyle: .caption1).pointSize * 2)
        #expect(!label.acceptsFirstResponder)
        #expect(try feedbackInk(in: capture(hosting), label: label, view: hosting) > 0)
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
                close: {}, copyValue: { _ in copies += 1; return succeeds }
            ).environment(\.colorScheme, dark ? .dark : .light)
                .background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = hosting
            defer { window.contentView = nil; window.close() }
            hosting.frame = frame
            try await settle(hosting)
            #expect(copies == 0)
            #expect(feedbackControl(in: hosting) == nil)
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
                let feedback = try #require(feedbackControl(in: hosting))
                #expect(hasVisibleFeedback(success ? "Copied" : "Could not copy. Try again.", in: hosting),
                        "Bounds: \(feedback.bounds); visible: \(feedback.visibleRect); content: \(feedback.alignmentRect(forFrame: feedback.bounds))")
                #expect(!feedback.isEditable && !feedback.isSelectable && !feedback.acceptsFirstResponder)
                #expect(feedback.font == .preferredFont(forTextStyle: .caption1))
                #expect(feedback.textColor == .secondaryLabelColor)
                let metrics = SidebarRenderingEvidence.metrics(for: hosting)
                #expect(metrics.documentWidth <= metrics.viewportWidth + 0.5)
                #expect(!window.isVisible)
                let bitmap = try capture(hosting)
                #expect(bitmap.pixelsWide == width * 2 && bitmap.pixelsHigh == 520)
                let feedbackRect = hosting.convert(
                    feedback.alignmentRect(forFrame: feedback.bounds), from: feedback
                )
                let buttonImageRect = hosting.convert(
                    try #require(button.cell).imageRect(forBounds: button.bounds), from: button
                )
                #expect(!feedbackRect.intersects(buttonImageRect))
                #expect(try feedbackInk(in: bitmap, label: feedback, view: hosting) > 0)
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
            }
            #expect(copies == 2)
        }
    }
}
