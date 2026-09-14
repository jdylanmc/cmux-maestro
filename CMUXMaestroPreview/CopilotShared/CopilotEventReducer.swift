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

    private static let knownTypes: Set<String> = [
        "session.start", "session.resume", "session.idle", "session.model_change", "session.shutdown",
        "session.error", "abort", "assistant.turn_start", "assistant.turn_end",
        "tool.execution_start", "tool.execution_complete", "subagent.started",
        "subagent.completed", "subagent.failed", "subagent.configured", "skill.invoked",
        "permission.requested", "permission.completed", "user_input.requested", "user_input.completed",
        "system.notification"
    ]

    var isUnknownWorkLifecycle: Bool {
        type != "tool.execution_partial_result" && !Self.knownTypes.contains(type)
            && ["subagent.", "tool.execution_", "assistant.turn_"].contains(where: { type.hasPrefix($0) })
    }

    private enum Keys: String, CodingKey { case id, type, agentId, data, timestamp }
    private enum Fields: String, CodingKey {
        case toolCallId, parentId, toolName, agentDisplayName, name, model
        case selectedModel, newModel, currentModel, requestId, success, cancelled
        case shutdownType, sessionId, version, turnId, trigger, kind, resolvedByHook
    }
    private enum NotificationFields: String, CodingKey { case type, shellId, exitCode }

    init(from decoder: any Decoder) throws {
        let outer = try decoder.container(keyedBy: Keys.self)
        let rawID = try outer.decode(String.self, forKey: .id)
        id = UUID(uuidString: rawID)?.uuidString ?? rawID
        type = try outer.decode(String.self, forKey: .type)
        agentID = try outer.decodeIfPresent(String.self, forKey: .agentId)
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
        var hookResolved: Bool?, turn: String?
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
                selectedModel = try data.decodeIfPresent(String.self, forKey: .model)
            case "tool.execution_start":
                tool = try data.decode(String.self, forKey: .toolCallId)
                toolKind = try data.decode(String.self, forKey: .toolName)
                selectedModel = try data.decodeIfPresent(String.self, forKey: .model)
            case "tool.execution_complete":
                tool = try data.decode(String.self, forKey: .toolCallId)
                didSucceed = try data.decode(Bool.self, forKey: .success)
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
        for identifier in [tool, parent, request, shell, turn].compactMap({ $0 }) {
            guard Self.validID(identifier) else { throw Self.invalid(decoder) }
        }
        toolCallID = tool
        parentAgentID = parent
        toolName = toolKind
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
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.:/".unicodeScalars.contains($0)
        }
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

    init(state: CopilotWorkState = .unknown, model: String? = nil, children: [CopilotChildWork] = []) {
        self.state = state
        self.model = model
        self.children = children
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
    }
    private struct Owner: Sendable { let agentID: String? }
    private struct Tool: Sendable {
        let agentID: String?
        var completed = false
    }
    let sessionID: UUID
    let maximumWorkItems: Int
    let maximumRelationships: Int
    let maximumDepth: Int
    private var rootState: CopilotWorkState = .unknown
    private var rootModel: String?
    private var rootTurnID: String?
    private var work: [String: Work] = [:]
    private var order: [String] = []
    private var toolOwners: [String: Tool] = [:]
    private var toolOrder: [String] = []
    private var agentForTool: [String: String] = [:]
    private var pending: [String: Owner] = [:]
    private var replay: CopilotReplayGuard
    private var replayExhausted = false
    private(set) var issues: [CopilotIssue] = []
    private var ended = false
    private var seenLifecycleEvents: CopilotReplayGuard
    // Start, retired-work/tool and resolved-request keys share `replay`.
    // Both ledgers retain bounded exact windows and never clear spilled bits.
    private var unsupportedSession = false

    var canPublishProjection: Bool {
        !unsupportedSession && issues.allSatisfy { $0 == .unsupportedFormat || $0 == .readLimitReached }
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

    mutating func consume(_ line: Data) {
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
        events: Int, eventReplayWords: Int
    ) {
        (work.count, toolOwners.count, agentForTool.count, pending.count, replay.retainedCount,
         replay.filterWordCount, seenLifecycleEvents.retainedCount, seenLifecycleEvents.filterWordCount)
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
            let blocked = pending.values.contains { $0.agentID == id }
            children.append(CopilotChildWork(
                id: id, parentID: parent, kind: item.kind, name: item.name,
                state: blocked && !ended ? .blocked : item.state, model: item.model,
                terminalEvent: item.terminalEvent
            ))
        }
        return .init(
            state: pending.values.contains(where: { $0.agentID == nil }) && !ended ? .blocked : rootState,
            model: rootModel, children: children
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
        if event.type == "tool.execution_partial_result" { return }
        // An obsolete completion cannot degrade a newer invocation even when
        // the replay ledger can no longer admit new event identities.
        if event.type == "subagent.completed" || event.type == "subagent.failed" {
            guard let tool = event.toolCallID, let id = agentForTool[tool],
                  work[id]?.spawnTool == tool else { return }
        }
        if event.type == "assistant.turn_end" {
            let current: String?
            if let id = event.agentID {
                guard let item = work[id], !Self.terminal(item.state) else { return }
                current = item.turnID
            } else {
                current = rootTurnID
            }
            if let current, current != event.turnID { return }
            if current == nil, let turn = event.turnID, rejectReplay(Self.turnKey(turn, owner: event.agentID)) {
                return
            }
        }
        let start = startIdentity(for: event)
        let lifecyclePrefixes = ["session.", "assistant.turn_", "tool.execution_", "subagent.", "skill.",
                                 "permission.", "user_input.", "system.notification", "abort"]
        if lifecyclePrefixes.contains(where: { event.type.hasPrefix($0) }) {
            let eventMatch = seenLifecycleEvents.match(event.id)
            let startMatch = start.map { replay.match($0) } ?? .absent
            if eventMatch == .exact || startMatch == .exact { return }
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
        switch event.type {
        case "session.start":
            if let model = event.model { rootModel = model }
        case "session.resume":
            ended = false
            rootState = .unknown
            rootTurnID = nil
            retireRequests()
            demoteNonterminalChildren()
        case "session.model_change":
            rootModel = event.model
        case "session.idle":
            if !ended && rootState != .failed && rootState != .cancelled { rootState = .idle }
        case "session.shutdown":
            rootState = event.shutdownType == "error" ? .failed : .completed
            if let model = event.model { rootModel = model }
            ended = true
            retireRequests()
            demoteNonterminalChildren()
        case "session.error", "abort":
            let state: CopilotWorkState = event.type == "abort" ? .cancelled : .failed
            if let id = event.agentID {
                finish(id, state: state, event: event)
            } else {
                rootState = state
                retireRequests()
                demoteNonterminalChildren()
            }
        case "assistant.turn_start":
            guard let turn = event.turnID else { return }
            let key = Self.turnKey(turn, owner: event.agentID)
            guard !rejectReplay(key) else { return }
            if let id = event.agentID {
                if let previous = work[id], !Self.terminal(previous.state) {
                    guard remember(key) else { limitLifecycle(event); return }
                    // Fresh scoped identity wins over an untrusted wall clock.
                    work[id]?.startedAt = event.timestamp
                    work[id]?.terminalEvent = nil
                    work[id]?.turnID = turn
                    work[id]?.state = .working
                    setModel(event.model, agent: id)
                } else {
                    // A fresh turn attests activity, not the old spawn's name,
                    // parent or tool pairing, even if that row was retained.
                    if !insert(Work(
                        id: id, parent: "unresolved-owner", kind: .unknown,
                        name: "Unknown agent", state: .working, model: event.model,
                        startedAt: event.timestamp, lifecycle: key, turnID: turn
                    )) { failAdmission(event) }
                }
            } else {
                guard remember(key) else { limitLifecycle(event); return }
                ended = false
                rootTurnID = turn
                rootState = .working
                setModel(event.model, agent: nil)
            }
        case "assistant.turn_end":
            guard let turn = event.turnID else { return }
            if event.agentID == nil {
                guard rootTurnID == nil || rootTurnID == turn else { return }
                if rootTurnID == nil && rejectReplay(Self.turnKey(turn, owner: nil)) { return }
                remember(Self.turnKey(turn, owner: nil))
                rootTurnID = turn
                if !ended && !Self.terminal(rootState) { rootState = .idle }
            } else if let id = event.agentID, let item = work[id], !Self.terminal(item.state) {
                guard item.turnID == nil || item.turnID == turn else { return }
                if item.turnID == nil && rejectReplay(Self.turnKey(turn, owner: id)) { return }
                remember(Self.turnKey(turn, owner: id))
                work[id]?.turnID = turn
                work[id]?.state = .idle
            } else {
                return
            }
            setModel(event.model, agent: event.agentID)
        case "tool.execution_start":
            guard let tool = event.toolCallID else { return }
            guard !rejectReplay("tool:\(tool)"),
                  !rejectReplay("work:shell:\(tool)"),
                  !Self.terminal(work["shell:\(tool)"]?.state ?? .unknown) else { return }
            if toolOwners[tool] == nil {
                if toolOwners.count >= maximumRelationships {
                    guard let retired = toolOrder.first(where: { toolOwners[$0]?.completed == true }),
                          remember("tool:\(retired)") else {
                        addIssue(.readLimitReached); return
                    }
                    removeTool(retired)
                }
                toolOwners[tool] = Tool(agentID: event.agentID)
                toolOrder.append(tool)
            }
            guard remember("start-tool:\(tool)") else { limitLifecycle(event); return }
            for id in order where work[id]?.unresolvedTool == tool {
                work[id]?.parent = event.agentID
                work[id]?.unresolvedTool = nil
            }
            if let name = event.toolName, ["bash", "powershell", "local_shell"].contains(name) {
                insert(Work(
                    id: "shell:\(tool)", parent: event.agentID, kind: .shell,
                    name: "\(name) invocation", state: .working, model: event.model,
                    startedAt: event.timestamp
                ))
            }
        case "tool.execution_complete":
            guard let tool = event.toolCallID else { return }
            if work["shell:\(tool)"] != nil {
                // This is the tool invocation's lifetime, not evidence that a
                // background shell process has exited.
                finish("shell:\(tool)", state: event.success == true ? .completed : .failed, event: event)
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
            guard !rejectReplay(lifecycle) else { return }
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
            )) {
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
            guard !ended, let request = event.requestID else { return }
            let key = (event.type.hasPrefix("permission.") ? "permission:" : "input:") + request
            guard !rejectReplay("request:\(key)") else { return }
            if let agent = event.agentID {
                guard !Self.terminal(work[agent]?.state ?? .unknown) else { return }
            }
            if event.type == "permission.requested" && event.resolvedByHook == true {
                pending.removeValue(forKey: key)
                remember("request:\(key)")
                return
            }
            guard pending[key] != nil || pending.count < maximumRelationships else {
                addIssue(.readLimitReached); return
            }
            pending[key] = Owner(agentID: event.agentID)
        case "permission.completed", "user_input.completed":
            guard let request = event.requestID else { return }
            let key = (event.type.hasPrefix("permission.") ? "permission:" : "input:") + request
            pending.removeValue(forKey: key)
            remember("request:\(key)")
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
            return event.turnID.map { Self.turnKey($0, owner: event.agentID) }
        default: return nil
        }
    }

    private mutating func demoteTerminalForColdStart(_ event: CopilotEventProjection) {
        let id: String?
        switch event.type {
        case "subagent.started":
            id = event.agentID ?? event.toolCallID
        case "assistant.turn_start":
            id = event.agentID
            if id == nil {
                if Self.terminal(rootState) {
                    rootState = .unknown
                    rootTurnID = nil
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
    }

    private mutating func limitLifecycle(_ event: CopilotEventProjection) {
        addIssue(.readLimitReached)
        rootState = .unknown
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
            affected = Set(order)
        }
        for id in affected {
            work[id]?.state = .unknown
            work[id]?.terminalEvent = nil
            work[id]?.turnID = nil
        }
    }

    private mutating func finish(_ id: String, state: CopilotWorkState, event: CopilotEventProjection) {
        guard let item = work[id] else { return }
        if let start = item.startedAt, let time = event.timestamp, time < start { return }
        // Duplicate/late success cannot replace stronger evidence or restart its retention.
        guard item.state != state, item.state != .failed,
              item.state != .cancelled || state == .failed else { return }
        work[id]?.state = state
        work[id]?.terminalEvent = CopilotTerminalEvent(id: UUID(uuidString: event.id)!, timestamp: event.timestamp)
        retireRequests(owner: id)
        setModel(event.model, agent: id)
    }

    @discardableResult
    private mutating func insert(_ item: Work) -> Bool {
        var inserted = item
        if let previous = work[item.id], previous.kind == .unknown,
           previous.state == .working || previous.state == .idle, item.kind == .subagent {
            inserted.turnID = previous.turnID
            if inserted.model == nil { inserted.model = previous.model }
        }
        if let lifecycle = item.lifecycle {
            guard !rejectReplay(lifecycle) else { return false }
        } else {
            if let previous = work[item.id], Self.terminal(previous.state) { return false }
            if work[item.id] == nil && rejectReplay("work:\(item.id)") { return false }
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
                if Self.terminal(work[item.id]?.state ?? .unknown) { retireRequests(owner: item.id) }
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
        protected.formUnion(pending.values.compactMap(\.agentID))
        protected.formUnion(toolOwners.values.filter { !$0.completed }.compactMap(\.agentID))
        if let parent { protected.insert(parent) }
        guard let id = order.first(where: {
            Self.terminal(work[$0]?.state ?? .unknown) && !protected.contains($0)
        }) else { return false }
        guard remember(work[id]?.lifecycle ?? "work:\(id)") else { return false }
        let tools = agentForTool.filter { $0.value == id }.map(\.key).sorted()
        for tool in tools {
            guard remember("tool:\(tool)") else { return false }
        }
        for tool in tools {
            agentForTool.removeValue(forKey: tool)
            removeTool(tool)
        }
        for tool in toolOrder.filter({ toolOwners[$0]?.agentID == id && toolOwners[$0]?.completed == true }) {
            removeTool(tool)
        }
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

    private static func turnKey(_ turn: String, owner: String?) -> String {
        let owner = owner ?? ""
        return "turn:\(owner.utf8.count):\(owner):\(turn)"
    }

    private mutating func retireRequests() {
        for key in pending.keys.sorted() { remember("request:\(key)") }
        pending.removeAll()
    }

    private mutating func retireRequests(owner: String?) {
        for key in pending.keys.sorted() where pending[key]?.agentID == owner {
            remember("request:\(key)")
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

    private mutating func addIssue(_ issue: CopilotIssue) {
        if !issues.contains(issue) { issues.append(issue) }
    }

    private static func terminal(_ state: CopilotWorkState) -> Bool {
        state == .completed || state == .failed || state == .cancelled
    }
}
