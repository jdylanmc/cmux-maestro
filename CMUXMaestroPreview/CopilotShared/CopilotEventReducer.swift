import Foundation

// Projection from the installed Copilot 1.0.84-4 program schema. This decoder
// deliberately has no keys for prompts, arguments, results, errors, paths or questions.
nonisolated struct CopilotEventProjection: Decodable, Sendable {
    let id: String
    let type: String
    let agentID: String?
    let toolCallID: String?
    let parentAgentID: String?
    let toolName: String?
    let name: String?
    let model: String?
    let requestID: String?
    let success: Bool?
    let cancelled: Bool?
    let shutdownType: String?
    let sessionID: UUID?
    let version: Int?
    let shellID: String?
    let shellExitCode: Int?
    let resolvedByHook: Bool?
    let timestamp: Date?
    let turnID: String?
    let interactionID: String?
    let parentEventID: String?

    private static let knownTypes: Set<String> = [
        "session.start", "session.resume", "session.idle", "session.model_change", "session.shutdown",
        "session.error", "abort", "assistant.turn_start", "assistant.turn_end",
        "tool.execution_start", "tool.execution_complete", "tool.execution_partial_result", "subagent.started",
        "subagent.completed", "subagent.failed", "subagent.configured", "skill.invoked",
        "permission.requested", "permission.completed", "user_input.requested", "user_input.completed",
        "system.notification"
    ]

    var isUnknownWorkLifecycle: Bool {
        type != "tool.execution_partial_result" && !Self.knownTypes.contains(type)
            && ["subagent.", "tool.execution_", "assistant.turn_"].contains(where: { type.hasPrefix($0) })
    }

    private enum Keys: String, CodingKey { case id, type, agentId, data, timestamp, parentId }
    private enum Fields: String, CodingKey {
        case toolCallId, parentId, toolName, agentDisplayName, name, model
        case selectedModel, newModel, currentModel, requestId, success, cancelled
        case shutdownType, sessionId, version, turnId, interactionId, trigger, kind, resolvedByHook
    }
    private enum NotificationFields: String, CodingKey { case type, shellId, exitCode }

    init(from decoder: any Decoder) throws {
        let outer = try decoder.container(keyedBy: Keys.self)
        let rawID = try outer.decode(String.self, forKey: .id)
        id = UUID(uuidString: rawID)?.uuidString ?? rawID
        type = try outer.decode(String.self, forKey: .type)
        agentID = try outer.decodeIfPresent(String.self, forKey: .agentId)
        if let parent = try? outer.decode(String.self, forKey: .parentId), Self.validID(parent) {
            parentEventID = UUID(uuidString: parent)?.uuidString ?? parent
        } else {
            parentEventID = nil
        }
        // Public event timestamps are RFC 3339 strings, not epoch numbers.
        // Bad/missing timing must not discard otherwise valid terminal evidence.
        if let text = try? outer.decode(String.self, forKey: .timestamp), text.utf8.count <= 64 {
            timestamp = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
                ?? (try? Date.ISO8601FormatStyle().parse(text))
        } else {
            timestamp = nil
        }
        guard UUID(uuidString: id) != nil, type.count <= 128,
              agentID == nil || Self.validID(agentID!) else {
            throw Self.invalid(decoder)
        }
        var tool: String?, parent: String?, toolKind: String?, label: String?, selectedModel: String?
        var request: String?, didSucceed: Bool?, wasCancelled: Bool?, shutdown: String?
        var session: UUID?, format: Int?
        var shell: String?, exitCode: Int?
        var hookResolved: Bool?, turn: String?, interaction: String?
        if Self.knownTypes.contains(type) {
            let data = try outer.nestedContainer(keyedBy: Fields.self, forKey: .data)
            switch type {
            case "session.start":
                let value = try data.decode(String.self, forKey: .sessionId)
                guard let parsed = UUID(uuidString: value) else { throw Self.invalid(decoder) }
                session = parsed
                format = try data.decode(Int.self, forKey: .version)
                selectedModel = try data.decodeIfPresent(String.self, forKey: .selectedModel)
            case "session.model_change":
                selectedModel = try data.decode(String.self, forKey: .newModel)
            case "session.shutdown":
                shutdown = try data.decode(String.self, forKey: .shutdownType)
                guard ["routine", "error"].contains(shutdown!) else { throw Self.invalid(decoder) }
                selectedModel = try data.decodeIfPresent(String.self, forKey: .currentModel)
            case "assistant.turn_start", "assistant.turn_end":
                turn = try data.decode(String.self, forKey: .turnId)
                interaction = try data.decodeIfPresent(String.self, forKey: .interactionId)
                selectedModel = try data.decodeIfPresent(String.self, forKey: .model)
            case "tool.execution_start":
                tool = try data.decode(String.self, forKey: .toolCallId)
                toolKind = try data.decode(String.self, forKey: .toolName)
                selectedModel = try data.decodeIfPresent(String.self, forKey: .model)
            case "tool.execution_complete":
                tool = try data.decode(String.self, forKey: .toolCallId)
                didSucceed = try data.decode(Bool.self, forKey: .success)
                turn = try data.decodeIfPresent(String.self, forKey: .turnId)
                interaction = try data.decodeIfPresent(String.self, forKey: .interactionId)
            case "tool.execution_partial_result":
                tool = try data.decodeIfPresent(String.self, forKey: .toolCallId)
                turn = try data.decodeIfPresent(String.self, forKey: .turnId)
                interaction = try data.decodeIfPresent(String.self, forKey: .interactionId)
            case "subagent.started", "subagent.completed", "subagent.failed":
                tool = try data.decode(String.self, forKey: .toolCallId)
                label = try data.decode(String.self, forKey: .agentDisplayName)
                selectedModel = try data.decodeIfPresent(String.self, forKey: .model)
                if type == "subagent.started" {
                    parent = try data.decodeIfPresent(String.self, forKey: .parentId)
                }
                if type == "subagent.completed" {
                    wasCancelled = try data.decodeIfPresent(Bool.self, forKey: .cancelled)
                }
            case "subagent.configured":
                selectedModel = try data.decode(String.self, forKey: .model)
            case "skill.invoked":
                label = try data.decode(String.self, forKey: .name)
                selectedModel = try data.decodeIfPresent(String.self, forKey: .model)
            case "permission.requested", "permission.completed", "user_input.requested", "user_input.completed":
                request = try data.decode(String.self, forKey: .requestId)
                if type == "permission.requested" {
                    hookResolved = try data.decodeIfPresent(Bool.self, forKey: .resolvedByHook)
                }
            case "system.notification":
                let kind = try data.nestedContainer(keyedBy: NotificationFields.self, forKey: .kind)
                let notificationType = try kind.decode(String.self, forKey: .type)
                if ["shell_completed", "shell_detached_completed"].contains(notificationType) {
                    shell = try kind.decode(String.self, forKey: .shellId)
                    exitCode = try kind.decodeIfPresent(Int.self, forKey: .exitCode)
                }
            default: break
            }
        }
        if let interaction {
            guard !interaction.isEmpty, interaction.utf8.count <= 256,
                  !interaction.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw Self.invalid(decoder) }
        }
        for identifier in [tool, parent, request, shell, turn].compactMap({ $0 }) {
            guard Self.validID(identifier) else { throw Self.invalid(decoder) }
        }
        toolCallID = tool
        parentAgentID = parent
        toolName = toolKind.flatMap { Self.safeToolName($0) }
        name = label.map { Self.display($0, fallback: "Unnamed work") }
        model = selectedModel.map { Self.display($0, fallback: "Unknown model") }
        requestID = request
        success = didSucceed
        cancelled = wasCancelled
        shutdownType = shutdown
        sessionID = session
        version = format
        shellID = shell
        shellExitCode = exitCode
        resolvedByHook = hookResolved
        turnID = turn
        interactionID = interaction
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.:/".unicodeScalars.contains($0)
        }
    }

    static func safeToolName(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 100, value.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || [45, 46, 58, 95].contains($0)
        }) else { return nil }
        return value
    }

    private static func display(_ value: String, fallback: String) -> String {
        guard !value.isEmpty, value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return fallback
        }
        return value
    }

    private static func invalid(_ decoder: any Decoder) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid event metadata"))
    }
}

