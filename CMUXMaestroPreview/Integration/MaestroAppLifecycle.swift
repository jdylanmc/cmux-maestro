import AppKit
import Darwin
import Foundation
import Security

nonisolated struct MaestroAppProcess: Codable, Equatable, Sendable {
    let pid: Int32
    let uid: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let codeHash: String
    let executable: String
}

nonisolated struct MaestroAppRunningState: Codable, Equatable, Sendable {
    let process: MaestroAppProcess
    let hidden: Bool
}

nonisolated enum MaestroAppProcessResult: Sendable {
    case found(MaestroAppProcess), dead, unavailable
}

@MainActor
protocol MaestroApplicationHandle: AnyObject {
    var processIdentifier: pid_t { get }
    var bundleIdentifier: String? { get }
    var bundleURL: URL? { get }
    var executableURL: URL? { get }
    var isTerminated: Bool { get }
    var isFinishedLaunching: Bool { get }
    var launchDate: Date? { get }
    var isHidden: Bool { get }
    func terminate() -> Bool
}

extension NSRunningApplication: MaestroApplicationHandle {}

@MainActor
protocol MaestroApplicationWorkspace {
    func applications() -> [any MaestroApplicationHandle]
    func application(pid: Int32) -> (any MaestroApplicationHandle)?
    func process(_ pid: Int32) -> MaestroAppProcessResult
    func open(_ application: URL, hidden: Bool) async throws -> any MaestroApplicationHandle
}

@MainActor
struct SystemMaestroApplicationWorkspace: MaestroApplicationWorkspace {
    func applications() -> [any MaestroApplicationHandle] {
        NSRunningApplication.runningApplications(withBundleIdentifier: CopilotSetupAccess.productionBundleIdentifier)
    }

    func application(pid: Int32) -> (any MaestroApplicationHandle)? {
        NSRunningApplication(processIdentifier: pid)
    }

    nonisolated static func process(_ pid: Int32) -> MaestroAppProcessResult {
        guard pid > 1 else { return .unavailable }
        func generation() -> CopilotProcessIdentity? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_ruid == getuid(),
                  info.pbi_flags & 4 == 0, info.pbi_status != UInt32(SZOMB),
                  info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000 else { return nil }
            return CopilotProcessIdentity(pid: pid, parentPID: Int32(info.pbi_ppid), uid: info.pbi_uid,
                                          startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
        }
        guard let before = generation() else {
            if case .dead = CopilotProcessProbe.read(pid) { return .dead }
            return .unavailable
        }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return .unavailable }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return .unavailable }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let information = information as? [String: Any],
              let bytes = information[kSecCodeInfoUnique as String] as? Data, bytes.count == 20 else { return .unavailable }
        let hash = bytes.map { String(format: "%02x", $0) }.joined()
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return .unavailable }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("cdhash H\"\(hash)\"" as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess,
              generation() == before else { return .unavailable }
        return .found(MaestroAppProcess(pid: pid, uid: before.uid, startSeconds: before.startSeconds,
                                       startMicroseconds: before.startMicroseconds, codeHash: hash,
                                       executable: String(cString: path)))
    }

    func process(_ pid: Int32) -> MaestroAppProcessResult { Self.process(pid) }

    static func configuration(hidden: Bool) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = hidden
        configuration.hidesOthers = false
        configuration.promptsUserIfNeeded = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        return configuration
    }

    static func requireNonInteractiveLaunch(quarantine: Any?) throws {
        guard quarantine == nil || quarantine is NSNull else {
            throw CopilotRegistrationConflict("A quarantined containing app cannot be relaunched without possible system UI. No quarantine or permission setting was changed.")
        }
    }

    func open(_ application: URL, hidden: Bool) async throws -> any MaestroApplicationHandle {
        let values = try application.resourceValues(forKeys: [.quarantinePropertiesKey])
        try Self.requireNonInteractiveLaunch(quarantine: values.allValues[.quarantinePropertiesKey])
        return try await NSWorkspace.shared.openApplication(at: application, configuration: Self.configuration(hidden: hidden))
    }
}

@MainActor
struct MaestroAppLifecycle {
    let application: URL
    let executable: URL
    let hashes: Set<String>
    let workspace: any MaestroApplicationWorkspace
    var ownPID: Int32 = getpid()

    private func matches(_ handle: any MaestroApplicationHandle) -> Bool {
        handle.processIdentifier != ownPID && !handle.isTerminated
            && handle.bundleIdentifier == CopilotSetupAccess.productionBundleIdentifier
            && handle.bundleURL?.standardizedFileURL == application.standardizedFileURL
            && handle.executableURL?.standardizedFileURL == executable.standardizedFileURL
            && (handle.launchDate != nil || handle.isFinishedLaunching)
    }

    private func state(_ handle: any MaestroApplicationHandle) throws -> MaestroAppRunningState {
        guard matches(handle), case .found(let before) = workspace.process(handle.processIdentifier),
              before.uid == getuid(), hashes.contains(before.codeHash), before.executable == executable.path,
              case .found(let after) = workspace.process(handle.processIdentifier), before == after else {
            throw CopilotRegistrationConflict("The containing application's exact process and signed-code identity could not be verified.")
        }
        return MaestroAppRunningState(process: before, hidden: handle.isHidden)
    }

    func inspect() throws -> MaestroAppRunningState? {
        let candidates = workspace.applications().filter(matches)
        guard candidates.count <= 1 else {
            throw CopilotRegistrationConflict("Multiple containing-app instances are ambiguous; no quit was requested.")
        }
        return try candidates.first.map(state)
    }

