import Darwin
import Foundation

private func inherited(_ name: String) -> String? {
    guard let value = getenv(name) else { return nil }
    return String(validatingCString: value)
}

private func boundedInput() -> Data? {
    var data = Data()
    let deadline = Date().addingTimeInterval(0.75)
    while Date() < deadline {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
        guard poll(&descriptor, 1, remaining) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        guard count >= 0 else { return nil }
        if count == 0 { return data }
        data.append(contentsOf: buffer.prefix(count))
        if data.count > 65_536 { return nil }
    }
    return nil
}

private func run() {
    let keys = ["CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_COPILOT_HOOKS_DISABLED", "MAESTRO_NATIVE_DISABLED"]
    let environment = Dictionary(uniqueKeysWithValues: keys.compactMap { key in inherited(key).map { (key, $0) } })
    guard !CopilotHookRecorder.isDisabled(environment) else { return }
    let root: URL
    let state: URL
    let pid: Int32
    let lookup: @Sendable (Int32) -> CopilotProcessLookup
    #if MAESTRO_HOOK_TESTING
    // Available only in the separately compiled synthetic smoke binary, never
    // in Debug/Release app targets. No production environment can forge proof.
    guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--fixture-root" else { return }
    let fixture = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    root = fixture.appendingPathComponent("integration")
    state = fixture.appendingPathComponent("state")
    pid = 9002
    lookup = { candidate in
        switch candidate {
        case 9002: .found(HookProcess(pid: 9002, parentPID: 9001, uid: getuid(), startSeconds: 1, startMicroseconds: 2))
        case 9001: .found(HookProcess(pid: 9001, parentPID: 1, uid: getuid(), startSeconds: 1, startMicroseconds: 1))
        default: .dead
        }
    }
    #else
    guard CommandLine.arguments.count == 1,
          let integration = try? CopilotPaths.integrationRoot(),
          let sessions = try? CopilotPaths.sessionStateRoot() else { return }
    root = integration
    state = sessions
    pid = getpid()
    lookup = { @Sendable pid in CopilotProcessProbe.read(pid) }
    #endif
    let recorder = CopilotHookRecorder(integrationRoot: root, sessionStateRoot: state,
                                       processID: pid, process: lookup)
    guard let input = boundedInput() else {
        recorder.diagnose(.invalidInput)
        return
    }
    _ = recorder.record(payload: input, environment: environment)
}

run()
exit(0)
