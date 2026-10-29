import Darwin
import Foundation
import Observation

nonisolated enum SidebarWorkerMode: String, Codable, Sendable {
    case bounded, interactive
}

nonisolated struct SidebarIconOverrides: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let nodeId: UUID
        let runId: UUID
        let workspaceId: UUID
        let surfaceId: UUID
        let iconId: String?
        @SidebarAgentIconColor var iconColor: SidebarAvatarColor? = nil
    }
    let version: Int
    let icons: [Entry]

    // Icons are cosmetic: a bad overlay must not discard the verified hierarchy.
    static func overlaid(_ data: Data, onto snapshot: SidebarOrchestrationSnapshot) -> SidebarOrchestrationSnapshot {
        (try? JSONDecoder().decode(Self.self, from: data).applying(to: snapshot)) ?? snapshot
    }

    func applying(to snapshot: SidebarOrchestrationSnapshot) throws -> SidebarOrchestrationSnapshot {
        guard version == 1, icons.count <= SidebarOrchestrationReader.maximumNodes,
              Dictionary(grouping: icons, by: \.workspaceId).values.allSatisfy({
                  $0.count <= SidebarOrchestrationReader.maximumWorkspaceNodes
              }),
              Set(icons.map(\.nodeId)).count == icons.count,
              icons.allSatisfy({
                  ($0.iconId != nil || $0.iconColor != nil)
                      && ($0.iconId.map(SidebarGlyphName.isValid) ?? true)
              }) else {
            throw CopilotFileError.unsafePath
        }
        let byID = Dictionary(uniqueKeysWithValues: icons.map { ($0.nodeId, $0) })
        let nodes = snapshot.nodes.map { node in
            guard let icon = byID[node.id], icon.runId == node.runId,
                  icon.workspaceId == node.workspaceId, icon.surfaceId == node.surfaceId else { return node }
            var updated = node
            updated.iconId = icon.iconId
            updated.iconColor = icon.iconColor
            return updated
        }
        return .init(version: snapshot.version, generatedAt: snapshot.generatedAt,
                     complete: snapshot.complete, omittedCount: snapshot.omittedCount, nodes: nodes,
                     processes: snapshot.processes)
    }
}

nonisolated struct SidebarGitChanges: Codable, Equatable, Sendable {
    let files: Int
    let insertions: Int
    let deletions: Int
    let untrackedFiles: Int
    let binaryFiles: Int

    var isValid: Bool {
        [files, insertions, deletions, untrackedFiles, binaryFiles].allSatisfy {
            (0...1_000_000_000).contains($0)
        } && untrackedFiles + binaryFiles <= files
            && (files > untrackedFiles + binaryFiles || (insertions == 0 && deletions == 0))
    }

    var description: String {
        "\(files) changed \(files == 1 ? "file" : "files") · +\(insertions) / −\(deletions) \(basisAndExclusions)"
    }

    var basisAndExclusions: String {
        String(
            localized: "sidebar.git.basisAndExclusions",
            defaultValue: "tracked lines vs HEAD · Untracked: \(untrackedFiles) · Binary: \(binaryFiles) · Excludes: untracked/binary lines, submodule contents"
        )
    }
}