    func quit(_ expected: MaestroAppRunningState) throws -> MaestroAppRunningState? {
        guard expected.process.pid != ownPID, expected.process.uid == getuid(), hashes.contains(expected.process.codeHash) else {
            throw CopilotRegistrationConflict("The quit request does not identify the owned containing application.")
        }
        if case .dead = workspace.process(expected.process.pid) { return nil }
        guard let handle = workspace.application(pid: expected.process.pid),
              try state(handle).process == expected.process else {
            throw CopilotRegistrationConflict("The containing application changed generation; no quit was requested.")
        }
        // Keep this application object: AppKit identities survive exit and are
        // not interchangeable with a later process that reuses the numeric PID.
        guard handle.terminate() else {
            throw CopilotRegistrationConflict("The containing application refused its normal quit request. No force termination was attempted.")
        }
        return expected
    }

    func launch(hidden: Bool) async throws -> MaestroAppRunningState {
        if let running = try inspect() { return running }
        let handle = try await workspace.open(application, hidden: hidden)
        return try state(handle)
    }
}

@MainActor
enum MaestroAppLifecycleCommandLine {
    static let flag = "--coordinate-maestro-app"

    struct Request {
        let action: String
        let application: URL
        let hashes: Set<String>
        let expected: MaestroAppRunningState?
        let hidden: Bool
    }

    static func request(_ arguments: [String]) throws -> Request? {
        guard arguments.contains(flag) else { return nil }
        guard arguments.count >= 6, arguments[0] == flag, ["inspect", "quit", "launch"].contains(arguments[1]),
              arguments[2] == "--application", arguments[3].hasPrefix("/"),
              !arguments[3].split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              arguments[4] == "--code-hashes", arguments[5].utf8.count <= 8192,
              !arguments.contains(where: { $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw CopilotSetupCommandLine.Failure.usage
        }
        let hashes = try JSONDecoder().decode([String].self, from: Data(arguments[5].utf8))
        guard !hashes.isEmpty, hashes.count <= 64, hashes.allSatisfy({
            $0.utf8.count == 40 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }) else { throw CopilotSetupCommandLine.Failure.usage }
        var expected: MaestroAppRunningState?
        var hidden = false
        switch arguments[1] {
        case "inspect":
            guard arguments.count == 6 else { throw CopilotSetupCommandLine.Failure.usage }
        case "quit":
            guard arguments.count == 8, arguments[6] == "--process", arguments[7].utf8.count <= 2048 else {
                throw CopilotSetupCommandLine.Failure.usage
            }
            expected = try JSONDecoder().decode(MaestroAppRunningState.self, from: Data(arguments[7].utf8))
            guard let expected, expected.process.pid > 1, expected.process.uid == getuid(),
                  expected.process.startSeconds > 0, expected.process.startMicroseconds < 1_000_000,
                  hashes.contains(expected.process.codeHash), expected.process.executable.hasPrefix("/") else {
                throw CopilotSetupCommandLine.Failure.usage
            }
        default:
            guard arguments.count == 8, arguments[6] == "--hidden", ["true", "false"].contains(arguments[7]) else {
                throw CopilotSetupCommandLine.Failure.usage
            }
            hidden = arguments[7] == "true"
        }
        return Request(action: arguments[1], application: URL(fileURLWithPath: arguments[3]),
                       hashes: Set(hashes), expected: expected, hidden: hidden)
    }

    static func perform(_ request: Request) async -> CopilotSetupCommandLine.Completion {
        guard CopilotSetupAccess.currentAppAllowsChanges else { return CopilotSetupCommandLine.completion(.validationOnly) }
        do {
            guard getuid() != 0, geteuid() == getuid() else { throw CopilotFileError.unsafePath }
            let home = try CopilotPaths.realUserHome()
            guard request.application.deletingLastPathComponent() == home.appendingPathComponent("Applications"),
                  request.application.pathExtension == "app",
                  let bundle = Bundle(url: request.application),
                  bundle.bundleIdentifier == CopilotSetupAccess.productionBundleIdentifier,
                  let name = bundle.infoDictionary?["CFBundleExecutable"] as? String,
                  !name.isEmpty, !name.contains("/"), name != ".", name != "..",
                  let executable = bundle.executableURL,
                  executable.standardizedFileURL == request.application.appendingPathComponent("Contents/MacOS/\(name)").standardizedFileURL
            else { throw CopilotFileError.unsafePath }
            let lifecycle = MaestroAppLifecycle(application: request.application, executable: executable,
                hashes: request.hashes, workspace: SystemMaestroApplicationWorkspace())
            let result: MaestroAppRunningState?
            switch request.action {
            case "inspect": result = try lifecycle.inspect()
            case "quit":
                guard let expected = request.expected else { throw CopilotFileError.io }
                result = try lifecycle.quit(expected)
            default: result = try await lifecycle.launch(hidden: request.hidden)
            }
            let object: Any = try result.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()
            let data = try JSONSerialization.data(withJSONObject: [
                "schema": 1, "action": request.action, "application": request.application.path, "process": object,
            ], options: [.sortedKeys])
            return .init(exitCode: 0, useStandardOutput: true, text: String(decoding: data, as: UTF8.self) + "\n")
        } catch {
            let reason = (error as? CopilotRegistrationConflict)?.message
                ?? "Containing-app lifecycle could not be verified; no force termination or activation fallback was attempted."
            return .init(exitCode: 1, useStandardOutput: false, text: reason + "\n")
        }
    }
}
