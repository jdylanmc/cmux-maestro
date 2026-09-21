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

    var message: String {
        switch self {
        case .installed:
            "Copilot reported installation success. New Maestro-launched sessions get messaging automatically. Existing sessions are not adopted or restarted; restart or resume manually only to load skills and identity hooks."
        case .uninstalled:
            "Copilot reported uninstallation success. New messaging launches are disabled. Existing sessions and their in-memory adapters remain untouched; close them normally."
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
        }
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

    static func files(helper: URL) throws -> [String: Data] {
        guard helper.isFileURL, helper.path.hasPrefix("/"), !helper.path.contains("\0") else {
            throw HookFiles.Failure.unavailable
        }
        let hook: [String: Any] = ["type": "command", "bash": command(helper: helper), "timeoutSec": 2]
        let hooks = Dictionary(uniqueKeysWithValues: events.map { ($0, [hook]) })
        return [
            "plugin.json": try JSONSerialization.data(withJSONObject: [
                "name": name, "version": "1.1.0",
                "description": "CMUX Maestro session identity, lifecycle and peer messaging skills",
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
        let messagingSkillData = try boundedResource(
            resources.appendingPathComponent("maestro/SKILL.md"), maximum: 65_536
        )
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
        for (name, data) in try CopilotPluginManifest.files(helper: helper) {
            try HookFiles.atomicWrite(data, name: name, directory: directory)
        }
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
        let messagingSkill = try HookFiles.privateDirectory(
            plugin.appendingPathComponent("skills/maestro", isDirectory: true)
        )
        defer { close(messagingSkill) }
        try HookFiles.atomicWrite(messagingSkillData, name: "SKILL.md", directory: messagingSkill)

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
    func run(executable: URL, arguments: [String], path: String) async -> CopilotProcessResult
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

    func run(executable: URL, arguments: [String], path: String) async -> CopilotProcessResult {
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
                        result = execute(executable: executable, arguments: arguments,
                                         environment: environment, cancellation: cancellation)
                    }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func execute(executable: URL, arguments: [String], environment: [String: String],
                         cancellation: CopilotSetupCancellation) -> CopilotProcessResult {
        guard !cancellation.isCancelled else { return .cancelled }
        guard timeout.isFinite, timeout > 0, terminationGrace.isFinite, terminationGrace >= 0
        else { return .unavailable }
        guard let pid = Self.spawn(executable: executable, arguments: arguments,
                                   environment: environment, cancellation: cancellation) else {
            return cancellation.isCancelled ? .cancelled : .unavailable
        }
        let deadline = deadlineNow().advanced(by: .seconds(timeout))
        var outcome: CopilotProcessResult
        while true {
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
                              cancellation: CopilotSetupCancellation) -> Int32? {
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
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0
        else { return nil }
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

nonisolated struct CopilotSetup {
    let files: any CopilotSetupFileSystem
    let runner: any CopilotSetupProcessRunner
    private let allowsChanges: Bool

    init(files: any CopilotSetupFileSystem = LocalCopilotSetupFiles(),
         runner: any CopilotSetupProcessRunner = LocalCopilotSetupRunner(),
         bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        self.files = files
        self.runner = runner
        allowsChanges = CopilotSetupAccess.allowsChanges(bundleIdentifier: bundleIdentifier)
    }

    // Only the explicit consent buttons call this; constructing the app performs
    // no discovery, writes, CLI invocations or provider observation.
    func perform(_ action: CopilotSetupAction, selected: URL?, path: String,
                 root: URL, helper: URL, controller: URL, skill: URL) async -> CopilotSetupResult {
        guard allowsChanges else { return .validationOnly }
        do {
            let executable = try files.executable(selected: selected, path: path)
            let arguments: [String]
            switch action {
            case .install:
                let plugin = try files.preparePlugin(
                    root: root, helper: helper, controller: controller, skill: skill
                )
                arguments = ["--no-auto-update", "plugin", "install", plugin.path]
            case .uninstall:
                arguments = ["--no-auto-update", "plugin", "uninstall", CopilotPluginManifest.name]
            }
            switch await runner.run(executable: executable, arguments: arguments, path: path) {
            case .exited(0):
                if action == .uninstall { try files.removeMessaging(root: root) }
                return action == .install ? .installed : .uninstalled
            case .exited(let status): return .failed(status)
            case .unavailable: return .unavailable
            case .timedOut: return .timedOut
            case .cancelled: return .cancelled
            }
        } catch { return .unavailable }
    }
}
