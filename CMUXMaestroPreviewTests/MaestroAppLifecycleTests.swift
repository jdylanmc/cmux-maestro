import AppKit
import Darwin
import Foundation
import Testing
@testable import CMUXMaestroPreview

@MainActor
enum MaestroProcessProofFixture {
    static func run() -> Int32 {
        do {
            guard case .found(let process) = SystemMaestroApplicationWorkspace.process(getpid()) else { return 2 }
            FileHandle.standardOutput.write(try JSONEncoder().encode(process) + Data("\n".utf8))
            guard try FileHandle.standardInput.read(upToCount: 1) == Data("G".utf8) else { return 3 }
            return 0
        } catch { return 1 }
    }
}

@MainActor
private final class LifecycleApplication: MaestroApplicationHandle {
    var processIdentifier: pid_t = 41001
    var bundleIdentifier: String? = CopilotSetupAccess.productionBundleIdentifier
    var bundleURL: URL? = URL(fileURLWithPath: "/fixture/Applications/Maestro.app")
    var executableURL: URL? = URL(fileURLWithPath: "/fixture/Applications/Maestro.app/Contents/MacOS/Maestro")
    var isTerminated = false
    var isFinishedLaunching = true
    var launchDate: Date? = Date(timeIntervalSince1970: 100)
    var isHidden = false
    var allowsQuit = true
    var quitCalls = 0
    func terminate() -> Bool { quitCalls += 1; return allowsQuit }
}

@MainActor
private final class LifecycleWorkspace: MaestroApplicationWorkspace {
    var handles: [LifecycleApplication] = []
    var processes: [Int32: MaestroAppProcessResult] = [:]
    var opened: [(URL, Bool)] = []
    var launchResult: LifecycleApplication?
    var processOverride: ((Int32) -> MaestroAppProcessResult)?

    func applications() -> [any MaestroApplicationHandle] { handles }
    func application(pid: Int32) -> (any MaestroApplicationHandle)? { handles.first { $0.processIdentifier == pid } }
    func process(_ pid: Int32) -> MaestroAppProcessResult { processOverride?(pid) ?? processes[pid] ?? .dead }
    func open(_ application: URL, hidden: Bool) async throws -> any MaestroApplicationHandle {
        opened.append((application, hidden))
        guard let launchResult else { throw CopilotFileError.io }
        handles.append(launchResult)
        return launchResult
    }
}

@MainActor
struct MaestroAppLifecycleTests {
    private let app = URL(fileURLWithPath: "/fixture/Applications/Maestro.app")
    private let executable = URL(fileURLWithPath: "/fixture/Applications/Maestro.app/Contents/MacOS/Maestro")
    private let hash = String(repeating: "a", count: 40)

    private func identity(pid: Int32 = 41001, start: UInt64 = 100) -> MaestroAppProcess {
        MaestroAppProcess(pid: pid, uid: getuid(), startSeconds: start, startMicroseconds: 123,
                          codeHash: hash, executable: executable.path)
    }

    private func lifecycle(_ workspace: LifecycleWorkspace) -> MaestroAppLifecycle {
        MaestroAppLifecycle(application: app, executable: executable, hashes: [hash], workspace: workspace)
    }

    @Test func exactOwnedAppReceivesOnlyNormalQuitAndAcceptanceIsNotExitProof() throws {
        let workspace = LifecycleWorkspace()
        let handle = LifecycleApplication()
        handle.isHidden = true
        workspace.handles = [handle]
        workspace.processes[41001] = .found(identity())
        let before = try #require(try lifecycle(workspace).inspect())
        #expect(before.hidden)
        #expect(try lifecycle(workspace).quit(before) == before)
        #expect(handle.quitCalls == 1)
        #expect(!handle.isTerminated, "A sent normal quit request does not prove process release")
        #expect(workspace.opened.isEmpty)
    }

    @Test func gracefulQuitRefusalIsAnErrorWithoutForceOrLaunchFallback() throws {
        let workspace = LifecycleWorkspace()
        let handle = LifecycleApplication()
        handle.allowsQuit = false
        workspace.handles = [handle]
        workspace.processes[41001] = .found(identity())
        let before = try #require(try lifecycle(workspace).inspect())
        #expect(throws: CopilotRegistrationConflict.self) { try lifecycle(workspace).quit(before) }
        #expect(handle.quitCalls == 1)
        #expect(workspace.opened.isEmpty)
    }

    @Test(arguments: ["bundle", "path", "helper", "extension", "generation", "hash", "owner", "kernel-path", "unavailable"])
    func mismatchedOrUnavailableOwnershipNeverQuits(kind: String) throws {
        let workspace = LifecycleWorkspace()
        let handle = LifecycleApplication()
        workspace.handles = [handle]
        let before = MaestroAppRunningState(process: identity(), hidden: false)
        workspace.processes[41001] = .found(identity())
        switch kind {
        case "bundle": handle.bundleIdentifier = "com.example.Other"
        case "path": handle.bundleURL = URL(fileURLWithPath: "/another/Maestro.app")
        case "helper": handle.executableURL = app.appendingPathComponent("Contents/Helpers/CMUXMaestroCopilotHook")
        case "extension": handle.bundleURL = app.appendingPathComponent("Contents/Extensions/Sidebar.appex")
        case "generation": workspace.processes[41001] = .found(identity(start: 200))
        case "hash": workspace.processes[41001] = .found(.init(pid: 41001, uid: getuid(), startSeconds: 100,
                                                              startMicroseconds: 123, codeHash: String(repeating: "b", count: 40),
                                                              executable: executable.path))
        case "owner": workspace.processes[41001] = .found(.init(pid: 41001, uid: getuid() + 1, startSeconds: 100,
                                                               startMicroseconds: 123, codeHash: hash, executable: executable.path))
        case "kernel-path": workspace.processes[41001] = .found(.init(pid: 41001, uid: getuid(), startSeconds: 100,
            startMicroseconds: 123, codeHash: hash, executable: "/another/executable"))
        default: workspace.processes[41001] = .unavailable
        }
        #expect(throws: CopilotRegistrationConflict.self) { try lifecycle(workspace).quit(before) }
        #expect(handle.quitCalls == 0)
        #expect(workspace.opened.isEmpty)
    }

