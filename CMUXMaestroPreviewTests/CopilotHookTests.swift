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

    @Test func hookRetiresOnlySupersededDeadBindingsAndKeepsRecoveryEvidence() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        let older = try historicalBinding(root, number: 1, pid: 201)
        let newest = try historicalBinding(root, number: 2, pid: 202)
        let live = try historicalBinding(root, number: 3, pid: 101)
        let unknown = try historicalBinding(root, number: 4, pid: 204)
        let resumed = try historicalBinding(root, number: 5, pid: 205)
        let resumedID = resumed.deletingPathExtension().lastPathComponent
        try Data().write(to: root.appendingPathComponent("state/\(resumedID)/inuse.101.lock"))
        let otherSurface = try historicalBinding(root, number: 6, pid: 206, surface: UUID())
        let probe: @Sendable (Int32) -> HookLookup = { pid in
            pid == 204 ? .unavailable : lookup(pid)
        }

        #expect(recorder(root, process: probe).bind(payload: payload, environment: environment) == .recorded)

        #expect(!FileManager.default.fileExists(atPath: older.path))
        for file in [newest, live, unknown, resumed, otherSurface] {
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
        let archives = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("integration/retired-bindings"), includingPropertiesForKeys: nil)
        #expect(archives.count == 1)
        let archived = try CopilotIdentityJSON.decode(Data(contentsOf: #require(archives.first)))
        #expect(archived.ownerPID == 201)
        let lock = older.deletingLastPathComponent().appendingPathComponent(
            ".\(older.deletingPathExtension().lastPathComponent).lock")
        #expect(FileManager.default.fileExists(atPath: lock.path))
    }

    private func historicalBinding(
        _ root: URL, number: Int, pid: Int32, surface: UUID? = nil
    ) throws -> URL {
        let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
        let record = CopilotIdentityRecord(
            sessionID: id, surfaceID: surface ?? self.surface, launchWorkspaceID: workspace,
            ownerPID: pid, ownerStartSeconds: 1, ownerStartMicroseconds: 0,
            recordedAt: Date(timeIntervalSince1970: Double(number)))
        let file = root.appendingPathComponent("integration/bindings/\(id.uuidString.lowercased()).json")
        try CopilotIdentityJSON.encode(record).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("state/\(id.uuidString.lowercased())"), withIntermediateDirectories: true)
        return file
    }

    @Test(arguments: ["rewrite", "resume", "unknown"])
    func retirementRevalidatesConcurrentChanges(change: String) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        let older = try historicalBinding(root, number: 1, pid: 201)
        let newest = try historicalBinding(root, number: 2, pid: 202)
        let previous = try CopilotIdentityJSON.decode(Data(contentsOf: older))
        let replacement = CopilotIdentityRecord(
            sessionID: previous.sessionID, surfaceID: previous.surfaceID,
            launchWorkspaceID: previous.launchWorkspaceID, ownerPID: 101,
            ownerStartSeconds: 1, ownerStartMicroseconds: 0, recordedAt: previous.recordedAt)
        let replacementData = try CopilotIdentityJSON.encode(replacement)
        let calls = HookProbeCalls()
        let probe: @Sendable (Int32) -> HookLookup = { pid in
            if pid == 201, calls.next() == 3 {
                switch change {
                case "rewrite":
                    do {
                        try replacementData.write(to: older, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: older.path)
                    } catch { Issue.record(error) }
                case "resume":
                    do {
                        try Data().write(to: root.appendingPathComponent(
                            "state/\(previous.sessionID.uuidString.lowercased())/inuse.101.lock"))
                    } catch { Issue.record(error) }
                default: return .unavailable
                }
            }
            return lookup(pid)
        }

        #expect(recorder(root, process: probe).bind(payload: payload, environment: environment) == .recorded)

        #expect(FileManager.default.fileExists(atPath: older.path))
        #expect(FileManager.default.fileExists(atPath: newest.path))
        if change == "rewrite" {
            #expect(try CopilotIdentityJSON.decode(Data(contentsOf: older)) == replacement)
        }
    }

    @Test func retirementNeverDeletesBusyBindingOrInstallLocks() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        let older = try historicalBinding(root, number: 1, pid: 201)
        _ = try historicalBinding(root, number: 2, pid: 202)
        let lockURL = older.deletingLastPathComponent().appendingPathComponent(
            ".\(older.deletingPathExtension().lastPathComponent).lock")
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let installLock = root.appendingPathComponent("integration/install.lock")
        try Data("preserve-install-lock".utf8).write(to: installLock)
        let before = try CMUXMaestroPreview.CopilotFileAccess.statFile(fd)

        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)

        #expect(FileManager.default.fileExists(atPath: older.path))
        #expect(try CMUXMaestroPreview.CopilotFileAccess.statFile(fd) == before)
        #expect(try String(contentsOf: installLock, encoding: .utf8) == "preserve-install-lock")
        #expect(flock(fd, LOCK_UN) == 0)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        #expect(!FileManager.default.fileExists(atPath: older.path))
        #expect(FileManager.default.fileExists(atPath: lockURL.path))
    }

    @Test(arguments: ["missing-source", "reused-pid", "hard-link", "permissions", "unsupported", "archive-failure"])
    func retirementPreservesUnverifiableOrUnarchivableBindings(reason: String) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        let older = try historicalBinding(root, number: 1, pid: 201)
        _ = try historicalBinding(root, number: 2, pid: 202)
        switch reason {
        case "missing-source":
            try FileManager.default.removeItem(at: root.appendingPathComponent(
                "state/\(older.deletingPathExtension().lastPathComponent)"))
        case "hard-link":
            try FileManager.default.linkItem(at: older, to: root.appendingPathComponent("linked-binding"))
        case "permissions":
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: older.path)
        case "unsupported":
            let data = try String(contentsOf: older, encoding: .utf8)
            try Data(data.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8)
                .write(to: older)
        case "archive-failure":
            try Data("not a directory".utf8).write(to: root.appendingPathComponent("integration/retired-bindings"))
        default: break
        }
        let probe: @Sendable (Int32) -> HookLookup = { pid in
            if pid == 201, reason == "reused-pid" {
                return .found(HookProcess(pid: pid, parentPID: 1, uid: getuid(), startSeconds: 9, startMicroseconds: 1))
            }
            return lookup(pid)
        }

        #expect(recorder(root, process: probe).bind(payload: payload, environment: environment) == .recorded)

        #expect(FileManager.default.fileExists(atPath: older.path))
    }

    @Test func retirementBoundsCandidateWorkAndRotatesPastTheFirstBatch() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        for number in 1...70 { _ = try historicalBinding(root, number: number, pid: 201) }

        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)

        let status = root.appendingPathComponent("integration/binding-retirement-status.json")
        let first = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: status)) as? [String: Any])
        #expect(first["examined"] as? Int == 64)
        #expect(first["retired"] as? Int == 63)
        let last = root.appendingPathComponent("integration/bindings/00000000-0000-4000-8000-000000000070.json")
        #expect(FileManager.default.fileExists(atPath: last.path))
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        let second = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: status)) as? [String: Any])
        #expect(second["examined"] as? Int == 7)
        #expect(second["retired"] as? Int == 5)
        #expect(FileManager.default.fileExists(atPath: last.path))
        #expect(try binding(root).ownerPID == 101)
    }

    @Test func retirementDirectoryOverflowDoesNoCandidateWork() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        let older = try historicalBinding(root, number: 1, pid: 201)
        _ = try historicalBinding(root, number: 2, pid: 202)
        for index in 0..<4097 {
            try Data().write(to: root.appendingPathComponent("integration/bindings/foreign-\(index)"))
        }

        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)

        let status = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("integration/binding-retirement-status.json"))) as? [String: Any])
        #expect(status["status"] as? String == "limited")
        #expect(status["examined"] as? Int == 0)
        #expect(status["retired"] as? Int == 0)
        #expect(FileManager.default.fileExists(atPath: older.path))
    }

    @Test func ownSessionAppearanceNeedsExistingProofAndSurvivesHookRefreshes() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        let choice = CMUXMaestroPreview.CopilotSessionAppearance(sessionID: session, iconId: "md-duck", iconColor: "teal")
        #expect(recorder(root).setAppearance(choice, payload: payload, environment: environment) == .noOwner)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        let before = try binding(root)
        #expect(recorder(root).setAppearance(choice, payload: payload, environment: environment) == .recorded)
        #expect(try binding(root) == before)
        let file = root.appendingPathComponent("integration/bindings/appearance-\(session.uuidString.lowercased()).json")
        let selected = try JSONDecoder().decode(CMUXMaestroPreview.CopilotSessionAppearance.self, from: Data(contentsOf: file))
        #expect(selected == choice)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        #expect(try JSONDecoder().decode(CMUXMaestroPreview.CopilotSessionAppearance.self, from: Data(contentsOf: file)) == choice)
        let colorOnly = CMUXMaestroPreview.CopilotSessionAppearance(sessionID: session, iconId: nil, iconColor: "blue")
        #expect(recorder(root).setAppearance(colorOnly, payload: payload, environment: environment) == .recorded)
        let recolored = try JSONDecoder().decode(CMUXMaestroPreview.CopilotSessionAppearance.self, from: Data(contentsOf: file))
        #expect(recolored.iconId == "md-duck")
        #expect(recolored.iconColor == "blue")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Orchestration").path))
    }

    @Test func proveNeedsExistingBindingAndWritesNothing() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).prove(payload: payload, environment: environment) == .noOwner)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        let before = try binding(root)
        #expect(recorder(root).prove(payload: payload, environment: environment) == .recorded)
        #expect(try binding(root) == before)
        let appearance = root.appendingPathComponent("integration/bindings/appearance-\(session.uuidString.lowercased()).json")
        #expect(!FileManager.default.fileExists(atPath: appearance.path))
        let different = environment.merging(["CMUX_SURFACE_ID": UUID().uuidString]) { _, value in value }
        #expect(recorder(root).prove(payload: payload, environment: different) == .noOwner)
    }

    @Test func everyIntentSharesTheDisabledAndInputGatesWithoutWriting() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        let choice = CMUXMaestroPreview.CopilotSessionAppearance(sessionID: session, iconId: "md-duck", iconColor: "teal")
        let disabled = environment.merging(["MAESTRO_NATIVE_DISABLED": "1"]) { _, new in new }
        #expect(recorder(root).bind(payload: payload, environment: disabled) == .disabled)
        #expect(recorder(root).setAppearance(choice, payload: payload, environment: disabled) == .disabled)
        #expect(recorder(root).prove(payload: payload, environment: disabled) == .disabled)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("integration").path))
        let malformed = Data("{}".utf8)
        #expect(recorder(root).bind(payload: malformed, environment: environment) == .invalidInput)
        #expect(recorder(root).setAppearance(choice, payload: malformed, environment: environment) == .invalidInput)
        #expect(recorder(root).prove(payload: malformed, environment: environment) == .invalidInput)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        let foreign = CMUXMaestroPreview.CopilotSessionAppearance(sessionID: UUID(), iconId: "md-duck", iconColor: "teal")
        #expect(recorder(root).setAppearance(foreign, payload: payload, environment: environment) == .invalidInput)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(
            "integration/bindings/appearance-\(session.uuidString.lowercased()).json"
        ).path))
    }

    @Test func ownSessionAppearanceRejectsDifferentSurfaceInvalidColorAndUncertainOwner() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        let choice = CMUXMaestroPreview.CopilotSessionAppearance(sessionID: session, iconId: "md-duck", iconColor: "teal")
        let different = environment.merging(["CMUX_SURFACE_ID": UUID().uuidString]) { _, value in value }
        #expect(recorder(root).setAppearance(choice, payload: payload, environment: different) == .noOwner)
        let invalid = CMUXMaestroPreview.CopilotSessionAppearance(sessionID: session, iconId: "md-duck", iconColor: "orange")
        #expect(recorder(root).setAppearance(invalid, payload: payload, environment: environment) == .invalidInput)
        #expect(recorder(root, process: { _ in .unavailable }).setAppearance(choice, payload: payload, environment: environment) == .noOwner)
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
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
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
            #expect(recorder(root).bind(payload: input, environment: environment) == .invalidInput)
        }
        #expect(recorder(root).bind(payload: payload, environment: ["CMUX_SURFACE_ID": "bad"]) == .invalidInput)
        let diagnostic = try String(contentsOf: root.appendingPathComponent("integration/hook-status.json"), encoding: .utf8)
        #expect(diagnostic == "{\"status\":\"invalidInput\"}\n")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("integration/bindings").path))
    }

    @Test func supportsCanonicalSnakeCaseAndIgnoresTranscriptPath() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        let input = Data("{\"session_id\":\"\(session.uuidString)\",\"transcriptPath\":\"/not/used\"}".utf8)
        #expect(recorder(root).bind(payload: input, environment: environment) == .recorded)
    }

    @Test(arguments: [19, 1_048_577])
    func sourceMarkerContentAndSizeAreIrrelevantToMetadataProof(size: Int) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state/\(session.uuidString.lowercased())/inuse.101.lock")
        try Data(repeating: 0x61, count: size).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        if getuid() != 0 { #expect(access(file.path, R_OK) == -1) }
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
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
        #expect(recorder(root, process: changing).bind(payload: payload, environment: environment) == .noOwner)
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
            #expect(recorder(root, process: conflicting).bind(payload: payload, environment: environment) == .noOwner)
            #expect(throws: (any Error).self) { try binding(root) }
        }
    }

    @Test func disabledFlagsDoNotWriteAndLegacyFlagDoesNotDisableNative() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload,
            environment: environment.merging(["MAESTRO_NATIVE_DISABLED": "1"]) { _, new in new }) == .disabled)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("integration").path))
        #expect(recorder(root).bind(payload: payload,
            environment: environment.merging(["MAESTRO_DISABLED": "1"]) { _, new in new }) == .recorded)
    }

    /// Maestro launches set CMUX_COPILOT_HOOKS_DISABLED=1 so CMUX's own restore never claims them
    /// (ADR 0024). That switch belongs to CMUX; Maestro keeps observing the session.
    @Test func cmuxRestoreSwitchDoesNotSilenceMaestroObservation() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(!CopilotHookRecorder.isDisabled(["CMUX_COPILOT_HOOKS_DISABLED": "1"]))
        #expect(recorder(root).bind(payload: payload,
            environment: environment.merging(["CMUX_COPILOT_HOOKS_DISABLED": "1"]) { _, new in new }) == .recorded)
    }

    @Test func absentMarkerNeverGuessesAndLaterHookCanRecord() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(recorder(root).bind(payload: payload, environment: environment) == .noOwner)
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
    }

    @Test func unrelatedMarkerAndDifferentUserAreRejected() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root, pid: 999)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .noOwner)
        try marker(root)
        let foreign: @Sendable (Int32) -> HookLookup = { pid in
            guard case .found(let value) = lookup(pid) else { return .dead }
            return .found(HookProcess(pid: value.pid, parentPID: value.parentPID,
                uid: pid == 101 ? getuid() + 1 : getuid(),
                startSeconds: value.startSeconds, startMicroseconds: value.startMicroseconds))
        }
        #expect(recorder(root, process: foreign).bind(payload: payload, environment: environment) == .noOwner)
    }

    @Test func replacedGenerationDuringCommitCannotBind() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        // The bindings lock exists only after ownership was proven; the owner dies after that.
        let lock = root.appendingPathComponent("integration/bindings/.\(session.uuidString.lowercased()).lock").path
        let proven = HookProbeCalls()
        let afterProof = HookProbeCalls()
        let changing: @Sendable (Int32) -> HookLookup = { pid in
            guard pid == 101 else { return lookup(pid) }
            guard FileManager.default.fileExists(atPath: lock) else { _ = proven.next(); return lookup(pid) }
            _ = afterProof.next()
            return .dead
        }
        #expect(recorder(root, process: changing).bind(payload: payload, environment: environment) == .noOwner)
        #expect(proven.next() > 2, "The owner must be found and verified before the commit check")
        #expect(afterProof.next() > 1, "The commit check must look the owner up again")
        #expect(throws: (any Error).self) { try binding(root) }
        // Control: the same live owner commits.
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        #expect(try binding(root).ownerPID == 101)
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
            #expect(recorder(root).bind(payload: payload, environment: environment) != .recorded)
            #expect(!FileManager.default.fileExists(atPath: external.appendingPathComponent("bindings").path))
        }
    }

    @Test func anotherLiveOwnerCannotBeOverwrittenButProvenResumeCanMove() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        try marker(root, pid: 201)
        let livePrevious: @Sendable (Int32) -> HookLookup = { pid in
            if pid == 103 { return .found(HookProcess(pid: 103, parentPID: 201, uid: getuid(), startSeconds: 5, startMicroseconds: 0)) }
            if pid == 201 { return .found(HookProcess(pid: 201, parentPID: 1, uid: getuid(), startSeconds: 4, startMicroseconds: 0)) }
            return lookup(pid)
        }
        let moved = environment.merging(["CMUX_SURFACE_ID": UUID().uuidString]) { _, new in new }
        #expect(recorder(root, process: livePrevious).bind(payload: payload, environment: moved) == .noOwner)
        #expect(try binding(root).surfaceID == surface)
        let deadPrevious: @Sendable (Int32) -> HookLookup = { $0 == 101 ? .dead : livePrevious($0) }
        #expect(recorder(root, process: deadPrevious).bind(payload: payload, environment: moved) == .recorded)
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
        #expect(plist["com.apple.security.files.user-selected.read-only"] as? Bool == true)
        let writes = try #require(plist["com.apple.security.temporary-exception.files.home-relative-path.read-write"] as? [String])
        #expect(writes == ["/Library/Application Support/CMUXMaestroPreview/Beats/"])
        #expect(plist.count == 4)
    }
}
