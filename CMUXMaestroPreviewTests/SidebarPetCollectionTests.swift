import AppKit
import Foundation
import Testing

@MainActor
struct SidebarPetCollectionTests {
    private func pngSheet() throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1536, pixelsHigh: 1872, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// `reopen` builds an independent store over the same persisted state.
    private func makeStore() throws -> (SidebarPetStore, URL, UUID, reopen: () -> SidebarPetStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pet-collection-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let session = UUID()
        let petFolder = sessions.appendingPathComponent(session.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("blob", isDirectory: true)
        try FileManager.default.createDirectory(at: petFolder, withIntermediateDirectories: true)
        try pngSheet().write(to: petFolder.appendingPathComponent("spritesheet.png"))
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
}
