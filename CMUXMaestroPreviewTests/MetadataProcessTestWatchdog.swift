import Darwin
import Foundation

// A dedicated thread and condition keep diagnostics independent of the executor
// under investigation. All mutable observation state is protected by the condition.
nonisolated final class MetadataProcessTestWatchdog: @unchecked Sendable {
    static let test = "CMUXMaestroPreviewTests/CopilotObserverRegistrationTests/metadataProcessUsesSupervisorForSuccessTimeoutAndMalformedOutput()"
    private let condition = NSCondition()
    private let directory: URL
    private let limit: Duration
    private var phase = "fixture"
    private var deadline: ContinuousClock.Instant
    private var samples = 0
    private var lastSample: ContinuousClock.Instant?
    private var finished = false

    init(directory: URL, limit: Duration = .seconds(30)) throws {
        self.directory = directory
        self.limit = limit
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
            test: Self.test, pid: getpid(), phase: phase, deadlineSamples: samples,
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
            _exit(124)
        }
        var report = initial
        save(report)
        Self.log("Metadata test stalled: phase=\(report.phase) deadlineSamples=\(report.deadlineSamples) report=\(directory.path)/stall.json")
        let sampleURL = directory.appendingPathComponent("sample.txt")
        do {
            let sampler = Process()
            sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            sampler.arguments = [String(getpid()), "1", "1", "-file", sampleURL.path]
            sampler.standardOutput = FileHandle.nullDevice
            sampler.standardError = FileHandle.standardError
            try sampler.run()
            sampler.waitUntilExit()
            report.sampleStatus = "exit-\(sampler.terminationStatus)"
            report.sample = try String(contentsOf: sampleURL, encoding: .utf8)
        } catch {
            report.sampleStatus = "failed: \(error)"
            Self.log("Metadata stall sampling failed: \(error)")
        }
        save(report)
        // Never resume a stalled assertion or reinterpret cancellation as a pass.
        _exit(124)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