nonisolated struct CopilotReducedState: Equatable, Sendable {
    let state: CopilotWorkState
    let model: String?
    let children: [CopilotChildWork]
    let attention: [AgentAttention]
    let activity: AgentActivity?

    init(
        state: CopilotWorkState = .unknown, model: String? = nil, children: [CopilotChildWork] = [],
        attention: [AgentAttention] = [], activity: AgentActivity? = nil
    ) {
        self.state = state
        self.model = model
        self.children = children
        self.attention = attention
        self.activity = activity
    }
}

// Exact recent tombstones spill into a fixed, deterministic no-false-negative
// filter. A cold match is uncertain, never permission to resurrect old work.
nonisolated struct CopilotReplayGuard: Sendable {
    enum Match { case absent, exact, uncertain }
    private let capacity: Int
    private let wordCount: Int
    private var recent: Set<String> = []
    private var order: [String] = []
    private var cursor = 0
    private var bits: [UInt64] = []
    private(set) var occupiedBits = 0

    init(capacity: Int, wordCount: Int = 16_384) {
        self.capacity = max(1, capacity)
        self.wordCount = max(1, wordCount)
    }

    var retainedCount: Int { recent.count }
    var filterWordCount: Int { bits.count }

    func match(_ key: String) -> Match {
        if recent.contains(key) { return .exact }
        if !bits.isEmpty && positions(key).allSatisfy({ bits[$0 / 64] & (1 << ($0 % 64)) != 0 }) {
            return .uncertain
        }
        return .absent
    }

    @discardableResult
    mutating func remember(_ key: String) -> Bool {
        if match(key) != .absent { return true }
        if recent.count == capacity {
            // Stop before the filter becomes indiscriminate. Never clear old bits
            // or retire an identity whose anti-replay evidence cannot be retained.
            guard occupiedBits < wordCount * 32 else { return false }
            if bits.isEmpty { bits = Array(repeating: 0, count: wordCount) }
            let old = order[cursor]
            for position in positions(old) {
                let mask: UInt64 = 1 << (position % 64)
                if bits[position / 64] & mask == 0 {
                    bits[position / 64] |= mask
                    occupiedBits += 1
                }
            }
            recent.remove(old)
            order[cursor] = key
            cursor = (cursor + 1) % capacity
        } else {
            order.append(key)
        }
        recent.insert(key)
        return true
    }

    private func positions(_ key: String) -> [Int] {
        // Unlike Swift.Hasher this is stable across launches/reconstruction.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        var mixed = hash
        mixed = (mixed ^ (mixed >> 30)) &* 0xbf58476d1ce4e5b9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94d049bb133111eb
        let step = (mixed ^ (mixed >> 31)) | 1
        return (0..<7).map { Int((hash &+ UInt64($0) &* step) % UInt64(wordCount * 64)) }
    }
}

