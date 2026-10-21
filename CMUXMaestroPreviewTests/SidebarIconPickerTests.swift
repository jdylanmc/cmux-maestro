import AppKit
import SwiftUI
import Testing
import Carbon.HIToolbox

@MainActor
@Suite(.serialized, SidebarAppKitTestScope())
struct SidebarIconPickerTests {
    @Test func iconPickerIncludesANativeColorWellWithoutOpeningThePanel() throws {
        var changes: [SidebarIconChoice] = []
        let picker = SidebarIconPicker(
            catalog: try SidebarGlyphCatalog.shared.get(),
            selection: .init(glyph: "md-duck", color: .teal), source: "Your choice",
            choose: { changes.append($0) },
            resetDefault: {}, close: {}
        )
        let host = NSHostingView(rootView: picker)
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 520)
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let wells = descendants(host).compactMap { $0 as? NSColorWell }
        let well = try #require(wells.first)
        #expect(wells.count == 1)
        #expect(changes.isEmpty, "Rendering must not change the color")
        #expect(!NSColorPanel.sharedColorPanelExists || !NSColorPanel.shared.isVisible)
        well.color = NSColor(srgbRed: 0x12 / 255.0, green: 0xab / 255.0, blue: 0xef / 255.0, alpha: 1)
        #expect(well.sendAction(well.action, to: well.target))
        #expect(changes == [.init(glyph: "md-duck", color: try #require(SidebarAvatarColor(rawValue: "#12ABEF")))])
    }

    @Test func customColorDragCommitsOnlyOnceWhenPanelCloses() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let target = SidebarIconTarget.session(UUID())
        let initial = SidebarIconChoice(glyph: "md-duck", color: .teal)
        preferences.setIcon(initial, for: target)
        let file = fixture.root.appendingPathComponent("sidebar-icons.json")
        let before = try Data(contentsOf: file)
        var writes = 0
        let host = NSHostingView(rootView: SidebarIconPicker(
            catalog: try SidebarGlyphCatalog.shared.get(), selection: initial, source: "Your choice",
            choose: { writes += 1; preferences.setIcon($0, for: target) }, resetDefault: {}, close: {}
        ))
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 520)
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let well = try #require(descendants(host).compactMap { $0 as? NSColorWell }.first)
        #expect(well.accessibilityPerformPress())
        let panel = NSColorPanel.shared
        defer { panel.close() }
        #expect(panel.isVisible)
        for hex in ["#123456", "#ABCDEF", "#FEDCBA"] {
            well.color = try #require(SidebarTagColor(hex: hex)).nativeColor
            #expect(well.sendAction(well.action, to: well.target))
        }
        #expect(writes == 0)
        #expect(try Data(contentsOf: file) == before)
        panel.close()
        #expect(writes == 1)
        #expect(preferences.icons.resolve(target: target, standard: initial, agent: nil).choice.color.rawValue == "#FEDCBA")
        well.activate(true)
        #expect(well.sendAction(well.action, to: well.target))
        panel.close()
        #expect(writes == 1, "Opening and closing an unchanged canonical color must not write")
    }

    @Test func nativePanelKeepsTransientTagPopoverAndSavesItsOpenDraft() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let session = UUID()
        #expect(preferences.setHumanTags("release", for: session) == nil)
        var draft = SidebarTagDraft(text: "release, review")
        let edit = SidebarColorEdit()
        let original = preferences.tagSettings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: window.frame)
        window.contentView = anchor
        window.orderFront(nil)
        let popover = NSPopover()
        popover.animates = false
        popover.behavior = .transient
        let content = NSHostingController(rootView: SidebarCustomColorPicker(
            color: NSColor.systemTeal, edit: edit, choose: { draft.colors["release"] = .some(.custom($0)) }
        ).padding(12).frame(width: 220, height: 80))
        popover.contentViewController = content
        defer { NSColorPanel.shared.close(); popover.close(); window.close() }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        content.view.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let well = try #require(descendants(content.view).compactMap { $0 as? SidebarNativeColorWell }.first)
        #expect(popover.isShown)
        let nativeWindow = try #require(well.window)
        let point = well.convert(NSPoint(x: well.bounds.midX, y: well.bounds.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: nativeWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        well.mouseDown(with: down)
        let panel = NSColorPanel.shared
        #expect(panel.isVisible)
        #expect(!well.supportsAlpha)
        #expect(panel.parent === content.view.window)
        panel.makeKeyAndOrderFront(nil)
        well.color = try #require(SidebarTagColor(hex: "#123456")).nativeColor
        #expect(well.sendAction(well.action, to: well.target))
        popover.performClose(nil)
        #expect(popover.isShown, "The open native panel must prevent outside-click dismissal")
        #expect(draft.text == "release, review" && draft.colors.isEmpty)
        edit.finish()
        #expect(popover.isShown)
        #expect(draft.colors["release"] == .some(.custom(try #require(SidebarTagColor(hex: "#123456")))))
        #expect(preferences.tagSettings == original, "Finishing the native edit changes only the draft")
        #expect(draft.commit(to: preferences, session: session) == nil)
        #expect(preferences.humanTags(for: session) == ["release", "review"])
        #expect(preferences.tags(for: session).first?.background.hex == "#123456")
        popover.performClose(nil)
        #expect(!popover.isShown, "Closing the panel must restore normal popover dismissal")
    }

    @Test func refusingAForeignPanelDoesNotDetachOrCloseIt() throws {
        let foreignWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        foreignWindow.isReleasedWhenClosed = false
        let panel = NSColorPanel.shared
        foreignWindow.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        defer { foreignWindow.removeChildWindow(panel); panel.close(); foreignWindow.close() }
        let well = SidebarNativeColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        var unavailable = false
        var writes = 0
        well.configure(color: .systemTeal, label: "Custom", choose: { _ in writes += 1 }, unavailable: { unavailable = $0 })
        #expect(!well.accessibilityPerformPress())
        #expect(unavailable && !well.isActive)
        well.cancel()
        well.finish()
        #expect(panel.parent === foreignWindow && panel.isVisible)
        #expect(writes == 0)
    }

    @Test func cancellingAPendingNativeColorDiscardsTheDraft() {
        let well = SidebarNativeColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        var changes: [SidebarTagColor] = []
        well.configure(color: .systemTeal, label: "Custom", choose: { changes.append($0) }, unavailable: { _ in })
        #expect(well.accessibilityPerformPress())
        defer { NSColorPanel.shared.close() }
        well.color = .red
        #expect(well.sendAction(well.action, to: well.target))
        well.cancel()
        #expect(!well.isActive && !NSColorPanel.shared.isVisible)
        #expect(changes.isEmpty)
    }

    @Test func successfulActivationClearsAnEarlierForeignPanelWarning() {
        let foreignWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        foreignWindow.isReleasedWhenClosed = false
        let panel = NSColorPanel.shared
        foreignWindow.addChildWindow(panel, ordered: .above)
        defer { panel.close(); foreignWindow.close() }
        let well = SidebarNativeColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        var unavailable = false
        well.configure(color: .systemTeal, label: "Custom", choose: { _ in }, unavailable: { unavailable = $0 })
        #expect(!well.accessibilityPerformPress())
        #expect(unavailable)
        foreignWindow.removeChildWindow(panel)
        #expect(well.accessibilityPerformPress())
        #expect(panel.isVisible && !unavailable, "Successful retry must clear the warning before any color change")
        well.cancel()
    }

    @Test(arguments: [false, true])
    func sameColorResetDiscardsPendingCustomColor(resetToAgent: Bool) throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let target = SidebarIconTarget.session(UUID())
        let standard = SidebarIconChoice(glyph: "md-robot", color: .theme)
        let agent = SidebarIconChoice(glyph: "md-cat", color: .theme)
        preferences.setIcon(.init(glyph: "md-duck", color: .theme), for: target)
        let edit = SidebarColorEdit()
        let well = SidebarNativeColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        edit.attach(well)
        var changes = 0
        let choose: (SidebarTagColor) -> Void = { color in
            changes += 1
            preferences.setIcon(.init(glyph: "md-duck", color: .custom(color)), for: target)
        }
        well.configure(color: .labelColor, label: "Custom", choose: choose, unavailable: { _ in })
        #expect(well.accessibilityPerformPress())
        defer { NSColorPanel.shared.close() }
        well.color = .red
        #expect(well.sendAction(well.action, to: well.target))
        edit.cancel()
        if resetToAgent { preferences.resetIconToAgentSelection(for: target) }
        else { preferences.resetIconToDefault(for: target) }
        let resolved = preferences.icons.resolve(target: target, standard: standard, agent: agent)
        #expect(resolved.choice == (resetToAgent ? agent : standard))
        well.configure(color: resolved.choice.color.nativeColor, label: "Custom", choose: choose, unavailable: { _ in })
        NSColorPanel.shared.close()
        edit.finish()
        #expect(changes == 0 && !well.isActive)
        #expect(preferences.icons.resolve(target: target, standard: standard, agent: agent).choice == resolved.choice)
    }

    @Test func externalResetCancelsAnOpenColorEditWithoutOverwritingIt() throws {
        let well = SidebarNativeColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        var changes: [SidebarTagColor] = []
        well.configure(color: .systemTeal, label: "Custom", choose: { changes.append($0) }, unavailable: { _ in })
        well.activate(true)
        defer { NSColorPanel.shared.close() }
        well.color = .red
        #expect(well.sendAction(well.action, to: well.target))
        well.configure(color: .black, label: "Custom", choose: { changes.append($0) }, unavailable: { _ in })
        #expect(!well.isActive && changes.isEmpty)
        #expect(SidebarTagColor(nativeColor: well.color) == .black)
        NSColorPanel.shared.close()
        #expect(changes.isEmpty)
    }

    @Test func customIconUsesAnOpaqueNonTemplateImageWithAContrastingOutline() throws {
        let custom = try #require(SidebarAvatarColor(rawValue: "#FFFFFF"))
        let host = NSHostingView(rootView: SidebarIconPickerButton(
            catalog: try SidebarGlyphCatalog.shared.get(), selection: .init(glyph: "md-robot", color: custom),
            label: "Example", enabled: true, action: {}
        ))
        host.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let button = try #require(descendants(host).compactMap { $0 as? SidebarIconNativeButton }.first)
        let image = try #require(button.image)
        #expect(!image.isTemplate)
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        var white = 0, black = 0
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
            let pixel = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            if pixel.alphaComponent > 0.9 {
                if pixel.redComponent > 0.9 { white += 1 }
                if pixel.redComponent < 0.1 { black += 1 }
            }
        } }
        #expect(white > 0 && black > 0, "White glyph must retain a black outline on a white row")
    }

    @Test func staleMenuIconRequestCannotRetargetAReplacementSession() {
        let original = SidebarIconTarget.session(UUID())
        let replacement = SidebarIconTarget.session(UUID())
        #expect(SidebarItemIcon.requestIsCurrent(original, target: original))
        #expect(!SidebarItemIcon.requestIsCurrent(original, target: replacement))
        #expect(!SidebarItemIcon.requestIsCurrent(original, target: nil))
        #expect(SidebarItemIcon.requestIsCurrent(nil, target: replacement))
    }

    @Test func catalogSearchCoversTheWholeFontAndAliasesDeterministically() throws {
        let catalog = try SidebarGlyphCatalog.shared.get()
        let all = catalog.search("")
        #expect(all.count == 10_994)
        #expect(Set(all.map(\.name)).count == all.count)
        #expect(all.first?.name == "md-robot")
        #expect(all.map(\.name) == catalog.search(" \n ").map(\.name))
        #expect(catalog.search("RUBBER duck").contains { $0.name == "md-duck" })
        #expect(catalog.search("nf-md-bug_check").contains { $0.name == "md-bug_check" })
        #expect(catalog.search("code braces").contains { $0.name == "md-code_braces" })
        #expect(catalog.search("browser").contains { $0.name == "fa-edge" })
        #expect(catalog.search("not-a-real-icon-xyzzy").isEmpty)
    }

    @Test func controlledPickerEmitsOnlyInjectedCallbacks() throws {
        let catalog = try SidebarGlyphCatalog.shared.get()
        let original = SidebarIconChoice(glyph: "md-duck", color: .teal)
        var changes: [SidebarIconChoice] = []
        var defaults = 0, agents = 0, closes = 0
        let picker = SidebarIconPicker(
            catalog: catalog, selection: original, source: "Example owner",
            choose: { changes.append($0) }, resetDefault: { defaults += 1 },
            resetAgentSelection: { agents += 1 }, close: { closes += 1 }
        )
        picker.selectGlyph("nf-fa-edge")
        picker.selectColor(.purple)
        #expect(changes == [.init(glyph: "fa-edge", color: .teal), .init(glyph: "md-duck", color: .purple)])
        #expect(picker.selection == original)
        #expect(defaults == 0 && agents == 0 && closes == 0)
        picker.resetDefault()
        picker.resetAgentSelection?()
        picker.close()
        #expect(defaults == 1 && agents == 1 && closes == 1)
        let nonAgent = SidebarIconPicker(
            catalog: catalog, selection: original, source: "Default",
            choose: { _ in }, resetDefault: {}, close: {}
        )
        #expect(nonAgent.resetAgentSelection == nil)
    }

    @Test func nativeAnchorUsesOneActionForPrimarySecondaryControlClickAndKeyboard() throws {
        let button = SidebarIconNativeButton()
        var opened = 0
        button.activate = { opened += 1 }
        button.performClick(nil)
        let right = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        button.rightMouseDown(with: right)
        let controlClick = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: .control, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        button.mouseDown(with: controlClick)
        let keyboard = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(kVK_F10)
        ))
        button.keyDown(with: keyboard)
        #expect(opened == 4)
        let pageDown = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(kVK_PageDown)
        ))
        button.keyDown(with: pageDown)
        #expect(opened == 4)
        #expect(button.accessibilityPerformPress())
        #expect(opened == 5)
        button.isEnabled = false
        button.rightMouseDown(with: right)
        button.mouseDown(with: controlClick)
        button.keyDown(with: keyboard)
        button.keyDown(with: pageDown)
        #expect(!button.accessibilityPerformPress())
        #expect(opened == 5)
    }

    @Test(arguments: [false, true])
    func pickerRendersWithoutAnySidebarEnvironment(dark: Bool) async throws {
        let catalog = try SidebarGlyphCatalog.shared.get()
        let picker = SidebarIconPicker(
            catalog: catalog, selection: .init(glyph: "md-duck", color: try #require(SidebarAvatarColor(rawValue: "#12ABEF"))),
            source: "Your choice",
            choose: { _ in Issue.record("Rendering must not select an icon") },
            resetDefault: { Issue.record("Rendering must not reset preferences") },
            resetAgentSelection: { Issue.record("Rendering must not follow an agent") },
            close: { Issue.record("Rendering must not dismiss") }
        )
        let frame = NSRect(x: 0, y: 0, width: 280, height: 510)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: picker
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.frame = frame
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        hosting.layoutSubtreeIfNeeded()
        #expect(!window.isVisible)
        #expect(hosting.fittingSize.width <= 280.5)
        let metrics = SidebarRenderingEvidence.metrics(for: hosting)
        #expect(metrics.documentWidth <= metrics.viewportWidth + 0.5)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let scale = Double(bitmap.pixelsHigh) / Double(hosting.bounds.height)
        var coloredGridPixels = 0
        for y in Int(140 * scale)..<Int(345 * scale) {
            for x in 0..<bitmap.pixelsWide {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if max(color.redComponent, color.greenComponent, color.blueComponent)
                    - min(color.redComponent, color.greenComponent, color.blueComponent) > 0.08 {
                    coloredGridPixels += 1
                }
            }
        }
        #expect(coloredGridPixels == 0, "Catalog grid must remain neutral even with an opt-in teal selection")
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1_024)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("icon-picker-\(dark ? "dark" : "light").png")
        try png.write(to: image)
        let text = try SidebarRenderingEvidence.recognizedLines(in: image, dark: dark, naturalLanguage: true)
        for label in ["Choose icon", "Your choice", "Reset to default", "Reset to agent selection"] {
            #expect(text.contains(label), "Missing visible picker control: \(label); OCR: \(text)")
        }
    }

    @Test func componentSourcesDeclareAccessibilityAndHaveNoSidebarSideEffects() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("CMUXMaestroSidebar/UI/SidebarIconPicker.swift"), encoding: .utf8)
        for forbidden in ["SidebarPreferences", "SidebarNavigation", "SidebarCopilot", "UserDefaults", "FileManager", "SidebarSeen"] {
            #expect(!source.contains(forbidden))
        }
        for required in [".accessibilityLabel", ".accessibilityValue", ".focused", ".onMoveCommand", ".cancelAction"] {
            #expect(source.contains(required))
        }
        for id in ["icon-picker-search", "icon-picker-glyph-", "icon-picker-color-", "icon-picker-reset-default", "icon-picker-reset-agent"] {
            #expect(source.contains(id))
        }
    }
}
