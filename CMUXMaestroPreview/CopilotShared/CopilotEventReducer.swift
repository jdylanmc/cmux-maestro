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

    private enum Keys: String, CodingKey { case id, type, agentId, data }
    private enum Fields: String, CodingKey {
        case toolCallId, parentId, toolName, agentDisplayName, name, model
        case selectedModel, newModel, currentModel, requestId, success, cancelled
        case shutdownType, sessionId, version, turnId, trigger, kind, resolvedByHook
    }
    private enum NotificationFields: String, CodingKey { case type, shellId, exitCode }

    init(from decoder: any Decoder) throws {
        let outer = try decoder.container(keyedBy: Keys.self)
        id = try outer.decode(String.self, forKey: .id)
        type = try outer.decode(String.self, forKey: .type)
        agentID = try outer.decodeIfPresent(String.self, forKey: .agentId)
        guard UUID(uuidString: id) != nil, type.count <= 128,
              agentID == nil || Self.validID(agentID!) else {
            throw Self.invalid(decoder)
        }
        var tool: String?, parent: String?, toolKind: String?, label: String?, selectedModel: String?
        var request: String?, didSucceed: Bool?, wasCancelled: Bool?, shutdown: String?
        var session: UUID?, format: Int?
        var shell: String?, exitCode: Int?
        var hookResolved: Bool?
        let known: Set<String> = [
            "session.start", "session.resume", "session.idle", "session.model_change", "session.shutdown",
            "session.error", "abort", "assistant.turn_start", "assistant.turn_end",
            "tool.execution_start", "tool.execution_complete", "subagent.started",
            "subagent.completed", "subagent.failed", "subagent.configured", "skill.invoked",
            "permission.requested", "permission.completed", "user_input.requested", "user_input.completed",
            "system.notification"
        ]
        if known.contains(type) {
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
                _ = try data.decode(String.self, forKey: .turnId)
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
        for identifier in [tool, parent, request, shell].compactMap({ $0 }) {
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

nonisolated struct CopilotEventReducer: Sendable {
    private struct Work: Sendable {
        var id: String
        var parent: String?
        var unresolvedTool: String?
        var kind: CopilotWorkKind
        var name: String
        var state: CopilotWorkState
        var model: String?
    }
    private struct Owner: Sendable { let agentID: String? }
    let sessionID: UUID
    let maximumWorkItems: Int
    let maximumRelationships: Int
    let maximumDepth: Int
    private var rootState: CopilotWorkState = .unknown
    private var rootModel: String?
    private var work: [String: Work] = [:]
    private var order: [String] = []
    private var toolOwners: [String: Owner] = [:]
    private var agentForTool: [String: String] = [:]
    private var pending: [String: Owner] = [:]
    private(set) var issues: [CopilotIssue] = []
    private var ended = false

    init(sessionID: UUID, maximumWorkItems: Int = 256, maximumRelationships: Int = 4096, maximumDepth: Int = 16) {
        self.sessionID = sessionID
        self.maximumWorkItems = maximumWorkItems
        self.maximumRelationships = maximumRelationships
        self.maximumDepth = maximumDepth
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
                state: blocked && !ended ? .blocked : item.state, model: item.model
            ))
        }
        return .init(
            state: pending.values.contains(where: { $0.agentID == nil }) && !ended ? .blocked : rootState,
            model: rootModel, children: children
        )
    }

    private mutating func apply(_ event: CopilotEventProjection) {
        switch event.type {
        case "session.start":
            guard event.sessionID == sessionID else { addIssue(.identityChanged); return }
            // The installed schema specifies a positive integer, not a closed version enum.
            guard let version = event.version, version > 0 else { addIssue(.unsupportedFormat); return }
            if let model = event.model { rootModel = model }
        case "session.resume":
            ended = false
            rootState = .unknown
            pending.removeAll()
            demoteNonterminalChildren()
        case "session.model_change":
            rootModel = event.model
        case "session.idle":
            if !ended && rootState != .failed && rootState != .cancelled { rootState = .idle }
        case "session.shutdown":
            rootState = event.shutdownType == "error" ? .failed : .completed
            if let model = event.model { rootModel = model }
            ended = true
            pending.removeAll()
            demoteNonterminalChildren()
        case "session.error", "abort":
            setState(event.type == "abort" ? .cancelled : .failed, agent: event.agentID)
            pending = pending.filter { $0.value.agentID != event.agentID }
        case "assistant.turn_start":
            if event.agentID == nil { ended = false }
            setState(.working, agent: event.agentID)
            setModel(event.model, agent: event.agentID)
        case "assistant.turn_end":
            if event.agentID == nil {
                if !ended && !Self.terminal(rootState) { rootState = .idle }
            } else if let id = event.agentID, let item = work[id], !Self.terminal(item.state) {
                work[id]?.state = .idle
            }
            setModel(event.model, agent: event.agentID)
        case "tool.execution_start":
            guard let tool = event.toolCallID else { return }
            if toolOwners[tool] == nil {
                guard toolOwners.count < maximumRelationships else { addIssue(.readLimitReached); return }
                toolOwners[tool] = Owner(agentID: event.agentID)
            }
            for id in order where work[id]?.unresolvedTool == tool {
                work[id]?.parent = event.agentID
                work[id]?.unresolvedTool = nil
            }
            if let name = event.toolName, ["bash", "powershell", "local_shell"].contains(name) {
                insert(Work(
                    id: "shell:\(tool)", parent: event.agentID, kind: .shell,
                    name: "\(name) invocation", state: .working, model: event.model
                ))
            }
        case "tool.execution_complete":
            if let tool = event.toolCallID, work["shell:\(tool)"] != nil {
                // This is the tool invocation's lifetime, not evidence that a
                // background shell process has exited.
                work["shell:\(tool)"]?.state = event.success == true ? .completed : .failed
            }
        case "system.notification":
            if let shell = event.shellID {
                // No argument/result scraping to guess a join from shell IDs
                // to invocation IDs. Only this structured kind establishes exit.
                insert(Work(
                    id: "shell-session:\(shell)", parent: event.agentID, kind: .shell,
                    name: "Background shell", state: event.shellExitCode.map { $0 == 0 ? .completed : .failed } ?? .completed,
                    model: nil
                ))
            }
        case "subagent.started":
            guard let tool = event.toolCallID else { return }
            let id = event.agentID ?? tool
            let owner = toolOwners[tool]
            let parent = event.parentAgentID ?? owner?.agentID
            let unresolved = event.parentAgentID == nil && owner == nil ? tool : nil
            guard agentForTool[tool] != nil || agentForTool.count < maximumRelationships else {
                addIssue(.readLimitReached); return
            }
            agentForTool[tool] = id
            insert(Work(
                id: id, parent: parent, unresolvedTool: unresolved, kind: .subagent,
                name: event.name ?? "Subagent", state: .working, model: event.model
            ))
        case "subagent.completed", "subagent.failed":
            guard let tool = event.toolCallID, let id = agentForTool[tool], let item = work[id] else { return }
            if event.type == "subagent.failed" {
                work[id]?.state = .failed
            } else if event.cancelled == true {
                if item.state != .failed { work[id]?.state = .cancelled }
            } else if item.state != .failed && item.state != .cancelled {
                work[id]?.state = .completed
            }
            pending = pending.filter { $0.value.agentID != id }
            setModel(event.model, agent: id)
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
            if event.type == "permission.requested" && event.resolvedByHook == true {
                pending.removeValue(forKey: key)
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
        default: break
        }
    }

    private mutating func insert(_ item: Work) {
        guard work[item.id] != nil || work.count < maximumWorkItems else {
            addIssue(.readLimitReached); return
        }
        if work[item.id] == nil { order.append(item.id) }
        work[item.id] = item
    }

    private mutating func demoteNonterminalChildren() {
        // A resumed owner cannot attest that pre-crash background work is active.
        for id in order where !Self.terminal(work[id]?.state ?? .unknown) {
            work[id]?.state = .unknown
        }
    }

    private mutating func setState(_ state: CopilotWorkState, agent: String?) {
        if let agent {
            if work[agent] != nil { work[agent]?.state = state }
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
