import Testing

// Swift Testing's body stays concurrent with NonisolatedNonsendingByDefault enabled.
typealias SidebarScopedTestBody = @concurrent @Sendable () async throws -> Void

nonisolated struct SidebarAppKitTestScope: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: SidebarScopedTestBody
    ) async throws {
        // Scope individual cases, not their containing suite (which would reacquire the same gate).
        guard testCase != nil else { try await function(); return }
        try await SidebarAppKitTestGate.shared.run {
            print("R3 AppKit scope begin: \(test.name)")
            defer { print("R3 AppKit scope end: \(test.name)") }
            try await function()
        }
    }
}

@MainActor
final class SidebarAppKitTestGate {
    static let shared = SidebarAppKitTestGate()
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var waitingCount: Int { waiters.count }

    func run(_ function: @Sendable () async throws -> Void) async throws {
        if occupied {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            occupied = true
        }
        defer {
            if waiters.isEmpty { occupied = false }
            else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        try await function()
    }
}