nonisolated struct SidebarOrchestrationNode: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let runId: UUID
    let parentId: UUID?
    let role: String
    let label: String
    let workspaceId: UUID
    let surfaceId: UUID
    let generation: Int
    let phase: String
    let availability: String
    let copilotSessionId: UUID?
    let executionMode: SidebarWorkerMode?
    /// `born` for a session that enrolled itself at start (ADR 0025); nil for launches.
    var enrollment: String? = nil
    var iconId: String?
    @SidebarAgentIconColor var iconColor: SidebarAvatarColor? = nil
    let worktreeLabel: String?
    let branchLabel: String?
    let gitEvidenceStatus: String?
    let gitEvidenceAt: Date?
    let gitChangesStatus: String?
    let gitChanges: SidebarGitChanges?
    let gitChangesAt: Date?
    let createdAt: Date
    let updatedAt: Date
    /// Presentation only, never decoded: a born root's exact session name (ADR 0022).
    var sessionTitle: String? = nil
    /// Exact-generation authored metadata only; excluded from the lifecycle wire contract.
    var selfReportedMood: SidebarMoodObservation.Mood? = nil
    var selfReportedMoodSequence: Int? = nil

    /// The row title: a born root's eligible session name, otherwise its projected label.
    var title: String { sessionTitle ?? label }

    private enum CodingKeys: String, CodingKey {
        case id, runId, parentId, role, label, workspaceId, surfaceId, generation, phase, availability
        case copilotSessionId, executionMode, enrollment, iconId, iconColor, worktreeLabel, branchLabel
        case gitEvidenceStatus, gitEvidenceAt, gitChangesStatus, gitChanges, gitChangesAt, createdAt, updatedAt
    }

    init(
        id: UUID, runId: UUID, parentId: UUID?, role: String, label: String,
        workspaceId: UUID, surfaceId: UUID, generation: Int, phase: String,
        availability: String, copilotSessionId: UUID? = nil,
        executionMode: SidebarWorkerMode? = nil,
        iconId: String? = nil,
        iconColor: SidebarAvatarColor? = nil,
        worktreeLabel: String? = nil, branchLabel: String? = nil,
        gitEvidenceStatus: String? = nil, gitEvidenceAt: Date? = nil,
        gitChangesStatus: String? = nil, gitChanges: SidebarGitChanges? = nil,
        gitChangesAt: Date? = nil,
        createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.runId = runId
        self.parentId = parentId
        self.role = role
        self.label = label
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.generation = generation
        self.phase = phase
        self.availability = availability
        self.copilotSessionId = copilotSessionId
        self.executionMode = executionMode
        self.iconId = iconId
        self.iconColor = iconColor
        self.worktreeLabel = worktreeLabel
        self.branchLabel = branchLabel
        self.gitEvidenceStatus = gitEvidenceStatus
        self.gitEvidenceAt = gitEvidenceAt
        self.gitChangesStatus = gitChangesStatus
        self.gitChanges = gitChanges
        self.gitChangesAt = gitChangesAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isActive: Bool {
        !["reported-completed", "reported-failed", "launch-failed",
          "startup-failed", "turn-failed", "process-disappeared",
          "terminal-disappeared", "resource-retired"].contains(phase)
    }

    func hasFreshGitEvidence(at date: Date) -> Bool {
        guard gitEvidenceStatus == "verified", let gitEvidenceAt else { return false }
        let age = date.timeIntervalSince(gitEvidenceAt)
        return age >= -1 && age <= SidebarOrchestrationReader.gitEvidenceFreshInterval
    }

    func currentGitChanges(at date: Date) -> SidebarGitChanges? {
        guard hasFreshGitEvidence(at: date), gitChangesStatus == "verified",
              let gitChanges, gitChanges.isValid, let gitChangesAt,
              (-1...SidebarOrchestrationReader.gitEvidenceFreshInterval).contains(date.timeIntervalSince(gitChangesAt))
        else { return nil }
        return gitChanges
    }
}

nonisolated struct SidebarOrchestrationSnapshot: Codable, Equatable, Sendable {
    let version: Int
    let generatedAt: Date
    let complete: Bool
    let omittedCount: Int
    var nodes: [SidebarOrchestrationNode]
    /// Owned-process observations matched to exactly these node bindings (ADR 0029); never decoded
    /// from `current.json`.
    var processes: [UUID: SidebarProcessObservation.Node] = [:]
    var moodsUnavailable = false

    private enum CodingKeys: String, CodingKey {
        case version, generatedAt, complete, omittedCount, nodes
    }

    static let empty = Self(
        version: 1, generatedAt: .distantPast, complete: true, omittedCount: 0, nodes: []
    )
}

