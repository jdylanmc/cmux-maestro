import Darwin
import Foundation

// A dedicated thread and condition keep diagnostics independent of the executor
// under investigation. All mutable observation state is protected by the condition.
nonisolated final class MetadataProcessTestWatchdog: @unchecked Sendable {
    static let test = "CMUXMaestroPreviewTests/CopilotObserverRegistrationTests/metadataProcessUsesSupervisorForSuccessTimeoutAndMalformedOutput()"
    private let condition = NSCondition()
    private let directory: URL
    private let testIdentity: String
    private let limit: Duration
    private let samplerExecutable: URL
    private var phase = "fixture"
    private var deadline: ContinuousClock.Instant
    private var samples = 0
    private var lastSample: ContinuousClock.Instant?
    private var finished = false
    private var samplerPID: Int32?

    init(directory: URL, testIdentity: String = MetadataProcessTestWatchdog.test,
         limit: Duration = .seconds(30),
         samplerExecutable: URL = URL(fileURLWithPath: "/usr/bin/sample")) throws {
        self.directory = directory
        self.testIdentity = testIdentity
        self.limit = limit
        self.samplerExecutable = samplerExecutable
        deadline = ContinuousClock.now.advanced(by: limit)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Thread.detachNewThread { self.observe() }
    }

    func begin(_ phase: String) {
        condition.lock()
        defer { condition.unlock() }
        self.phase = phase
        samples = 0
        lastSample = nil
        deadline = ContinuousClock.now.advanced(by: limit)
        condition.signal()
    }

    func now() -> ContinuousClock.Instant {
        let instant = ContinuousClock.now
        condition.lock()
        samples += 1
        lastSample = instant
        condition.unlock()
        return instant
    }

    func finish() {
        condition.lock()
        finished = true
        condition.signal()
        condition.unlock()
    }

    private func observe() {
        condition.lock()
        while !finished, ContinuousClock.now < deadline {
            // Date only schedules a wakeup; the failure boundary is monotonic.
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1))
        }
        guard !finished else { condition.unlock(); return }
        let report = Report(
            test: testIdentity, pid: getpid(), phase: phase, deadlineSamples: samples,
            lastSampleAge: lastSample.map { String(describing: $0.duration(to: .now)) },
            sampleStatus: "pending", sample: nil)
        condition.unlock()
        diagnose(report)
    }

    private struct Report: Encodable {
        let test: String
        let pid: Int32
        let phase: String
        let deadlineSamples: Int
        let lastSampleAge: String?
        var sampleStatus: String
        var sample: String?
        var samplerPID: Int32?
        var samplerReaped: Bool?
        var samplerSignalError: Int32?
    }

    private func save(_ report: Report) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: directory.appendingPathComponent("stall.json"), options: .atomic)
        } catch {
            Self.log("Cannot preserve metadata stall report: \(error)")
        }
    }

    private func diagnose(_ initial: Report) -> Never {
        // Sampling must not turn a bounded diagnostic into another indefinite wait.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 5)
            self.killSampler()
            _exit(124)
        }
        var report = initial
        save(report)
        Self.log("Metadata test stalled: phase=\(report.phase) deadlineSamples=\(report.deadlineSamples) report=\(directory.path)/stall.json")
        let sampleURL = directory.appendingPathComponent("sample.txt")
        do {
            report.samplerPID = try spawnSampler(output: sampleURL)
            report.samplerReaped = false
            save(report)
            if let status = try waitForSampler(until: .now.advanced(by: .seconds(3))) {
                report.sampleStatus = Self.exitDescription(status)
                report.samplerReaped = true
            } else {
                let signalError = killSampler()
                if signalError != 0 { report.samplerSignalError = signalError }
                let status = try waitForSampler(until: .now.advanced(by: .seconds(1)))
                report.samplerReaped = status != nil
                report.sampleStatus = "timed-out/" + (status.map(Self.exitDescription) ?? "reap-unconfirmed")
            }
            report.sample = try String(contentsOf: sampleURL, encoding: .utf8)
        } catch {
            report.sampleStatus = "failed: \(error)"
            Self.log("Metadata stall sampling failed: \(error)")
        }
        save(report)
        // Never resume a stalled assertion or reinterpret cancellation as a pass.
        _exit(124)
    }

    private enum SamplerFailure: Error {
        case system(Int32)
    }

    private static func check(_ result: Int32) throws {
        guard result == 0 else { throw SamplerFailure.system(result) }
    }

    private func spawnSampler(output: URL) throws -> Int32 {
        var disposition = sigaction()
        guard sigaction(SIGCHLD, nil, &disposition) == 0,
              disposition.__sigaction_u.__sa_handler == nil,
              disposition.sa_flags & SA_NOCLDWAIT == 0 else { throw SamplerFailure.system(ECHILD) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try Self.check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try Self.check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try Self.check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try Self.check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try Self.check(posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0))
        try Self.check(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO,
            directory.appendingPathComponent("sampler-stderr.txt").path, O_WRONLY | O_CREAT | O_EXCL, 0o600))
        let arguments = [samplerExecutable.path, String(getpid()), "1", "1", "-file", output.path]
        let strings = arguments.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        guard strings.allSatisfy({ $0 != nil }) else { throw SamplerFailure.system(ENOMEM) }
        var pid: Int32 = 0
        let result = (strings + [nil]).withUnsafeBufferPointer { argv in
            // The sampler needs no inherited credentials or environment.
            [UnsafeMutablePointer<CChar>?](arrayLiteral: nil).withUnsafeBufferPointer { envp in
                posix_spawn(&pid, samplerExecutable.path, &actions, &attributes, argv.baseAddress, envp.baseAddress)
            }
        }
        guard result == 0 else { throw SamplerFailure.system(result) }
        condition.lock()
        samplerPID = pid
        condition.unlock()
        return pid
    }

    private func waitForSampler(until deadline: ContinuousClock.Instant) throws -> Int32? {
        while ContinuousClock.now < deadline {
            condition.lock()
            guard let pid = samplerPID else {
                condition.unlock()
                throw SamplerFailure.system(ECHILD)
            }
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            let failure = errno
            if result > 0 || (result < 0 && failure == ECHILD) { samplerPID = nil }
            condition.unlock()
            if result > 0 { return status }
            if result < 0 && failure != EINTR { throw SamplerFailure.system(failure) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }

    @discardableResult
    private func killSampler() -> Int32 {
        condition.lock()
        defer { condition.unlock() }
        // Only this class reaps this POSIX child. The lock keeps its unreaped
        // PID anchor valid across the hard-bound thread's signal and normal reap.
        if let samplerPID, kill(samplerPID, SIGKILL) != 0 { return errno }
        return 0
    }

    private static func exitDescription(_ status: Int32) -> String {
        status & 0x7f == 0 ? "exit-\(status >> 8)" : "signal-\(status & 0x7f)"
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
