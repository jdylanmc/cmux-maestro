import Darwin
import Dispatch
import Foundation

nonisolated enum CopilotSetupAction: Equatable, Sendable {
    case install, uninstall
}

nonisolated enum CopilotSetupAccess {
    static let productionBundleIdentifier = "com.jdylanmc.CMUXMaestroPreview"

    static func allowsChanges(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == productionBundleIdentifier
    }

    static var currentAppAllowsChanges: Bool {
        allowsChanges(bundleIdentifier: Bundle.main.bundleIdentifier)
    }
}

nonisolated enum CopilotSetupResult: Equatable, Sendable {
    case installed, uninstalled, unavailable, failed(Int32), timedOut, cancelled, validationOnly
    case installedDisabled
    case conflict(String)
    case incomplete(IntegrationSetupPhase, String)

    var message: String {
        switch self {
        case .installed:
            "The hookless native plugin and dedicated observer registration are verified on disk. Loaded hooks, observation and messaging readiness are not implied. Maestro did not restart or reload existing sessions."
        case .installedDisabled:
            "The native plugin is installed and observer registration remains disabled on disk. Disable choices were preserved; no effective provider-wide suppression is claimed."
        case .uninstalled:
            "Owned observer registration and the native plugin are removed, and new messaging entry points are disabled. Existing sessions may retain cached hooks and adapters; close them normally."
        case .unavailable:
            "Setup could not access the selected executable, bundled helper, or integration directory. Choose a trusted Copilot CLI executable and retry."
        case .failed(let status):
            "Copilot setup failed (exit \(status)). Check your CLI installation and retry. CLI output is not displayed."
        case .timedOut:
            "Copilot setup timed out and its installer processes were stopped. Check your CLI installation before retrying."
        case .cancelled:
            "Copilot setup was cancelled and its installer processes were stopped."
        case .validationOnly:
            "This validation copy cannot install or uninstall Copilot integration. Use the installed CMUX Maestro Preview app."
        case .conflict(let reason):
            "Setup refused before changing observer registration: \(reason)"
        case .incomplete(let phase, let reason):
            "Setup is incomplete after \(phase.label). \(reason) Review registration status before retrying. Maestro did not restart or reload sessions."
        }
    }
}

nonisolated enum CopilotSetupCommandLine {
    static let installFlag = "--install-copilot-integration"
    static let usage = "Usage: CMUX Maestro Preview --install-copilot-integration --copilot-executable /absolute/path/to/copilot"

    enum Failure: Error { case usage }

    static func executable(arguments: [String]) throws -> URL? {
        guard arguments.contains(installFlag) else { return nil }
        guard arguments.count == 3, arguments[0] == installFlag,
              arguments[1] == "--copilot-executable", arguments[2].hasPrefix("/"),
              !arguments[2].unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw Failure.usage }
        return URL(fileURLWithPath: arguments[2])
    }

    static func install(selected: URL) async -> CopilotSetupResult {
        guard CopilotSetupAccess.currentAppAllowsChanges else { return .validationOnly }
        guard let root = try? CopilotPaths.integrationRoot(),
              let controller = Bundle.main.url(forResource: "cmux-maestro-orchestrator", withExtension: "py"),
              let skill = Bundle.main.url(forResource: "SKILL", withExtension: "md") else {
            return .unavailable
        }
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/CMUXMaestroCopilotHook")
        return await CopilotSetup().perform(
            .install, selected: selected,
            path: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            root: root, helper: helper, controller: controller, skill: skill
        )
    }
}

