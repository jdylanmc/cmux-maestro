import AppKit
import Foundation
import SwiftUI
import Testing

@MainActor
struct SidebarPetCollectionTests {
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