extension SidebarOrchestrationSnapshot {
    /// A born-managed root has no launch label. Its row shows its exact session's Copilot
    /// name under ADR 0022's rules (`SidebarCopilotTree.eligibleSessionName`), or, while its
    /// node runs and the observer has not bound that session yet, the name read for the
    /// controller's exact session (`SidebarCopilotTree.managedDetails`). Launched rows and every
    /// other node keep their projected label.
    @MainActor func namingBornRoots(from tree: SidebarCopilotTree, now: Date) -> Self {
        guard nodes.contains(where: { $0.enrollment == "born" }) else { return self }
        let named = nodes.map { node -> SidebarOrchestrationNode in
            var updated = node
            updated.sessionTitle = nil
            guard node.enrollment == "born", let session = node.copilotSessionId else { return updated }
            updated.sessionTitle = tree.eligibleSessionName(
                id: session, workspaceID: node.workspaceId, surfaceID: node.surfaceId, now: now)
                ?? (node.phase == "turn-running" ? tree.managedDetails(id: session, now: now)?.sessionName : nil)
            return updated
        }
        return .init(version: version, generatedAt: generatedAt, complete: complete,
                     omittedCount: omittedCount, nodes: named, processes: processes, moodsUnavailable: moodsUnavailable)
    }
}

nonisolated enum SidebarOrchestrationAvailability: Equatable, Sendable {
    case waiting, loading, ready, partial, stale, unavailable, hidden, disconnected
}

nonisolated enum SidebarOrchestrationPhase: String, CaseIterable, Hashable, Sendable {
    case registered
    case launching
    case turnQueued = "turn-queued"
    case turnRunning = "turn-running"
    case reportedBlocked = "reported-blocked"
    case reportedCompleted = "reported-completed"
    case reportedFailed = "reported-failed"
    case reportMissing = "report-missing"
    case permissionDenied = "permission-denied"
    case turnFailed = "turn-failed"
    case processDisappeared = "process-disappeared"
    case terminalDisappeared = "terminal-disappeared"
    case launchFailed = "launch-failed"
    case startupFailed = "startup-failed"
    case resourceRetired = "resource-retired"

    func title(availability: String) -> String {
        switch self {
        case .registered: "Registered"
        case .launching: "Launching"
        case .turnQueued: "Queued"
        case .turnRunning: "Working"
        case .reportedBlocked: "Blocked"
        case .reportedCompleted:
            availability == "idle" ? "Completed · available" : "Completed"
        case .reportedFailed:
            availability == "idle" ? "Failed · available" : "Failed"
        case .reportMissing: "Report missing"
        case .permissionDenied: "Permission denied · available"
        case .turnFailed: "Turn failed"
        case .processDisappeared: "Process disappeared"
        case .terminalDisappeared: "Terminal disappeared"
        case .launchFailed: "Launch failed"
        case .startupFailed: "Startup failed"
        case .resourceRetired: "Resource retired"
        }
    }

    func symbolName(role: String) -> String {
        if role == "coordinator" { return "person.2" }
        return self == .permissionDenied ? "exclamationmark.shield" : "terminal"
    }
}