nonisolated enum CopilotPluginManifest {
    static let name = "cmux-maestro-native"
    static let events = ["sessionStart", "userPromptSubmitted", "postToolUse"]

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func command(helper: URL) -> String {
        // Keep a shell parent so helper crashes/signals/missing binaries cannot
        // become hook control output or a negative exit status.
        "{ \(shellQuoted(helper.path)) >/dev/null 2>&1 || :; } >/dev/null 2>&1; exit 0"
    }

    static func observerHooks(helper: URL) -> [String: [[String: Any]]] {
        let hook: [String: Any] = ["type": "command", "bash": command(helper: helper), "timeoutSec": 2]
        return Dictionary(uniqueKeysWithValues: events.map { ($0, [hook]) })
    }

    static func files(helper: URL, includeObserverHooks: Bool = false) throws -> [String: Data] {
        guard helper.isFileURL, helper.path.hasPrefix("/"), !helper.path.contains("\0") else {
            throw HookFiles.Failure.unavailable
        }
        let hooks = includeObserverHooks ? observerHooks(helper: helper) : [:]
        return [
            "plugin.json": try JSONSerialization.data(withJSONObject: [
                "name": name, "version": "1.1.0",
                "description": "CMUX Maestro session identity, lifecycle and icon skills",
                "hooks": "hooks.json",
            ], options: [.prettyPrinted, .sortedKeys]),
            "hooks.json": try JSONSerialization.data(withJSONObject: [
                "version": 1, "hooks": hooks,
            ], options: [.prettyPrinted, .sortedKeys]),
        ]
    }
}

nonisolated protocol CopilotSetupFileSystem: Sendable {
    func executable(selected: URL?, path: String) throws -> URL
    func preparePlugin(root: URL, helper: URL, controller: URL, skill: URL) throws -> URL
    func removeMessaging(root: URL) throws
}

