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
    private var metadataPID: Int32?
    private var metadataReadiness: ProcessObservation?
    private var runnerMetadataReturned = false
    private var outerTaskValueReceived = false

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

    func metadataPIDReady(_ pid: Int32) {
        condition.lock()
        metadataPID = pid
        condition.unlock()
        // The observer remains armed while the test thread queries the OS.
        let observation = Self.observeProcess(pid)
        condition.lock()
        metadataReadiness = observation
        condition.unlock()
    }

    func metadataCallReturned() {
        condition.lock()
        runnerMetadataReturned = true
        condition.unlock()
    }

    func taskValueReceived() {
        condition.lock()
        outerTaskValueReceived = true
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
            sampleStatus: "pending", sample: nil,
            metadataPID: metadataPID, metadataReadiness: metadataReadiness,
            runnerMetadataReturned: runnerMetadataReturned, outerTaskValueReceived: outerTaskValueReceived)
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
        var sampleReadError: String?
        var samplerPID: Int32?
        var samplerReaped: Bool?
        var samplerSignalError: Int32?
        var metadataPID: Int32?
        var metadataReadiness: ProcessObservation?
        var metadataAtStall: ProcessObservation?
        var runnerMetadataReturned: Bool
        var outerTaskValueReceived: Bool
    }

    struct ProcessRecord: Encodable, Sendable {
        let pid: UInt32
        let parent: UInt32
        let group: UInt32
        var startSeconds: UInt64
        let startMicroseconds: UInt64
        let status: UInt32

        func sameIdentity(as other: Self) -> Bool {
            pid == other.pid && group == other.group && startSeconds == other.startSeconds
                && startMicroseconds == other.startMicroseconds
        }
    }

    struct ProcessObservation: Encodable, Sendable {
        var state: String
        var queryBytes: Int32?
        var queryError: Int32?
        var process: ProcessRecord?
        var groupState: String?
        var groupBytes: Int32?
        var members: [ProcessRecord]?
        var childWait: ChildWaitObservation?
    }

    struct ChildWaitObservation: Encodable, Sendable {
        let result: Int32
        let error: Int32
        let pid: Int32
        let code: Int32
        let status: Int32
    }

    // Sequential numeric observations only, never a quiescence verdict or a
    // signaling authority. A missing/reused anchor forbids group enumeration.
    static func observeProcess(
        _ pid: Int32, expected: ProcessRecord? = nil, memberLimit: Int = 64
    ) -> ProcessObservation {
        guard pid > 1, pid != getpid(), pid != getpgrp() else {
            return ProcessObservation(state: "invalid-owned-pid")
        }
        guard (1...64).contains(memberLimit) else {
            return ProcessObservation(state: "invalid-member-limit")
        }
        var observation = readProcess(pid)
        guard let anchor = observation.process else {
            if let expected, expected.pid == UInt32(pid), expected.group == UInt32(pid),
               expected.parent == UInt32(getpid()) {
                // Darwin may hide an unreaped zombie from proc_pidinfo. This
                // non-consuming child query adds evidence, not start-identity
                // validation: the overall state stays unknown; no group read.
                var info = siginfo_t()
                errno = 0
                let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                observation.childWait = ChildWaitObservation(
                    result: result, error: errno, pid: info.si_pid, code: info.si_code, status: info.si_status)
            }
            return observation
        }
        if let expected {
            guard anchor.sameIdentity(as: expected) else {
                return ProcessObservation(state: "identity-changed")
            }
        } else if anchor.parent != UInt32(getpid()) || anchor.group != UInt32(pid) {
            return ProcessObservation(state: "ownership-unconfirmed")
        }
        guard anchor.group == UInt32(pid) else {
            return ProcessObservation(state: "ownership-unconfirmed")
        }
        var pids = [Int32](repeating: 0, count: memberLimit)
        let capacity = Int32(pids.count * MemoryLayout<Int32>.size)
        errno = 0
        let count = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), &pids, capacity)
        let queryError = errno
        observation.groupBytes = count
        guard count > 0, count < capacity, count % Int32(MemoryLayout<Int32>.size) == 0 else {
            observation.groupState = "unknown-enumeration"
            observation.queryError = queryError
            return observation
        }
        let members = pids.prefix(Int(count) / MemoryLayout<Int32>.size).filter { $0 > 0 }.sorted()
        guard members.contains(pid) else {
            observation.groupState = "unknown-missing-anchor"
            return observation
        }
        var records: [ProcessRecord] = []
        for member in members {
            let current = readProcess(member)
            guard let record = current.process, record.group == anchor.group else {
                observation.groupState = "unknown-member"
                observation.queryError = current.queryError
                return observation
            }
            records.append(record)
        }
        let after = readProcess(pid)
        guard let current = after.process else {
            observation.groupState = "unknown-anchor-after-enumeration"
            observation.queryError = after.queryError
            return observation
        }
        guard current.sameIdentity(as: anchor) else {
            observation.groupState = "identity-changed-after-enumeration"
            return observation
        }
        observation.groupState = "sequential-observation"
        observation.members = records
        return observation
    }

    private static func readProcess(_ pid: Int32) -> ProcessObservation {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        let queryError = errno
        guard count == size, info.pbi_pid == UInt32(pid) else {
            return ProcessObservation(state: "unknown-pid-query", queryBytes: count, queryError: queryError)
        }
        return ProcessObservation(
            state: info.pbi_status == 5 ? "exited-unreaped" : "living",
            queryBytes: count,
            process: ProcessRecord(pid: info.pbi_pid, parent: info.pbi_ppid, group: info.pbi_pgid,
                                   startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec,
                                   status: info.pbi_status))
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
        if report.metadataPID != nil {
            report.metadataAtStall = ProcessObservation(state: "pending")
        }
        save(report)
        if let pid = report.metadataPID {
            // This query runs outside the condition, inside the existing hard
            // diagnostic bound. Never adopt a PID whose readiness was unknown.
            if let expected = report.metadataReadiness?.process {
                report.metadataAtStall = Self.observeProcess(pid, expected: expected)
            } else {
                report.metadataAtStall = ProcessObservation(state: "unknown-readiness")
            }
            save(report)
        }
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
            save(report)
            do {
                report.sample = try String(contentsOf: sampleURL, encoding: .utf8)
            } catch {
                report.sampleReadError = String(describing: error)
                Self.log("Metadata stall sample read failed: \(error)")
            }
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
