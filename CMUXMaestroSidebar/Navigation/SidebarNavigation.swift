import Foundation
import Observation

enum SidebarNavigationTarget: Equatable, Sendable {
    case workspace(UUID)
    case surface(workspaceID: UUID, surfaceID: UUID)
}

enum SidebarNavigationError: Error {
    case rejected, cancelled, disconnected
}

enum SidebarNavigationStatus: Equatable {
    case idle, selecting, selected, denied, rejected, cancelled, staleTarget, disconnected, timedOut

    var message: String? {
        switch self {
        case .idle: nil
        case .selecting: "Focusing in CMUX…"
        case .selected: "Focused in CMUX."
        case .denied: "Navigation permission not granted. Enable the selection action in CMUX extension settings."
        case .rejected: "CMUX rejected the selection. The target may no longer be available."
        case .cancelled: "Selection was cancelled."
        case .staleTarget: "The target changed. Select its current row to focus."
        case .disconnected: "Cannot focus while CMUX is disconnected."
        case .timedOut: "CMUX did not confirm selection in time. Select the row to try again."
        }
    }
}

@Observable
@MainActor
final class SidebarNavigation {
    typealias Perform = @MainActor @Sendable (SidebarNavigationTarget) async throws -> Void

    private(set) var status: SidebarNavigationStatus = .idle
    private var topology = SidebarTopology(.empty)
    private var workspaceAllowed = false
    private var surfaceAllowed = false
    private var connected = false
    private var perform: Perform?
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var activeTarget: SidebarNavigationTarget?
    private let timeout: @Sendable () async throws -> Void

    init(timeout: @escaping @Sendable () async throws -> Void = {
        try await Task.sleep(for: .seconds(10))
    }) {
        self.timeout = timeout
    }

    var permissionSummary: String? {
        guard connected else { return nil }
        if !workspaceAllowed && !surfaceAllowed {
            return "Focus disabled: grant workspace and surface selection in CMUX extension settings."
        }
        if !workspaceAllowed { return "Workspace focus requires workspace selection permission." }
        if !surfaceAllowed { return "Surface and Copilot focus require surface selection permission." }
        return nil
    }

    func update(
        topology: SidebarTopology,
        connected: Bool,
        workspaceAllowed: Bool,
        surfaceAllowed: Bool,
        perform: Perform?
    ) {
        let changed = self.topology != topology || self.connected != connected
            || self.workspaceAllowed != workspaceAllowed || self.surfaceAllowed != surfaceAllowed
        self.topology = topology
        self.connected = connected
        self.workspaceAllowed = workspaceAllowed
        self.surfaceAllowed = surfaceAllowed
        self.perform = perform
        if changed, activeTarget != nil {
            generation &+= 1
            task?.cancel()
            watchdog?.cancel()
            task = nil
            watchdog = nil
            activeTarget = nil
            status = connected ? .staleTarget : .disconnected
        } else if changed {
            status = connected ? .idle : .disconnected
        }
    }

    func disconnect() {
        update(
            topology: topology, connected: false,
            workspaceAllowed: false, surfaceAllowed: false, perform: nil
        )
    }

    func cancelPending() {
        guard activeTarget != nil else { return }
        generation &+= 1
        task?.cancel()
        watchdog?.cancel()
        task = nil
        watchdog = nil
        activeTarget = nil
        status = .cancelled
    }

    func disabledReason(for target: SidebarNavigationTarget) -> String? {
        guard connected, perform != nil else { return SidebarNavigationStatus.disconnected.message }
        guard isCurrent(target) else { return SidebarNavigationStatus.staleTarget.message }
        guard isAllowed(target) else { return SidebarNavigationStatus.denied.message }
        return nil
    }

    func select(_ target: SidebarNavigationTarget, onSuccess: @escaping @MainActor () -> Void = {}) {
        generation &+= 1
        let token = generation
        task?.cancel()
        watchdog?.cancel()
        task = nil
        watchdog = nil
        activeTarget = nil
        guard connected, let perform else { status = .disconnected; return }
        guard isCurrent(target) else { status = .staleTarget; return }
        guard isAllowed(target) else { status = .denied; return }
        status = .selecting
        activeTarget = target
        task = Task { [weak self] in
            let result: SidebarNavigationStatus
            do {
                try await perform(target)
                result = .selected
            } catch is CancellationError {
                result = .cancelled
            } catch let error as SidebarNavigationError {
                switch error {
                case .rejected: result = .rejected
                case .cancelled: result = .cancelled
                case .disconnected: result = .disconnected
                }
            } catch {
                result = .rejected
            }
            guard let self, self.generation == token else { return }
            self.status = self.isCurrent(target) ? result : .staleTarget
            self.watchdog?.cancel()
            self.watchdog = nil
            self.activeTarget = nil
            self.task = nil
            if self.status == .selected { onSuccess() }
        }
        let timeout = timeout
        watchdog = Task { [weak self] in
            do { try await timeout() } catch { return }
            guard let self, self.generation == token, self.activeTarget != nil else { return }
            self.generation &+= 1
            self.task?.cancel()
            self.task = nil
            self.watchdog = nil
            self.activeTarget = nil
            self.status = .timedOut
        }
    }

    private func isAllowed(_ target: SidebarNavigationTarget) -> Bool {
        switch target {
        case .workspace: workspaceAllowed
        case .surface: surfaceAllowed
        }
    }

    private func isCurrent(_ target: SidebarNavigationTarget) -> Bool {
        guard topology.windowID != nil else { return false }
        switch target {
        case .workspace(let id): return topology.workspaceIDs.contains(id)
        case .surface(let workspaceID, let surfaceID):
            return topology.workspaceBySurface[surfaceID] == workspaceID
        }
    }
}