nonisolated struct LocalCopilotSetupFiles: CopilotSetupFileSystem {
    var nativeExtensions = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".copilot/extensions", isDirectory: true)
    var messagingRoutes: URL?

    func executable(selected: URL?, path: String) throws -> URL {
        let candidates: [URL]
        if let selected {
            guard selected.isFileURL, selected.path.hasPrefix("/") else { throw HookFiles.Failure.unavailable }
            candidates = [selected]
        } else {
            candidates = path.split(separator: ":").compactMap { component in
                guard component.hasPrefix("/") else { return nil }
                return URL(fileURLWithPath: String(component), isDirectory: true).appendingPathComponent("copilot")
            }
        }
        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath()
            var info = stat()
            if stat(resolved.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
               info.st_uid == getuid() || info.st_uid == 0,
               info.st_mode & 0o022 == 0, access(resolved.path, X_OK) == 0 {
                return candidate
            }
        }
        throw HookFiles.Failure.unavailable
    }

    func preparePlugin(root: URL, helper: URL, controller: URL, skill: URL) throws -> URL {
        let iconSkill = skill.deletingLastPathComponent().appendingPathComponent("maestro-icon/SKILL.md")
        let resources = skill.deletingLastPathComponent()
        let adapterData = try boundedResource(resources.appendingPathComponent("adapter.mjs"), maximum: 65_536)
        let loaderData = try boundedResource(resources.appendingPathComponent("extension.mjs"), maximum: 8192)
        guard FileManager.default.isExecutableFile(atPath: helper.path),
              FileManager.default.isReadableFile(atPath: controller.path),
              FileManager.default.isReadableFile(atPath: skill.path),
              FileManager.default.isReadableFile(atPath: iconSkill.path) else {
            throw HookFiles.Failure.unavailable
        }
        let iconSkillData = try boundedResource(iconSkill, maximum: 65_536)
        let glyphRoot = skill.deletingLastPathComponent().appendingPathComponent("NerdFonts", isDirectory: true)
        let glyphFiles: [(String, Int)] = [
            ("glyphnames.json", 2_097_152), ("presets.json", 32_768), ("manifest.json", 8_192),
            ("SymbolsNerdFont-Regular.ttf", 4_194_304), ("LICENSE", 16_384),
            ("NOTICE.md", 16_384), ("GLYPH-SOURCES.md", 32_768)
        ]
        let glyphData = try glyphFiles.map { name, limit in
            (name, try boundedResource(glyphRoot.appendingPathComponent(name), maximum: limit))
        }
        let rootFD = try HookFiles.privateDirectory(root)
        defer { close(rootFD) }
        let plugin = root.appendingPathComponent("plugin", isDirectory: true)
        let directory = try HookFiles.privateDirectory(plugin)
        defer { close(directory) }
        // Observer setup owns the conditional manifest writes and the
        // disabled-stage / official-replacement / publication transaction.
        let skills = try HookFiles.privateDirectory(plugin.appendingPathComponent("skills", isDirectory: true))
        defer { close(skills) }
        let orchestrationSkill = try HookFiles.privateDirectory(
            plugin.appendingPathComponent("skills/cmux-maestro-orchestrate", isDirectory: true)
        )
        defer { close(orchestrationSkill) }
        let skillData = try boundedResource(skill, maximum: 65_536)
        try HookFiles.atomicWrite(skillData, name: "SKILL.md", directory: orchestrationSkill)
        let iconSkillDirectory = try HookFiles.privateDirectory(
            plugin.appendingPathComponent("skills/maestro-icon", isDirectory: true)
        )
        defer { close(iconSkillDirectory) }
        try HookFiles.atomicWrite(iconSkillData, name: "SKILL.md", directory: iconSkillDirectory)
        try removeBundledMessagingSkill(at: skills)

        let orchestration = root.deletingLastPathComponent()
            .appendingPathComponent("Orchestration", isDirectory: true)
        let orchestrationRoot = try HookFiles.privateDirectory(orchestration)
        defer { close(orchestrationRoot) }
        let bin = try HookFiles.privateDirectory(orchestration.appendingPathComponent("bin", isDirectory: true))
        defer { close(bin) }
        try HookFiles.atomicWrite(
            JSONSerialization.data(withJSONObject: ["helper": helper.path], options: [.sortedKeys]),
            name: "identity-helper.json", directory: bin
        )
        let glyphDirectory = try HookFiles.privateDirectory(
            orchestration.appendingPathComponent("bin/NerdFonts", isDirectory: true)
        )
        defer { close(glyphDirectory) }
        for (name, data) in glyphData {
            try HookFiles.atomicWrite(data, name: name, directory: glyphDirectory)
        }
        try executableWrite(
            boundedResource(controller, maximum: 1_048_576),
            name: "cmux-maestro-orchestrator", directory: bin
        )
        let extensions = try HookFiles.directory(nativeExtensions, create: true)
        defer { close(extensions) }
        _ = try HookFiles.metadata(extensions, directory: true)
        let nativeRoot = nativeExtensions.appendingPathComponent("maestro", isDirectory: true)
        let nativeDirectory = try HookFiles.privateDirectory(nativeRoot)
        defer { close(nativeDirectory) }
        let routes = messagingRoutes ?? nativeRoot.appendingPathComponent("r", isDirectory: true)
        guard routes.appendingPathComponent(String(repeating: "0", count: 16) + ".sock").path.utf8.count <= 100 else {
            throw HookFiles.Failure.unavailable
        }
        let routeDirectory = try HookFiles.privateDirectory(routes)
        defer { close(routeDirectory) }
        try HookFiles.atomicWrite(adapterData, name: "adapter.mjs", directory: nativeDirectory)
        try HookFiles.atomicWrite(loaderData, name: "extension.mjs", directory: nativeDirectory)
        try HookFiles.atomicWrite(
            JSONSerialization.data(withJSONObject: [
                "version": 1, "routes": routes.path, "extension": nativeRoot.path,
            ], options: [.sortedKeys]),
            name: "messaging.json", directory: bin
        )
        return plugin
    }

    private func removeBundledMessagingSkill(at skills: Int32) throws {
        // Only the obsolete copy in this installer's plugin, never global skills.
        let directory: Int32
        do {
            directory = try CopilotFileAccess.openDirectory(at: skills, name: "maestro", owner: getuid())
        } catch CopilotFileError.missing { return }
        defer { close(directory) }
        let info = try HookFiles.metadata(directory, directory: true)
        guard info.st_mode & 0o777 == 0o700 else { throw HookFiles.Failure.unavailable }
        do {
            _ = try CopilotFileAccess.readStableRegular(
                at: directory, filename: "SKILL.md", owner: getuid(), maximum: 65_536, permissions: 0o600
            )
        } catch CopilotFileError.missing { return }
        guard unlinkat(directory, "SKILL.md", 0) == 0 else { throw HookFiles.Failure.unavailable }
    }

    func removeMessaging(root: URL) throws {
        // Remove only the installed entry point/configuration. Do not touch live
        // route bindings, sockets, cached children, or other extensions.
        let targets = [
            nativeExtensions.appendingPathComponent("maestro/extension.mjs"),
            root.deletingLastPathComponent().appendingPathComponent("Orchestration/bin/messaging.json"),
        ]
        for target in targets {
            let directory: Int32
            do {
                directory = try CopilotFileAccess.openDirectory(target.deletingLastPathComponent(), owner: getuid())
            } catch CopilotFileError.missing { continue }
            defer { close(directory) }
            if unlinkat(directory, target.lastPathComponent, 0) != 0, errno != ENOENT {
                throw HookFiles.Failure.unavailable
            }
        }
    }

    private func boundedResource(_ url: URL, maximum: Int) throws -> Data {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
            throw HookFiles.Failure.unavailable
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maximum else {
            throw HookFiles.Failure.unavailable
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == size else { throw HookFiles.Failure.unavailable }
        return data
    }

    private func executableWrite(_ data: Data, name: String, directory: Int32) throws {
        let pending = ".pending-\(UUID().uuidString)"
        let descriptor = openat(
            directory, pending, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700
        )
        guard descriptor >= 0 else { throw HookFiles.Failure.unavailable }
        defer {
            close(descriptor)
            unlinkat(directory, pending, 0)
        }
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count, fchmod(descriptor, 0o700) == 0, fsync(descriptor) == 0,
              renameat(directory, pending, directory, name) == 0 else {
            throw HookFiles.Failure.unavailable
        }
    }
}