nonisolated enum SidebarOrchestrationReader {
    static let maximumBytes = 1_048_576
    static let maximumNodes = 1024
    static let maximumWorkspaceNodes = 128
    static let maximumDepth = 8
    static let futureTolerance: TimeInterval = 300
    static let staleInterval: TimeInterval = 60
    static let gitEvidenceFreshInterval: TimeInterval = 60

    actor Cached {
        private var cache = Cache()

        func read() throws -> SidebarOrchestrationSnapshot {
            try SidebarOrchestrationReader.read(cache: &cache)
        }

        func resetMoodBaseline() {
            cache.moods.resetForConnection()
        }
    }

    struct Cache {
        var current = Decoded<SidebarOrchestrationSnapshot>()
        var icons = Decoded<SidebarIconOverrides>()
        var processes = Decoded<SidebarProcessObservation>()
        var moods = SidebarMoodObservation.Cache()
        var base: (current: Data, icons: Data?, snapshot: SidebarOrchestrationSnapshot, validatedAt: Date)?
        var resolved: (
            processes: Data?, snapshot: SidebarOrchestrationSnapshot, resolvedAt: Date, revalidateAt: Date?
        )?
        var validationCount = 0
        var iconApplicationCount = 0
        var processMatchCount = 0
    }

    struct Decoded<Value: Decodable & Sendable> {
        private var entry: (bytes: Data, result: Result<Value, Error>)?

        mutating func value(
            for data: Data, decode: (Data) throws -> Value = { try decoder().decode(Value.self, from: $0) }
        ) throws -> Value {
            if let entry, entry.bytes == data { return try entry.result.get() }
            // One bounded input per source, including malformed input; never reuse last-good evidence.
            let result = Result { try decode(data) }
            entry = (data, result)
            return try result.get()
        }
    }

    static func read() throws -> SidebarOrchestrationSnapshot {
        var cache = Cache()
        return try read(cache: &cache)
    }

    private static func read(cache: inout Cache) throws -> SidebarOrchestrationSnapshot {
        let owner = getuid()
        let observer = try CopilotFileAccess.openDirectory(
            try CopilotPaths.orchestrationObserverDirectory(), owner: owner
        )
        defer { close(observer) }
        let data = try CopilotFileAccess.readStableRegular(
            at: observer, filename: "current.json", owner: owner,
            maximum: maximumBytes, permissions: 0o600
        )
        let iconData = try? CopilotFileAccess.readStableRegular(
            at: observer, filename: "icons.json", owner: owner,
            maximum: maximumBytes, permissions: 0o600
        )
        let processData = try? CopilotFileAccess.readStableRegular(
            at: observer, filename: "processes.json", owner: owner,
            maximum: maximumBytes, permissions: 0o600
        )
        let moodData: Data?
        do {
            moodData = try CopilotFileAccess.readStableRegular(
                at: observer, filename: "moods.json", owner: owner,
                maximum: SidebarMoodObservation.maximumBytes, permissions: 0o600
            )
        } catch CopilotFileError.missing {
            moodData = nil
        } catch {
            // Invalid optional data disables only authored expressions, with a bounded diagnostic.
            moodData = Data()
        }
        // Still securely open and validate every file: metadata alone must not preserve revoked access.
        return try resolve(current: data, icons: iconData, processes: processData, moods: moodData, cache: &cache, now: Date())
    }

    static func resolve(
        current data: Data, icons iconData: Data?, processes processData: Data?, moods moodData: Data? = nil,
        cache: inout Cache, now: Date
    ) throws -> SidebarOrchestrationSnapshot {
        let base = try resolveBase(current: data, icons: iconData, processes: processData, cache: &cache, now: now)
        return cache.moods.applying(moodData, to: base)
    }

    private static func resolveBase(
        current data: Data, icons iconData: Data?, processes processData: Data?, cache: inout Cache, now: Date
    ) throws -> SidebarOrchestrationSnapshot {
        let base: SidebarOrchestrationSnapshot
        if let previous = cache.base, previous.current == data, previous.icons == iconData,
           now >= previous.validatedAt {
            // Validation has only future-time bounds; advancing time cannot invalidate this base.
            base = previous.snapshot
        } else {
            cache.base = nil
            cache.resolved = nil
            var snapshot = try cache.current.value(for: data)
            cache.validationCount += 1
            try validate(snapshot, now: now)
            if let iconData {
                cache.iconApplicationCount += 1
                if let icons = try? cache.icons.value(for: iconData),
                   let overlaid = try? icons.applying(to: snapshot) { snapshot = overlaid }
            } else {
                cache.icons = .init()
            }
            base = snapshot
            cache.base = (data, iconData, base, now)
        }
        if let previous = cache.resolved, previous.processes == processData, now >= previous.resolvedAt,
           previous.revalidateAt.map({ now < $0 }) ?? true { return previous.snapshot }
        var snapshot = base
        var revalidateAt: Date?
        if let processData, let processes = try? cache.processes.value(for: processData) {
            cache.processMatchCount += 1
            snapshot.processes = processes.matching(snapshot: snapshot, now: now)
            // A future-dated optional observation must become eligible even when its bytes do not change.
            let eligibleAt = (processes.nodes.map(\.observedAt).max().map {
                max($0, processes.observedAt)
            } ?? processes.observedAt).addingTimeInterval(-futureTolerance)
            if eligibleAt > now { revalidateAt = eligibleAt }
        } else if processData == nil {
            cache.processes = .init()
        }
        cache.resolved = (processData, snapshot, now, revalidateAt)
        return snapshot
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = fractional.date(from: value) ?? standard.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(), debugDescription: "Invalid timestamp"
                )
            }
            return date
        }
        return decoder
    }

    static func validate(_ snapshot: SidebarOrchestrationSnapshot, now: Date = Date()) throws {
        guard snapshot.version == 1, snapshot.nodes.count <= maximumNodes,
              Dictionary(grouping: snapshot.nodes, by: \.workspaceId).values.allSatisfy({
                  $0.count <= maximumWorkspaceNodes
              }),
              snapshot.omittedCount >= 0,
              Set(snapshot.nodes.map(\.id)).count == snapshot.nodes.count,
              snapshot.generatedAt <= now.addingTimeInterval(futureTolerance) else {
            throw CopilotFileError.unsafePath
        }
        let nodes = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        var surfaces = Set<UUID>()
        var rootsByRun: [UUID: Int] = [:]
        for node in snapshot.nodes {
            guard !node.label.isEmpty, node.label.utf8.count <= 100,
                  node.iconId.map(SidebarGlyphName.isValid) ?? true,
                  boundedLabel(node.worktreeLabel), boundedLabel(node.branchLabel),
                  node.generation >= 0, node.createdAt <= node.updatedAt,
                  node.updatedAt <= now.addingTimeInterval(futureTolerance),
                  node.updatedAt <= snapshot.generatedAt.addingTimeInterval(futureTolerance),
                  surfaces.insert(node.surfaceId).inserted,
                  validState(node) else {
                throw CopilotFileError.unsafePath
            }
            guard validGitEvidence(node, generatedAt: snapshot.generatedAt),
                  node.role == "worker" || node.executionMode == .interactive
                    || node.copilotSessionId == nil,
                  // Born: an interactive root. A root must be a coordinator (below), and an
                  // interactive coordinator carries its session (validState and the clause above).
                  node.enrollment == nil || (node.enrollment == "born" && node.parentId == nil
                    && node.executionMode == .interactive) else {
                throw CopilotFileError.unsafePath
            }

            if node.parentId == nil {
                rootsByRun[node.runId, default: 0] += 1
            }
        }
        guard rootsByRun.values.allSatisfy({ $0 == 1 }) else {
            throw CopilotFileError.unsafePath
        }
        for node in snapshot.nodes {
            var current = node
            var seen = Set([node.id])
            var depth = 0
            while let parentId = current.parentId {
                guard let parent = nodes[parentId], seen.insert(parent.id).inserted,
                      parent.runId == node.runId,
                      parent.workspaceId == node.workspaceId else {
                    throw CopilotFileError.unsafePath
                }
                depth += 1
                guard depth <= maximumDepth else { throw CopilotFileError.unsafePath }
                current = parent
            }
            guard current.role == "coordinator" else { throw CopilotFileError.unsafePath }
        }
    }

    private static func boundedLabel(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value.utf8.count <= 120
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func validGitEvidence(
        _ node: SidebarOrchestrationNode, generatedAt: Date
    ) -> Bool {
        switch node.gitChangesStatus {
        case "verified":
            guard node.gitChanges?.isValid == true, node.gitChangesAt != nil else {
                return false
            }
        case nil, "unavailable":
            guard node.gitChanges == nil else { return false }
        default:
            return false
        }
        if let captured = node.gitChangesAt {
            guard node.gitChangesStatus != nil, captured <= generatedAt.addingTimeInterval(1) else { return false }
        }
        switch node.gitEvidenceStatus {
        case nil:
            // Version-1 observers written before evidence timestamps remain
            // decodable, but hasFreshGitEvidence never presents their labels.
            return node.gitEvidenceAt == nil
        case "verified":
            guard let captured = node.gitEvidenceAt, node.worktreeLabel != nil else {
                return false
            }
            return captured <= generatedAt.addingTimeInterval(1)
        case "unavailable":
            guard let captured = node.gitEvidenceAt else { return false }
            return captured <= generatedAt.addingTimeInterval(1)
                && node.worktreeLabel == nil && node.branchLabel == nil
        default:
            return false
        }
    }

    static func isStale(_ snapshot: SidebarOrchestrationSnapshot, now: Date = Date()) -> Bool {
        now.timeIntervalSince(snapshot.generatedAt) > staleInterval
    }

    private static func validState(_ node: SidebarOrchestrationNode) -> Bool {
        if node.role == "coordinator", node.executionMode != .interactive {
            return node.parentId == nil && node.generation == 0
                && node.phase == "registered" && node.availability == "active"
        }
        let managedCoordinator = node.role == "coordinator" && node.parentId == nil
            && node.executionMode == .interactive && node.generation >= 1  // >1 after a relaunch resume
            && node.copilotSessionId != nil
        guard managedCoordinator || (node.role == "worker" && node.parentId != nil
                                     && node.generation > 0) else {
            return false
        }
        guard let phase = SidebarOrchestrationPhase(rawValue: node.phase) else {
            return false
        }
        switch phase {
        case .launching, .turnQueued, .turnRunning:
            if phase == .turnQueued && node.executionMode == .interactive { return false }
            return node.availability == "busy"
        case .reportedBlocked, .reportedCompleted, .reportedFailed,
             .reportMissing, .permissionDenied, .turnFailed:
            guard node.executionMode != .interactive || phase == .turnFailed else { return false }
            return node.availability == "idle"
        case .processDisappeared, .terminalDisappeared, .launchFailed,
             .startupFailed, .resourceRetired:
            return node.availability == "unavailable"
        case .registered:
            return false
        }
    }
}

