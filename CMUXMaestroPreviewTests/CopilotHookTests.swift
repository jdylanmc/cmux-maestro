import CryptoKit
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

    func peek() -> Int {
        lock.lock()
        defer { lock.unlock() }
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
        #expect(first["examined"] as? Int == 16)
        #expect(first["retired"] as? Int == 2)
        let last = root.appendingPathComponent("integration/bindings/00000000-0000-4000-8000-000000000070.json")
        #expect(FileManager.default.fileExists(atPath: last.path))
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        let second = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: status)) as? [String: Any])
        #expect(second["examined"] as? Int == 16)
        #expect(second["retired"] as? Int == 2)
        #expect(FileManager.default.fileExists(atPath: last.path))
        #expect(try binding(root).ownerPID == 101)
    }

    @Test func retirementParentSyncFailurePreservesBinding() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        let older = try historicalBinding(root, number: 1, pid: 201)
        _ = try historicalBinding(root, number: 2, pid: 202)
        let fd = try HookFiles.privateDirectory(root.appendingPathComponent("integration"))
        defer { close(fd) }
        let parent = try CMUXMaestroPreview.CopilotFileAccess.statFile(fd)
        var retirement = CopilotBindingRetirement(
            integrationRoot: root.appendingPathComponent("integration"),
            sessionStateRoot: root.appendingPathComponent("state"), process: { lookup($0) })
        retirement.syncDirectory = { directory in
            guard let stamp = try? CMUXMaestroPreview.CopilotFileAccess.statFile(directory),
                  !stamp.sameFile(as: parent) else { return -1 }
            return fsync(directory)
        }
        retirement.run()
        #expect(FileManager.default.fileExists(atPath: older.path))
        retirement.syncDirectory = { fsync($0) }
        retirement.run()
        #expect(!FileManager.default.fileExists(atPath: older.path))
    }

    @Test func postToolHookDoesNotRunRetirement() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        let older = try historicalBinding(root, number: 1, pid: 201)
        _ = try historicalBinding(root, number: 2, pid: 202)
        let toolPayload = try JSONSerialization.data(withJSONObject: [
            "sessionId": session.uuidString, "toolName": "view",
        ])
        #expect(recorder(root).bind(payload: toolPayload, environment: environment) == .recorded)
        #expect(FileManager.default.fileExists(atPath: older.path))
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        #expect(!FileManager.default.fileExists(atPath: older.path))
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

    private func recorder(
        _ root: URL, process: (@Sendable (Int32) -> HookLookup)? = nil,
        placement: @escaping @Sendable (Int32, UUID) -> Bool = { _, _ in true }
    ) -> CopilotHookRecorder {
        var recorder = CopilotHookRecorder(integrationRoot: root.appendingPathComponent("integration"),
                                           sessionStateRoot: root.appendingPathComponent("state"),
                                           processID: 103, process: process ?? { @Sendable pid in lookup(pid) })
        recorder.placement = placement
        return recorder
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

    @Test func inheritedCMUXValuesOutsideTheirSurfaceRecordNothing() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        let asked = HookProbeCalls()
        let outcome = recorder(root, placement: { owner, claimed in
            _ = asked.next()
            return !(owner == 101 && claimed == surface)
        }).bind(payload: payload, environment: environment)
        #expect(outcome == .unplaced)
        #expect(asked.peek() == 1)
        let bindings = root.appendingPathComponent("integration/bindings")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: bindings.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.isEmpty)
        let status = try String(contentsOf: root.appendingPathComponent("integration/hook-status.json"), encoding: .utf8)
        #expect(status == "{\"status\":\"unplaced\"}\n")
    }

    @Test func placementIsAskedOnlyBeforeABindingIsCreatedOrMoved() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        let asked = HookProbeCalls()
        let placement: @Sendable (Int32, UUID) -> Bool = { _, _ in _ = asked.next(); return true }
        #expect(recorder(root, placement: placement).bind(payload: payload, environment: environment) == .recorded)
        #expect(recorder(root, placement: placement).bind(payload: payload, environment: environment) == .recorded)
        #expect(asked.peek() == 1)
        let moved = environment.merging(["CMUX_SURFACE_ID": UUID().uuidString]) { _, new in new }
        #expect(recorder(root, placement: { _, _ in _ = asked.next(); return false })
            .bind(payload: payload, environment: moved) == .unplaced)
        #expect(asked.peek() == 2)
        #expect(try binding(root).surfaceID == surface)
    }

    @Test func surfaceTerminalReadsOnlyTheOneExactSurface() throws {
        func report(_ surfaces: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["windows": [["workspaces": [["panes": [
                ["surfaces": surfaces.map { ["kind": "surface"].merging($0) { _, new in new } }]
            ]]]]]])
        }
        let other = UUID().uuidString
        let place = CopilotTerminalPlacement.surfaceTerminal
        #expect(place(try report([["id": other, "tty": "ttys000"], ["id": surface.uuidString.lowercased(),
                                                                       "tty": "/dev/ttys014"]]), surface) == "ttys014")
        #expect(place(try report([["id": other, "tty": "ttys014"]]), surface) == nil)
        #expect(place(try report([["id": surface.uuidString, "tty": "ttys014"],
                                  ["id": surface.uuidString, "tty": "ttys014"]]), surface) == nil)
        for tty: Any in [NSNull(), "", "??", "pts/1", "tty../x", 7] {
            #expect(place(try report([["id": surface.uuidString, "tty": tty]]), surface) == nil)
        }
        #expect(place(Data("not json".utf8), surface) == nil)
    }

    @Test func cmuxTopIsBoundedAndOnlyATrustedSuccessfulAnswerCounts() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        func tool(_ name: String, _ body: String, mode: Int = 0o700) throws -> String {
            let url = root.appendingPathComponent(name)
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            return url.path
        }
        // System binaries, not fresh scripts: a parallel fork can hold a just-written file open
        // (ETXTBSY). Generous hang guards on a loaded runner; only the silent case uses the bound.
        let guardTime: TimeInterval = 60
        #expect(CopilotTerminalPlacement.cmuxTop(executable: "/bin/echo", timeout: guardTime)
            .map { String(decoding: $0, as: UTF8.self) } == "--json --id-format uuids top --all\n")
        #expect(CopilotTerminalPlacement.cmuxTop(executable: "/usr/bin/false", timeout: guardTime) == nil)
        #expect(CopilotTerminalPlacement.cmuxTop(executable: "/usr/bin/yes", timeout: guardTime) == nil)
        #expect(CopilotTerminalPlacement.cmuxTop(executable: try tool("silent", "exec tail -f /dev/null"),
                                                 timeout: 0.2) == nil)
        #expect(CopilotTerminalPlacement.cmuxTop(executable: nil) == nil)

        let writable = try tool("writable", "true", mode: 0o772)
        #expect(CopilotTerminalPlacement.cmuxExecutable(environment: ["CMUX_BUNDLED_CLI_PATH": writable]) == nil)
        #expect(CopilotTerminalPlacement.cmuxExecutable(environment: ["CMUX_BUNDLED_CLI_PATH": "relative/cmux"]) == nil)
        let trusted = try tool("trusted", "true")
        let resolved = CopilotTerminalPlacement.cmuxExecutable(environment: ["CMUX_BUNDLED_CLI_PATH": trusted])
        #expect(resolved.map { URL(fileURLWithPath: $0).lastPathComponent } == "trusted")
        _ = try tool("cmux", "true")
        #expect(CopilotTerminalPlacement.cmuxExecutable(environment: ["PATH": "relative:\(root.path)"])
            .map { URL(fileURLWithPath: $0).lastPathComponent } == "cmux")
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

    /// `/restart` or `/update`: the bound CLI (101) stays alive as the parent and the same
    /// session continues in its direct child (201), which now holds the only live lock.
    private func restarted(
        child: Int32 = 201, childParent: Int32 = 101, childStart: UInt64 = 4,
        extra: [Int32: HookProcess] = [:]
    ) -> @Sendable (Int32) -> HookLookup {
        let base: [Int32: HookProcess] = [
            103: HookProcess(pid: 103, parentPID: child, uid: getuid(), startSeconds: 9, startMicroseconds: 0),
            child: HookProcess(pid: child, parentPID: childParent, uid: getuid(), startSeconds: childStart, startMicroseconds: 0),
            101: HookProcess(pid: 101, parentPID: 1, uid: getuid(), startSeconds: 1, startMicroseconds: 0),
        ]
        let table = base.merging(extra) { _, new in new }
        return { pid in table[pid].map { .found($0) } ?? .dead }
    }

    private func moveLock(_ root: URL, from old: Int32, to new: Int32) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(
            "state/\(session.uuidString.lowercased())/inuse.\(old).lock"))
        try marker(root, pid: new)
    }

    private func archivedOwners(_ root: URL) throws -> [Int32] {
        let directory = root.appendingPathComponent("integration/retired-bindings")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { try CopilotIdentityJSON.decode(Data(contentsOf: $0)).ownerPID }.sorted()
    }

    @Test func inPlaceRestartRebindsToTheLockHoldingDirectChild() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        try moveLock(root, from: 101, to: 201)
        let probe = restarted()

        #expect(recorder(root, process: probe).bind(payload: payload, environment: environment) == .recorded)

        let identity = try binding(root)
        #expect(identity.ownerPID == 201 && identity.ownerStartSeconds == 4)
        #expect(identity.sessionID == session && identity.surfaceID == surface && identity.launchWorkspaceID == workspace)
        #expect(try archivedOwners(root) == [101])
        // The rebound child is now the ordinary owner of its own later hooks.
        #expect(recorder(root, process: probe).prove(payload: payload, environment: environment) == .recorded)
    }

    @Test func repeatedInPlaceRestartsFollowOnlyTheCurrentBoundOwner() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        try moveLock(root, from: 101, to: 201)
        #expect(recorder(root, process: restarted()).bind(payload: payload, environment: environment) == .recorded)
        try moveLock(root, from: 201, to: 301)
        let second = restarted(child: 301, childParent: 201, childStart: 6, extra: [
            201: HookProcess(pid: 201, parentPID: 101, uid: getuid(), startSeconds: 4, startMicroseconds: 0),
        ])

        #expect(recorder(root, process: second).bind(payload: payload, environment: environment) == .recorded)

        #expect(try binding(root).ownerPID == 301)
        #expect(try archivedOwners(root) == [101, 201])
    }

    @Test func restartGrandchildOfTheBoundOwnerIsNotAHandoff() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        // Two restarts with no hook in between: the bound owner is the lock holder's grandparent.
        try moveLock(root, from: 101, to: 301)
        let skipped = restarted(child: 301, childParent: 201, childStart: 6, extra: [
            201: HookProcess(pid: 201, parentPID: 101, uid: getuid(), startSeconds: 4, startMicroseconds: 0),
        ])

        #expect(recorder(root, process: skipped).bind(payload: payload, environment: environment) == .superseded)

        #expect(try binding(root).ownerPID == 101)
        #expect(try archivedOwners(root).isEmpty)
    }

    @Test(arguments: ["no-child-lock", "two-holders", "unrelated", "older-child", "surface", "workspace"])
    func liveOwnerWithoutExactRestartEvidenceKeepsItsBinding(_ variant: String) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        var probe = restarted()
        var env = environment
        var expected = HookOutcome.superseded
        switch variant {
        case "no-child-lock":
            try FileManager.default.removeItem(at: root.appendingPathComponent(
                "state/\(session.uuidString.lowercased())/inuse.101.lock"))
            expected = .noOwner
        case "two-holders":
            try marker(root, pid: 201)
            expected = .noOwner
        case "unrelated":
            try moveLock(root, from: 101, to: 201)
            probe = restarted(childParent: 150, extra: [
                150: HookProcess(pid: 150, parentPID: 1, uid: getuid(), startSeconds: 2, startMicroseconds: 0),
            ])
        case "older-child":
            try moveLock(root, from: 101, to: 201)
            // Not started after the bound owner, so not the process its restart created.
            probe = restarted(childStart: 1)
        case "surface":
            try moveLock(root, from: 101, to: 201)
            env["CMUX_SURFACE_ID"] = UUID().uuidString
        default:
            try moveLock(root, from: 101, to: 201)
            env["CMUX_WORKSPACE_ID"] = UUID().uuidString
        }

        #expect(recorder(root, process: probe).bind(payload: payload, environment: env) == expected)

        #expect(try binding(root).ownerPID == 101)
        #expect(try binding(root).surfaceID == surface)
        #expect(try archivedOwners(root).isEmpty)
    }

    @Test func liveParentStillHoldingTheLockStaysTheOwner() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)

        #expect(recorder(root, process: restarted()).bind(payload: payload, environment: environment) == .recorded)

        #expect(try binding(root).ownerPID == 101)
        #expect(try archivedOwners(root).isEmpty)
    }

    @Test func restartHandoffNeverCrossesSessions() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        let other = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let otherState = root.appendingPathComponent("state/\(other.uuidString.lowercased())")
        try FileManager.default.createDirectory(at: otherState, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: root.appendingPathComponent(
            "state/\(session.uuidString.lowercased())/inuse.101.lock"))
        try Data().write(to: otherState.appendingPathComponent("inuse.201.lock"))
        let otherPayload = Data("{\"sessionId\":\"\(other.uuidString)\"}".utf8)

        #expect(recorder(root, process: restarted()).bind(payload: otherPayload, environment: environment) == .recorded)

        #expect(try binding(root).ownerPID == 101)
        #expect(try archivedOwners(root).isEmpty)
        let otherBinding = try CopilotIdentityJSON.decode(Data(contentsOf: root.appendingPathComponent(
            "integration/bindings/\(other.uuidString.lowercased()).json")))
        #expect(otherBinding.ownerPID == 201)
    }

    @Test func unarchivableRestartHandoffKeepsTheParentBinding() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        try moveLock(root, from: 101, to: 201)
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("integration/retired-bindings"))

        #expect(recorder(root, process: restarted()).bind(payload: payload, environment: environment) == .unavailable)

        #expect(try binding(root).ownerPID == 101)
    }

    @Test func lockMovingToARestartedChildAfterOwnerSelectionCannotProveTheParent() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        let state = root.appendingPathComponent("state/\(session.uuidString.lowercased())")
        // Hook 103 descends from the parent 101; its restarted child 201 is not its ancestor.
        func racing() -> @Sendable (Int32) -> HookLookup {
            let calls = HookProbeCalls()
            return { pid in
                // 101's first lookup selects it by its lock; the second opens its proof.
                if pid == 101, calls.next() == 2 {
                    do {
                        try FileManager.default.removeItem(at: state.appendingPathComponent("inuse.101.lock"))
                        try Data().write(to: state.appendingPathComponent("inuse.201.lock"))
                    } catch { Issue.record(error) }
                }
                if pid == 201 {
                    return .found(HookProcess(pid: 201, parentPID: 101, uid: getuid(), startSeconds: 4, startMicroseconds: 0))
                }
                return lookup(pid)
            }
        }

        #expect(recorder(root, process: racing()).bind(payload: payload, environment: environment) == .noOwner)
        try FileManager.default.removeItem(at: state.appendingPathComponent("inuse.201.lock"))
        try marker(root)
        #expect(recorder(root, process: racing()).prove(payload: payload, environment: environment) == .noOwner)

        #expect(try binding(root).ownerPID == 101)
        #expect(try archivedOwners(root).isEmpty)
    }

    @Test func parentBindingNewerThanTheChildHookBlocksTheHandoff() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        let previous = try binding(root)
        let newer = CopilotIdentityRecord(
            sessionID: previous.sessionID, surfaceID: previous.surfaceID,
            launchWorkspaceID: previous.launchWorkspaceID, ownerPID: previous.ownerPID,
            ownerStartSeconds: previous.ownerStartSeconds, ownerStartMicroseconds: previous.ownerStartMicroseconds,
            recordedAt: Date(timeIntervalSince1970: 100))
        let file = root.appendingPathComponent("integration/bindings/\(session.uuidString.lowercased()).json")
        try CopilotIdentityJSON.encode(newer).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try moveLock(root, from: 101, to: 201)

        #expect(recorder(root, process: restarted()).bind(payload: payload, environment: environment) == .superseded)

        #expect(try binding(root) == newer)
        #expect(try archivedOwners(root).isEmpty)
    }

    @Test func parentExitingAfterTheHandoffDecisionRefusesTheWrite() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        try moveLock(root, from: 101, to: 201)
        let base = restarted()
        let decided = HookProbeCalls()
        let exited = HookProbeCalls()
        // 101 is looked up only by the handoff decision; afterwards it exits and 201 is reparented.
        let exiting: @Sendable (Int32) -> HookLookup = { pid in
            if pid == 101 {
                if decided.next() == 1 { return base(pid) }
                return .dead
            }
            guard pid == 201, decided.peek() > 0 else { return base(pid) }
            _ = exited.next()
            return .found(HookProcess(pid: 201, parentPID: 1, uid: getuid(), startSeconds: 4, startMicroseconds: 0))
        }

        #expect(recorder(root, process: exiting).bind(payload: payload, environment: environment) == .noOwner)

        #expect(exited.peek() > 0, "The commit fence must look the child up after the decision")
        #expect(try binding(root).ownerPID == 101)
        #expect(try archivedOwners(root).isEmpty)
    }

    @Test func handoffArchiveDirectoryMustBeDurableBeforeTheBindingMoves() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        try moveLock(root, from: 101, to: 201)
        let fd = try HookFiles.privateDirectory(root.appendingPathComponent("integration"))
        defer { close(fd) }
        let parent = try CMUXMaestroPreview.CopilotFileAccess.statFile(fd)
        var failing = recorder(root, process: restarted())
        failing.syncDirectory = { directory in
            guard let stamp = try? CMUXMaestroPreview.CopilotFileAccess.statFile(directory),
                  !stamp.sameFile(as: parent) else { return -1 }
            return fsync(directory)
        }

        #expect(failing.bind(payload: payload, environment: environment) == .unavailable)
        #expect(try binding(root).ownerPID == 101)
        #expect(recorder(root, process: restarted()).bind(payload: payload, environment: environment) == .recorded)
        #expect(try binding(root).ownerPID == 201)
    }

    /// The parent's archive name and exact bytes, plus an archive directory ready for fault injection.
    private func parentArchive(_ root: URL) throws -> (directory: URL, file: URL, bytes: Data) {
        let bytes = try CopilotIdentityJSON.encode(binding(root))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent("integration/retired-bindings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return (directory, directory.appendingPathComponent(digest + ".json"), bytes)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func pendingArchives(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(CopilotBindingRetirement.pendingArchivePrefix) }.sorted()
    }

    @Test(arguments: ["empty", "truncated", "garbage"])
    func incompleteDigestArchiveIsReplacedSoTheHandoffCompletes(_ damage: String) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        let archive = try parentArchive(root)
        // What an interrupted or short write by an earlier helper leaves under the final name.
        let left = switch damage {
        case "empty": Data()
        case "truncated": archive.bytes.prefix(archive.bytes.count / 2)
        default: Data(repeating: 0x7B, count: archive.bytes.count)
        }
        try writePrivate(Data(left), to: archive.file)
        try moveLock(root, from: 101, to: 201)

        #expect(recorder(root, process: restarted()).bind(payload: payload, environment: environment) == .recorded)

        #expect(try binding(root).ownerPID == 201)
        #expect(try Data(contentsOf: archive.file) == archive.bytes)
        #expect(try archivedOwners(root) == [101])
        #expect(try pendingArchives(archive.directory).isEmpty)
    }

    @Test func identicalExistingArchiveIsReusedByTheHandoff() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        let archive = try parentArchive(root)
        try writePrivate(archive.bytes, to: archive.file)
        let before = try FileManager.default.attributesOfItem(atPath: archive.file.path)[.systemFileNumber] as? Int
        try moveLock(root, from: 101, to: 201)

        #expect(recorder(root, process: restarted()).bind(payload: payload, environment: environment) == .recorded)

        #expect(try binding(root).ownerPID == 201)
        #expect(try FileManager.default.attributesOfItem(atPath: archive.file.path)[.systemFileNumber] as? Int == before)
        #expect(try archivedOwners(root) == [101])
    }

    @Test(arguments: ["symlink", "hard-link", "permissions"])
    func unsafeExistingDigestEntryIsNeverReplaced(_ kind: String) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        let archive = try parentArchive(root)
        let outside = root.appendingPathComponent("outside")
        try writePrivate(Data(), to: outside)
        switch kind {
        case "symlink": try FileManager.default.createSymbolicLink(at: archive.file, withDestinationURL: outside)
        case "hard-link": try FileManager.default.linkItem(at: outside, to: archive.file)
        default:
            try Data().write(to: archive.file)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: archive.file.path)
        }
        try moveLock(root, from: 101, to: 201)

        #expect(recorder(root, process: restarted()).bind(payload: payload, environment: environment) == .unavailable)

        #expect(try binding(root).ownerPID == 101)
        #expect(try Data(contentsOf: outside).isEmpty)
        #expect(try pendingArchives(archive.directory).isEmpty)
    }

    @Test func pendingArchivesFromExitedWritersAreHarmlessAndSwept() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        let archive = try parentArchive(root)
        let prefix = CopilotBindingRetirement.pendingArchivePrefix
        // A writer killed after a partial write, and one killed after a complete, synced write but
        // before publishing (the digest name was never created).
        let partial = prefix + "999-1-0-\(UUID().uuidString.lowercased())"
        let unpublished = prefix + "998-1-0-\(UUID().uuidString.lowercased())"
        let reused = prefix + "101-7-0-\(UUID().uuidString.lowercased())"
        let live = prefix + "101-1-0-\(UUID().uuidString.lowercased())"
        try writePrivate(archive.bytes.prefix(5), to: archive.directory.appendingPathComponent(partial))
        try writePrivate(archive.bytes, to: archive.directory.appendingPathComponent(unpublished))
        try writePrivate(Data(), to: archive.directory.appendingPathComponent(reused))
        try writePrivate(Data(), to: archive.directory.appendingPathComponent(live))
        try moveLock(root, from: 101, to: 201)

        // The prompt hook hands off, then its retirement pass sweeps exited writers' leftovers.
        #expect(recorder(root, process: restarted()).bind(payload: payload, environment: environment) == .recorded)

        #expect(try binding(root).ownerPID == 201)
        #expect(try Data(contentsOf: archive.file) == archive.bytes)
        #expect(try archivedOwners(root) == [101])
        #expect(try pendingArchives(archive.directory) == [live], "Only a live writer's attempt survives")
    }

    @Test func failedPublishLeavesNoPendingOrPartialArchive() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try marker(root)
        #expect(recorder(root).bind(payload: payload, environment: environment) == .recorded)
        let record = try CMUXMaestroPreview.CopilotIdentityJSON.decode(Data(contentsOf: root.appendingPathComponent(
            "integration/bindings/\(session.uuidString.lowercased()).json")))
        let archive = try parentArchive(root)
        let fd = open(archive.directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(fd >= 0)
        defer { close(fd) }

        #expect(throws: (any Error).self) {
            try CopilotBindingRetirement.preserve(record, archive: fd, publish: { _, _, _ in
                errno = EIO
                return -1
            })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: archive.directory.path).isEmpty)
        try CopilotBindingRetirement.preserve(record, archive: fd)
        #expect(try Data(contentsOf: archive.file) == archive.bytes)
        #expect(try pendingArchives(archive.directory).isEmpty)
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