nonisolated enum CopilotProcessResult: Equatable, Sendable {
    case exited(Int32), unavailable, timedOut, cancelled
}

nonisolated protocol CopilotSetupProcessRunner: Sendable {
    func run(executable: URL, arguments: [String], path: String, providerHome: URL?) async -> CopilotProcessResult
    func metadata(executable: URL, path: String, providerHome: URL?) async -> CopilotMetadataResult
}

private nonisolated final class CopilotSetupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        requested = true
    }
}

nonisolated enum CopilotSetupFileWork {
    private static let queue = DispatchQueue(
        label: "com.jdylanmc.CMUXMaestroPreview.copilot-setup-files",
        qos: .userInitiated, attributes: .concurrent)

    static func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let cancellation = CopilotSetupCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value: Value = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        continuation.resume(returning: try operation())
                    } catch { continuation.resume(throwing: error) }
                }
            }
            // Cancellation waits for an already-started writer to finish. A
            // returned result must never race a still-running file mutation.
            try Task.checkCancellation()
            return value
        } onCancel: {
            cancellation.cancel()
        }
    }
}

nonisolated struct LocalCopilotSetupRunner: CopilotSetupProcessRunner {
    var timeout: TimeInterval = 45
    var terminationGrace: TimeInterval = 0.25
    var deadlineNow: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }

    // POSIX waits must not occupy Swift's cooperative executor. Concurrent
    // dispatch workers also let independent invocations make progress together.
    private static let processQueue = DispatchQueue(
        label: "com.jdylanmc.CMUXMaestroPreview.copilot-setup",
        qos: .userInitiated,
        attributes: .concurrent
    )

    func run(executable: URL, arguments: [String], path: String, providerHome: URL? = nil) async -> CopilotProcessResult {
        await invoke(executable: executable, arguments: arguments, path: path, providerHome: providerHome, exchange: nil)
    }

    func metadata(executable: URL, path: String, providerHome: URL? = nil) async -> CopilotMetadataResult {
        do {
            let exchange = try CopilotMetadataExchange()
            defer { exchange.closeAll() }
            let result = await invoke(executable: executable, arguments: [
                "--no-auto-update", "--headless", "--stdio", "--disable-builtin-mcps",
                "--no-custom-instructions", "--no-remote", "--no-remote-export", "--log-level", "error",
            ], path: path, providerHome: providerHome, exchange: exchange)
            guard result == .exited(0), let snapshot = exchange.snapshot else {
                return .failed(result == .exited(0) ? .unavailable : result)
            }
            return .value(snapshot)
        } catch { return .failed(.unavailable) }
    }

    private func invoke(executable: URL, arguments: [String], path: String, providerHome: URL?,
                        exchange: CopilotMetadataExchange?) async -> CopilotProcessResult {
        guard !Task.isCancelled else { return .cancelled }
        let cancellation = CopilotSetupCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.processQueue.async {
                    let result: CopilotProcessResult
                    if cancellation.isCancelled {
                        result = .cancelled
                    } else {
                        var environment = ProcessInfo.processInfo.environment
                        environment["PATH"] = executable.deletingLastPathComponent().path + ":" + path
                        if let providerHome { environment["COPILOT_HOME"] = providerHome.path }
                        result = execute(executable: executable, arguments: arguments,
                                         environment: environment, cancellation: cancellation, exchange: exchange)
                    }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func execute(executable: URL, arguments: [String], environment: [String: String],
                         cancellation: CopilotSetupCancellation,
                         exchange: CopilotMetadataExchange?) -> CopilotProcessResult {
        guard !cancellation.isCancelled else { return .cancelled }
        guard timeout.isFinite, timeout > 0, terminationGrace.isFinite, terminationGrace >= 0
        else { return .unavailable }
        guard let pid = Self.spawn(executable: executable, arguments: arguments,
                                   environment: environment, cancellation: cancellation, exchange: exchange) else {
            return cancellation.isCancelled ? .cancelled : .unavailable
        }
        exchange?.spawned()
        let deadline = deadlineNow().advanced(by: .seconds(timeout))
        var outcome: CopilotProcessResult
        while true {
            do { try exchange?.poll() } catch {
                _ = Self.stopGroup(pid, grace: terminationGrace)
                return .unavailable
            }
            if cancellation.isCancelled {
                outcome = .cancelled
                break
            }
            switch Self.childState(pid) {
            case .exited(let status):
                if Self.groupIsQuiescent(pid) {
                    Self.reap(pid)
                    return .exited(status)
                }
            case .unavailable:
                _ = Self.stopGroup(pid, grace: terminationGrace)
                return .unavailable
            default: break
            }
            if deadlineNow() >= deadline {
                outcome = .timedOut
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // Cancellation cannot bypass cleanup: this synchronous wait stays on
        // the dispatch worker until no member can perform further writes.
        return Self.stopGroup(pid, grace: terminationGrace) ? outcome : .unavailable
    }

    private static func spawn(executable: URL, arguments: [String],
                              environment: [String: String],
                              cancellation: CopilotSetupCancellation,
                              exchange: CopilotMetadataExchange?) -> Int32? {
        // Automatic child reaping would invalidate the retained PID/group anchor.
        var disposition = sigaction()
        guard sigaction(SIGCHLD, nil, &disposition) == 0,
              disposition.__sigaction_u.__sa_handler == nil,
              disposition.sa_flags & SA_NOCLDWAIT == 0 else { return nil }
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var mask = sigset_t()
        sigemptyset(&mask)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGPIPE] { sigaddset(&defaults, signal) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK
                          | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0
        else { return nil }
        if let exchange {
            guard posix_spawn_file_actions_adddup2(&actions, exchange.input[0], STDIN_FILENO) == 0,
                  posix_spawn_file_actions_adddup2(&actions, exchange.output[1], STDOUT_FILENO) == 0
            else { return nil }
        } else {
            guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
                  posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0
            else { return nil }
        }
        let strings = [executable.path] + arguments
        let variables = environment.map { "\($0.key)=\($0.value)" }
        guard !(strings + variables).contains(where: { $0.contains("\0") }) else { return nil }
        let argv = strings.map { strdup($0) }
        let envp = variables.map { strdup($0) }
        defer {
            for pointer in argv + envp { free(pointer) }
        }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else { return nil }
        var pid: pid_t = 0
        let result = (argv + [nil]).withUnsafeBufferPointer { arguments in
            (envp + [nil]).withUnsafeBufferPointer { environment in
                guard !cancellation.isCancelled else { return ECANCELED }
                return posix_spawn(&pid, executable.path, &actions, &attributes,
                                   arguments.baseAddress, environment.baseAddress)
            }
        }
        return result == 0 ? pid : nil
    }

    private enum ChildState {
        case running, exited(Int32), unavailable
    }

    private static func childState(_ pid: Int32) -> ChildState {
        var info = siginfo_t()
        var result: Int32
        repeat {
            result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        } while result < 0 && errno == EINTR
        guard result == 0 else { return .unavailable }
        guard info.si_pid == pid else { return .running }
        return .exited(info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status)
    }

    private static func groupMembers(_ group: Int32) -> [Int32]? {
        let required = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), nil, 0)
        guard required >= 0 else { return nil }
        var members = [Int32](repeating: 0, count: Int(required) / MemoryLayout<Int32>.size + 32)
        let capacity = Int32(members.count * MemoryLayout<Int32>.size)
        let count = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), &members, capacity)
        guard count >= 0, count < capacity else { return nil }
        return members.prefix(Int(count) / MemoryLayout<Int32>.size).filter { $0 > 0 }.sorted()
    }

    private static func groupIsQuiescent(_ group: Int32) -> Bool {
        guard let members = groupMembers(group) else { return false }
        for pid in members {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
                if info.pbi_pgid == UInt32(group), info.pbi_status != 5 { return false }
            } else if errno != ESRCH {
                return false
            }
        }
        // A member may have forked immediately before exiting. Re-enumerate
        // rather than treating a disappearing PID as proof the whole group ended.
        return groupMembers(group) == members
    }

    private static func stopGroup(_ pid: Int32, grace: TimeInterval) -> Bool {
        // posix_spawn atomically gave this invocation a new group named by its
        // PID. WNOWAIT retains its leader until cleanup, preventing group-ID
        // reuse. Never signal the application's group or a reaped invocation.
        guard pid > 1, pid != getpgrp() else { return false }
        if case .unavailable = childState(pid) { return false }
        kill(-pid, SIGTERM)
        let deadline = ContinuousClock.now.advanced(by: .seconds(grace))
        while !groupIsQuiescent(pid), ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if case .unavailable = childState(pid) { return false }
        kill(-pid, SIGKILL)
        while !groupIsQuiescent(pid) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        reap(pid)
        return true
    }

    private static func reap(_ pid: Int32) {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
}

