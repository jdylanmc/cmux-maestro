import Foundation

nonisolated enum AgentSessionSnapshotJSONCodec {
    static let fractionalSecondDigits = 9

    static func decode(_ data: Data) throws -> AgentSessionSnapshot {
        try decoder().decode(AgentSessionSnapshot.self, from: data)
    }

    static func encode(_ snapshot: AgentSessionSnapshot) throws -> Data {
        try encoder().encode(snapshot)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let style = value.contains(".") ? fractionalDateStyle : wholeSecondDateStyle

            do {
                return try style.parse(value)
            } catch {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a canonical ISO-8601 UTC timestamp"
                )
            }
        }
        return decoder
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let interval = date.timeIntervalSince1970
            guard interval.isFinite else {
                throw EncodingError.invalidValue(
                    date,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "Cannot encode a non-finite timestamp"
                    )
                )
            }

            var wholeSeconds = floor(interval)
            var nanoseconds = Int(
                ((interval - wholeSeconds) * 1_000_000_000).rounded()
            )
            if nanoseconds == 1_000_000_000 {
                wholeSeconds += 1
                nanoseconds = 0
            }

            let wholeSecond = Date(timeIntervalSince1970: wholeSeconds)
                .formatted(wholeSecondDateStyle)
            let timestamp = String(wholeSecond.dropLast())
                + String(
                    format: ".%0*dZ",
                    fractionalSecondDigits,
                    nanoseconds
                )

            var container = encoder.singleValueContainer()
            try container.encode(timestamp)
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static let wholeSecondDateStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: false,
        timeZone: TimeZone(secondsFromGMT: 0)!
    )

    private static let fractionalDateStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: TimeZone(secondsFromGMT: 0)!
    )
}

