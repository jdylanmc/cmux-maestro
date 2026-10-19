import AppKit
import Foundation
import SwiftUI
import Testing

@MainActor
@Suite(.serialized)
struct SidebarTagTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("scripts/test-fixtures")

    /// An agent store written the way the controller writes it: private folder, private file.
    private struct AgentStore {
        let file: SidebarAgentTagsFile

        init(root: URL) throws {
            let directory = root.appendingPathComponent("agent-tags", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            file = .init(directory: directory)
        }

        func write(_ sessions: [UUID: [String]], version: Int = 1) throws {
            let body: [String: Any] = ["version": version, "sessions": Dictionary(uniqueKeysWithValues: sessions.map {
                ($0.key.uuidString.lowercased(), $0.value)
            })]
            try writeRaw(JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        }

        func writeRaw(_ data: Data) throws {
            let url = file.directory.appendingPathComponent(SidebarAgentTagsFile.filename)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private func preferences(
        _ fixture: SidebarPreferenceFixture, agent: SidebarAgentTagsFile? = nil,
        retained: @escaping (UUID) -> Bool = { _ in true }
    ) -> SidebarPreferences {
        SidebarPreferences(
            defaults: fixture.defaults, historyFile: fixture.historyFile, attentionFile: fixture.attentionFile,
            layoutStore: .init(file: .init(url: fixture.layoutFile)), agentTagsFile: agent, sessionRetained: retained
        )
    }

    @Test func agentStoreContractMatchesTheController() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("tag-store-cases.json"))
        let cases = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for item in try #require(cases["valid"] as? [[String: String]]) {
            #expect(throws: Never.self, "\(item["name"] ?? "")") { try SidebarAgentTagsFile.decode(Data(item["raw"]!.utf8)) }
        }
        let invalid = try #require(cases["invalid"] as? [[String: String]])
        #expect(invalid.count >= 15)
        for item in invalid {
            #expect(throws: (any Error).self, "\(item["name"] ?? "")") { try SidebarAgentTagsFile.decode(Data(item["raw"]!.utf8)) }
        }
    }

    /// The byte caps never bind before the entry caps, so a full store is always one pruning can recover.
    @Test func largestValidStoresFitTheirByteCaps() throws {
        let wide = String(repeating: "\u{20000}", count: SidebarTagSlug.maximumLength)  // CJK letter, 4 UTF-8 bytes
        let slug = SidebarTagSlug.canonical(wide)
        #expect(SidebarTagSlug.isCanonical(slug) && slug.utf8.count == 96)
        var settings = SidebarTagSettings()
        let distinct = (0..<SidebarTagSlug.maximumPerSource).map { index in
            String(slug.unicodeScalars.dropLast().map(Character.init)) + "\(index)"
        }
        for _ in 0..<SidebarTagSettings.maximumEntries {
            settings.assignments[SidebarTagSettings.key(UUID())] = distinct
        }
        for index in 0..<SidebarTagSettings.maximumEntries {
            settings.colors[String(slug.unicodeScalars.dropLast(4).map(Character.init)) + String(format: "%04d", index)] = .slate
        }
        #expect(distinct.allSatisfy { SidebarTagSlug.isCanonical($0) && $0.utf8.count >= 93 })
        #expect(settings.isValid)
        #expect(try JSONEncoder().encode(settings).count <= SidebarTagSettings.maximumStoredBytes)

        var agent: [String: [String]] = [:]
        for _ in 0..<SidebarAgentTagsFile.maximumSessions { agent[UUID().uuidString.lowercased()] = distinct }
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": agent], options: [.sortedKeys])
        #expect(data.count <= SidebarAgentTagsFile.maximumBytes)
        #expect(try SidebarAgentTagsFile.decode(data).count == SidebarAgentTagsFile.maximumSessions)
    }

    @Test func fullStoresDropOnlyEndedSessionsAndUnusedColorsThenRefuse() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let ended = (0..<SidebarTagSettings.maximumEntries / 2).map { _ in UUID() }
        let kept = (0..<SidebarTagSettings.maximumEntries / 2).map { _ in UUID() }
        let endedKeys = Set(ended.map(SidebarTagSettings.key))
        var settings = SidebarTagSettings()
        for id in ended + kept { settings.assignments[SidebarTagSettings.key(id)] = ["x"] }
        for index in 0..<SidebarTagSettings.maximumEntries { settings.colors["unused-\(index)"] = .rose }
        settings.colors["x"] = .plum
        settings.colors.removeValue(forKey: "unused-0")
        try JSONEncoder().encode(settings)
            .write(to: fixture.root.appendingPathComponent("sidebar-tags.json"))
        let preferences = preferences(fixture, retained: { !endedKeys.contains(SidebarTagSettings.key($0)) })
        #expect(preferences.tagSettings.assignments.count == SidebarTagSettings.maximumEntries)
        let newcomer = UUID()
        #expect(preferences.setHumanTags("new", for: newcomer) == nil)
        #expect(preferences.tagSettings.assignments.count == kept.count + 1)
        #expect(preferences.humanTags(for: kept[0]) == ["x"] && preferences.humanTags(for: ended[0]).isEmpty)
        #expect(preferences.setTagColor(.ocean, for: "new") == nil)
        #expect(preferences.tagSettings.colors == ["x": .plum, "new": .ocean])

        let allKept = self.preferences(fixture)
        for id in (0..<(SidebarTagSettings.maximumEntries - kept.count - 1)).map({ _ in UUID() }) {
            allKept.setHumanTags("y", for: id)
        }
        #expect(allKept.tagSettings.assignments.count == SidebarTagSettings.maximumEntries)
        #expect(allKept.setHumanTags("z", for: UUID()) == "Tag storage is full.")
        #expect(allKept.tagSettings.assignments.count == SidebarTagSettings.maximumEntries)
        allKept.resetTags()
        #expect(allKept.tagSettings == SidebarTagSettings() && allKept.tagNotice == nil)
    }

    @Test func canonicalizationMatchesTheControllerOnSharedCases() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("tag-slug-cases.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == SidebarTagSlug.version)
        let cases = try #require(object["cases"] as? [[String: String]])
        #expect(cases.count >= 20)
        for item in cases {
            let input = try #require(item["input"]), expected = try #require(item["slug"])
            #expect(SidebarTagSlug.canonical(input).unicodeScalars.elementsEqual(expected.unicodeScalars),
                    "\(input.debugDescription)")
            #expect(SidebarTagSlug.canonical(expected) == expected, "idempotent: \(expected)")
        }
    }

    @Test func spellingsThatNormalizeAlikeCollideIntoOneSlug() throws {
        #expect(try SidebarTagSlug.parse("Front End, front_end, ＦＲＯＮＴ ｅｎｄ, --FRONT--END--") == ["front-end"])
        #expect(try SidebarTagSlug.parse("Café, Cafe\u{301}") == ["café"])
        #expect(try SidebarTagSlug.parse(" a ,, b, ") == ["a", "b"])
        #expect(try SidebarTagSlug.parse("") == [])
    }

    @Test func invalidEntriesAreRefusedNotTruncated() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = preferences(fixture)
        let session = UUID()
        #expect(preferences.setHumanTags("keep", for: session) == nil)
        let seven = (1...7).map { "t\($0)" }.joined(separator: ",")
        let tooLong = String(repeating: "x", count: SidebarTagSlug.maximumLength + 1)
        let exact = String(repeating: "y", count: SidebarTagSlug.maximumLength)
        for (input, error) in [(seven, SidebarTagError.tooMany), (tooLong, .tooLong), ("ok, !!!", .noLetterOrNumber)] {
            #expect(preferences.setHumanTags(input, for: session) == error.message)
            #expect(preferences.humanTags(for: session) == ["keep"])
        }
        #expect(preferences.setHumanTags((1...6).map { "t\($0)" }.joined(separator: ",") + ",\(exact)", for: session)
            == SidebarTagError.tooMany.message)
        #expect(preferences.setHumanTags(exact, for: session) == nil)
        #expect(preferences.humanTags(for: session) == [exact])
    }

    @Test func bothOwnersShareOneChipAndRemovingOneSourceKeepsTheOther() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let store = try AgentStore(root: fixture.root)
        let session = UUID()
        try store.write([session: ["deploy", "review"]])
        let preferences = preferences(fixture, agent: store.file)
        preferences.setHumanTags("Deploy, notes", for: session)
        #expect(preferences.tags(for: session).map { [$0.slug, $0.owners] } == [
            ["deploy", "You + agent"], ["notes", "You"], ["review", "Agent"]
        ])
        preferences.setHumanTags("notes", for: session)
        let agentOnly = try #require(preferences.tags(for: session).first { $0.slug == "deploy" })
        #expect(!agentOnly.human && agentOnly.agent)
        preferences.setHumanTags("deploy", for: session)
        try store.write([session: ["review"]])
        preferences.refreshTags()
        #expect(preferences.tags(for: session).map(\.slug) == ["deploy", "review"])
        #expect(preferences.tags(for: session)[0].human && !preferences.tags(for: session)[0].agent)
    }

    @Test func assignmentsBindToExactSessionsNotOtherSessions() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let store = try AgentStore(root: fixture.root)
        let first = UUID(), second = UUID()
        try store.write([first: ["agent-only"]])
        let preferences = preferences(fixture, agent: store.file)
        preferences.setHumanTags("mine", for: first)
        #expect(preferences.tags(for: second).isEmpty)
        #expect(preferences.tags(for: nil).isEmpty)
        #expect(preferences.tags(for: first).map(\.slug) == ["mine", "agent-only"])
    }

    @Test func humanTagsAndColorsPersistAndConvergeAcrossWindows() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let first = preferences(fixture), second = preferences(fixture)
        let a = UUID(), b = UUID()
        first.setHumanTags("shared", for: a)
        second.setHumanTags("shared, other", for: b)
        first.setTagColor(.ocean, for: "shared")
        #expect(first.tagSettings == second.tagSettings)
        let restarted = preferences(fixture)
        #expect(restarted.tags(for: a).map(\.swatch) == [.ocean])
        #expect(restarted.tags(for: b).map(\.swatch) == [.ocean, nil])
        #expect(restarted.history == first.history && restarted.icons == first.icons)
    }

    @Test func overridesApplyEverywhereAndResetRestoresTheAutomaticColor() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let store = try AgentStore(root: fixture.root)
        let human = UUID(), agent = UUID()
        try store.write([agent: ["release"]])
        let preferences = preferences(fixture, agent: store.file)
        preferences.setHumanTags("release", for: human)
        let automatic = SidebarTagPalette.automatic("release")
        #expect(preferences.tags(for: agent)[0].background == automatic)
        #expect(preferences.setTagColor(.plum, for: "release") == nil)
        #expect(preferences.tags(for: human)[0].background == SidebarTagSwatch.plum.color)
        #expect(preferences.tags(for: agent)[0].background == SidebarTagSwatch.plum.color)
        // A later agent write leaves the human color in place.
        try store.write([agent: ["release", "hotfix"]])
        preferences.refreshTags()
        #expect(preferences.tags(for: agent)[0].swatch == .plum)
        #expect(preferences.setTagColor(nil, for: "release") == nil)
        #expect(preferences.tags(for: agent)[0].background == automatic)
        #expect(preferences.tagSettings.colors.isEmpty)
        #expect(preferences.setTagColor(.rose, for: "Not Canonical") != nil)
    }

    @Test func automaticColorsMatchTheApprovedReference() {
        // Computed with the frozen prototype's defaultTagColor.
        let reference = ["front-end": "#dc7489", "accessibility": "#86dad3", "content": "#df9d81",
                         "数据-pipeline": "#dad195", "café": "#ddb28d", "😀": "#8a8ce0"]
        for (slug, hex) in reference { #expect(SidebarTagPalette.automatic(slug).hex == hex, "\(slug)") }
    }

    @Test func everyPossibleBackgroundKeepsTextContrastAtLeastFourPointFive() {
        var weakest = Double.infinity
        for hue in 0..<360 {
            for saturation in 0..<13 {
                for lightness in 0..<9 {
                    let background = SidebarTagPalette.hsl(hue: hue, saturationStep: saturation, lightnessStep: lightness)
                    weakest = min(weakest, SidebarTagColor.contrast(background.foreground, background))
                }
            }
        }
        #expect(weakest >= 4.5)
        for swatch in SidebarTagSwatch.allCases {
            #expect(SidebarTagColor.contrast(swatch.color.foreground, swatch.color) >= 4.5, "\(swatch)")
        }
    }

    /// Renders each chip and measures the drawn pixels: the background is opaque at its
    /// registered color, and the drawn text reaches at least 4.5:1 against it.
    @Test func renderedChipsMeetContrastOnTheirActualBackground() throws {
        let tags = [SidebarResolvedTag(slug: "release", human: true, agent: false, swatch: nil)]
            + SidebarTagSwatch.allCases.map { SidebarResolvedTag(slug: "release", human: false, agent: true, swatch: $0) }
        for tag in tags {
            let renderer = ImageRenderer(content: SidebarTagChip(tag: tag, compact: false).environment(\.colorScheme, .dark))
            renderer.scale = 4
            let image = try #require(renderer.cgImage)
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let width = image.width, height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                                 bytesPerRow: width * 4, space: space,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            func color(_ x: Int, _ y: Int) -> SidebarTagColor {
                let offset = (y * width + x) * 4
                return .init(red: pixels[offset], green: pixels[offset + 1], blue: pixels[offset + 2])
            }
            // Inside the left padding, clear of the capsule edge and any dashed outline.
            let sampled = color(12, height / 2)
            #expect(pixels[((height / 2) * width + 12) * 4 + 3] == 255, "opaque \(tag.background.hex)")
            for (drawn, expected) in zip([sampled.red, sampled.green, sampled.blue],
                                         [tag.background.red, tag.background.green, tag.background.blue]) {
                #expect(abs(Int(drawn) - Int(expected)) <= 1, "\(tag.background.hex) drew \(sampled.hex)")
            }
            var strongest = 0.0
            for y in 0..<height { for x in 0..<width where pixels[(y * width + x) * 4 + 3] == 255 {
                strongest = max(strongest, SidebarTagColor.contrast(color(x, y), sampled))
            } }
            #expect(strongest >= 4.5, "\(tag.background.hex): \(strongest)")
        }
    }

    @Test func editorDraftChangesNothingUntilSavedSoCancelDiscardsColors() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = preferences(fixture)
        let session = UUID()
        preferences.setHumanTags("release", for: session)
        preferences.setTagColor(.rose, for: "release")
        let saved = preferences.tagSettings
        var draft = SidebarTagDraft(text: "release, notes")
        draft.colors["release"] = .some(.ocean)
        #expect(draft.preview(preferences.tags(for: session)).map(\.swatch) == [.ocean])
        // Cancel drops the draft: nothing was written.
        #expect(preferences.tagSettings == saved)
        #expect(self.preferences(fixture).tagSettings == saved)
        draft.colors["release"] = .some(nil)
        #expect(draft.preview(preferences.tags(for: session)).map(\.swatch) == [nil])
        #expect(draft.commit(to: preferences, session: session) == nil)
        #expect(preferences.humanTags(for: session) == ["release", "notes"])
        #expect(preferences.tagSettings.colors.isEmpty)
        var refused = SidebarTagDraft(text: "!!!")
        refused.colors["release"] = .some(.plum)
        #expect(refused.commit(to: preferences, session: session) == SidebarTagError.noLetterOrNumber.message)
        #expect(preferences.tagSettings.colors.isEmpty)
    }

    @Test func failedSaveChangesNeitherTagsNorColors() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let session = UUID()
        var settings = SidebarTagSettings()
        let used = (0..<SidebarTagSettings.maximumEntries).map { "used-\($0)" }
        // Every colored slug is carried by some session, so no color can be dropped to make room.
        for chunk in stride(from: 0, to: used.count, by: SidebarTagSlug.maximumPerSource) {
            settings.assignments[SidebarTagSettings.key(UUID())] = Array(used[chunk..<min(chunk + 6, used.count)])
        }
        for slug in used { settings.colors[slug] = .rose }
        settings.assignments[SidebarTagSettings.key(session)] = ["before"]
        try JSONEncoder().encode(settings).write(to: fixture.root.appendingPathComponent("sidebar-tags.json"))
        let preferences = preferences(fixture)
        let saved = preferences.tagSettings
        #expect(saved.colors.count == SidebarTagSettings.maximumEntries)
        var draft = SidebarTagDraft(text: "after, new")
        draft.colors["new"] = .some(.ocean)
        let error = draft.commit(to: preferences, session: session)
        #expect(error == "Tag storage is full.")
        #expect(SidebarTagEditor.messages(error: error, notice: preferences.tagNotice) == ["Tag storage is full."])
        #expect(SidebarTagEditor.messages(error: "Each tag needs a letter or number.", notice: "Tags not saved.")
            == ["Each tag needs a letter or number.", "Tags not saved."])
        #expect(preferences.tagSettings == saved)
        #expect(self.preferences(fixture).tagSettings == saved)
        #expect(preferences.humanTags(for: session) == ["before"])
    }

    @Test func unreadableAgentStoreNeverDropsColorsForAgentOnlySlugs() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let store = try AgentStore(root: fixture.root)
        let agentSession = UUID()
        let agentOnly = (0..<SidebarTagSettings.maximumEntries).map { "agent-\($0)" }
        var settings = SidebarTagSettings()
        for slug in agentOnly { settings.colors[slug] = .rose }
        try JSONEncoder().encode(settings).write(to: fixture.root.appendingPathComponent("sidebar-tags.json"))
        var sessions: [UUID: [String]] = [:]
        for chunk in stride(from: 0, to: agentOnly.count, by: SidebarTagSlug.maximumPerSource) {
            sessions[chunk == 0 ? agentSession : UUID()] = Array(agentOnly[chunk..<min(chunk + 6, agentOnly.count)])
        }
        try store.writeRaw(Data("not json".utf8))
        let preferences = preferences(fixture, agent: store.file)
        #expect(preferences.agentTags.isEmpty)
        #expect(preferences.setTagColor(.ocean, for: "new") == "Tag storage is full.")
        #expect(self.preferences(fixture).tagSettings.colors == settings.colors)
        // Readable again: agent-only slugs are carried, so they are kept and the registry stays full.
        try store.write(sessions)
        #expect(preferences.setTagColor(.ocean, for: "new") == "Tag storage is full.")
        #expect(self.preferences(fixture).tagSettings.colors == settings.colors)
        // Once an agent drops a slug, its color is the one that makes room.
        sessions[agentSession] = Array(sessions[agentSession]!.dropFirst())
        try store.write(sessions)
        #expect(preferences.setTagColor(.ocean, for: "new") == nil)
        #expect(preferences.tagSettings.colors["agent-0"] == nil && preferences.tagSettings.colors["new"] == .ocean)
        #expect(preferences.tagSettings.colors.count == SidebarTagSettings.maximumEntries)
    }

    @Test func decomposedSpellingsAreNotCanonical() {
        #expect(SidebarTagSlug.isCanonical("caf\u{E9}"))
        #expect(!SidebarTagSlug.isCanonical("cafe\u{301}"))
        #expect(SidebarTagSlug.canonical("cafe\u{301}").unicodeScalars.elementsEqual("caf\u{E9}".unicodeScalars))
    }

    @Test func onlyAMissingSessionEntryCountsAsEnded() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("session-state", isDirectory: true)
        let kept = UUID(), gone = UUID()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(kept.uuidString.lowercased()),
                                                withIntermediateDirectories: true)
        #expect(SidebarPreferences.sessionKept(kept, under: root))
        #expect(!SidebarPreferences.sessionKept(gone, under: root))
        #expect(SidebarPreferences.sessionKept(gone, under: fixture.root.appendingPathComponent("absent")))

        var settings = SidebarTagSettings()
        let sessions = (0..<SidebarTagSettings.maximumEntries).map { _ in UUID() }
        for id in sessions { settings.assignments[SidebarTagSettings.key(id)] = ["x"] }
        try JSONEncoder().encode(settings).write(to: fixture.root.appendingPathComponent("sidebar-tags.json"))
        // The root can be stat'd but not searched: every child lookup is denied, which proves nothing.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        #expect(SidebarPreferences.sessionKept(gone, under: root))
        let preferences = preferences(fixture, retained: { SidebarPreferences.sessionKept($0, under: root) })
        #expect(preferences.setHumanTags("new", for: UUID()) == "Tag storage is full.")
        #expect(self.preferences(fixture).tagSettings == settings)
    }

    @Test func agentStoreReadsStrictlyAndAFailedReadKeepsTheLastGoodTags() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let store = try AgentStore(root: fixture.root)
        let session = UUID()
        #expect(try store.file.read().isEmpty)
        try store.write([session: ["ok"]])
        let preferences = preferences(fixture, agent: store.file)
        #expect(preferences.agentTags[session] == ["ok"])
        let key = session.uuidString.lowercased()
        for raw in [
            #"{"version":2,"sessions":{}}"#,
            #"{"version":1,"sessions":{"\#(session.uuidString)":["ok"]}}"#,
            #"{"version":1,"sessions":{"\#(key)":["Not Canonical"]}}"#,
            #"{"version":1,"sessions":{"\#(key)":["a","b","c","d","e","f","g"]}}"#,
            #"{"version":1,"sessions":{"\#(key)":[]}}"#,
            #"{"version":1,"sessions":{"\#(key)":["a","a"]}}"#,
            #"{"version":1,"sessions":{},"extra":1}"#,
            "not json"
        ] {
            try store.writeRaw(Data(raw.utf8))
            #expect(throws: (any Error).self, "\(raw)") { try store.file.read() }
            preferences.refreshTags()
            #expect(preferences.agentTags[session] == ["ok"])
        }
        let url = store.file.directory.appendingPathComponent(SidebarAgentTagsFile.filename)
        try store.write([session: ["ok"]])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(throws: (any Error).self) { try store.file.read() }
    }

    @Test func rowActionOffersTagEditingOnlyWithAnExactSession() {
        var edited = false
        let available = SidebarRowActionGroup.appearance(icon: nil, agent: true, tags: { edited = true })
        let editAction = available.actions.first { $0.title == "Edit tags…" }
        #expect(editAction?.unavailable == nil)
        editAction?.perform()
        #expect(edited)
        let unavailable = SidebarRowActionGroup.appearance(icon: nil, agent: true)
        #expect(unavailable.actions.first { $0.title == "Edit tags…" }?.unavailable != nil)
        #expect(!SidebarRowActionGroup.appearance(icon: nil, agent: false, tags: {}).actions.contains { $0.title == "Edit tags…" })
    }

    @Test func detailsTargetOnlyTheAgentsOwnSession() {
        let session = UUID()
        #expect(SidebarDetailContent(title: "a", isAgent: true, petSessionID: session).tagSessionID == session)
        #expect(SidebarDetailContent(title: "surface", petSessionID: session).tagSessionID == nil)
        #expect(SidebarDetailContent(title: "child", isAgent: true).tagSessionID == nil)
        #expect(SidebarPresentation.taggedLabel("Focus a", tags: []) == "Focus a")
        let tags = SidebarResolvedTag.resolve(human: ["x"], agent: ["x", "y"], colors: [:])
        #expect(SidebarPresentation.taggedLabel("Focus a", tags: tags) == "Focus a. Tags: x (you + agent), y (agent)")
    }
}