nonisolated struct CopilotEventReducer: Sendable {
    private struct Work: Sendable {
        var id: String
        var parent: String?
        var unresolvedTool: String?
        var kind: CopilotWorkKind
        var name: String
        var state: CopilotWorkState
        var model: String?
        var startedAt: Date?
        var terminalEvent: CopilotTerminalEvent?
        var lifecycle: String?
        var spawnTool: String?
        var turnID: String?
        var interactionID: String?
    }
    private struct Owner: Hashable, Sendable { let agentID: String? }
    private struct Turn: Sendable {
        let id: String
        let interactionID: String?
        let eventID: String
        let startedAt: Date?
        var causalTip: String
        var requiresCausalProof: Bool
    }
    private struct TurnOrigin: Sendable {
        let eventID: String
        let turnID: String
        let interactionID: String?
    }
    private struct Tool: Sendable {
        let agentID: String?
        let name: String?
        let startedAt: Date?
        let turnOrigin: TurnOrigin?
        var executing = true
        var completed = false
    }
    private struct Request: Hashable, Sendable {
        let owner: Owner
        let kind: AgentAttentionKind
        let id: String
    }
    let sessionID: UUID
    let maximumWorkItems: Int
    let maximumRelationships: Int
    let maximumDepth: Int
    private var rootState: CopilotWorkState = .unknown
    private var rootModel: String?
    private var rootStartedAt: Date?
    private var resumedAt: Date?
    private var rootTurnID: String?
    private var rootInteractionID: String?
    private var work: [String: Work] = [:]
    private var order: [String] = []
    private var toolOwners: [String: Tool] = [:]
    private var toolOrder: [String] = []
    private var agentForTool: [String: String] = [:]
    private var pending: [Request: AgentAttention] = [:]
    private var turns: [Owner: Turn] = [:]
    private var outcomes: [Owner: AgentAttention] = [:]
    private var primaryCompletion: AgentAttention?
    private var lastToolActivity: [Owner: AgentActivity] = [:]
    private var replay: CopilotReplayGuard
    private var replayExhausted = false
    private(set) var issues: [CopilotIssue] = []
    private var ended = false
    private var seenLifecycleEvents: CopilotReplayGuard
    // Start, retired-work/tool and resolved-request keys share `replay`.
    // Both ledgers retain bounded exact windows and never clear spilled bits.
    private var unsupportedSession = false

    var canPublishProjection: Bool {
        !unsupportedSession && issues.allSatisfy {
            $0 == .unsupportedFormat || $0 == .readLimitReached || $0 == .ambiguousTurn
        }
    }

    init(
        sessionID: UUID, maximumWorkItems: Int = 256, maximumRelationships: Int = 4096,
        maximumDepth: Int = 16, maximumLifecycleEvents: Int = 65_536,
        maximumReplayFilterWords: Int = 16_384
    ) {
        self.sessionID = sessionID
        self.maximumWorkItems = max(1, maximumWorkItems)
        self.maximumRelationships = max(1, maximumRelationships)
        self.maximumDepth = maximumDepth
        seenLifecycleEvents = CopilotReplayGuard(capacity: maximumLifecycleEvents, wordCount: maximumReplayFilterWords)
        replay = CopilotReplayGuard(capacity: maximumRelationships, wordCount: maximumReplayFilterWords)
    }

    // Retain the input API, but read time must never decide lifecycle acceptance.
    mutating func consume(_ line: Data, observedAt _: Date = Date()) {
        do {
            let event = try JSONDecoder().decode(CopilotEventProjection.self, from: line)
            apply(event)
        } catch {
            addIssue(.malformedData)
        }
    }

    mutating func markMalformed() { addIssue(.malformedData) }
    mutating func markLimited() { addIssue(.readLimitReached) }

    var retentionCounts: (
        work: Int, owners: Int, agents: Int, requests: Int, tombstones: Int, replayWords: Int,
        events: Int, eventReplayWords: Int, turns: Int, outcomes: Int, activities: Int, interactionOwners: Int
    ) {
        (work.count, toolOwners.count, agentForTool.count, pending.count, replay.retainedCount,
         replay.filterWordCount, seenLifecycleEvents.retainedCount, seenLifecycleEvents.filterWordCount,
         turns.count, outcomes.count + (primaryCompletion == nil ? 0 : 1), lastToolActivity.count,
         work.values.filter { $0.interactionID != nil }.count + (rootInteractionID == nil ? 0 : 1))
    }

    mutating func value() -> CopilotReducedState {
        var children: [CopilotChildWork] = []
        for id in order {
            guard let item = work[id] else { continue }
            var parent = item.parent
            if let unresolved = item.unresolvedTool {
                // Kept as an unresolved edge, not silently attached to the root.
                parent = "unresolved-tool:\(unresolved)"
            } else if let candidate = parent {
                var cursor: String? = candidate
                var seen: Set<String> = [id]
                var depth = 0
                while let current = cursor {
                    if seen.contains(current) {
                        parent = "unresolved-cycle:\(candidate)"
                        addIssue(.malformedData)
                        break
                    }
                    guard depth < maximumDepth else {
                        parent = "unresolved-depth:\(candidate)"
                        addIssue(.readLimitReached)
                        break
                    }
                    seen.insert(current)
                    cursor = work[current]?.parent
                    depth += 1
                }
            }
            let attention = attention(for: id)
            let blocked = attention.contains { $0.kind.isBlocking }
            children.append(CopilotChildWork(
                id: id, parentID: parent, kind: item.kind, name: item.name,
                state: blocked && !ended ? .blocked : item.state, model: item.model,
                terminalEvent: item.terminalEvent, attention: attention, activity: activity(for: id)
            ))
        }
        return .init(
            state: pending.keys.contains(where: { $0.owner.agentID == nil }) && !ended ? .blocked : rootState,
            model: rootModel, children: children, attention: attention(for: nil), activity: activity(for: nil)
        )
    }

    private mutating func apply(_ event: CopilotEventProjection) {
        // Source identity/schema validation must not be bypassed by deduplication or limits.
        if event.type == "session.start" {
            guard event.sessionID == sessionID else { addIssue(.identityChanged); return }
            // The installed schema specifies a positive integer, not a closed version enum.
            guard let version = event.version, version > 0 else {
                unsupportedSession = true
                addIssue(.unsupportedFormat)
                return
            }
        }
        if event.type == "tool.execution_partial_result" {
            observeToolCausality(event)
            return
        }
        // An obsolete completion cannot degrade a newer invocation even when
        // the replay ledger can no longer admit new event identities.
        if event.type == "subagent.completed" || event.type == "subagent.failed" {
            guard let tool = event.toolCallID, let id = agentForTool[tool],
                  work[id]?.spawnTool == tool else { return }
        }
        if event.type == "tool.execution_complete", let tool = event.toolCallID {
            guard let invocation = toolOwners[tool] else {
                // Missing ownership cannot mutate another current invocation.
                remember("tool:\(tool)")
                return
            }
            guard invocation.agentID == event.agentID, !invocation.completed else { return }
            if let origin = invocation.turnOrigin {
                guard turnTagsMatch(event, turnID: origin.turnID, interactionID: origin.interactionID) else { return }
            } else if let current = turns[Owner(agentID: event.agentID)] {
                guard turnTagsMatch(event, turnID: current.id, interactionID: current.interactionID) else { return }
            }
        }
        let start = startIdentity(for: event)
        let lifecyclePrefixes = ["session.", "assistant.turn_", "tool.execution_", "subagent.", "skill.",
                                 "permission.", "user_input.", "system.notification", "abort"]
        if lifecyclePrefixes.contains(where: { event.type.hasPrefix($0) }) {
            let eventMatch = seenLifecycleEvents.match(event.id)
            let startMatch = startReplayMatch(for: event)
            if eventMatch == .exact || startMatch == .exact { return }
            if event.type == "tool.execution_start", let tool = event.toolCallID {
                // Delayed ownership for an ended spawn is not fresh activity.
                if let id = agentForTool[tool], let item = work[id],
                   item.spawnTool != tool || Self.terminal(item.state) { return }
                if Self.terminal(work["shell:\(tool)"]?.state ?? .unknown) { return }
            }
            // A cold match may be a fresh start's false positive. Terminal history
            // must fail open, but a possible old A replay cannot change live B.
            if startMatch == .uncertain {
                addIssue(.readLimitReached)
                demoteTerminalForColdStart(event)
                return
            }
            if eventMatch == .uncertain {
                if start != nil { limitLifecycle(event) } else { addIssue(.readLimitReached) }
                return
            }
            guard !replayExhausted, seenLifecycleEvents.remember(event.id) else {
                limitLifecycle(event)
                return
            }
        }
        defer { observeCausalEvent(event) }
        switch event.type {
        case "session.start":
            if let model = event.model { rootModel = model }
        case "session.resume":
            retireInteractions()
            ended = false
            rootState = .unknown
            clearSignals()
            rootStartedAt = event.timestamp
            resumedAt = event.timestamp
            rootTurnID = nil
            retireRequests()
            demoteNonterminalChildren()
        case "session.model_change":
            rootModel = event.model
        case "session.idle":
            if !ended && rootState != .failed && rootState != .cancelled { rootState = .idle }
        case "session.shutdown":
            guard !isStale(event, owner: nil) else { return }
            retireInteractions()
            if event.shutdownType == "error" {
                if rootState != .failed { recordOutcome(.error, owner: nil, event: event) }
                rootState = .failed
            }
            else if rootState != .failed && rootState != .cancelled { rootState = .completed }
            if let model = event.model { rootModel = model }
            ended = true
            turns.removeAll()
            stopTools()
            retireRequests()
            demoteNonterminalChildren()
        case "session.error", "abort":
            let state: CopilotWorkState = event.type == "abort" ? .cancelled : .failed
            if let id = event.agentID {
                guard !isStale(event, owner: id) else { return }
                guard ensureOwner(id, event: event) else { return }
                finish(id, state: state, event: event)
            } else {
                guard !isStale(event, owner: nil),
                      rootState != .failed,
                      rootState != .cancelled || state == .failed else { return }
                rootState = state
                recordOutcome(state == .failed ? .error : .aborted, owner: nil, event: event)
                // A primary-turn abort/error is not evidence that background children ended.
                retireRequests(owner: nil)
                turns.removeValue(forKey: Owner(agentID: nil))
                stopTools(owner: Owner(agentID: nil))
            }
        case "assistant.turn_start":
            guard let turn = event.turnID else { return }
            let key = Self.turnKey(turn, owner: event.agentID, interaction: event.interactionID)
            let reusedRawTurn = replay.match(Self.rawTurnKey(turn, owner: event.agentID)) != .absent
                || (event.interactionID != nil && replay.match(Self.turnKey(turn, owner: event.agentID)) != .absent)
            guard prepareInteraction(event) else { limitLifecycle(event); return }
            if let id = event.agentID {
                if let previous = work[id], !Self.terminal(previous.state) {
                    guard remember(key) else { limitLifecycle(event); return }
                    // Fresh scoped identity wins over an untrusted wall clock.
                    work[id]?.startedAt = event.timestamp
                    work[id]?.terminalEvent = nil
                    work[id]?.turnID = turn
                    if let interaction = event.interactionID { work[id]?.interactionID = interaction }
                    work[id]?.state = .working
                    setModel(event.model, agent: id)
                } else {
                    // A fresh turn attests activity, not the old spawn's name,
                    // parent or tool pairing, even if that row was retained.
                    if !insert(Work(
                        id: id, parent: "unresolved-owner", kind: .unknown,
                        name: "Unknown agent", state: .working, model: event.model,
                        startedAt: event.timestamp, lifecycle: key, turnID: turn,
                        interactionID: event.interactionID
                    ), validatedStart: true) { failAdmission(event); return }
                }
            } else {
                guard remember(key) else { limitLifecycle(event); return }
                ended = false
                rootTurnID = turn
                if let interaction = event.interactionID { rootInteractionID = interaction }
                rootState = .working
                setModel(event.model, agent: nil)
            }
            let owner = Owner(agentID: event.agentID)
            if event.agentID == nil {
                rootStartedAt = event.timestamp
                // A new primary turn bounds outcomes, not background requests or history.
                outcomes.removeAll()
                primaryCompletion = nil
            } else {
                outcomes.removeValue(forKey: owner)
            }
            turns[owner] = Turn(
                id: turn, interactionID: event.interactionID, eventID: event.id,
                startedAt: event.timestamp, causalTip: event.id, requiresCausalProof: reusedRawTurn
            )
            lastToolActivity.removeValue(forKey: owner)
            stopTools(owner: owner)
        case "assistant.turn_end":
            guard let turn = event.turnID else { return }
            let owner = Owner(agentID: event.agentID)
            let activeTurn = turns[owner]
            if let id = event.agentID, work[id]?.state.isTerminal != false { return }
            if let activeTurn {
                guard activeTurn.id == turn else { return }
                if let interaction = event.interactionID {
                    guard interaction == activeTurn.interactionID else { return }
                } else if activeTurn.requiresCausalProof && !isCausallyLinked(event, to: activeTurn) {
                    markTurnUnknown(owner: event.agentID)
                    addIssue(.ambiguousTurn)
                    return
                }
            } else {
                // Missing-start legacy evidence can establish idle, never a primary
                // completion. It cannot be assigned to a known interaction namespace.
                guard event.interactionID == nil, currentInteraction(owner: event.agentID) == nil,
                      replay.match(Self.rawTurnKey(turn, owner: event.agentID)) == .absent else { return }
                let current = event.agentID.flatMap { work[$0]?.turnID } ?? (event.agentID == nil ? rootTurnID : nil)
                guard current == nil || current == turn,
                      !rejectReplay(Self.turnKey(turn, owner: event.agentID)) else { return }
            }
            turns.removeValue(forKey: owner)
            if event.agentID == nil {
                rootTurnID = turn
                remember(Self.turnKey(turn, owner: nil, interaction: activeTurn?.interactionID))
                if !ended && !Self.terminal(rootState) {
                    rootState = .idle
                    if let activeTurn {
                        recordOutcome(.turnFinished, owner: nil,
                                      evidence: completionEvidence(event, startedAt: activeTurn.startedAt))
                    }
                }
            } else if let id = event.agentID, let item = work[id], !Self.terminal(item.state) {
                remember(Self.turnKey(turn, owner: id, interaction: activeTurn?.interactionID))
                work[id]?.turnID = turn
                work[id]?.state = .idle
            } else {
                return
            }
            setModel(event.model, agent: event.agentID)
        case "tool.execution_start":
            guard let tool = event.toolCallID else { return }
            guard ensureOwner(event.agentID, event: event) else { return }
            if toolOwners[tool] == nil {
                if toolOwners.count >= maximumRelationships {
                    guard let retired = toolOrder.first(where: {
                        toolOwners[$0]?.completed == true || toolOwners[$0]?.executing == false
                    }),
                          remember("tool:\(retired)") else {
                        addIssue(.readLimitReached)
                        demoteTerminalForColdStart(event)
                        return
                    }
                    removeTool(retired)
                }
                let currentTurn = turns[Owner(agentID: event.agentID)]
                let origin = currentTurn.flatMap {
                    !$0.requiresCausalProof || isCausallyLinked(event, to: $0)
                        ? TurnOrigin(eventID: $0.eventID, turnID: $0.id, interactionID: $0.interactionID) : nil
                }
                toolOwners[tool] = Tool(
                    agentID: event.agentID, name: event.toolName, startedAt: event.timestamp, turnOrigin: origin
                )
                toolOrder.append(tool)
            }
            guard remember("start-tool:\(tool)") else { limitLifecycle(event); return }
            let owner = Owner(agentID: event.agentID)
            outcomes.removeValue(forKey: owner)
            if let id = event.agentID {
                if work[id]?.state.isTerminal == true {
                    guard removeSpawnJoins(for: id) else { limitLifecycle(event); return }
                    work[id]?.spawnTool = nil
                    work[id]?.turnID = nil
                    turns.removeValue(forKey: owner)
                }
                if work[id]?.startedAt == nil || work[id]?.state.isTerminal == true {
                    work[id]?.startedAt = event.timestamp
                }
                work[id]?.terminalEvent = nil
                work[id]?.state = .working
            } else {
                primaryCompletion = nil
                ended = false
                if rootStartedAt == nil || rootState.isTerminal { rootStartedAt = event.timestamp }
                rootState = .working
            }
            for id in order where work[id]?.unresolvedTool == tool {
                work[id]?.parent = event.agentID
                work[id]?.unresolvedTool = nil
            }
            if let name = event.toolName, ["bash", "powershell", "local_shell"].contains(name) {
                insert(Work(
                    id: "shell:\(tool)", parent: event.agentID, kind: .shell,
                    name: "\(name) invocation", state: .working, model: event.model,
                    startedAt: event.timestamp
                ), validatedStart: true)
            }
            observeToolCausality(event)
        case "tool.execution_complete":
            guard let tool = event.toolCallID else { return }
            guard let invocation = toolOwners[tool] else {
                remember("tool:\(tool)")
                return
            }
            guard invocation.agentID == event.agentID, !invocation.completed else { return }
            let evidence = completionEvidence(event, startedAt: invocation.startedAt)
            observeToolCausality(event)
            toolOwners[tool]?.completed = true
            toolOwners[tool]?.executing = false
            if invocation.executing, let name = invocation.name {
                lastToolActivity[Owner(agentID: invocation.agentID)] = AgentActivity(
                    kind: .idle, summary: "Last completed tool: \(name)", lastEventAt: evidence.timestamp
                )
            }
            if work["shell:\(tool)"] != nil {
                // This is the tool invocation's lifetime, not evidence that a
                // background shell process has exited.
                finish("shell:\(tool)", state: event.success == true ? .completed : .failed,
                       event: event, matchedEvidence: evidence)
            } else if invocation.executing, event.success == false {
                recordOutcome(.error, owner: invocation.agentID, evidence: evidence)
            }
            // Shell joins are fully projected. Keep other completed owners until
            // pressure, so a delayed subagent.started still gets its known parent.
            if remember("tool:\(tool)") {
                toolOwners[tool]?.completed = true
                if work["shell:\(tool)"] != nil { removeTool(tool) }
            }
        case "system.notification":
            if let shell = event.shellID {
                // No argument/result scraping to guess a join from shell IDs
                // to invocation IDs. Only this structured kind establishes exit.
                let id = "shell-session:\(shell)"
                if work[id] == nil {
                    insert(Work(
                        id: id, parent: event.agentID, kind: .shell,
                        name: "Background shell", state: .unknown, model: nil
                    ))
                }
                finish(id, state: event.shellExitCode.map { $0 == 0 ? .completed : .failed } ?? .completed, event: event)
            }
        case "subagent.started":
            guard let tool = event.toolCallID else { return }
            let id = event.agentID ?? tool
            let lifecycle = "subagent:\(tool)"
            guard agentForTool[tool] == nil || agentForTool[tool] == id else {
                addIssue(.malformedData); return
            }
            let owner = toolOwners[tool]
            let parent = event.parentAgentID ?? owner?.agentID
            let unresolved = event.parentAgentID == nil && owner == nil ? tool : nil
            if agentForTool[tool] == nil && !agentForTool.values.contains(id) {
                while agentForTool.count >= maximumRelationships && retireTerminalLeaf(protecting: parent) {}
                guard agentForTool.count < maximumRelationships else {
                    failAdmission(event); return
                }
            }
            if insert(Work(
                id: id, parent: parent, unresolvedTool: unresolved, kind: .subagent,
                name: event.name ?? "Subagent", state: .working, model: event.model,
                startedAt: event.timestamp, lifecycle: lifecycle, spawnTool: tool
            ), validatedStart: true) {
                agentForTool[tool] = id
            } else {
                failAdmission(event)
            }
        case "subagent.completed", "subagent.failed":
            guard let tool = event.toolCallID, let id = agentForTool[tool],
                  let item = work[id], item.spawnTool == tool else { return }
            finish(id, state: event.type == "subagent.failed" ? .failed
                : event.cancelled == true ? .cancelled : .completed, event: event)
        case "subagent.configured":
            if let agent = event.agentID { setModel(event.model, agent: agent) }
        case "skill.invoked":
            insert(Work(
                id: "skill:\(event.id)", parent: event.agentID, kind: .skill,
                name: event.name ?? "Skill", state: .unknown, model: event.model
            ))
        case "permission.requested", "user_input.requested":
            guard let request = event.requestID else { return }
            let kind: AgentAttentionKind = event.type.hasPrefix("permission.") ? .permission : .answer
            let key = Request(owner: Owner(agentID: event.agentID), kind: kind, id: request)
            if event.type == "permission.requested" && event.resolvedByHook == true {
                pending.removeValue(forKey: key)
                remember(Self.requestKey(key))
                return
            }
            guard !ended, !rejectReplay(Self.requestKey(key)),
                  !predatesLifecycle(event, owner: event.agentID) else { return }
            if let id = event.agentID, work[id]?.state.isTerminal == true { return }
            guard ensureOwner(event.agentID, event: event) else { return }
            guard pending[key] != nil || pending.count < maximumRelationships else {
                addIssue(.readLimitReached); return
            }
            if pending[key] == nil { pending[key] = signal(kind, event: event) }
        case "permission.completed", "user_input.completed":
            guard let request = event.requestID else { return }
            let key = Request(owner: Owner(agentID: event.agentID),
                              kind: event.type.hasPrefix("permission.") ? .permission : .answer, id: request)
            pending.removeValue(forKey: key)
            remember(Self.requestKey(key))
        default:
            if event.isUnknownWorkLifecycle {
                addIssue(.unsupportedFormat)
                demoteUncertainLifecycle(affectedBy: event)
            }
        }
    }

    private func startIdentity(for event: CopilotEventProjection) -> String? {
        switch event.type {
        case "subagent.started":
            guard let tool = event.toolCallID else { return nil }
            return "subagent:\(tool)"
        case "tool.execution_start":
            return event.toolCallID.map { "start-tool:\($0)" }
        case "assistant.turn_start":
            return event.turnID.map { Self.turnKey($0, owner: event.agentID, interaction: event.interactionID) }
        default: return nil
        }
    }

    private func startReplayMatch(for event: CopilotEventProjection) -> CopilotReplayGuard.Match {
        guard let start = startIdentity(for: event) else { return .absent }
        var keys = [start]
        if event.type == "tool.execution_start", let tool = event.toolCallID {
            // Keep the legacy shell-row alias even for non-shell names: tool IDs
            // share replay protection across names. Classify every alias before
            // adopting any owner state, model, timestamp or executing activity.
            keys += ["tool:\(tool)", "work:shell:\(tool)"]
        }
        if event.type == "assistant.turn_start", let interaction = event.interactionID,
           interaction != currentInteraction(owner: event.agentID) {
            keys.append(Self.interactionKey(interaction, owner: event.agentID))
        }
        var uncertain = false
        for key in keys {
            switch replay.match(key) {
            case .exact: return .exact
            case .uncertain: uncertain = true
            case .absent: break
            }
            if event.type == "assistant.turn_start", event.interactionID == nil, let turn = event.turnID,
               replay.match(Self.rawTurnKey(turn, owner: event.agentID)) != .absent {
                uncertain = true
            }
        }
        return uncertain ? .uncertain : .absent
    }

    private mutating func demoteTerminalForColdStart(_ event: CopilotEventProjection) {
        if event.type == "assistant.turn_start",
           let active = turns[Owner(agentID: event.agentID)], active.id == event.turnID,
           active.interactionID != event.interactionID {
            turns[Owner(agentID: event.agentID)]?.requiresCausalProof = true
        }
        let id: String?
        switch event.type {
        case "subagent.started":
            id = event.agentID ?? event.toolCallID
        case "assistant.turn_start", "tool.execution_start":
            id = event.agentID
            if id == nil {
                if Self.terminal(rootState) {
                    rootState = .unknown
                    rootTurnID = nil
                    rootStartedAt = nil
                    clearActivity(owner: Owner(agentID: nil))
                }
                return
            }
        default: return
        }
        guard let id, let item = work[id], Self.terminal(item.state) else { return }
        // Unknown is not admission or fresh activity. Clear the obsolete outcome
        // and pairing so old completion cannot hide this row again. Live state,
        // pending requests, ancestry and previously observed models are untouched.
        work[id]?.state = .unknown
        work[id]?.terminalEvent = nil
        work[id]?.startedAt = nil
        work[id]?.spawnTool = nil
        work[id]?.turnID = nil
        clearActivity(owner: Owner(agentID: id))
    }

    private mutating func limitLifecycle(_ event: CopilotEventProjection) {
        addIssue(.readLimitReached)
        if event.type == "assistant.turn_start" || event.type == "assistant.turn_end" {
            markTurnUnknown(owner: event.agentID)
            demoteTerminalForColdStart(event)
            return
        }
        rootState = .unknown
        clearActivities()
        demoteNonterminalChildren()
        if startIdentity(for: event) != nil || event.isUnknownWorkLifecycle || event.type == "session.resume" {
            demoteUncertainLifecycle(affectedBy: event)
        }
    }

    private mutating func failAdmission(_ event: CopilotEventProjection) {
        addIssue(.readLimitReached)
        let id = event.agentID ?? (event.type == "subagent.started" ? event.toolCallID : nil)
        if let id, work[id] != nil { demoteUncertainLifecycle(affectedBy: event) }
    }

    private mutating func demoteUncertainLifecycle(affectedBy event: CopilotEventProjection) {
        var affected: Set<String> = []
        if let id = event.agentID, work[id] != nil { affected.insert(id) }
        if let tool = event.toolCallID {
            if event.type == "subagent.started", event.agentID == nil, work[tool] != nil {
                affected.insert(tool)
            }
            if let id = agentForTool[tool] { affected.insert(id) }
            if work["shell:\(tool)"] != nil { affected.insert("shell:\(tool)") }
        }
        if affected.isEmpty {
            rootState = .unknown
            clearActivities()
            affected = Set(order)
        }
        for id in affected {
            work[id]?.state = .unknown
            work[id]?.terminalEvent = nil
            clearActivity(owner: Owner(agentID: id))
            work[id]?.spawnTool = nil
            work[id]?.turnID = nil
        }
    }

    private mutating func finish(
        _ id: String, state: CopilotWorkState, event: CopilotEventProjection,
        matchedEvidence: CopilotTerminalEvent? = nil
    ) {
        guard let item = work[id] else { return }
        guard matchedEvidence != nil || !isStale(event, owner: id) else { return }
        // Duplicate/late success cannot replace stronger evidence or restart its retention.
        guard item.state != state, item.state != .failed,
              item.state != .cancelled || state == .failed else { return }
        work[id]?.state = state
        let evidence = matchedEvidence ?? completionEvidence(event)
        work[id]?.terminalEvent = evidence
        if state == .failed || state == .cancelled {
            recordOutcome(state == .failed ? .error : .aborted, owner: id, evidence: evidence)
        }
        retireRequests(owner: id)
        turns.removeValue(forKey: Owner(agentID: id))
        stopTools(owner: Owner(agentID: id))
        setModel(event.model, agent: id)
    }

    @discardableResult
    private mutating func insert(_ item: Work, validatedStart: Bool = false) -> Bool {
        var inserted = item
        let enriching = work[item.id].map {
            $0.kind == .unknown && !Self.terminal($0.state) && item.kind == .subagent
        } ?? false
        if let previous = work[item.id], enriching {
            inserted.turnID = previous.turnID
            inserted.interactionID = previous.interactionID
            inserted.startedAt = previous.startedAt ?? item.startedAt
            if inserted.model == nil { inserted.model = previous.model }
        }
        // Start callers already proved all their keys absent before any mutation.
        // Bounded retirement can add colliding bits, but cannot undo that proof.
        if let lifecycle = item.lifecycle, !validatedStart {
            guard !rejectReplay(lifecycle) else { return false }
        } else if item.lifecycle == nil {
            if let previous = work[item.id], Self.terminal(previous.state) { return false }
            if !validatedStart && work[item.id] == nil && rejectReplay("work:\(item.id)") { return false }
        }
        if work[item.id] == nil && work.count >= maximumWorkItems {
            guard retireTerminalLeaf(protecting: item.parent) else {
                addIssue(.readLimitReached); return false
            }
        }
        if let lifecycle = item.lifecycle {
            guard remember(lifecycle) else { return false }
            if work[item.id] != nil {
                guard removeSpawnJoins(for: item.id) else { return false }
                if !enriching {
                    if work[item.id]?.interactionID != item.interactionID,
                       !retireInteraction(owner: item.id) { return false }
                    retireRequests(owner: item.id)
                    outcomes.removeValue(forKey: Owner(agentID: item.id))
                    clearActivity(owner: Owner(agentID: item.id))
                }
            }
        }
        if work[item.id] == nil { order.append(item.id) }
        work[item.id] = inserted
        return true
    }

    private mutating func retireTerminalLeaf(protecting parent: String?) -> Bool {
        // Even a terminal ancestor is needed while a retained descendant (or
        // pending request) refers to it. Unknown work is not completion evidence.
        var protected = Set(work.values.compactMap(\.parent))
        protected.formUnion(pending.keys.compactMap(\.owner.agentID))
        protected.formUnion(outcomes.keys.compactMap(\.agentID))
        protected.formUnion(toolOwners.values.filter(\.executing).compactMap(\.agentID))
        if let parent { protected.insert(parent) }
        guard let id = order.first(where: {
            Self.terminal(work[$0]?.state ?? .unknown) && !protected.contains($0)
        }) else { return false }
        guard retireInteraction(owner: id) else { return false }
        guard remember(work[id]?.lifecycle ?? "work:\(id)") else { return false }
        let tools = agentForTool.filter { $0.value == id }.map(\.key).sorted()
        for tool in tools {
            guard remember("tool:\(tool)") else { return false }
        }
        for tool in tools {
            agentForTool.removeValue(forKey: tool)
            removeTool(tool)
        }
        for tool in toolOrder.filter({ toolOwners[$0]?.agentID == id && toolOwners[$0]?.executing == false }) {
            guard remember("tool:\(tool)") else { return false }
            removeTool(tool)
        }
        clearActivity(owner: Owner(agentID: id))
        outcomes.removeValue(forKey: Owner(agentID: id))
        work.removeValue(forKey: id)
        order.removeAll { $0 == id }
        return true
    }

    private mutating func removeTool(_ tool: String) {
        toolOwners.removeValue(forKey: tool)
        toolOrder.removeAll { $0 == tool }
    }

    private mutating func removeSpawnJoins(for id: String) -> Bool {
        for tool in agentForTool.keys.sorted() where agentForTool[tool] == id {
            guard remember("tool:\(tool)") else { return false }
            agentForTool.removeValue(forKey: tool)
            removeTool(tool)
        }
        return true
    }

    private static func turnKey(_ turn: String, owner: String?, interaction: String? = nil) -> String {
        let owner = owner ?? ""
        if let interaction {
            return "interaction-turn:\(owner.utf8.count):\(owner):\(interaction.utf8.count):\(interaction):\(turn)"
        }
        return "turn:\(owner.utf8.count):\(owner):\(turn)"
    }

    private static func interactionKey(_ interaction: String, owner: String?) -> String {
        let owner = owner ?? ""
        return "retired-interaction:\(owner.utf8.count):\(owner):\(interaction)"
    }

    private static func rawTurnKey(_ turn: String, owner: String?) -> String {
        let owner = owner ?? ""
        return "interaction-raw-turn:\(owner.utf8.count):\(owner):\(turn)"
    }

    private func currentInteraction(owner: String?) -> String? {
        owner.flatMap { work[$0]?.interactionID } ?? (owner == nil ? rootInteractionID : nil)
    }

    private mutating func prepareInteraction(_ event: CopilotEventProjection) -> Bool {
        guard let interaction = event.interactionID, let turn = event.turnID else { return true }
        if let previous = currentInteraction(owner: event.agentID), previous != interaction {
            guard remember(Self.interactionKey(previous, owner: event.agentID)) else { return false }
        }
        return remember(Self.rawTurnKey(turn, owner: event.agentID))
    }

    private mutating func retireInteraction(owner: String?) -> Bool {
        guard let interaction = currentInteraction(owner: owner) else { return true }
        guard remember(Self.interactionKey(interaction, owner: owner)) else { return false }
        if let owner { work[owner]?.interactionID = nil } else { rootInteractionID = nil }
        return true
    }

    private mutating func retireInteractions() {
        _ = retireInteraction(owner: nil)
        for id in order { _ = retireInteraction(owner: id) }
    }

    private func isCausallyLinked(_ event: CopilotEventProjection, to turn: Turn) -> Bool {
        guard let parent = event.parentEventID else { return false }
        return parent == turn.causalTip || parent == turn.eventID
    }

    private func turnTagsMatch(
        _ event: CopilotEventProjection, turnID: String, interactionID: String?
    ) -> Bool {
        (event.turnID == nil || event.turnID == turnID)
            && (event.interactionID == nil || event.interactionID == interactionID)
    }

    private mutating func observeCausalEvent(_ event: CopilotEventProjection) {
        // One tip per active owner, not a transcript graph. Unknown gaps fail
        // closed; ignored payload-bearing events contribute only their envelope.
        guard event.type != "assistant.turn_start", event.type != "assistant.turn_end",
              !event.type.hasPrefix("tool.execution_"), event.toolCallID == nil, event.shellID == nil else { return }
        let owner = Owner(agentID: event.agentID)
        guard let turn = turns[owner], event.id != turn.eventID,
              isCausallyLinked(event, to: turn) else { return }
        turns[owner]?.causalTip = event.id
    }

    private mutating func observeToolCausality(_ event: CopilotEventProjection) {
        // Tool identity outranks a later parent link, including for partial output.
        // Missing/old origin never inherits the current turn through generic fallback.
        guard let id = event.toolCallID, let tool = toolOwners[id],
              tool.agentID == event.agentID, !tool.completed, let origin = tool.turnOrigin else { return }
        let owner = Owner(agentID: tool.agentID)
        guard let current = turns[owner], current.eventID == origin.eventID,
              turnTagsMatch(event, turnID: origin.turnID, interactionID: origin.interactionID) else { return }
        turns[owner]?.causalTip = event.id
    }
    private mutating func markTurnUnknown(owner: String?) {
        if let owner {
            if work[owner]?.state.isTerminal == false { work[owner]?.state = .unknown }
        } else if !rootState.isTerminal {
            rootState = .unknown
        }
    }

    private static func requestKey(_ request: Request) -> String {
        let owner = request.owner.agentID ?? ""
        return "request:\(owner.utf8.count):\(owner):\(request.kind.rawValue):\(request.id)"
    }

    private mutating func retireRequests() {
        for key in pending.keys.sorted(by: { Self.requestKey($0) < Self.requestKey($1) }) {
            remember(Self.requestKey(key))
        }
        pending.removeAll()
    }

    private mutating func retireRequests(owner: String?) {
        for key in pending.keys.sorted(by: { Self.requestKey($0) < Self.requestKey($1) })
            where key.owner.agentID == owner {
            remember(Self.requestKey(key))
            pending.removeValue(forKey: key)
        }
    }

    private mutating func rejectReplay(_ key: String) -> Bool {
        switch replay.match(key) {
        case .absent:
            if replayExhausted { addIssue(.readLimitReached) }
            return replayExhausted
        case .exact: return true
        case .uncertain:
            addIssue(.readLimitReached)
            return true
        }
    }

    @discardableResult
    private mutating func remember(_ key: String) -> Bool {
        guard replay.remember(key) else {
            replayExhausted = true
            addIssue(.readLimitReached)
            return false
        }
        return true
    }

    private mutating func demoteNonterminalChildren() {
        // A resumed owner cannot attest that pre-crash background work is active.
        for id in order where !Self.terminal(work[id]?.state ?? .unknown) {
            work[id]?.state = .unknown
            work[id]?.turnID = nil
        }
    }

    private mutating func setState(_ state: CopilotWorkState, agent: String?) {
        if let agent {
            if let item = work[agent], !Self.terminal(item.state) { work[agent]?.state = state }
        } else {
            rootState = state
        }
    }

    private mutating func setModel(_ model: String?, agent: String?) {
        guard let model else { return }
        if let agent {
            if work[agent] != nil { work[agent]?.model = model }
        } else {
            rootModel = model
        }
    }

    private func signal(_ kind: AgentAttentionKind, event: CopilotEventProjection) -> AgentAttention {
        signal(kind, evidence: completionEvidence(event))
    }

    private func signal(_ kind: AgentAttentionKind, evidence: CopilotTerminalEvent) -> AgentAttention {
        AgentAttention(kind: kind, evidence: .init(source: "copilot.events", eventID: evidence.id),
                       occurredAt: evidence.timestamp)
    }

    private mutating func recordOutcome(_ kind: AgentAttentionKind, owner: String?, event: CopilotEventProjection) {
        recordOutcome(kind, owner: owner, evidence: completionEvidence(event))
    }

    private mutating func recordOutcome(_ kind: AgentAttentionKind, owner: String?, evidence: CopilotTerminalEvent) {
        guard owner == nil || work[owner!] != nil else { return }
        if kind == .turnFinished {
            primaryCompletion = signal(kind, evidence: evidence)
            return
        }
        outcomes[Owner(agentID: owner)] = signal(kind, evidence: evidence)
    }

    private func attention(for owner: String?) -> [AgentAttention] {
        let blocking = pending.filter { $0.key.owner.agentID == owner }.values.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.evidence.eventID.uuidString < $1.evidence.eventID.uuidString
        }
        return blocking + (outcomes[Owner(agentID: owner)].map { [$0] } ?? [])
            + (owner == nil ? primaryCompletion.map { [$0] } ?? [] : [])
    }

    private func activity(for owner: String?) -> AgentActivity? {
        if let id = toolOrder.reversed().first(where: {
            toolOwners[$0]?.agentID == owner && toolOwners[$0]?.executing == true
        }), let tool = toolOwners[id], let name = tool.name {
            return AgentActivity(kind: .executing, summary: "Executing tool: \(name)", lastEventAt: tool.startedAt)
        }
        return lastToolActivity[Owner(agentID: owner)]
    }

    @discardableResult
    private mutating func ensureOwner(_ id: String?, event: CopilotEventProjection) -> Bool {
        guard let id, work[id] == nil else { return true }
        return insert(Work(id: id, parent: "unresolved-owner", kind: .unknown,
                           name: "Agent", state: .unknown, model: nil,
                           lifecycle: "owner:\(event.id)"))
    }

    private func isEarlier(_ time: Date?, than start: Date?) -> Bool {
        guard let time, let start, time.timeIntervalSince1970.isFinite,
              start.timeIntervalSince1970.isFinite else { return false }
        return time < start
    }

    private func completionEvidence(_ event: CopilotEventProjection, startedAt: Date? = nil) -> CopilotTerminalEvent {
        // A uniquely matched completion is authoritative even when its clock is
        // contradictory. Retain identity/state; do not publish a fabricated age.
        CopilotTerminalEvent(id: UUID(uuidString: event.id)!,
                             timestamp: isEarlier(event.timestamp, than: startedAt) ? nil : event.timestamp)
    }

    private func predatesLifecycle(_ event: CopilotEventProjection, owner: String?) -> Bool {
        isEarlier(event.timestamp, than: resumedAt)
            || isEarlier(event.timestamp, than: owner.flatMap { work[$0]?.startedAt } ?? (owner == nil ? rootStartedAt : nil))
    }

    private func isStale(_ event: CopilotEventProjection, owner: String?) -> Bool {
        predatesLifecycle(event, owner: owner)
            || pending.contains { $0.key.owner.agentID == owner && isEarlier(event.timestamp, than: $0.value.occurredAt) }
            || toolOwners.values.contains {
                $0.agentID == owner && $0.executing && isEarlier(event.timestamp, than: $0.startedAt)
            }
    }

    private mutating func stopTools(owner: Owner? = nil) {
        for key in toolOwners.keys where owner == nil || toolOwners[key]?.agentID == owner?.agentID {
            toolOwners[key]?.executing = false
        }
    }

    private mutating func clearActivity(owner: Owner) {
        turns.removeValue(forKey: owner)
        lastToolActivity.removeValue(forKey: owner)
        stopTools(owner: owner)
    }

    private mutating func clearSignals() {
        outcomes.removeAll()
        primaryCompletion = nil
        clearActivities()
    }

    private mutating func clearActivities() {
        turns.removeAll()
        lastToolActivity.removeAll()
        stopTools()
    }

    private mutating func addIssue(_ issue: CopilotIssue) {
        if !issues.contains(issue) { issues.append(issue) }
    }

    private static func terminal(_ state: CopilotWorkState) -> Bool {
        state == .completed || state == .failed || state == .cancelled
    }
}
