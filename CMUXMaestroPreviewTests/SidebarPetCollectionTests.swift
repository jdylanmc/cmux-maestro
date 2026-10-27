import AppKit
import Foundation
import SwiftUI
import Testing

@MainActor
struct SidebarPetCollectionTests {
    @Test func hoverBadgeOffersSaveForSessionPetsAndEditForSavedPets() {
        let cases: [(SidebarPetDescriptor.Source?, SidebarPetButton.Badge)] = [
            (.session, .save), (.uploaded, .edit), (.bundled, .edit), (nil, .none)
        ]
        for (source, expected) in cases {
            #expect(SidebarPetButton.Badge.resolve(source: source, hasSession: true, hidden: false,
                                                 hovering: true, captured: false) == expected)
            #expect(SidebarPetButton.Badge.resolve(source: source, hasSession: true, hidden: false,
                                                 hovering: false, captured: false) == .none)
        }
    }

    @Test func hiddenPetsAndMissingSessionsNeverShowBadges() {
        let sources: [SidebarPetDescriptor.Source?] = [.session, .uploaded, .bundled, nil]
        for source in sources {
            for captured in [false, true] {
                for hovering in [false, true] {
                    #expect(SidebarPetButton.Badge.resolve(source: source, hasSession: true, hidden: true,
                                                         hovering: hovering, captured: captured) == .none)
                    #expect(SidebarPetButton.Badge.resolve(source: source, hasSession: false, hidden: false,
                                                         hovering: hovering, captured: captured) == .none)
                }
            }
        }
    }

    @Test func saveConfirmationTakesPriorityUntilTheFlashEnds() {
        for hovering in [false, true] {
            #expect(SidebarPetButton.Badge.resolve(source: .uploaded, hasSession: true, hidden: false,
                                                 hovering: hovering, captured: true) == .save)
            #expect(SidebarPetButton.Badge.resolve(source: .uploaded, hasSession: true, hidden: false,
                                                 hovering: hovering, captured: false) == (hovering ? .edit : .none))
        }
    }

    @Test(SidebarAppKitTestScope(), arguments: [false, true])
    func petLabelReceivesMouseClick(animated: Bool) throws {
        let stores = SidebarStoreFixture()
        var clicks = 0
        let host = NSHostingView(rootView: Button { clicks += 1 } label: {
            SidebarPetView(store: stores.pets, petID: SidebarPetStore.defaultID, state: .idle, width: 46,
                           animated: animated)
        }.buttonStyle(.plain))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 60, height: 60),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        #expect(descendants(host).contains { $0 is SidebarPetAnimationView } == animated)
        let point = NSPoint(x: 30, y: 30)
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0
        ))
        window.sendEvent(down)
        window.sendEvent(up)
        #expect(clicks == 1, "The animated and static pet labels must both activate their enclosing button")
    }

    private func pngSheet() throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1536, pixelsHigh: 1872, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// A sheet whose played cells are opaque from `clearRows` cell pixels below each cell top.
    private func pngSheet(clearRows: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1536, pixelsHigh: 1872, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try #require(rep.bitmapData)
        for row in 0..<SidebarPetSheet.rows {
            for y in (row * 208 + clearRows)..<((row + 1) * 208) {
                for x in 0..<1536 {
                    let offset = y * rep.bytesPerRow + x * 4
                    (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3]) = (40, 80, 160, 255)
                }
            }
        }
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// `reopen` builds an independent store over the same persisted state.
    private func makeStore(sheet: Data? = nil) throws -> (SidebarPetStore, URL, UUID, reopen: () -> SidebarPetStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pet-collection-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let session = UUID()
        let petFolder = sessions.appendingPathComponent(session.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("blob", isDirectory: true)
        try FileManager.default.createDirectory(at: petFolder, withIntermediateDirectories: true)
        try (sheet ?? pngSheet()).write(to: petFolder.appendingPathComponent("spritesheet.png"))
        let manifest = #"{"id":"blob","displayName":"Blob","spritesheetPath":"spritesheet.png"}"#
        try Data(manifest.utf8).write(to: petFolder.appendingPathComponent("pet.json"))
        let suite = "pet-collection-\(UUID().uuidString)"
        let reopen = {
            SidebarPetStore(
                defaults: UserDefaults(suiteName: suite)!, uploadDirectory: root.appendingPathComponent("Pets", isDirectory: true),
                sessionDirectory: sessions)
        }
        return (reopen(), root, session, reopen)
    }

    @Test func capturedPetIsSharedAndRemovalFallsBack() throws {
        let (store, root, session, reopen) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = UUID()

        #expect(store.descriptor("blob", session: session)?.source == .session)
        #expect(store.descriptor("blob", session: other) == nil)

        #expect(store.saveToRepository("blob", session: session) != nil)
        #expect(store.descriptor("blob", session: session)?.source == .uploaded)
        #expect(store.available(for: other).contains { $0.id == "blob" })
        #expect(reopen().descriptor("blob", session: other)?.source == .uploaded)

        store.choose("blob", session: other)
        #expect(store.resolvedID(session: other, agentChoice: nil) == "blob")
        #expect(reopen().resolvedID(session: other, agentChoice: nil) == "blob")
        store.removeUpload("blob")
        #expect(!store.available(for: other).contains { $0.id == "blob" })
        #expect(store.resolvedID(session: other, agentChoice: nil) == SidebarPetStore.defaultID)
        let reopened = reopen()
        #expect(!reopened.available(for: other).contains { $0.id == "blob" })
        #expect(reopened.resolvedID(session: other, agentChoice: nil) == SidebarPetStore.defaultID)
        #expect(reopened.hasOverride(session: other))
    }

    @Test func exactSessionPreferencesKeepPrecedenceResetsAndHiddenStateAcrossRestart() throws {
        let (store, root, session, reopen) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let replacement = UUID()

        #expect(store.visibleID(session: session, agentChoice: "blob") == "blob")
        store.resetToDefault(session: session)
        #expect(store.isDefaultChoice(session: session) && store.hasOverride(session: session))
        #expect(store.resolvedID(session: session, agentChoice: "blob") == SidebarPetStore.defaultID)
        #expect(reopen().resolvedID(session: session, agentChoice: "blob") == SidebarPetStore.defaultID)
        store.clearChoice(session: session)
        #expect(!store.hasOverride(session: session))
        #expect(store.resolvedID(session: session, agentChoice: "blob") == "blob")

        store.choose("blob", session: session)
        #expect(store.resolvedID(session: session, agentChoice: SidebarPetStore.defaultID) == "blob")
        store.setHidden(true, session: session)
        #expect(store.visibleID(session: session, agentChoice: nil) == nil)
        #expect(store.resolvedID(session: session, agentChoice: nil) == "blob")
        let restarted = reopen()
        #expect(restarted.isHidden(session: session))
        #expect(restarted.visibleID(session: session, agentChoice: nil) == nil)
        #expect(restarted.resolvedID(session: session, agentChoice: nil) == "blob")

        // A replacement session in the same pane inherits nothing.
        #expect(!restarted.isHidden(session: replacement) && !restarted.hasOverride(session: replacement))
        #expect(restarted.visibleID(session: replacement, agentChoice: nil) == SidebarPetStore.defaultID)
        #expect(restarted.visibleID(session: nil, agentChoice: "blob") == nil)

        restarted.setHidden(false, session: session)
        #expect(reopen().visibleID(session: session, agentChoice: nil) == "blob")
    }

    @Test func repeatedHoverLookupsPastTheSessionCacheDecodeTheSheetOnce() throws {
        let (_, root, session, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SidebarPetStore(
            defaults: UserDefaults(suiteName: "pet-decode-\(UUID().uuidString)")!,
            uploadDirectory: root.appendingPathComponent("Pets", isDirectory: true),
            sessionDirectory: root.appendingPathComponent("sessions", isDirectory: true), sessionCacheSeconds: 0)
        let sheet = root.appendingPathComponent("sessions/\(session.uuidString.lowercased())/blob/spritesheet.png")
        let before = SidebarPetStore.decodeCount(sheet)
        for index in 0..<5 {
            let id = try #require(store.visibleID(session: session, agentChoice: "blob"))
            #expect(id == "blob")
            #expect(store.available(for: session).contains { $0.id == "blob" })
            #expect(store.frame(petID: id, session: session, state: .working, index: index) != nil)
            _ = store.topInset(petID: id, session: session)
        }
        #expect(SidebarPetStore.decodeCount(sheet) - before == 1)
    }

    @Test func sheetThatFailsToDecodeAfterTheScanFailsOnceAndLeavesThePicker() throws {
        let (_, root, session, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SidebarPetStore(
            defaults: UserDefaults(suiteName: "pet-broken-\(UUID().uuidString)")!,
            uploadDirectory: root.appendingPathComponent("Pets", isDirectory: true),
            sessionDirectory: root.appendingPathComponent("sessions", isDirectory: true), sessionCacheSeconds: 60)
        let sheet = root.appendingPathComponent("sessions/\(session.uuidString.lowercased())/blob/spritesheet.png")
        #expect(store.available(for: session).contains { $0.id == "blob" })
        // The agent rewrites its sheet after the header scan; the half-written file cannot decode.
        try Data("not an image".utf8).write(to: sheet)
        let before = SidebarPetStore.decodeCount(sheet)
        for index in 0..<5 {
            _ = store.frame(petID: "blob", session: session, state: .idle, index: index)
        }
        #expect(SidebarPetStore.decodeCount(sheet) - before == 1)
        #expect(!store.available(for: session).contains { $0.id == "blob" })

        try pngSheet().write(to: sheet)
        store.refresh()
        #expect(store.available(for: session).contains { $0.id == "blob" })
        #expect(store.sheet(for: "blob", session: session) != nil)
    }

    @Test func choosePetRowActionIsOnlyForExactAgentSessionsAndMotionRespectsReduceMotion() {
        var opened = 0
        let presenter = SidebarRowMenuPresenter()
        presenter.groups = [
            .appearance(icon: nil, agent: true, pet: { opened += 1 }),
            .appearance(icon: nil, agent: true),
            .appearance(icon: nil, agent: true, child: true),
            .appearance(icon: nil, agent: false, pet: { opened += 1 })
        ]
        let menus = presenter.menu().items.map { $0.submenu?.items.first { $0.title == "Choose pet…" } }
        #expect(menus[0]?.isEnabled == true && menus[1]?.isEnabled == false && menus[2]?.isEnabled == false)
        #expect(menus[3] == nil)
        for item in menus.compactMap({ $0 }) { presenter.invoke(item) }
        #expect(opened == 1)

        #expect(SidebarPetView.animates(true, reduceMotion: false))
        #expect(!SidebarPetView.animates(true, reduceMotion: true))
    }

    @Test func bundledPetCannotBeRemoved() throws {
        let (store, root, _, reopen) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.removeUpload(SidebarPetStore.defaultID)
        #expect(store.available(for: nil).contains { $0.id == SidebarPetStore.defaultID })
        #expect(reopen().available(for: nil).contains { $0.id == SidebarPetStore.defaultID })
    }

    @Test func framesAreCachedAndWrapByIndex() throws {
        let (store, root, session, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try #require(store.frame(petID: "blob", session: session, state: .idle, index: 0))
        let again = try #require(store.frame(petID: "blob", session: session, state: .idle, index: 0))
        let wrapped = try #require(store.frame(petID: "blob", session: session, state: .idle, index: SidebarPetState.idle.frameCount))
        #expect(first === again)
        #expect(first === wrapped)
        #expect(first.width == SidebarPetSheet.cellWidth)
    }

    @Test func opaqueTopSheetHasNoInsetAndLaysOutTheFullCell() async throws {
        let (store, root, session, _) = try makeStore(sheet: pngSheet(clearRows: 0))
        defer { try? FileManager.default.removeItem(at: root) }
        let inset = store.topInset(petID: "blob", session: session)
        #expect(inset == 0)
        #expect(store.topInset(petID: "blob", session: session) == inset)

        var frame = CGRect.null
        let hosting = NSHostingView(rootView: SidebarPetView(
            store: store, petID: "blob", session: session, state: .idle, width: 48, animated: false, topTrim: inset)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .fixedSize())
        hosting.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        hosting.layoutSubtreeIfNeeded()
        // The laid-out (and button hit) frame is the whole 48x52 cell, so no opaque art lies outside it.
        #expect(abs(frame.width - 48) < 0.5 && abs(frame.height - 52) < 0.5, "\(frame)")
        #expect(abs(SidebarFooterPetSize.height(forWidth: 48, topInset: inset) - 52) < 0.001)
    }

    @Test func transparentTopSheetMeasuresItsSharedClearBand() throws {
        let (store, root, session, _) = try makeStore(sheet: pngSheet(clearRows: 12))
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(abs(store.topInset(petID: "blob", session: session) - 12.0 / 208) < 0.0001)

        let (deep, deepRoot, deepSession, _) = try makeStore(sheet: pngSheet(clearRows: 60))
        defer { try? FileManager.default.removeItem(at: deepRoot) }
        #expect(abs(deep.topInset(petID: "blob", session: deepSession) - SidebarPetSheet.maximumTopInset) < 0.0001)
    }

    @Test func bundledSheetKeepsItsTrimmedTopBand() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CMUXMaestroSidebar/Pets/maestro-pet.webp")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let decoded = try #require(SidebarPetStore.decoded(image))
        // The working row's art starts 17 fully transparent cell pixels down; the cap is 19.
        #expect(abs(decoded.topInset - 17.0 / 208) < 0.0001)
    }
}