@Observable
@MainActor
final class SidebarOrchestrationPolling {
    typealias Read = @Sendable () async throws -> SidebarOrchestrationSnapshot
    typealias Pause = @Sendable () async throws -> Void
    typealias ExpiryPause = @Sendable (TimeInterval) async throws -> Void
    typealias Changes = @Sendable () async -> SidebarRefreshTrigger

    private(set) var availability: SidebarOrchestrationAvailability = .waiting
    private(set) var snapshot = SidebarOrchestrationSnapshot.empty
    // The filtered projection before born-root naming; names come from Copilot observations.
    private var projected = SidebarOrchestrationSnapshot.empty
    private var observedTree: SidebarCopilotTree?
    private var topology = SidebarTopology(.empty)
    private var visible = false
    private var connected = false
    private var needsMoodBaseline = false
    private var generation: UInt64 = 0
    private var worker: Task<Void, Never>?
    private let read: Read
    private let resetMoodBaseline: @Sendable () async -> Void
    private let pause: Pause
    private let now: @Sendable () -> Date
    private let expiryPause: ExpiryPause
    @ObservationIgnored private var presentationExpiry: Task<Void, Never>?
    @ObservationIgnored private var presentationDeadline: Date?
    private let changes: Changes?
    // Observe quiescence without exposing cancellable task handles.
    private let taskFinished: @MainActor @Sendable (UInt64) -> Void