nonisolated struct SnapshotSchemaVersion: Codable, Equatable, Hashable, Sendable {
    static let current = SnapshotSchemaVersion(rawValue: 1)
    static let supported: Set<Self> = [.current]

    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(Int.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated struct WorkspaceID: Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated struct SurfaceID: Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated struct ChildWorkID: Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated struct ProviderSessionIdentity: Codable, Equatable, Hashable, Sendable {
    let providerID: String
    let sessionID: String

    init(providerID: String, sessionID: String) {
        self.providerID = providerID
        self.sessionID = sessionID
    }
}

nonisolated enum SnapshotAvailability: String, Codable, Equatable, Sendable {
    case known
    case unknown
    case degraded
}

nonisolated struct SnapshotValue<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    let availability: SnapshotAvailability
    let value: Value?
    let detail: String?

    init(availability: SnapshotAvailability, value: Value? = nil, detail: String? = nil) {
        self.availability = availability
        self.value = value
        self.detail = detail
    }

    static func known(_ value: Value) -> Self {
        Self(availability: .known, value: value)
    }

    static func unknown(detail: String? = nil) -> Self {
        Self(availability: .unknown, detail: detail)
    }

    static func degraded(_ detail: String, value: Value? = nil) -> Self {
        Self(availability: .degraded, value: value, detail: detail)
    }

    var isValidObservation: Bool {
        switch availability {
        case .known: value != nil && detail == nil
        case .unknown: value == nil
        case .degraded: detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    var knownValue: Value? { availability == .known && isValidObservation ? value : nil }
    var isDegraded: Bool { availability == .degraded || !isValidObservation }
}

nonisolated enum AgentSessionState: String, Codable, Equatable, Sendable {
    case unknown
    case queued
    case working
    case blocked
    case done
}

// Only distinctions that v1 cannot express. The legacy state must be unknown
// when a detail is present, so old decoders never mistake idle/failure for done.
nonisolated enum AgentSessionStateDetail: String, Codable, Equatable, Sendable {
    case idle, failed, cancelled
}

nonisolated enum AgentWorkState: String, Codable, Equatable, Sendable {
    case unknown, queued, working, idle, blocked, completed, failed, cancelled

    var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }

    static func resolve(
        _ state: SnapshotValue<AgentSessionState>, detail: AgentSessionStateDetail?
    ) -> Self {
        guard state.isValidObservation else { return .unknown }
        if let detail {
            guard state.availability == .unknown, state.value == nil else { return .unknown }
            switch detail {
            case .idle: return .idle
            case .failed: return .failed
            case .cancelled: return .cancelled
            }
        }
        guard state.availability == .known, let state = state.value else { return .unknown }
        switch state {
        case .unknown: return .unknown
        case .queued: return .queued
        case .working: return .working
        case .blocked: return .blocked
        case .done: return .completed
        }
    }
}

nonisolated enum AgentProcessLiveness: String, Codable, Equatable, Sendable {
    case alive, dead, ambiguous, unknown
}

nonisolated enum AgentWorkKind: String, Codable, Equatable, Sendable {
    case subagent, skill, shell, unknown
}

nonisolated struct AgentTerminalEvent: Codable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date?
}

nonisolated struct AgentSessionAppearance: Codable, Equatable, Sendable {
    let iconId: String?
    let iconColor: String?
}

// Additional evidence, never a reinterpretation of v1's nested childWork.
// Items are ordered literal edges; missing parents and cycles are permissible.
nonisolated struct AgentChildWorkObservation: Codable, Equatable, Sendable {
    let items: [AgentChildWork]
    let legacyProjectionIsLossless: Bool

    init(items: [AgentChildWork], legacyProjectionIsLossless: Bool = false) {
        self.items = items
        self.legacyProjectionIsLossless = legacyProjectionIsLossless
    }
}

nonisolated struct AgentSnapshotIssue: RawRepresentable, Codable, Equatable, Sendable {
    let rawValue: String

    static let integrationNotInstalled = Self(rawValue: "integrationNotInstalled")
    static let noIdentityRecords = Self(rawValue: "noIdentityRecords")
    static let permissionDenied = Self(rawValue: "permissionDenied")
    static let loadingHistory = Self(rawValue: "loadingHistory")
    static let stateUnavailable = Self(rawValue: "stateUnavailable")
    static let malformedData = Self(rawValue: "malformedData")
    static let unsupportedFormat = Self(rawValue: "unsupportedFormat")
    static let identityChanged = Self(rawValue: "identityChanged")
    static let ambiguousIdentity = Self(rawValue: "ambiguousIdentity")
    static let ambiguousTurn = Self(rawValue: "ambiguousTurn")
    static let readLimitReached = Self(rawValue: "readLimitReached")
    static let appearanceUnavailable = Self(rawValue: "appearanceUnavailable")
}

nonisolated struct AgentModel: Codable, Equatable, Sendable {
    let identifier: String
    let displayName: String?

    init(identifier: String, displayName: String? = nil) {
        self.identifier = identifier
        self.displayName = displayName
    }
}

nonisolated struct FileSystemPath: Codable, Equatable, Sendable {
    let value: String

    init(_ value: String) {
        self.value = value
    }
}

nonisolated struct AgentWorktree: Codable, Equatable, Sendable {
    let path: FileSystemPath
    let branch: SnapshotValue<String>

    init(path: FileSystemPath, branch: SnapshotValue<String>) {
        self.path = path
        self.branch = branch
    }
}

nonisolated struct AgentSessionPaths: Codable, Equatable, Sendable {
    let currentDirectory: SnapshotValue<FileSystemPath>
    let worktree: SnapshotValue<AgentWorktree>

    init(
        currentDirectory: SnapshotValue<FileSystemPath>,
        worktree: SnapshotValue<AgentWorktree>
    ) {
        self.currentDirectory = currentDirectory
        self.worktree = worktree
    }
}

nonisolated struct AgentSessionTiming: Codable, Equatable, Sendable {
    let startedAt: Date
    let updatedAt: Date
    let completedAt: Date?

    init(startedAt: Date, updatedAt: Date, completedAt: Date? = nil) {
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

nonisolated enum SurfaceKind: String, Codable, Equatable, Sendable {
    case unknown
    case terminal
    case editor
    case browser
    case other
}

nonisolated struct CMUXSurfaceSnapshot: Codable, Equatable, Sendable {
    let id: SurfaceID
    let workspaceID: WorkspaceID
    let title: SnapshotValue<String>
    let kind: SurfaceKind

    init(
        id: SurfaceID,
        workspaceID: WorkspaceID,
        title: SnapshotValue<String>,
        kind: SurfaceKind
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.title = title
        self.kind = kind
    }
}

nonisolated struct CMUXWorkspaceSnapshot: Codable, Equatable, Sendable {
    let id: WorkspaceID
    let title: SnapshotValue<String>
    let surfaces: [CMUXSurfaceSnapshot]

    init(id: WorkspaceID, title: SnapshotValue<String>, surfaces: [CMUXSurfaceSnapshot]) {
        self.id = id
        self.title = title
        self.surfaces = surfaces
    }
}

nonisolated struct AgentSessionBinding: Codable, Equatable, Sendable {
    let workspaceID: WorkspaceID
    let surfaceID: SurfaceID

    init(workspaceID: WorkspaceID, surfaceID: SurfaceID) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
    }
}

nonisolated enum AgentSessionBindingObservation: Codable, Equatable, Sendable {
    case bound(AgentSessionBinding)
    case unbound
    case unknown(lastKnownBinding: AgentSessionBinding? = nil, detail: String? = nil)
    case degraded(lastKnownBinding: AgentSessionBinding? = nil, detail: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case binding
        case lastKnownBinding
        case detail
    }

    private enum Kind: String, Codable {
        case bound
        case unbound
        case unknown
        case degraded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        switch try container.decode(Kind.self, forKey: .kind) {
        case .bound:
            self = .bound(try container.decode(AgentSessionBinding.self, forKey: .binding))
        case .unbound:
            self = .unbound
        case .unknown:
            self = .unknown(
                lastKnownBinding: try container.decodeIfPresent(
                    AgentSessionBinding.self,
                    forKey: .lastKnownBinding
                ),
                detail: try container.decodeIfPresent(String.self, forKey: .detail)
            )
        case .degraded:
            self = .degraded(
                lastKnownBinding: try container.decodeIfPresent(
                    AgentSessionBinding.self,
                    forKey: .lastKnownBinding
                ),
                detail: try container.decode(String.self, forKey: .detail)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .bound(binding):
            try container.encode(Kind.bound, forKey: .kind)
            try container.encode(binding, forKey: .binding)
        case .unbound:
            try container.encode(Kind.unbound, forKey: .kind)
        case let .unknown(lastKnownBinding, detail):
            try container.encode(Kind.unknown, forKey: .kind)
            try container.encodeIfPresent(lastKnownBinding, forKey: .lastKnownBinding)
            try container.encodeIfPresent(detail, forKey: .detail)
        case let .degraded(lastKnownBinding, detail):
            try container.encode(Kind.degraded, forKey: .kind)
            try container.encodeIfPresent(lastKnownBinding, forKey: .lastKnownBinding)
            try container.encode(detail, forKey: .detail)
        }
    }
}

nonisolated enum AgentChildWorkParent: Codable, Equatable, Sendable {
    case session(ProviderSessionIdentity)
    case child(ChildWorkID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case providerSession
        case childWorkID
    }

    private enum Kind: String, Codable {
        case session
        case child
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        switch try container.decode(Kind.self, forKey: .kind) {
        case .session:
            self = .session(
                try container.decode(ProviderSessionIdentity.self, forKey: .providerSession)
            )
        case .child:
            self = .child(try container.decode(ChildWorkID.self, forKey: .childWorkID))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .session(identity):
            try container.encode(Kind.session, forKey: .kind)
            try container.encode(identity, forKey: .providerSession)
        case let .child(id):
            try container.encode(Kind.child, forKey: .kind)
            try container.encode(id, forKey: .childWorkID)
        }
    }
}

nonisolated struct AgentChildWork: Codable, Equatable, Sendable {
    let id: ChildWorkID
    let parent: AgentChildWorkParent
    let title: SnapshotValue<String>
    let state: SnapshotValue<AgentSessionState>
    let activity: SnapshotValue<AgentActivity>
    let children: [AgentChildWork]
    let stateDetail: AgentSessionStateDetail?
    let kind: AgentWorkKind?
    let model: SnapshotValue<AgentModel>?
    let terminalEvent: AgentTerminalEvent?
    let attention: [AgentAttention]?

    var workState: AgentWorkState { .resolve(state, detail: stateDetail) }
    var parentID: String? {
        if case .child(let id) = parent { return id.rawValue }
        return nil
    }

    func containing(_ children: [AgentChildWork]) -> Self {
        Self(id: id, parent: parent, title: title, state: state, activity: activity,
             children: children, stateDetail: stateDetail, kind: kind, model: model,
             terminalEvent: terminalEvent, attention: attention)
    }

    init(
        id: ChildWorkID,
        parent: AgentChildWorkParent,
        title: SnapshotValue<String>,
        state: SnapshotValue<AgentSessionState>,
        activity: SnapshotValue<AgentActivity>,
        children: [AgentChildWork] = [],
        stateDetail: AgentSessionStateDetail? = nil,
        kind: AgentWorkKind? = nil,
        model: SnapshotValue<AgentModel>? = nil,
        terminalEvent: AgentTerminalEvent? = nil,
        attention: [AgentAttention]? = nil
    ) {
        self.id = id
        self.parent = parent
        self.title = title
        self.state = state
        self.activity = activity
        self.children = children
        self.stateDetail = stateDetail
        self.kind = kind
        self.model = model
        self.terminalEvent = terminalEvent
        self.attention = attention
    }
}

nonisolated struct AgentSessionSnapshotItem: Codable, Equatable, Sendable {
    let identity: ProviderSessionIdentity
    let binding: AgentSessionBindingObservation
    let title: SnapshotValue<String>
    let state: SnapshotValue<AgentSessionState>
    let activity: SnapshotValue<AgentActivity>
    let model: SnapshotValue<AgentModel>
    let paths: SnapshotValue<AgentSessionPaths>
    let timing: SnapshotValue<AgentSessionTiming>
    let childWork: [AgentChildWork]
    let stateDetail: AgentSessionStateDetail?
    let liveness: AgentProcessLiveness?
    let observedAt: Date?
    let launchBinding: AgentSessionBinding?
    let appearance: AgentSessionAppearance?
    let attention: [AgentAttention]?
    let childWorkObservation: AgentChildWorkObservation?

    var workState: AgentWorkState { .resolve(state, detail: stateDetail) }

    init(
        identity: ProviderSessionIdentity,
        binding: AgentSessionBindingObservation,
        title: SnapshotValue<String>,
        state: SnapshotValue<AgentSessionState>,
        activity: SnapshotValue<AgentActivity>,
        model: SnapshotValue<AgentModel>,
        paths: SnapshotValue<AgentSessionPaths>,
        timing: SnapshotValue<AgentSessionTiming>,
        childWork: [AgentChildWork] = [],
        stateDetail: AgentSessionStateDetail? = nil,
        liveness: AgentProcessLiveness? = nil,
        observedAt: Date? = nil,
        launchBinding: AgentSessionBinding? = nil,
        appearance: AgentSessionAppearance? = nil,
        attention: [AgentAttention]? = nil,
        childWorkObservation: AgentChildWorkObservation? = nil
    ) {
        self.identity = identity
        self.binding = binding
        self.title = title
        self.state = state
        self.activity = activity
        self.model = model
        self.paths = paths
        self.timing = timing
        self.childWork = childWork
        self.stateDetail = stateDetail
        self.liveness = liveness
        self.observedAt = observedAt
        self.launchBinding = launchBinding
        self.appearance = appearance
        self.attention = attention
        self.childWorkObservation = childWorkObservation
    }
}

nonisolated struct AgentSessionSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: SnapshotSchemaVersion
    let generatedAt: Date
    let workspaces: [CMUXWorkspaceSnapshot]
    let sessions: [AgentSessionSnapshotItem]
    let issues: [AgentSnapshotIssue]?
    let completeness: SnapshotValue<Bool>?

    var isComplete: Bool { completeness?.knownValue == true }

    init(
        schemaVersion: SnapshotSchemaVersion = .current,
        generatedAt: Date,
        workspaces: [CMUXWorkspaceSnapshot],
        sessions: [AgentSessionSnapshotItem],
        issues: [AgentSnapshotIssue]? = nil,
        completeness: SnapshotValue<Bool>? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.workspaces = workspaces
        self.sessions = sessions
        self.issues = issues
        self.completeness = completeness
    }

    func validate() throws {
        guard SnapshotSchemaVersion.supported.contains(schemaVersion) else {
            throw AgentSessionSnapshotValidationError.unsupportedSchemaVersion(schemaVersion.rawValue)
        }
        try validateDate(generatedAt, at: "generatedAt")
        if let completeness { try validateValue(completeness, at: "completeness") }
        for (index, issue) in (issues ?? []).enumerated() {
            try validateIdentity(issue.rawValue, at: "issues[\(index)]")
        }

        var workspaceIDs = Set<WorkspaceID>()
        var surfacesByID: [SurfaceID: WorkspaceID] = [:]

        for (workspaceIndex, workspace) in workspaces.enumerated() {
            let workspacePath = "workspaces[\(workspaceIndex)]"
            try validateIdentity(workspace.id.rawValue, at: "\(workspacePath).id")
            guard workspaceIDs.insert(workspace.id).inserted else {
                throw AgentSessionSnapshotValidationError.duplicateIdentity(workspace.id.rawValue)
            }
            try validateValue(workspace.title, at: "\(workspacePath).title")

            for (surfaceIndex, surface) in workspace.surfaces.enumerated() {
                let surfacePath = "\(workspacePath).surfaces[\(surfaceIndex)]"
                try validateIdentity(surface.id.rawValue, at: "\(surfacePath).id")
                guard surface.workspaceID == workspace.id else {
                    throw AgentSessionSnapshotValidationError.invalidHierarchyReference(
                        path: "\(surfacePath).workspaceID",
                        reference: surface.workspaceID.rawValue
                    )
                }
                guard surfacesByID.updateValue(workspace.id, forKey: surface.id) == nil else {
                    throw AgentSessionSnapshotValidationError.duplicateIdentity(surface.id.rawValue)
                }
                try validateValue(surface.title, at: "\(surfacePath).title")
            }
        }

        var sessionIDs = Set<ProviderSessionIdentity>()
        for (sessionIndex, session) in sessions.enumerated() {
            let sessionPath = "sessions[\(sessionIndex)]"
            try validateIdentity(session.identity.providerID, at: "\(sessionPath).identity.providerID")
            try validateIdentity(session.identity.sessionID, at: "\(sessionPath).identity.sessionID")
            guard sessionIDs.insert(session.identity).inserted else {
                throw AgentSessionSnapshotValidationError.duplicateIdentity(
                    "\(session.identity.providerID):\(session.identity.sessionID)"
                )
            }

            try validateBinding(
                session.binding,
                workspaceIDs: workspaceIDs,
                surfacesByID: surfacesByID,
                at: "\(sessionPath).binding"
            )

            if let error = assess(session, at: sessionPath).firstError { throw error }
        }
    }
}

nonisolated struct AgentSessionObservationAssessment {
    static let maximumNodes = 4096
    static let maximumDepth = 64

    var firstError: (any Error)?
    var sessionStateIsValid = true
    var children: [AgentChildWork] = []
    var invalidChildren: Set<ChildWorkID> = []
    var invalidStates: Set<ChildWorkID> = []
    var unresolvedParents: Set<ChildWorkID> = []
    var omittedChildren = 0
    var hasUncountedChildren = false

    var isValid: Bool { firstError == nil }

    @discardableResult
    mutating func check(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            return true
        } catch {
            if firstError == nil { firstError = error }
            return false
        }
    }
}

extension AgentSessionSnapshot {
    // Both strict validation and the live consumer use these checks. A consumer
    // can retain safe peers/fields while refusing invalid history and ancestry.
    nonisolated func assess(
        _ session: AgentSessionSnapshotItem, at path: String
    ) -> AgentSessionObservationAssessment {
        var result = AgentSessionObservationAssessment()
        result.check { try validateValue(session.title, at: "\(path).title") }
        result.sessionStateIsValid = result.check {
            try validateWorkState(session.state, detail: session.stateDetail, activity: session.activity, at: path)
        }
        result.check {
            if let date = session.observedAt { try validateDate(date, at: "\(path).observedAt") }
            if let launch = session.launchBinding {
                try validateIdentity(launch.workspaceID.rawValue, at: "\(path).launchBinding.workspaceID")
                try validateIdentity(launch.surfaceID.rawValue, at: "\(path).launchBinding.surfaceID")
            }
            try validateActivity(session.activity, at: "\(path).activity")
            try validateModel(session.model, at: "\(path).model")
            try validatePaths(session.paths, at: "\(path).paths")
            try validateTiming(session.timing, state: session.state, detail: session.stateDetail,
                               generatedAt: generatedAt, at: "\(path).timing")
            try validateActivityTiming(activity: session.activity, timing: session.timing, at: path)
        }
        let legacy = assessChildren(session.childWork, session: session.identity, flat: false, at: "\(path).childWork")
        let evidence = session.childWorkObservation.map {
            assessChildren($0.items, session: session.identity, flat: true, at: "\(path).childWorkObservation.items")
        } ?? legacy
        if result.firstError == nil { result.firstError = legacy.firstError ?? evidence.firstError }
        result.children = evidence.children
        result.invalidChildren = evidence.invalidChildren
        result.invalidStates = evidence.invalidStates
        result.unresolvedParents = evidence.unresolvedParents
        result.omittedChildren = evidence.omittedChildren
        result.hasUncountedChildren = evidence.hasUncountedChildren
        if session.childWorkObservation != nil, !legacy.isValid {
            result.invalidChildren.formUnion(evidence.children.map(\.id))
        }
        if let observation = session.childWorkObservation, legacy.isValid {
            // Unrelated errors cannot waive consistency; only unique, valid
            // entries may establish a match against the compatibility view.
            let groups = Dictionary(grouping: evidence.children, by: \.id)
            let byID = groups.compactMapValues { matches -> AgentChildWork? in
                guard matches.count == 1, let child = matches.first,
                      !evidence.invalidChildren.contains(child.id),
                      !evidence.unresolvedParents.contains(child.id) else { return nil }
                return child
            }
            let consistent = result.check {
                guard legacy.children.allSatisfy({ byID[$0.id] == $0.containing([]) }),
                      !observation.legacyProjectionIsLossless
                        || (evidence.isValid && legacy.children.count == observation.items.count) else {
                    throw AgentSessionSnapshotValidationError.inconsistentChildProjection(path: "\(path).childWork")
                }
            }
            if !consistent { result.invalidChildren.formUnion(evidence.children.map(\.id)) }
        }
        return result
    }
}

nonisolated enum AgentSessionSnapshotValidationError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case invalidIdentity(path: String)
    case duplicateIdentity(String)
    case invalidAvailability(path: String)
    case invalidHierarchyReference(path: String, reference: String)
    case invalidTimestampOrder(path: String)
    case timestampAfterSnapshot(path: String)
    case invalidStateTiming(path: String)
    case incompatibleStateActivity(path: String)
    case incompatibleStateDetail(path: String)
    case invalidTimestamp(path: String)
    case observationLimitExceeded(path: String)
    case inconsistentChildProjection(path: String)
}