nonisolated struct CopilotSetup: Sendable {
    let files: any CopilotSetupFileSystem
    let runner: any CopilotSetupProcessRunner
    private let allowsChanges: Bool
    private let registration: CopilotObserverRegistration?

    init(files: any CopilotSetupFileSystem = LocalCopilotSetupFiles(),
         runner: any CopilotSetupProcessRunner = LocalCopilotSetupRunner(),
         bundleIdentifier: String? = Bundle.main.bundleIdentifier,
         registration: CopilotObserverRegistration? = nil) {
        self.files = files
        self.runner = runner
        allowsChanges = CopilotSetupAccess.allowsChanges(bundleIdentifier: bundleIdentifier)
        self.registration = registration
    }

    // Only the explicit consent buttons call this; constructing the app performs
    // no discovery, writes, CLI invocations or provider observation.
    func perform(_ action: CopilotSetupAction, selected: URL?, path: String,
                 root: URL, helper: URL, controller: URL, skill: URL) async -> CopilotSetupResult {
        guard allowsChanges else { return .validationOnly }
        let cancellation = CopilotSetupCancellation()
        return await withTaskCancellationHandler {
            await executeSetup(action, selected: selected, path: path, root: root,
                               helper: helper, controller: controller, skill: skill, cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func executeSetup(_ action: CopilotSetupAction, selected: URL?, path: String,
                              root: URL, helper: URL, controller: URL, skill: URL,
                              cancellation: CopilotSetupCancellation) async -> CopilotSetupResult {
        var transaction: CopilotObserverRegistration.Transaction?
        do {
            try Task.checkCancellation()
            let (registration, executable) = try await CopilotSetupFileWork.run {
                let registration = try self.registration ?? CopilotObserverRegistration(
                    home: CopilotPaths.realUserHome(), root: root, helper: helper)
                try registration.validateLocal()
                return (registration, try self.files.executable(selected: selected, path: path))
            }
            let initial: CopilotSetupMetadata
            switch await runner.metadata(executable: executable, path: path, providerHome: registration.providerHome) {
            case .value(let value): initial = value
            case .failed(let failure): return Self.processFailure(failure)
            }
            let operation = try await CopilotSetupFileWork.run {
                try registration.begin(action, metadata: initial, isCancelled: { cancellation.isCancelled })
            }
            transaction = operation
            try await CopilotSetupFileWork.run { try operation.stage() }
            switch await runner.metadata(executable: executable, path: path, providerHome: registration.providerHome) {
            case .value(let value): try await CopilotSetupFileWork.run { try operation.verifyStaging(value) }
            case .failed(let failure): return .incomplete(operation.phase, Self.processFailure(failure).message)
            }
            let arguments: [String]
            switch action {
            case .install:
                let plugin = try await CopilotSetupFileWork.run {
                    let plugin = try self.files.preparePlugin(
                        root: root, helper: helper, controller: controller, skill: skill)
                    try operation.acceptPreparedResources()
                    try operation.preparePluginManifest()
                    return plugin
                }
                arguments = ["--no-auto-update", "plugin", "install", plugin.path]
            case .uninstall:
                try await CopilotSetupFileWork.run { try operation.removeRegistration() }
                arguments = ["--no-auto-update", "plugin", "uninstall", CopilotPluginManifest.name]
            }
            try await CopilotSetupFileWork.run { try operation.beforePluginCommand() }
            if action == .install || operation.pluginWasInstalled {
                let result = await runner.run(executable: executable, arguments: arguments, path: path,
                                              providerHome: registration.providerHome)
                guard result == .exited(0) else {
                    return .incomplete(operation.phase, Self.processFailure(result).message)
                }
                try await CopilotSetupFileWork.run { try operation.pluginCommandSucceeded() }
            }
            let changed: CopilotSetupMetadata
            switch await runner.metadata(executable: executable, path: path, providerHome: registration.providerHome) {
            case .value(let value): changed = value
            case .failed(let failure): return .incomplete(operation.phase, Self.processFailure(failure).message)
            }
            if action == .uninstall {
                try await CopilotSetupFileWork.run {
                    try operation.verifyRemoval(changed)
                    try self.files.removeMessaging(root: root)
                }
                return .uninstalled
            }
            try await CopilotSetupFileWork.run {
                try operation.verifyPlugin(changed)
                try operation.publish()
            }
            switch await runner.metadata(executable: executable, path: path, providerHome: registration.providerHome) {
            case .value(let value): try await CopilotSetupFileWork.run { try operation.verifyPublished(value) }
            case .failed(let failure): return .incomplete(operation.phase, Self.processFailure(failure).message)
            }
            return operation.disabled ? .installedDisabled : .installed
        } catch {
            let reason: String
            if let conflict = error as? CopilotRegistrationConflict { reason = conflict.message }
            else if error is CancellationError { reason = CopilotSetupResult.cancelled.message }
            else { reason = "A required file is unsafe, unreadable, malformed or changed during setup. No unverified rollback was attempted." }
            if let transaction, transaction.phase != .preflight {
                return .incomplete(transaction.phase, reason)
            }
            return error is CancellationError ? .cancelled : .conflict(reason)
        }
    }

    private static func processFailure(_ result: CopilotProcessResult) -> CopilotSetupResult {
        switch result {
        case .exited(let status): status == 0 ? .unavailable : .failed(status)
        case .unavailable: .unavailable
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        }
    }
}
