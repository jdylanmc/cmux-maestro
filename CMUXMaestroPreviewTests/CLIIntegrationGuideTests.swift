import Darwin
import Foundation
import Testing
@testable import CMUXMaestroPreview

nonisolated struct CLIIntegrationGuideTests {
    @Test func absentLocationsAreMissingWithoutCreatingAnything() throws {
        let fixture = try GuideFixture()
        defer { fixture.cleanup() }
        #expect(fixture.inspect().map(\.status) == [.missing, .missing])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path).isEmpty)
    }

    @Test func exactBytesMatchBothLocationsIndependently() throws {
        let fixture = try GuideFixture()
        defer { fixture.cleanup() }
        for location in CLIIntegrationGuideLocation.allCases { try fixture.install(location) }
        let rows = fixture.inspect()
        #expect(rows.map(\.location) == [.copilot, .legacy])
        #expect(rows.map(\.status) == [.matching, .matching])
        #expect(rows.allSatisfy { $0.detail.contains("SKILL.md") && $0.detail.contains("intent.md") })
    }

    @Test(arguments: ["SKILL.md", "intent.md"])
    func byteDifferenceInEitherFileIsDifferent(_ filename: String) throws {
        let fixture = try GuideFixture()
        defer { fixture.cleanup() }
        try fixture.install(.copilot)
        let file = fixture.directory(.copilot).appendingPathComponent(filename)
        var changed = try Data(contentsOf: file)
        changed.append(0x20)
        try changed.write(to: file)
        let result = fixture.inspect()[0]
        #expect(result.status == .different)
        #expect(result.detail.contains(filename))
        #expect(!result.detail.contains("older"))
    }

    @Test(arguments: ["SKILL.md", "intent.md"])
    func partialInstallIsDifferentNotMissing(_ filename: String) throws {
        let fixture = try GuideFixture()
        defer { fixture.cleanup() }
        try fixture.install(.copilot)
        try FileManager.default.removeItem(at: fixture.directory(.copilot).appendingPathComponent(filename))
        let result = fixture.inspect()[0]
        #expect(result.status == .different)
        #expect(result.detail.contains("Incomplete") && result.detail.contains(filename))
    }

    @Test func emptyDirectoryIsIncompleteAndEmptyFileIsDifferent() throws {
        let fixture = try GuideFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.directory(.copilot), withIntermediateDirectories: true)
        #expect(fixture.inspect()[0].status == .different)
        try fixture.install(.copilot)
        try Data().write(to: fixture.directory(.copilot).appendingPathComponent("SKILL.md"))
        #expect(fixture.inspect()[0].status == .different)
    }

    @Test func invalidBaselineNeverProducesMissingOrMatching() throws {
        let fixture = try GuideFixture()
        defer { fixture.cleanup() }
        try fixture.install(.copilot)
        let bad: [Data?] = [
            nil, Data(), Data("not-json".utf8), Data("[]".utf8),
            Data(#"{"version":2,"files":{}}"#.utf8),
            Data(#"{"version":true,"files":{}}"#.utf8),
            Data(#"{"version":1,"files":{"SKILL.md":"bad","intent.md":"bad"}}"#.utf8),
            Data(repeating: 0x20, count: 16_385),
            try JSONSerialization.data(withJSONObject: [
                "version": 1, "files": ["SKILL.md": String(repeating: "a", count: 64)]
            ]),
            try JSONSerialization.data(withJSONObject: [
                "version": 1, "files": ["SKILL.md": String(repeating: "g", count: 64),
                                       "intent.md": String(repeating: "a", count: 64)]
            ])
        ]
        for baseline in bad {
            let rows = CLIIntegrationGuideChecker.inspect(home: fixture.home, baseline: baseline)
            #expect(rows.map(\.status) == [.unreadable, .unreadable])
            #expect(rows.allSatisfy { $0.detail.contains("baseline") && $0.detail.count < 300 })
        }
    }

    @Test(arguments: [262_144, 262_145])
    func exactSizeBoundIsEnforced(_ count: Int) throws {
        let fixture = try GuideFixture()
        defer { fixture.cleanup() }
        try fixture.install(.copilot)
        try Data(repeating: 0x61, count: count)
            .write(to: fixture.directory(.copilot).appendingPathComponent("SKILL.md"))
        #expect(fixture.inspect()[0].status == (count == 262_144 ? .different : .unreadable))
        #expect(CLIIntegrationGuideChecker.maximumFileBytes == 262_144)
    }

    @Test(arguments: ["file-link", "broken-link", "directory-link", "ancestor-link", "directory-file", "fifo"])
    func unsafeTypesAndSymlinksAreUnreadable(_ kind: String) throws {
        let fixture = try GuideFixture()
        defer { fixture.cleanup() }
        try fixture.install(.copilot)
        let directory = fixture.directory(.copilot)
        let file = directory.appendingPathComponent("SKILL.md")
        switch kind {
        case "file-link", "broken-link":
            try FileManager.default.removeItem(at: file)
            let target = kind == "file-link" ? directory.appendingPathComponent("intent.md")
                : fixture.home.appendingPathComponent("does-not-exist")
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        case "directory-link":
            try FileManager.default.moveItem(at: directory, to: fixture.home.appendingPathComponent("elsewhere"))
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: fixture.home.appendingPathComponent("elsewhere"))
        case "ancestor-link":
            let ancestor = fixture.home.appendingPathComponent(".copilot")
            let target = fixture.home.appendingPathComponent("elsewhere")
            try FileManager.default.moveItem(at: ancestor, to: target)
            try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: target)
        case "directory-file":
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        default:
            try FileManager.default.removeItem(at: file)
            #expect(mkfifo(file.path, 0o600) == 0)
        }
        let result = fixture.inspect()[0]
        #expect(result.status == .unreadable)
        #expect(!result.detail.isEmpty && result.detail.count < 300)
    }

    @Test(arguments: [false, true])
    func unreadableFileOrDirectoryIsNotMissing(_ directoryDenied: Bool) throws {
        let fixture = try GuideFixture()
        defer { fixture.cleanup() }
        try fixture.install(.copilot)
        let target = directoryDenied ? fixture.directory(.copilot)
            : fixture.directory(.copilot).appendingPathComponent("intent.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: target.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path) }
        #expect(getuid() != 0, "Permission evidence requires an unprivileged test process.")
        #expect(fixture.inspect()[0].status == .unreadable)
    }

    @Test func missingFileDoesNotMaskUnsafeOtherFile() throws {
        let fixture = try GuideFixture()
        defer { fixture.cleanup() }
        try fixture.install(.copilot)
        try FileManager.default.removeItem(at: fixture.directory(.copilot).appendingPathComponent("SKILL.md"))
        let intent = fixture.directory(.copilot).appendingPathComponent("intent.md")
        try FileManager.default.removeItem(at: intent)
        try FileManager.default.createDirectory(at: intent, withIntermediateDirectories: false)
        #expect(fixture.inspect()[0].status == .unreadable)
    }

    @Test @MainActor func currentCopyUpdateDoesNotClaimLegacyUpdate() async throws {
        let fixture = try GuideFixture()
        defer { fixture.cleanup() }
        try fixture.install(.legacy)
        let legacy = fixture.directory(.legacy).appendingPathComponent("SKILL.md")
        try Data("Different legacy content".utf8).write(to: legacy)
        let home = fixture.home
        let model = CLIIntegrationGuideCheck(read: {
            CLIIntegrationGuideChecker.inspect(home: home, baseline: GuideFixture.baseline)
        })
        #expect(model.inspections.map(\.status) == [.unchecked, .unchecked])
        #expect(model.checkedAt == nil)
        await model.recheck()
        #expect(model.inspections.map(\.status) == [.missing, .different])
        try fixture.install(.copilot)
        await model.recheck()
        #expect(model.inspections.map(\.status) == [.matching, .different])
        #expect(try Data(contentsOf: legacy) == Data("Different legacy content".utf8))
        #expect(model.checkedAt != nil && !model.isChecking)
        try FileManager.default.removeItem(at: fixture.directory(.copilot))
        await model.recheck()
        #expect(model.inspections.map(\.status) == [.missing, .different])
    }

    @Test @MainActor func recheckClearsOldSuccessAndRejectsOverlappingChecks() async throws {
        let pending = GuidePendingRead()
        let matching = CLIIntegrationGuideLocation.allCases.map {
            CLIIntegrationGuideInspection(location: $0, status: .matching, detail: "Previously checked.")
        }
        let model = CLIIntegrationGuideCheck(inspections: matching, read: { await pending.read() })
        let task = Task { await model.recheck() }
        await pending.waitUntilReading()
        #expect(model.isChecking)
        #expect(model.inspections.map(\.status) == [.unchecked, .unchecked])
        #expect(model.checkedAt == nil)
        await model.recheck()
        #expect(await pending.calls == 1)
        let failed = CLIIntegrationGuideLocation.allCases.map {
            CLIIntegrationGuideInspection(location: $0, status: .unreadable, detail: "Synthetic read failure.")
        }
        await pending.finish(failed)
        await task.value
        #expect(model.inspections == failed)
        #expect(!model.isChecking && model.checkedAt != nil)
    }

    @Test func inspectionPreservesFilesAndDoesNotCreateMissingLocations() throws {
        let fixture = try GuideFixture()
        defer { fixture.cleanup() }
        try fixture.install(.copilot)
        let other = fixture.home.appendingPathComponent("unrelated/SKILL.md")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Do not inspect or modify".utf8).write(to: other)
        let paths = [other] + ["SKILL.md", "intent.md"].map { fixture.directory(.copilot).appendingPathComponent($0) }
        let before = try paths.map { try Data(contentsOf: $0) }
        let modificationDates = try paths.map {
            try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date
        }
        #expect(fixture.inspect().map(\.status) == [.matching, .missing])
        #expect(try paths.map { try Data(contentsOf: $0) } == before)
        #expect(try paths.map {
            try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date
        } == modificationDates)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory(.legacy).path))
    }
}

