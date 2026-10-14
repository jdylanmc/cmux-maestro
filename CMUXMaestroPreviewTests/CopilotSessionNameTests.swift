import Darwin
import Foundation
import Testing
@testable import CMUXMaestroPreview

/// Copilot session names (ADR 0022): strict parsing of one top-level `name:` scalar from a
/// bounded `workspace.yaml`, cached per exact session UUID. Synthetic content only.
nonisolated struct CopilotSessionNameTests {
    private func parse(_ text: String) -> String? { CopilotSessionName.parse(Data(text.utf8)) }

    // MARK: Parser

    @Test func plainAndQuotedNames() {
        #expect(parse("id: x\nname: Synthetic plain task\nuser_named: false\n") == "Synthetic plain task")
        #expect(parse("name: 'Synthetic ''quoted'' task'\n") == "Synthetic 'quoted' task")
        #expect(parse("name: \"Synthetic \\\"double\\\" task\"\n") == "Synthetic \"double\" task")
        #expect(parse("name: \"Synthetic: colon \\u00e9\" # comment\n") == "Synthetic: colon é")
        #expect(parse("name: Synthetic task # trailing comment\n") == "Synthetic task")
        #expect(parse("name: Synthetic - with dash - Waiting\n") == "Synthetic - with dash - Waiting",
                "Never split on \" - \"")
        #expect(parse("\u{FEFF}name: Synthetic BOM\r\nuser_named: true\r\n") == "Synthetic BOM")
    }

    @Test func missingNestedAndOtherFieldsAreIgnored() {
        #expect(parse("id: x\nuser_named: true\nsummary_count: 0\n") == nil)
        #expect(parse("meta:\n  name: Synthetic nested\n") == nil, "Nested key is not the session name")
        #expect(parse("summary: |\n  name: Synthetic in block\nuser_named: true\n") == nil)
        #expect(parse("user_named: true\nname: Synthetic real\nuser_named: false\n") == "Synthetic real")
        #expect(parse("names: Synthetic other\nname_x: other\nname:x\n") == nil)
        #expect(parse("") == nil)
    }

    @Test(arguments: [
        "name: |\n  Synthetic block\n",
        "name: >-\n  Synthetic folded\n",
        "name:\n  Synthetic next line\n",
        "name: Synthetic first\n  continued plain\n",
        "name: \"Synthetic unterminated\n  rest\"\n",
        "name: 'Synthetic unterminated\n",
        "name: \"Synthetic\" trailing\n",
        "name: 'Synthetic' trailing\n",
        "name: [Synthetic, flow]\n",
        "name: {a: b}\n",
        "name: &anchor Synthetic\n",
        "name: *alias\n",
        "name: !tag Synthetic\n",
        "name: a: b\n",
        "name: \"bad \\q escape\"\n",
        "name: \"line\\nbreak\"\n",
        "name: Synthetic one\nname: Synthetic two\n",
        "name:   \n",
        "name: -\n",
    ])
    func blockMultilineAndMalformedValuesAreUnavailable(_ text: String) {
        #expect(parse(text) == nil)
    }

    @Test func controlCharactersAreStripped() {
        #expect(parse("name: Synthetic\u{07}bell\u{1B}[31m red\u{202E}\n") == "Syntheticbell[31m red")
        #expect(parse("name: \"tab\\there\"\n") == "tab here")
        #expect(parse("name: \"\\u0007\"\n") == nil, "Nothing left after stripping")
    }

    @Test func lengthIsCapped() throws {
        let long = String(repeating: "s", count: 500)
        let name = try #require(parse("name: \(long)\n"))
        #expect(name.count == CopilotSessionName.maximumCharacters)
    }

    @Test func oversizedOrInvalidDataIsRefused() {
        let padding = String(repeating: "#", count: CopilotSessionName.maximumFileBytes)
        #expect(CopilotSessionName.parse(Data("name: Synthetic\n\(padding)\n".utf8)) == nil)
        #expect(CopilotSessionName.parse(Data([0x6E, 0x61, 0x6D, 0x65, 0x3A, 0x20, 0xFF, 0x0A])) == nil)
    }

    // MARK: Cache

    private struct Folder {
        let root: URL
        let session: URL
        let sessionID = UUID()

        init() throws {
            root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/copilot-session-name-fixtures/\(UUID().uuidString)", isDirectory: true)
            session = root.appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        }

        var file: URL { session.appendingPathComponent(CopilotSessionName.filename) }

        func write(_ text: String, modified: Date? = nil) throws {
            try Data(text.utf8).write(to: file)
            if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path) }
        }

        func open() throws -> Int32 { try CopilotFileAccess.openDirectory(session, owner: getuid()) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func cacheReReadsOnlyWhenTheFileChanges() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try folder.write("name: Synthetic first\n", modified: stamp)
        let directory = try folder.open()
        defer { close(directory) }
        var cache = CopilotSessionNameCache()
        #expect(cache.name(for: folder.sessionID, sessionDirectory: directory, owner: getuid()) == "Synthetic first")
        #expect(cache.name(for: folder.sessionID, sessionDirectory: directory, owner: getuid()) == "Synthetic first")
        #expect(cache.reads == 1, "Unchanged size and mtime reuse the cached name")
        // Same size, new mtime: re-read.
        try folder.write("name: Synthetic other\n", modified: stamp.addingTimeInterval(5))
        #expect(cache.name(for: folder.sessionID, sessionDirectory: directory, owner: getuid()) == "Synthetic other")
        #expect(cache.reads == 2)
        try FileManager.default.removeItem(at: folder.file)
        #expect(cache.name(for: folder.sessionID, sessionDirectory: directory, owner: getuid()) == nil)
        #expect(cache.count == 0)
    }

    @Test func cacheIsKeyedByExactSessionID() throws {
        let folder = try Folder()
        defer { folder.remove() }
        try folder.write("name: Synthetic keyed\n")
        let directory = try folder.open()
        defer { close(directory) }
        var cache = CopilotSessionNameCache()
        let other = UUID()
        #expect(cache.name(for: folder.sessionID, sessionDirectory: directory, owner: getuid()) == "Synthetic keyed")
        cache.retain(only: [other])
        #expect(cache.count == 0, "Entries for sessions no longer bound are dropped")
        #expect(cache.name(for: folder.sessionID, sessionDirectory: directory, owner: getuid()) == "Synthetic keyed")
        #expect(cache.reads == 2)
    }

    @Test func symlinkedOversizedEmptyOrForeignFilesAreRefused() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let target = folder.root.appendingPathComponent("target.yaml")
        try Data("name: Synthetic linked\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: folder.file, withDestinationURL: target)
        let directory = try folder.open()
        defer { close(directory) }
        var cache = CopilotSessionNameCache()
        #expect(cache.name(for: folder.sessionID, sessionDirectory: directory, owner: getuid()) == nil)
        try FileManager.default.removeItem(at: folder.file)
        try folder.write("name: Synthetic\n" + String(repeating: "#", count: CopilotSessionName.maximumFileBytes))
        #expect(cache.name(for: folder.sessionID, sessionDirectory: directory, owner: getuid()) == nil)
        try folder.write("")
        #expect(cache.name(for: folder.sessionID, sessionDirectory: directory, owner: getuid()) == nil)
        try folder.write("name: Synthetic owned\n")
        #expect(cache.name(for: folder.sessionID, sessionDirectory: directory, owner: getuid() &+ 1) == nil)
        #expect(cache.reads == 0, "Refused before any content read")
    }

    // MARK: Reader

    @Test func readerPublishesTheNameOnlyForTheExactBoundSession() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        try Data("name: Synthetic bound session\nuser_named: true\n".utf8)
            .write(to: fixture.session.appendingPathComponent("workspace.yaml"))
        let unbound = try fixture.addSession(surface: UUID())
        try Data("name: Synthetic other session\n".utf8).write(to: unbound.appendingPathComponent("workspace.yaml"))
        let reader = fixture.reader()
        let snapshot = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(snapshot.isComplete)
        #expect(snapshot.sessions.map(\.sessionName) == ["Synthetic bound session"])
        let adapted = CopilotSnapshotAdapter.snapshot(snapshot, workspaceBySurface: [fixture.surface: fixture.workspace])
        #expect(adapted.sessions.first?.title == .known("Synthetic bound session"))

        let modified = Date().addingTimeInterval(60)
        let file = fixture.session.appendingPathComponent("workspace.yaml")
        try Data("name: Synthetic renamed session\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        let renamed = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(renamed.sessions.first?.sessionName == "Synthetic renamed session")
        #expect(renamed.sessions.first?.state == .idle, "A name never changes lifecycle")
    }

    @Test func missingOrMalformedNameIsUnavailableWithoutAnIssue() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let reader = fixture.reader()
        let missing = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(missing.isComplete && missing.issues.isEmpty)
        #expect(missing.sessions.first?.sessionName == nil)
        let adapted = CopilotSnapshotAdapter.snapshot(missing, workspaceBySurface: [fixture.surface: fixture.workspace])
        #expect(adapted.sessions.first?.title.knownValue == nil)
        try Data("name: |\n  Synthetic block\n".utf8).write(to: fixture.session.appendingPathComponent("workspace.yaml"))
        let malformed = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(malformed.isComplete && malformed.issues.isEmpty)
        #expect(malformed.sessions.first?.sessionName == nil)
    }

    @Test func missingSessionDirectoryLeavesTheNameUnavailable() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.session)
        let snapshot = try await fixture.reader().read(surfaceIDs: [fixture.surface])
        #expect(snapshot.sessions.allSatisfy { $0.sessionName == nil })
    }
}