    init(
        read: Read? = nil,
        resetMoodBaseline: (@Sendable () async -> Void)? = nil,
        pause: @escaping Pause = { try await Task.sleep(for: .seconds(2)) },
        expiryPause: @escaping ExpiryPause = { try await Task.sleep(for: .seconds($0)) },
        changes: Changes? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        taskFinished: @escaping @MainActor @Sendable (UInt64) -> Void = { _ in }
    ) {
        let reader = SidebarOrchestrationReader.Cached()
        self.read = read ?? {
            try await reader.read()
        }
        self.resetMoodBaseline = resetMoodBaseline ?? {
            await reader.resetMoodBaseline()
        }
        self.pause = pause
        self.now = now
        self.expiryPause = expiryPause
        self.changes = changes ?? (read == nil ? {
            await SidebarRefreshTrigger.live { [try CopilotPaths.orchestrationObserverDirectory()] }
        } : nil)
        self.taskFinished = taskFinished
    }

    var roots: [SidebarOrchestrationNode] {
        let ids = Set(snapshot.nodes.map(\.id))
        return snapshot.nodes.filter { node in
            guard let parent = node.parentId else { return true }
            return !ids.contains(parent)
        }
    }

    /// Re-titles born-managed roots from the latest Copilot observations (ADR 0022).
    func updateObservedSessions(_ tree: SidebarCopilotTree, now: Date? = nil) {
        observedTree = tree
        retitle(now: now ?? self.now())
    }