private extension AgentSessionSnapshot {
    nonisolated func validateDate(_ date: Date, at path: String) throws {
        guard date.timeIntervalSince1970.isFinite else {
            throw AgentSessionSnapshotValidationError.invalidTimestamp(path: path)
        }
        guard date <= generatedAt else {
            throw AgentSessionSnapshotValidationError.timestampAfterSnapshot(path: path)
        }
    }

    nonisolated func validateStateDetail(
        _ detail: AgentSessionStateDetail?, state: SnapshotValue<AgentSessionState>, at path: String
    ) throws {
        if detail != nil, state.availability != .unknown || state.value != nil {
            throw AgentSessionSnapshotValidationError.incompatibleStateDetail(path: "\(path).stateDetail")
        }
    }

    nonisolated func validateIdentity(_ value: String, at path: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentSessionSnapshotValidationError.invalidIdentity(path: path)
        }
    }

    nonisolated func validateValue<Value>(_ snapshotValue: SnapshotValue<Value>, at path: String) throws {
        guard snapshotValue.isValidObservation else {
            throw AgentSessionSnapshotValidationError.invalidAvailability(path: path)
        }
    }

    nonisolated func validateActivity(_ value: SnapshotValue<AgentActivity>, at path: String) throws {
        try validateValue(value, at: path)
        if let lastEventAt = value.value?.lastEventAt, lastEventAt > generatedAt {
            throw AgentSessionSnapshotValidationError.timestampAfterSnapshot(path: "\(path).value.lastEventAt")
        }
    }

    nonisolated func validateBinding(
        _ observation: AgentSessionBindingObservation,
        workspaceIDs: Set<WorkspaceID>,
        surfacesByID: [SurfaceID: WorkspaceID],
        at path: String
    ) throws {
        switch observation {
        case let .bound(binding):
            try validateBindingReference(
                binding,
                workspaceIDs: workspaceIDs,
                surfacesByID: surfacesByID,
                at: "\(path).binding"
            )
        case .unbound:
            break
        case let .unknown(lastKnownBinding, _):
            if let lastKnownBinding {
                try validateBindingReference(
                    lastKnownBinding,
                    workspaceIDs: workspaceIDs,
                    surfacesByID: surfacesByID,
                    at: "\(path).lastKnownBinding"
                )
            }
        case let .degraded(lastKnownBinding, detail):
            guard !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentSessionSnapshotValidationError.invalidAvailability(path: path)
            }
            if let lastKnownBinding {
                try validateBindingReference(
                    lastKnownBinding,
                    workspaceIDs: workspaceIDs,
                    surfacesByID: surfacesByID,
                    at: "\(path).lastKnownBinding"
                )
            }
        }
    }

    nonisolated func validateBindingReference(
        _ binding: AgentSessionBinding,
        workspaceIDs: Set<WorkspaceID>,
        surfacesByID: [SurfaceID: WorkspaceID],
        at path: String
    ) throws {
        guard workspaceIDs.contains(binding.workspaceID) else {
            throw AgentSessionSnapshotValidationError.invalidHierarchyReference(
                path: "\(path).workspaceID",
                reference: binding.workspaceID.rawValue
            )
        }
        guard surfacesByID[binding.surfaceID] == binding.workspaceID else {
            throw AgentSessionSnapshotValidationError.invalidHierarchyReference(
                path: "\(path).surfaceID",
                reference: binding.surfaceID.rawValue
            )
        }
    }

    nonisolated func validateModel(_ value: SnapshotValue<AgentModel>, at path: String) throws {
        try validateValue(value, at: path)
        if let model = value.value {
            try validateIdentity(model.identifier, at: "\(path).value.identifier")
        }
    }

    nonisolated func validatePaths(_ value: SnapshotValue<AgentSessionPaths>, at path: String) throws {
        try validateValue(value, at: path)
        guard let paths = value.value else {
            return
        }

        try validateValue(paths.currentDirectory, at: "\(path).value.currentDirectory")
        if let currentDirectory = paths.currentDirectory.value {
            try validateIdentity(currentDirectory.value, at: "\(path).value.currentDirectory.value.value")
        }

        try validateValue(paths.worktree, at: "\(path).value.worktree")
        if let worktree = paths.worktree.value {
            try validateIdentity(worktree.path.value, at: "\(path).value.worktree.value.path.value")
            try validateValue(worktree.branch, at: "\(path).value.worktree.value.branch")
            if let branch = worktree.branch.value {
                try validateIdentity(branch, at: "\(path).value.worktree.value.branch.value")
            }
        }
    }

    nonisolated func validateTiming(
        _ value: SnapshotValue<AgentSessionTiming>,
        state: SnapshotValue<AgentSessionState>,
        detail: AgentSessionStateDetail?,
        generatedAt: Date,
        at path: String
    ) throws {
        try validateValue(value, at: path)
        guard let timing = value.value else {
            return
        }

        guard timing.startedAt <= timing.updatedAt,
              timing.completedAt.map({ timing.updatedAt <= $0 }) ?? true
        else {
            throw AgentSessionSnapshotValidationError.invalidTimestampOrder(path: path)
        }

        let latestTimestamp = timing.completedAt ?? timing.updatedAt
        guard latestTimestamp <= generatedAt else {
            throw AgentSessionSnapshotValidationError.timestampAfterSnapshot(path: path)
        }

        if value.availability == .known {
            let state = AgentWorkState.resolve(state, detail: detail)
            if state.isTerminal, timing.completedAt == nil {
                throw AgentSessionSnapshotValidationError.invalidStateTiming(path: path)
            }
            if [.queued, .working, .blocked, .idle].contains(state), timing.completedAt != nil {
                throw AgentSessionSnapshotValidationError.invalidStateTiming(path: path)
            }
        }
    }

    nonisolated func validateStateActivity(
        state: SnapshotValue<AgentSessionState>,
        detail: AgentSessionStateDetail?,
        activity: SnapshotValue<AgentActivity>,
        at path: String
    ) throws {
        guard activity.availability == .known,
              AgentWorkState.resolve(state, detail: detail).isTerminal,
              activity.value?.kind == .executing
        else {
            return
        }

        throw AgentSessionSnapshotValidationError.incompatibleStateActivity(
            path: "\(path).activity"
        )
    }

    nonisolated func validateActivityTiming(
        activity: SnapshotValue<AgentActivity>,
        timing: SnapshotValue<AgentSessionTiming>,
        at path: String
    ) throws {
        guard timing.availability == .known,
              let lastEventAt = activity.value?.lastEventAt,
              let knownTiming = timing.value
        else {
            return
        }

        guard lastEventAt >= knownTiming.startedAt,
              knownTiming.completedAt.map({ lastEventAt <= $0 }) ?? true
        else {
            throw AgentSessionSnapshotValidationError.invalidTimestampOrder(
                path: "\(path).activity.value.lastEventAt"
            )
        }
    }

    nonisolated func validateWorkState(
        _ state: SnapshotValue<AgentSessionState>, detail: AgentSessionStateDetail?,
        activity: SnapshotValue<AgentActivity>, at path: String
    ) throws {
        try validateValue(state, at: "\(path).state")
        try validateStateDetail(detail, state: state, at: path)
        try validateStateActivity(state: state, detail: detail, activity: activity, at: path)
    }

    nonisolated func assessChildren(
        _ children: [AgentChildWork], session: ProviderSessionIdentity, flat: Bool, at path: String
    ) -> AgentSessionObservationAssessment {
        struct Frame {
            let children: [AgentChildWork]
            var next = 0
            let parent: AgentChildWorkParent
            let path: String
            let unresolved: Bool
        }
        var result = AgentSessionObservationAssessment()
        var ids: Set<ChildWorkID> = []
        var frames = [Frame(children: children, parent: .session(session), path: path, unresolved: false)]
        while let frame = frames.last, result.children.count < AgentSessionObservationAssessment.maximumNodes {
            guard frame.next < frame.children.count else { frames.removeLast(); continue }
            frames[frames.count - 1].next += 1
            let child = frame.children[frame.next]
            let childPath = "\(frame.path)[\(frame.next)]"
            var valid = result.check {
                try validateIdentity(child.id.rawValue, at: "\(childPath).id")
                guard ids.insert(child.id).inserted else {
                    throw AgentSessionSnapshotValidationError.duplicateIdentity(child.id.rawValue)
                }
            }
            let parentValid = result.check {
                if flat {
                    switch child.parent {
                    case .session(let owner):
                        guard owner == session else {
                            throw AgentSessionSnapshotValidationError.invalidHierarchyReference(
                                path: "\(childPath).parent", reference: String(describing: child.parent))
                        }
                    case .child(let id): try validateIdentity(id.rawValue, at: "\(childPath).parent")
                    }
                } else if child.parent != frame.parent {
                    throw AgentSessionSnapshotValidationError.invalidHierarchyReference(
                        path: "\(childPath).parent", reference: String(describing: child.parent))
                }
            }
            let unresolved = frame.unresolved || !parentValid
            if unresolved { result.unresolvedParents.insert(child.id) }
            valid = parentValid && valid
            if !result.check({ try validateWorkState(child.state, detail: child.stateDetail,
                                                     activity: child.activity, at: childPath) }) {
                result.invalidStates.insert(child.id)
                valid = false
            }
            if !result.check({
                try validateValue(child.title, at: "\(childPath).title")
                if let model = child.model { try validateModel(model, at: "\(childPath).model") }
                try validateActivity(child.activity, at: "\(childPath).activity")
                if flat && !child.children.isEmpty {
                    throw AgentSessionSnapshotValidationError.invalidHierarchyReference(
                        path: "\(childPath).children", reference: "Nested contents in flat observations")
                }
            }) { valid = false }
            if !valid { result.invalidChildren.insert(child.id) }
            result.children.append(child)
            if !child.children.isEmpty {
                if frames.count < AgentSessionObservationAssessment.maximumDepth {
                    frames.append(Frame(children: child.children, parent: .child(child.id),
                                        path: "\(childPath).children", unresolved: unresolved || flat))
                } else {
                    result.omittedChildren += child.children.count
                }
            }
        }
        result.omittedChildren += frames.reduce(0) { $0 + $1.children.count - $1.next }
        if result.omittedChildren > 0 {
            result.hasUncountedChildren = true
            result.check { throw AgentSessionSnapshotValidationError.observationLimitExceeded(path: path) }
        }
        return result
    }
}