private nonisolated struct GuideFixture {
    static let baseline = Data(#"{"version":1,"files":{"SKILL.md":"0374b72880c630fd994f9ab305bdc0dadae181e993caf7fc22d0fd3e9171ad2b","intent.md":"3e78e503ebea0277b3d802135c675c56a424a3efdf08caa8a83f6cb4dc42aaad"}}"#.utf8)
    let home: URL

    init() throws {
        home = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/cli-guide-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func directory(_ location: CLIIntegrationGuideLocation) -> URL {
        home.appendingPathComponent(location.relativePath)
    }

    func install(_ location: CLIIntegrationGuideLocation) throws {
        let directory = directory(location)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("synthetic maestro guide\n".utf8).write(to: directory.appendingPathComponent("SKILL.md"))
        try Data("synthetic maestro intent\n".utf8).write(to: directory.appendingPathComponent("intent.md"))
    }

    func inspect() -> [CLIIntegrationGuideInspection] {
        CLIIntegrationGuideChecker.inspect(home: home, baseline: Self.baseline)
    }

    func cleanup() { try? FileManager.default.removeItem(at: home) }
}

private actor GuidePendingRead {
    private var continuation: CheckedContinuation<[CLIIntegrationGuideInspection], Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    func read() async -> [CLIIntegrationGuideInspection] {
        calls += 1
        return await withCheckedContinuation {
            continuation = $0
            started?.resume()
            started = nil
        }
    }

    func waitUntilReading() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ results: [CLIIntegrationGuideInspection]) {
        continuation?.resume(returning: results)
        continuation = nil
    }
}
