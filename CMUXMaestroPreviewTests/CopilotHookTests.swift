import Darwin
import Foundation
import Testing
@testable import CMUXMaestroPreview

private typealias HookLookup = CMUXMaestroPreview.CopilotProcessLookup

private final class HookProbeCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

struct CopilotHookTests: Sendable {
    private let session = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let surface = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let workspace = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    private var environment: [String: String] {
        ["CMUX_SURFACE_ID": surface.uuidString, "CMUX_WORKSPACE_ID": workspace.uuidString]
    }

    private var payload: Data { Data("{\"sessionId\":\"\(session.uuidString)\"}".utf8) }

    @Test func ownSessionAppearanceNeedsExistingProofAndSurvivesHookRefreshes() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        let choice = CMUXMaestroPreview.CopilotSessionAppearance(sessionID: session, iconId: "md-duck", iconColor: "teal")
        #expect(recorder(root).record(payload: payload, environment: environment, appearance: choice) == .noOwner)
        #expect(recorder(root).record(payload: payload, environment: environment) == .recorded)
        let before = try binding(root)
        #expect(recorder(root).record(payload: payload, environment: environment, appearance: choice) == .recorded)
        #expect(try binding(root) == before)
        let file = root.appendingPathComponent("integration/bindings/appearance-\(session.uuidString.lowercased()).json")
        let selected = try JSONDecoder().decode(CMUXMaestroPreview.CopilotSessionAppearance.self, from: Data(contentsOf: file))
        #expect(selected == choice)
        #expect(recorder(root).record(payload: payload, environment: environment) == .recorded)
        #expect(try JSONDecoder().decode(CMUXMaestroPreview.CopilotSessionAppearance.self, from: Data(contentsOf: file)) == choice)
        let colorOnly = CMUXMaestroPreview.CopilotSessionAppearance(sessionID: session, iconId: nil, iconColor: "blue")
        #expect(recorder(root).record(payload: payload, environment: environment, appearance: colorOnly) == .recorded)
        let recolored = try JSONDecoder().decode(CMUXMaestroPreview.CopilotSessionAppearance.self, from: Data(contentsOf: file))
        #expect(recolored.iconId == "md-duck")
        #expect(recolored.iconColor == "blue")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Orchestration").path))
    }

    @Test func ownSessionAppearanceRejectsDifferentSurfaceInvalidColorAndUncertainOwner() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).record(payload: payload, environment: environment) == .recorded)
        let choice = CMUXMaestroPreview.CopilotSessionAppearance(sessionID: session, iconId: "md-duck", iconColor: "teal")
        let different = environment.merging(["CMUX_SURFACE_ID": UUID().uuidString]) { _, value in value }
        #expect(recorder(root).record(payload: payload, environment: different, appearance: choice) == .noOwner)
        let invalid = CMUXMaestroPreview.CopilotSessionAppearance(sessionID: session, iconId: "md-duck", iconColor: "orange")
        #expect(recorder(root).record(payload: payload, environment: environment, appearance: invalid) == .invalidInput)
        #expect(recorder(root, process: { _ in .unavailable }).record(
            payload: payload, environment: environment, appearance: choice
        ) == .noOwner)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(
            "integration/bindings/appearance-\(session.uuidString.lowercased()).json"
        ).path))
    }

    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/hook-fixtures/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state/\(session.uuidString.lowercased())"),
                                                withIntermediateDirectories: true)
        return root
    }

    private func marker(_ root: URL, pid: Int32 = 101) throws {
        try Data().write(to: root.appendingPathComponent("state/\(session.uuidString.lowercased())/inuse.\(pid).lock"))
    }

    private func lookup(_ pid: Int32) -> HookLookup {
        switch pid {
        case 103: .found(HookProcess(pid: 103, parentPID: 102, uid: getuid(), startSeconds: 3, startMicroseconds: 0))
        case 102: .found(HookProcess(pid: 102, parentPID: 101, uid: getuid(), startSeconds: 2, startMicroseconds: 0))
        case 101: .found(HookProcess(pid: 101, parentPID: 1, uid: getuid(), startSeconds: 1, startMicroseconds: 0))
        default: .dead
        }
    }

    private func recorder(_ root: URL, process: (@Sendable (Int32) -> HookLookup)? = nil) -> CopilotHookRecorder {
        CopilotHookRecorder(integrationRoot: root.appendingPathComponent("integration"),
                            sessionStateRoot: root.appendingPathComponent("state"),
                            processID: 103, process: process ?? { @Sendable pid in lookup(pid) })
    }

    private func binding(_ root: URL) throws -> CopilotIdentityRecord {
        let data = try Data(contentsOf: root.appendingPathComponent("integration/bindings/\(session.uuidString.lowercased()).json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(CopilotIdentityRecord.self, from: data)
    }

    @Test func recordsAncestorOwnerNotShellAndUsesPrivateAtomicFiles() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).record(payload: payload, environment: environment) == .recorded)
        let identity = try binding(root)
        #expect(identity.sessionID == session)
        #expect(identity.surfaceID == surface)
        #expect(identity.launchWorkspaceID == workspace)
        #expect(identity.ownerPID == 101)
        #expect(identity.ownerStartSeconds == 1)
        let file = root.appendingPathComponent("integration/bindings/\(session.uuidString.lowercased()).json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directory = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        #expect((directory[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
            .contains(where: { $0.hasPrefix(".pending-") }))
    }

    @Test func rejectsMalformedUnknownConflictingAndOversizedPayloads() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        let inputs = [
            Data("not json".utf8),
            Data("{\"sessionID\":\"\(session.uuidString)\"}".utf8),
            Data("{\"transcriptPath\":\"/arbitrary/\(session.uuidString)\"}".utf8),
            Data("{\"sessionId\":\"\(session.uuidString)\",\"session_id\":\"\(surface.uuidString)\"}".utf8),
            Data(repeating: 32, count: 65_537),
        ]
        for input in inputs {
            #expect(recorder(root).record(payload: input, environment: environment) == .invalidInput)
        }
        #expect(recorder(root).record(payload: payload, environment: ["CMUX_SURFACE_ID": "bad"]) == .invalidInput)
        let diagnostic = try String(contentsOf: root.appendingPathComponent("integration/hook-status.json"), encoding: .utf8)
        #expect(diagnostic == "{\"status\":\"invalidInput\"}\n")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("integration/bindings").path))
    }

    @Test func supportsCanonicalSnakeCaseAndIgnoresTranscriptPath() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        let input = Data("{\"session_id\":\"\(session.uuidString)\",\"transcriptPath\":\"/not/used\"}".utf8)
        #expect(recorder(root).record(payload: input, environment: environment) == .recorded)
    }

    @Test(arguments: [19, 1_048_577])
    func sourceMarkerContentAndSizeAreIrrelevantToMetadataProof(size: Int) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state/\(session.uuidString.lowercased())/inuse.101.lock")
        try Data(repeating: 0x61, count: size).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        if getuid() != 0 { #expect(access(file.path, R_OK) == -1) }
        #expect(recorder(root).record(payload: payload, environment: environment) == .recorded)
        #expect(try binding(root).ownerPID == 101)
    }

    @Test(arguments: ["birth", "ctime"])
    func changedMarkerTimestampRejectsBindingDespiteUnchangedIdentitySizeAndMtime(kind: String) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        let file = root.appendingPathComponent("state/\(session.uuidString.lowercased())/inuse.101.lock")
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        #expect(fd >= 0)
        defer { close(fd) }
        var value = stat()
        #expect(fstat(fd, &value) == 0)
        let original = value

        // Isolate each timestamp in the shared proof's equality comparison, so
        // a birthtime mutation cannot be detected solely by its incidental ctime.
        var timestampOnly = original
        if kind == "birth" {
            timestampOnly.st_birthtimespec.tv_nsec += 1
        } else {
            timestampOnly.st_ctimespec.tv_nsec += 1
        }
        #expect(CMUXMaestroPreview.CopilotFileStamp(original)
            != CMUXMaestroPreview.CopilotFileStamp(timestampOnly))

        let calls = HookProbeCalls()
        let changing: @Sendable (Int32) -> HookLookup = { pid in
            if pid == 101, calls.next() == 4 {
                if kind == "birth" {
                    var attributes = attrlist()
                    attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
                    attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
                    var birth = original.st_birthtimespec
                    birth.tv_sec -= 1
                    #expect(fsetattrlist(fd, &attributes, &birth, MemoryLayout<timespec>.size, 0) == 0)
                } else {
                    usleep(2_000)
                    #expect(fchmod(fd, 0o400) == 0)
                    #expect(fchmod(fd, original.st_mode & 0o7777) == 0)
                }
            }
            return lookup(pid)
        }
        #expect(recorder(root, process: changing).record(payload: payload, environment: environment) == .noOwner)
        var changed = stat()
        #expect(fstat(fd, &changed) == 0)
        #expect(changed.st_ino == original.st_ino)
        #expect(changed.st_size == original.st_size)
        #expect(changed.st_mode == original.st_mode)
        #expect(changed.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec)
        #expect(changed.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec)
        if kind == "birth" {
            #expect(changed.st_birthtimespec.tv_sec != original.st_birthtimespec.tv_sec)
        } else {
            #expect(changed.st_ctimespec.tv_sec != original.st_ctimespec.tv_sec
                || changed.st_ctimespec.tv_nsec != original.st_ctimespec.tv_nsec)
        }
        #expect(throws: (any Error).self) { try binding(root) }
    }

    @Test func unknownOrMultipleLiveMarkerOwnersCannotBeSelectedByAncestry() throws {
        for uncertain in [false, true] {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try marker(root)
            try marker(root, pid: 999)
            let conflicting: @Sendable (Int32) -> HookLookup = { pid in
                if pid == 999 {
                    return uncertain ? .unavailable : .found(HookProcess(
                        pid: 999, parentPID: 1, uid: getuid(), startSeconds: 1, startMicroseconds: 0
                    ))
                }
                return lookup(pid)
            }
            #expect(recorder(root, process: conflicting).record(payload: payload, environment: environment) == .noOwner)
            #expect(throws: (any Error).self) { try binding(root) }
        }
    }

    @Test func disabledFlagsDoNotWriteAndLegacyFlagDoesNotDisableNative() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        for key in ["CMUX_COPILOT_HOOKS_DISABLED", "MAESTRO_NATIVE_DISABLED"] {
            #expect(recorder(root).record(payload: payload, environment: environment.merging([key: "1"]) { _, new in new }) == .disabled)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("integration").path))
        #expect(recorder(root).record(payload: payload,
            environment: environment.merging(["MAESTRO_DISABLED": "1"]) { _, new in new }) == .recorded)
    }

    @Test func absentMarkerNeverGuessesAndLaterHookCanRecord() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(recorder(root).record(payload: payload, environment: environment) == .noOwner)
        try marker(root)
        #expect(recorder(root).record(payload: payload, environment: environment) == .recorded)
    }

    @Test func unrelatedMarkerAndDifferentUserAreRejected() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root, pid: 999)
        #expect(recorder(root).record(payload: payload, environment: environment) == .noOwner)
        try marker(root)
        let foreign: @Sendable (Int32) -> HookLookup = { pid in
            guard case .found(let value) = lookup(pid) else { return .dead }
            return .found(HookProcess(pid: value.pid, parentPID: value.parentPID,
                uid: pid == 101 ? getuid() + 1 : getuid(),
                startSeconds: value.startSeconds, startMicroseconds: value.startMicroseconds))
        }
        #expect(recorder(root, process: foreign).record(payload: payload, environment: environment) == .noOwner)
    }

    @Test func replacedGenerationDuringCommitCannotBind() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        let calls = HookProbeCalls()
        let changing: @Sendable (Int32) -> HookLookup = { pid in
            if pid == 101, calls.next() > 1 { return .dead }
            return lookup(pid)
        }
        #expect(recorder(root, process: changing).record(payload: payload, environment: environment) == .noOwner)
        #expect(throws: (any Error).self) { try binding(root) }
    }

    @Test func symlinkSourceMarkerAndDestinationAreRejected() throws {
        for target in ["source", "marker", "destination"] {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try marker(root)
            let source = root.appendingPathComponent("state/\(session.uuidString.lowercased())")
            let external = root.appendingPathComponent("unrelated")
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            switch target {
            case "source":
                try FileManager.default.removeItem(at: source)
                try FileManager.default.createSymbolicLink(at: source, withDestinationURL: external)
            case "marker":
                let file = source.appendingPathComponent("inuse.101.lock")
                try FileManager.default.removeItem(at: file)
                try Data().write(to: external.appendingPathComponent("marker"))
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external.appendingPathComponent("marker"))
            default:
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("integration"),
                                                          withDestinationURL: external)
            }
            #expect(recorder(root).record(payload: payload, environment: environment) != .recorded)
            #expect(!FileManager.default.fileExists(atPath: external.appendingPathComponent("bindings").path))
        }
    }

    @Test func anotherLiveOwnerCannotBeOverwrittenButProvenResumeCanMove() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).record(payload: payload, environment: environment) == .recorded)
        try marker(root, pid: 201)
        let livePrevious: @Sendable (Int32) -> HookLookup = { pid in
            if pid == 103 { return .found(HookProcess(pid: 103, parentPID: 201, uid: getuid(), startSeconds: 5, startMicroseconds: 0)) }
            if pid == 201 { return .found(HookProcess(pid: 201, parentPID: 1, uid: getuid(), startSeconds: 4, startMicroseconds: 0)) }
            return lookup(pid)
        }
        let moved = environment.merging(["CMUX_SURFACE_ID": UUID().uuidString]) { _, new in new }
        #expect(recorder(root, process: livePrevious).record(payload: payload, environment: moved) == .noOwner)
        #expect(try binding(root).surfaceID == surface)
        let deadPrevious: @Sendable (Int32) -> HookLookup = { $0 == 101 ? .dead : livePrevious($0) }
        #expect(recorder(root, process: deadPrevious).record(payload: payload, environment: moved) == .recorded)
        #expect(try binding(root).surfaceID.uuidString == moved["CMUX_SURFACE_ID"])
    }

    @Test func sandboxGrantPrefixesAreExactAndReadOnly() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("CMUXMaestroSidebar/CMUXMaestroSidebar.entitlements"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let grants = try #require(plist["com.apple.security.temporary-exception.files.home-relative-path.read-only"] as? [String])
        #expect(grants == [
            "/Library/Application Support/CMUXMaestroPreview/Copilot/",
            "/Library/Application Support/CMUXMaestroPreview/Orchestration/observer/",
            "/.copilot/session-state/",
        ])
        #expect(grants.allSatisfy { $0.hasPrefix("/") && $0.hasSuffix("/") })
        #expect(plist["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(plist.count == 2)
    }
}
