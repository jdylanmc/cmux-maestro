import Darwin
import os

// Test-injected synchronous boundary recording; the short lock never encloses
// process work, cancellation, callbacks or serialization. Snapshot never waits.
nonisolated final class CopilotSetupObservation: Sendable {
    enum Boundary: Int, CaseIterable, Sendable {
        case cancelCall, cancelHandler, execute, poll, childWait, quiescence
        case stopGroup, termSignal, killSignal, reap, resume, invoke, metadata, taskValue
    }

    enum Reason: Int, Codable, Sendable {
        case unknown, cancellationObserved, childRunning, childExited, childUnavailable
        case quiescent, livingMember, enumerationUnavailable, memberQueryUnknown, membershipChanged
    }

    struct Detail: Codable, Equatable, Sendable {
        var reason: Reason = .unknown
        var result: Int32 = 0
        var error: Int32 = 0
        var pid: Int32 = 0
        var status: Int32 = 0
        var code: Int32 = 0
        var count: Int32 = 0
    }

    struct Entry: Codable, Equatable, Sendable {
        var begin: UInt64 = 0
        var end: UInt64 = 0
        var detailSequence: UInt64 = 0
        var detail = Detail()
    }

    struct Snapshot: Codable, Sendable {
        enum Availability: Int, Codable, Sendable { case available, unavailable }
        var version = 1
        var availability: Availability = .available
        var sequence: UInt64 = 0
        var overflow = false
        var invalidTransition = false
        var boundaries = Boundary.allCases.map { _ in Entry() }
    }

    private let storage: OSAllocatedUnfairLock<Snapshot>

    init(storage: OSAllocatedUnfairLock<Snapshot> = .init(initialState: Snapshot())) {
        self.storage = storage
    }

    func begin(_ boundary: Boundary) {
        let savedError = errno
        defer { errno = savedError }
        storage.withLock { state in
            let index = boundary.rawValue
            let previous = state.boundaries[index]
            guard previous.begin == 0 || previous.end > previous.begin else {
                state.invalidTransition = true
                return
            }
            guard Self.advance(&state) else { return }
            state.boundaries[index] = Entry(begin: state.sequence)
        }
    }

    func end(_ boundary: Boundary) {
        let savedError = errno
        defer { errno = savedError }
        storage.withLock { state in
            let index = boundary.rawValue
            guard state.boundaries[index].begin > 0, state.boundaries[index].end == 0 else {
                state.invalidTransition = true
                return
            }
            guard Self.advance(&state) else { return }
            state.boundaries[index].end = state.sequence
        }
    }

    func note(_ boundary: Boundary, _ detail: Detail) {
        let savedError = errno
        defer { errno = savedError }
        storage.withLock { state in
            let index = boundary.rawValue
            guard state.boundaries[index].begin > 0, state.boundaries[index].end == 0 else {
                state.invalidTransition = true
                return
            }
            guard Self.advance(&state) else { return }
            state.boundaries[index].detail = detail
            state.boundaries[index].detailSequence = state.sequence
        }
    }

    func snapshot() -> Snapshot {
        let savedError = errno
        defer { errno = savedError }
        return storage.withLockIfAvailable { $0 }
            ?? Snapshot(availability: .unavailable, boundaries: [])
    }

    private static func advance(_ state: inout Snapshot) -> Bool {
        guard state.sequence < UInt64.max else {
            state.overflow = true
            return false
        }
        state.sequence += 1
        return true
    }
}
