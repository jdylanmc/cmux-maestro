import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CMUXMaestroPreview

struct CLIIntegrationGuideTests {
    @Test func fourStatesAndExplicitRetryUseActualGlobalLocations() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let reader = fixture.reader()
        #expect(await reader.check() == fixture.result(.missing, .missing))
        try fixture.writeGuide(fixture.content, index: 0)
        #expect(await reader.check() == fixture.result(.matching, .missing))
        try fixture.writeGuide(Data("newer or customized".utf8), index: 1)
        #expect(await reader.check() == fixture.result(.matching, .different))
        try FileManager.default.removeItem(at: fixture.guide(0))
        try FileManager.default.createDirectory(at: fixture.guide(0), withIntermediateDirectories: true)
        #expect(await reader.check() == fixture.result(.unreadable(.unsafePath), .different))
        try FileManager.default.removeItem(at: fixture.guide(0))
        try fixture.writeGuide(fixture.content, index: 0)
        #expect(await reader.check() == fixture.result(.matching, .different))
        #expect(try Data(contentsOf: fixture.guide(1)) == Data("newer or customized".utf8))
        #expect(CLIIntegrationGuideReader.relativePaths == [
            ".agents/skills/maestro/SKILL.md", ".copilot/skills/maestro/SKILL.md"
        ])
    }

    @Test func supportedDirectoryAndFileLinksReadTheirActualContent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeGuide(fixture.content, index: 0)
        let copilotParent = fixture.guide(1).deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: copilotParent, withIntermediateDirectories: true)
        let link = fixture.guide(1).deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(atPath: link.path,
                                                  withDestinationPath: "../../.agents/skills/maestro")
        #expect(await fixture.reader().check() == fixture.result(.matching, .matching))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.guide(1), withDestinationURL: fixture.guide(0))
        #expect(await fixture.reader().check() == fixture.result(.matching, .matching))
    }

    @Test func deniedBrokenLoopingAndNonRegularFilesRemainUnreadable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeGuide(fixture.content, index: 0)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.guide(0).path)
        #expect(await fixture.reader().check() == fixture.result(.unreadable(.permissionDenied), .missing))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.guide(0).path)
        try FileManager.default.removeItem(at: fixture.guide(0))
        try FileManager.default.createSymbolicLink(atPath: fixture.guide(0).path, withDestinationPath: "absent.md")
        #expect(await fixture.reader().check() == fixture.result(.unreadable(.unsafePath), .missing))
        try FileManager.default.removeItem(at: fixture.guide(0))
        try FileManager.default.createSymbolicLink(atPath: fixture.guide(0).path, withDestinationPath: "SKILL.md")
        #expect(await fixture.reader().check() == fixture.result(.unreadable(.unsafePath), .missing))
        try FileManager.default.removeItem(at: fixture.guide(0))
        try #require(mkfifo(fixture.guide(0).path, 0o600) == 0)
        #expect(await fixture.reader().check() == fixture.result(.unreadable(.unsafePath), .missing))
    }

    @Test func boundedReadsDistinguishEmptyAndOversizedContent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeGuide(Data(), index: 0)
        try fixture.writeGuide(Data(repeating: 65, count: 65_536), index: 1)
        #expect(await fixture.reader().check() == fixture.result(.different, .different))
        try fixture.writeGuide(Data(repeating: 65, count: 65_537), index: 1)
        #expect(await fixture.reader().check() == fixture.result(.different, .unreadable(.tooLarge)))
    }

    @Test func absentMalformedAndUnreadableReferencesNeverProduceLocalVerdicts() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeGuide(fixture.content, index: 0)
        #expect(await CLIIntegrationGuideReader(home: fixture.home, reference: nil).check() == .referenceUnavailable)
        for invalid in [Data(), Data("invalid\n".utf8), Data(repeating: 103, count: 65),
                        Data(repeating: 97, count: 64), Data(repeating: 97, count: 66)] {
            try invalid.write(to: fixture.reference)
            #expect(await fixture.reader().check() == .referenceUnavailable)
        }
        try FileManager.default.removeItem(at: fixture.reference)
        #expect(await fixture.reader().check() == .referenceUnavailable)
        try FileManager.default.createDirectory(at: fixture.reference, withIntermediateDirectories: true)
        #expect(await fixture.reader().check() == .referenceUnavailable)
        #expect(try Data(contentsOf: fixture.guide(0)) == fixture.content)
    }

    @Test @MainActor func checkingRetryAndCopyFeedbackHaveNoImplicitActions() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let reader = fixture.reader()
        let model = CLIIntegrationGuideModel(read: { await reader.check() })
        #expect(model.result == nil)
        #expect(!model.isChecking)
        #expect(model.copyNotice == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.guide(0).path))
        await model.recheck()
        #expect(model.result == fixture.result(.missing, .missing))
        try fixture.writeGuide(fixture.content, index: 0)
        #expect(model.result == fixture.result(.missing, .missing), "No automatic polling")
        await model.recheck()
        #expect(model.result == fixture.result(.matching, .missing))
        var commands: [String] = []
        model.copyCommand {
            CLIIntegrationGuide.copyInstallCommand {
                commands.append($0)
                return true
            }
        }
        #expect(model.copyNotice == "Copied. Run the command in your terminal when ready.")
        model.copyCommand { CLIIntegrationGuide.copyInstallCommand { _ in false } }
        #expect(model.copyNotice == "Could not copy the command. Select and copy the text above.")
        #expect(commands == ["npx skills add jdylanmc/cmux-maestro --skill maestro --agent github-copilot --global --copy"])
        #expect(try Data(contentsOf: fixture.guide(0)) == fixture.content)
        #expect(!FileManager.default.fileExists(atPath: fixture.guide(1).path))
    }

    @Test @MainActor func inFlightReadClearsOldVerdictAndRejectsOverlappingChecks() async {
        let gate = ReadGate()
        let model = CLIIntegrationGuideModel(read: { await gate.read() })
        let task = Task { await model.recheck() }
        await gate.waitUntilReading()
        #expect(model.isChecking)
        #expect(model.result == nil)
        await model.recheck()
        #expect(await gate.calls == 1)
        await gate.finish()
        await task.value
        #expect(!model.isChecking)
        #expect(model.result == .referenceUnavailable)
        let retry = Task { await model.recheck() }
        await gate.waitUntilReading()
        #expect(model.result == nil)
        await gate.finish()
        await retry.value
        #expect(await gate.calls == 2)
    }

    private actor ReadGate {
        private var continuation: CheckedContinuation<CLIIntegrationGuideReader.Result, Never>?
        private var observer: CheckedContinuation<Void, Never>?
        private(set) var calls = 0

        func read() async -> CLIIntegrationGuideReader.Result {
            calls += 1
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                observer?.resume()
                observer = nil
            }
        }

        func waitUntilReading() async {
            if continuation != nil { return }
            await withCheckedContinuation { observer = $0 }
        }

        func finish() {
            continuation?.resume(returning: .referenceUnavailable)
            continuation = nil
        }
    }

    private struct Fixture {
        let home: URL
        let content = Data("---\nname: maestro\n---\nSynthetic guide.\n".utf8)
        var reference: URL { home.appendingPathComponent("maestro-guide.sha256") }

        init() throws {
            home = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/guide-tests/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
            try Data((digest + "\n").utf8).write(to: reference)
        }

        func guide(_ index: Int) -> URL {
            home.appendingPathComponent(CLIIntegrationGuideReader.relativePaths[index])
        }

        func writeGuide(_ bytes: Data, index: Int) throws {
            try FileManager.default.createDirectory(at: guide(index).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try bytes.write(to: guide(index))
        }

        func reader() -> CLIIntegrationGuideReader {
            CLIIntegrationGuideReader(home: home, reference: reference)
        }

        func result(_ first: CLIIntegrationGuideReader.Content,
                    _ second: CLIIntegrationGuideReader.Content) -> CLIIntegrationGuideReader.Result {
            .checked(zip(CLIIntegrationGuideReader.relativePaths, [first, second]).map {
                .init(relativePath: $0.0, content: $0.1)
            })
        }

        func cleanup() {
            do { try FileManager.default.removeItem(at: home) }
            catch { Issue.record("Could not remove guide fixture: \(error)") }
        }
    }
}