    @Test func unrelatedCopiesAndCLIProcessesAreNotContainingAppCandidates() throws {
        let workspace = LifecycleWorkspace()
        let other = LifecycleApplication()
        other.bundleURL = URL(fileURLWithPath: "/another/Maestro.app")
        let cli = LifecycleApplication()
        cli.launchDate = nil
        cli.isFinishedLaunching = false
        workspace.handles = [other, cli]
        #expect(try lifecycle(workspace).inspect() == nil)
        #expect(other.quitCalls == 0 && cli.quitCalls == 0)
    }

    @Test func processIdentityMustRemainStableDuringObservation() throws {
        let workspace = LifecycleWorkspace()
        workspace.handles = [LifecycleApplication()]
        var count = 0
        workspace.processOverride = { pid in
            count += 1
            return .found(identity(pid: pid, start: count == 1 ? 100 : 101))
        }
        #expect(throws: CopilotRegistrationConflict.self) { try lifecycle(workspace).inspect() }
        #expect(workspace.handles[0].quitCalls == 0)
    }

    @Test(arguments: [false, true])
    func restorationUsesExactURLAndNonActivatingConfiguration(hidden: Bool) async throws {
        let workspace = LifecycleWorkspace()
        let restored = LifecycleApplication()
        restored.isHidden = hidden
        restored.processIdentifier = 41002
        workspace.launchResult = restored
        workspace.processes[41002] = .found(identity(pid: 41002, start: 200))
        let result = try await lifecycle(workspace).launch(hidden: hidden)
        #expect(result.process.pid == 41002)
        #expect(workspace.opened.count == 1)
        #expect(workspace.opened[0].0 == app && workspace.opened[0].1 == hidden)
        _ = try await lifecycle(workspace).launch(hidden: hidden)
        #expect(workspace.opened.count == 1, "An already-running exact app must not be reopened or activated")
        let options = SystemMaestroApplicationWorkspace.configuration(hidden: hidden)
        #expect(!options.activates && options.hides == hidden && !options.hidesOthers)
        #expect(!options.promptsUserIfNeeded && !options.addsToRecentItems)
        #expect(!options.createsNewApplicationInstance && !options.allowsRunningApplicationSubstitution)
    }

    @Test func launchFailureIsReportedWithoutFallback() async {
        let workspace = LifecycleWorkspace()
        do {
            _ = try await lifecycle(workspace).launch(hidden: true)
            Issue.record("Expected launch refusal")
        } catch {}
        #expect(workspace.opened.count == 1)
    }

    @Test func quarantineDoesNotTriggerSystemPromptOrPermissionBypass() throws {
        try SystemMaestroApplicationWorkspace.requireNonInteractiveLaunch(quarantine: nil)
        try SystemMaestroApplicationWorkspace.requireNonInteractiveLaunch(quarantine: NSNull())
        #expect(throws: CopilotRegistrationConflict.self) {
            try SystemMaestroApplicationWorkspace.requireNonInteractiveLaunch(quarantine: ["LSQuarantineAgentName": "fixture"])
        }
    }

    @Test func ambiguousInstancesAndReusedCallerIdentityAreNotTerminated() throws {
        let workspace = LifecycleWorkspace()
        let first = LifecycleApplication()
        let second = LifecycleApplication()
        second.processIdentifier = 41002
        workspace.handles = [first, second]
        #expect(throws: CopilotRegistrationConflict.self) { try lifecycle(workspace).inspect() }
        let selfTarget = MaestroAppLifecycle(application: app, executable: executable, hashes: [hash],
            workspace: workspace, ownPID: 41001)
        #expect(throws: CopilotRegistrationConflict.self) {
            try selfTarget.quit(.init(process: identity(), hidden: false))
        }
        #expect(first.quitCalls == 0 && second.quitCalls == 0)
    }

    @Test func lifecycleParserRejectsArbitraryActionsAndMissingIdentity() throws {
        let prefix = [MaestroAppLifecycleCommandLine.flag, "inspect", "--application", app.path,
                      "--code-hashes", "[\"\(hash)\"]"]
        #expect(try MaestroAppLifecycleCommandLine.request(prefix)?.action == "inspect")
        for arguments in [
            [MaestroAppLifecycleCommandLine.flag, "force-quit"] + Array(prefix.dropFirst(2)),
            [MaestroAppLifecycleCommandLine.flag, "quit"] + Array(prefix.dropFirst(2)),
            Array(prefix.prefix(5)) + ["[]"],
            Array(prefix.prefix(5)) + ["[\"not-a-code-hash\"]"],
            prefix + ["--hidden", "false"],
        ] {
            #expect(throws: CopilotSetupCommandLine.Failure.self) { try MaestroAppLifecycleCommandLine.request(arguments) }
        }
    }

    @Test func publicProcessProofRecognizesOnlyTheOwnedNonUIRunner() {
        guard case .found(let process) = SystemMaestroApplicationWorkspace.process(getpid()) else {
            Issue.record("Public code identity must be available for this signed test executable")
            return
        }
        #expect(process.pid == getpid() && process.uid == getuid())
        #expect(process.startSeconds > 0 && process.startMicroseconds < 1_000_000)
        #expect(process.codeHash.count == 40)
    }
}