    private func retitle(now: Date) {
        let named = observedTree.map { projected.namingBornRoots(from: $0, now: now) }
            ?? projected.namingBornRoots(from: .waiting, now: now)
        if named != snapshot { snapshot = named }
    }

    func children(of id: UUID) -> [SidebarOrchestrationNode] {
        snapshot.nodes.filter { $0.parentId == id }
    }

    func update(topology: SidebarTopology, connected: Bool) {
        guard self.topology != topology || self.connected != connected else { return }
        if self.connected && !connected { needsMoodBaseline = true }
        self.topology = topology
        self.connected = connected
        invalidate()
    }

    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        invalidate()
    }

    private func invalidate() {
        cancelPresentationExpiry()
        generation &+= 1
        worker?.cancel()
        snapshot = .empty
        projected = .empty
        availability = !visible ? .hidden : !connected ? .disconnected : .loading
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard worker == nil, visible, connected else { return }
        let token = generation
        let topology = topology
        let read = read
        let pause = pause
        let taskFinished = taskFinished
        let changes = changes
        let resetMoodBaseline = resetMoodBaseline
        let needsMoodBaseline = needsMoodBaseline
        self.needsMoodBaseline = false
        worker = Task { [weak self] in
            defer { taskFinished(token) }
            // Replacement workers start only after obsolete reads finish. Reset here, not in an
            // unsequenced task, and even if cancelled before starting so the boundary is not lost.
            if needsMoodBaseline { await resetMoodBaseline() }
            let refresh = await changes?()
            while !Task.isCancelled {
                do {
                    let raw = try await read()
                    guard let self, self.generation == token, !Task.isCancelled else { break }
                    let byID = Dictionary(uniqueKeysWithValues: raw.nodes.map { ($0.id, $0) })
                    let onSurface = Set(raw.nodes.compactMap { node in
                        topology.workspaceBySurface[node.surfaceId] == node.workspaceId ? node.id : nil
                    })
                    let nodes = raw.nodes.filter { node in
                        var current: SidebarOrchestrationNode? = node
                        while let candidate = current {
                            guard onSurface.contains(candidate.id) else { return false }
                            current = candidate.parentId.flatMap { byID[$0] }
                        }
                        return true
                    }
                    self.projected = SidebarOrchestrationSnapshot(
                        version: raw.version, generatedAt: raw.generatedAt,
                        complete: raw.complete, omittedCount: raw.omittedCount,
                        nodes: nodes, processes: raw.processes, moodsUnavailable: raw.moodsUnavailable
                    )
                    self.retitle(now: self.now())
                    self.availability = SidebarOrchestrationReader.isStale(raw, now: self.now())
                        ? .stale : self.snapshot.complete ? .ready : .partial
                    self.schedulePresentationExpiry()
                } catch CopilotFileError.missing {
                    guard let self, self.generation == token, !Task.isCancelled else { break }
                    self.snapshot = .empty
                    self.projected = .empty
                    self.availability = .waiting
                    self.cancelPresentationExpiry()
                } catch {
                    guard let self, self.generation == token, !Task.isCancelled else { break }
                    self.snapshot = .empty
                    self.projected = .empty
                    self.availability = .unavailable
                    self.cancelPresentationExpiry()
                }
                do {
                    if let refresh { try await refresh.wait(fallback: pause) } else { try await pause() }
                } catch { break }
            }
            await refresh?.stop()
            guard let self else { return }
            self.worker = nil
            if self.generation != token { self.startIfNeeded() }
        }
    }

    private func cancelPresentationExpiry() {
        presentationExpiry?.cancel()
        presentationExpiry = nil
        presentationDeadline = nil
    }

    private func schedulePresentationExpiry() {
        let date = now()
        // A poll can win the actor before an already-due timer; don't cancel its redraw.
        if let pending = presentationDeadline, pending <= date {
            withMutation(keyPath: \.snapshot) {}
        }
        let deadline = nextPresentationDeadline(after: date)
        guard deadline != presentationDeadline else { return }
        cancelPresentationExpiry()
        guard let deadline else { return }
        presentationDeadline = deadline
        let token = generation
        let expiryPause = expiryPause
        presentationExpiry = Task { [weak self] in
            do { try await expiryPause(max(0, deadline.timeIntervalSince(date))) }
            catch { return }
            guard let self, !Task.isCancelled, self.generation == token, self.visible, self.connected else { return }
            self.presentationExpiry = nil
            self.presentationDeadline = nil
            self.availability = SidebarOrchestrationReader.isStale(self.projected, now: self.now())
                ? .stale : self.projected.complete ? .ready : .partial
            // Time changes presentation, not evidence. Equal snapshots still need a redraw here.
            self.withMutation(keyPath: \.snapshot) {}
            self.schedulePresentationExpiry()
        }
    }

    private func nextPresentationDeadline(after date: Date) -> Date? {
        var next: Date?
        func include(_ candidate: Date) {
            guard candidate > date else { return }
            next = min(next ?? candidate, candidate)
        }
        func expires(_ evidence: Date, after interval: TimeInterval) {
            // Freshness is inclusive at the boundary; wake at the next representable instant.
            let boundary = evidence.addingTimeInterval(interval).timeIntervalSinceReferenceDate
            include(Date(timeIntervalSinceReferenceDate: boundary.nextUp))
        }
        func freshness(_ evidence: Date, interval: TimeInterval) {
            include(evidence.addingTimeInterval(-1))
            expires(evidence, after: interval)
        }
        freshness(projected.generatedAt, interval: SidebarOrchestrationReader.staleInterval)
        for node in projected.nodes {
            freshness(node.updatedAt, interval: SidebarOrchestrationReader.staleInterval)
            if let gitAt = node.gitEvidenceAt {
                freshness(gitAt, interval: SidebarOrchestrationReader.gitEvidenceFreshInterval)
            }
            if let changesAt = node.gitChangesAt {
                freshness(changesAt, interval: SidebarOrchestrationReader.gitEvidenceFreshInterval)
            }
        }
        for process in projected.processes.values {
            expires(process.observedAt, after: SidebarProcessPresentation.staleInterval)
            expires(process.observedAt, after: SidebarProcessPresentation.unavailableInterval)
        }
        return next
    }
}
