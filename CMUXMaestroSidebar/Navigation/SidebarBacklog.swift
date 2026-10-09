import Foundation
import Observation

@Observable
@MainActor
final class SidebarBacklog {
    struct Request: Equatable, Sendable {
        let windowID: UUID
        let workspaceID: UUID
        let surfaceID: UUID
        let url: URL
    }

    enum Status: Equatable {
        case opening, accepted, missingURL, invalidURL, denied, unavailable, disconnected, rejected, cancelled, timedOut

        var message: String {
            switch self {
            case .opening: String(localized: "Opening a new CMUX browser split...")
            case .accepted: String(localized: "CMUX accepted the browser split. Page loading is not verified.")
            case .missingURL: String(localized: "No backlog URL configured. Use Configure backlog URL in the workspace menu.")
            case .invalidURL: SidebarBacklogSettings.invalidNotice
            case .denied: String(localized: "Backlog requires Split surfaces and Open URLs permissions in CMUX extension settings.")
            case .unavailable: String(localized: "The workspace or browser anchor is unavailable. Use its current row; no fallback was opened.")
            case .disconnected: String(localized: "CMUX is disconnected. Any pending browser request is unconfirmed.")
            case .rejected: String(localized: "CMUX rejected the browser split. The target or permissions may have changed.")
            case .cancelled: String(localized: "Browser request cancelled. A dispatched request may already have changed CMUX.")
            case .timedOut: String(localized: "CMUX did not confirm the browser split. Check CMUX before trying again.")
            }
        }
    }

    enum Failure: Error { case rejected, cancelled }
    typealias Perform = @MainActor @Sendable (Request) async throws -> Void

    private(set) var status: Status?
    private(set) var statusWorkspaceID: UUID?
    private(set) var pending: Request?
    private var hierarchy: HierarchySnapshot = .empty
    private var connected = false
    private var allowed = false
    private var perform: Perform?
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private let timeout: @Sendable () async throws -> Void

    init(timeout: @escaping @Sendable () async throws -> Void = {
        try await Task.sleep(for: .seconds(10))
    }) {
        self.timeout = timeout
    }

    func update(hierarchy: HierarchySnapshot, connected: Bool, allowed: Bool, perform: Perform?) {
        self.hierarchy = hierarchy
        self.connected = connected
        self.allowed = allowed
        self.perform = perform
        if let pending {
            if !connected { finish(.disconnected) }
            else if !allowed { finish(.denied) }
            else if !isCurrent(pending) { finish(.unavailable) }
        }
    }

    func disconnect() {
        update(hierarchy: hierarchy, connected: false, allowed: false, perform: nil)
    }

    func cancelPending() {
        if pending != nil { finish(.cancelled) }
    }

    func contains(workspaceID: UUID, windowID: UUID?) -> Bool {
        let topology = SidebarTopology(hierarchy)
        return connected && windowID != nil && topology.windowID == windowID
            && topology.workspaceIDs.contains(workspaceID)
    }

    func open(workspaceID: UUID, windowID: UUID?, urlText: String?) {
        guard pending == nil else { return }
        statusWorkspaceID = workspaceID
        guard connected, let perform else { status = .disconnected; return }
        guard contains(workspaceID: workspaceID, windowID: windowID), let windowID else {
            status = .unavailable
            return
        }
        guard let urlText, !urlText.isEmpty else { status = .missingURL; return }
        guard let url = SidebarBacklogSettings.validatedURL(urlText) else { status = .invalidURL; return }
        guard allowed else { status = .denied; return }
        guard let surfaceID = anchor(in: workspaceID) else { status = .unavailable; return }
        let request = Request(windowID: windowID, workspaceID: workspaceID, surfaceID: surfaceID, url: url)
        generation &+= 1
        let token = generation
        pending = request
        status = .opening
        task = Task { [weak self] in
            guard let self, self.generation == token else { return }
            guard self.connected, self.allowed, self.isCurrent(request) else {
                self.finish(.unavailable)
                return
            }
            let result: Status
            do {
                try Task.checkCancellation()
                try await perform(request)
                result = .accepted
            } catch is CancellationError {
                result = .cancelled
            } catch Failure.cancelled {
                result = .cancelled
            } catch {
                result = .rejected
            }
            guard self.generation == token else { return }
            self.finish(result)
        }
        let timeout = timeout
        watchdog = Task { [weak self] in
            do { try await timeout() } catch { return }
            guard let self, self.generation == token, self.pending != nil else { return }
            self.finish(.timedOut)
        }
    }

    private func anchor(in workspaceID: UUID) -> UUID? {
        guard let workspace = hierarchy.workspaces.first(where: { $0.id == workspaceID }),
              case .available(let surfaces) = workspace.surfaces else { return nil }
        let topology = SidebarTopology(hierarchy)
        let focused = surfaces.filter(\.isFocused)
        guard focused.count <= 1 else { return nil }
        if let focused = focused.first {
            return topology.workspaceBySurface[focused.id] == workspaceID ? focused.id : nil
        }
        return surfaces.first { topology.workspaceBySurface[$0.id] == workspaceID }?.id
    }

    private func isCurrent(_ request: Request) -> Bool {
        let topology = SidebarTopology(hierarchy)
        return topology.windowID == request.windowID
            && topology.workspaceBySurface[request.surfaceID] == request.workspaceID
    }

    private func finish(_ status: Status) {
        generation &+= 1
        task?.cancel()
        watchdog?.cancel()
        task = nil
        watchdog = nil
        pending = nil
        self.status = status
    }
}
