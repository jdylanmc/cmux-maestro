import AppKit
import SwiftUI
import Testing

@MainActor
@Suite(SidebarAppKitTestScope())
struct SidebarStoreInjectionTests {
    private func window(_ view: some View, size: NSSize) -> (NSWindow, NSHostingView<AnyView>) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func redPixels(footer content: SidebarDetailContent, pets: SidebarPetStore) throws -> Int {
        let footer = SidebarPinnedFooter(content: content, pets: pets, maximumHeight: 200,
                                         inspect: { Issue.record("Rendering must not inspect") })
            .background(Color.white)
        let (window, host) = window(footer, size: NSSize(width: 300, height: 120))
        defer { window.contentView = nil; window.close() }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var red = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent - max(color.greenComponent, color.blueComponent) > 0.5 { red += 1 }
            }
        }
        return red
    }

    @Test func headerRefreshesItsInjectedBeatsStore() async throws {
        let stores = SidebarStoreFixture()
        defer { stores.cleanup() }
        let session = UUID()
        _ = try SidebarBeatsFile(root: stores.root.appendingPathComponent("Beats", isDirectory: true))
            .mutate { _ = try $0.create(session: session, cron: "0 9 * * *", prompt: "Synthetic beat") }
        #expect(stores.beats.beats.isEmpty)
        let (window, _) = window(SidebarHeader(beats: stores.beats, taskboardActive: false, activate: { _ in }),
                                 size: NSSize(width: 280, height: 40))
        defer { window.contentView = nil; window.close() }
        let deadline = ContinuousClock.now + .seconds(5)
        while stores.beats.beats.isEmpty, ContinuousClock.now < deadline {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(stores.beats.beats.map(\.sessionId) == [session.uuidString.lowercased()])
    }

    @Test func footerDrawsTheAgentPetFromItsInjectedStore() throws {
        let stores = SidebarStoreFixture()
        defer { stores.cleanup() }
        let session = UUID()
        let folder = stores.root.appendingPathComponent("PetSessions/\(session.uuidString.lowercased())/blob",
                                                        isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sheet = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1536, pixelsHigh: 1872, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1536, height: 1872).fill()
        NSGraphicsContext.restoreGraphicsState()
        try #require(sheet.representation(using: .png, properties: [:]))
            .write(to: folder.appendingPathComponent("spritesheet.png"))
        try Data(#"{"id":"blob","displayName":"Synthetic Blob","spritesheetPath":"spritesheet.png"}"#.utf8)
            .write(to: folder.appendingPathComponent("pet.json"))
        let content = SidebarDetailContent(title: "Synthetic agent", isAgent: true, petSessionID: session,
                                           petChoice: "blob")
        // Only the store holding this session's pet draws it; another store falls back.
        let other = SidebarStoreFixture()
        defer { other.cleanup() }
        #expect(try redPixels(footer: content, pets: stores.pets) > 100)
        #expect(try redPixels(footer: content, pets: other.pets) == 0)
    }
}
