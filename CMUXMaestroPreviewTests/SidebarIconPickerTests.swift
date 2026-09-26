import AppKit
import SwiftUI
import Testing
import Carbon.HIToolbox

@MainActor
@Suite(.serialized, SidebarAppKitTestScope())
struct SidebarIconPickerTests {
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
            catalog: catalog, selection: .init(glyph: "md-duck", color: .teal), source: "Your choice",
            choose: { _ in Issue.record("Rendering must not select an icon") },
            resetDefault: { Issue.record("Rendering must not reset preferences") },
            resetAgentSelection: { Issue.record("Rendering must not follow an agent") },
            close: { Issue.record("Rendering must not dismiss") }
        )
        let frame = NSRect(x: 0, y: 0, width: 280, height: 470)
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
        let text = try SidebarRenderingEvidence.recognizedLines(in: image, dark: dark, naturalLanguage: true).joined(separator: " ")
        for label in ["Choose icon", "Your choice", "Reset to default", "Reset to agent selection"] {
            #expect(text.localizedCaseInsensitiveContains(label), "Missing visible picker control: \(label); OCR: \(text)")
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
