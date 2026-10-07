import Foundation

@main
nonisolated struct CopilotShellReducerTests {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() {
        do {
            try characterizeStructuredCompletion()
            try preservesExactOwnershipAndStrongerTerminalEvidence()
            try ignoresUnrelatedNotificationsAndRejectsMalformedExitCodes()
            try keepsInvocationFailureSeparateFromBackgroundExit()
            print("PASS: compiled production shell decoder/reducer; 10 exit cases and 3 guard scenarios")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }

    private static func event(
        _ type: String, id: UUID = UUID(), agent: String? = nil,
        timestamp: String = "2026-10-07T12:00:00Z", data: [String: Any]
    ) throws -> Data {
        var envelope: [String: Any] = [
            "id": id.uuidString, "type": type, "timestamp": timestamp, "data": data
        ]
        if let agent { envelope["agentId"] = agent }
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    private static func completion(
        _ type: String, shell: String, code: Int?, id: UUID = UUID(),
        agent: String? = nil, timestamp: String = "2026-10-07T12:00:01Z"
    ) throws -> Data {
        var kind: [String: Any] = ["type": type, "shellId": shell]
        if let code { kind["exitCode"] = code }
        return try event("system.notification", id: id, agent: agent, timestamp: timestamp, data: [
            "kind": kind, "content": "OPAQUE_CONTENT", "arguments": "OPAQUE_ARGUMENTS"
        ])
    }

    private static func shell(_ id: String, in state: CopilotReducedState) throws -> CopilotChildWork {
        guard let child = state.children.first(where: { $0.id == "shell-session:\(id)" }) else {
            throw Failure(description: "Missing exact structured shell row \(id)")
        }
        return child
    }

    private static func characterizeStructuredCompletion() throws {
        let baseline: [(Int?, CopilotWorkState, AgentAttentionKind?)] = [
            (0, .completed, nil), (1, .failed, .error), (137, .failed, .error),
            (143, .failed, .error), (nil, .completed, nil)
        ]
        for type in ["shell_completed", "shell_detached_completed"] {
            for (code, expected, attention) in baseline {
                var reducer = CopilotEventReducer(sessionID: UUID())
                reducer.consume(try event("assistant.turn_start", data: ["turnId": "root-turn"]))
                let identity = UUID()
                let payload = try completion(type, shell: "exact-shell", code: code, id: identity)
                let decoded = try JSONDecoder().decode(CopilotEventProjection.self, from: payload)
                try check(decoded.shellID == "exact-shell" && decoded.shellExitCode == code,
                          "\(type)/\(String(describing: code)): decoded structured identity/code")
                try check(decoded.cancelled == nil, "Numeric exit must not manufacture explicit cancellation metadata")
                reducer.consume(payload)
                let state = reducer.value()
                let child = try shell("exact-shell", in: state)
                try check(child.state == expected, "\(type)/\(String(describing: code)): expected baseline \(expected), got \(child.state)")
                try check(child.kind == .shell && child.name == "Background shell", "Exact shell kind/name")
                try check(child.terminalEvent?.id == identity, "Terminal identity must be the actual notification")
                try check((child.attention?.map(\.kind) ?? []) == (attention.map { [$0] } ?? []), "Exact shell outcome attention")
                if attention != nil {
                    try check(child.attention?.first?.evidence.eventID == identity, "Attention must retain exact notification identity")
                }
                try check(state.state == .working && state.attention.isEmpty, "Individual shell exit must not finish/error the root turn")
                try check(reducer.issues.isEmpty, "Valid notification must not create a decoding issue")
                print("PASS baseline \(type) code=\(code.map(String.init) ?? "missing") state=\(child.state.rawValue)")
            }
        }
    }

    private static func preservesExactOwnershipAndStrongerTerminalEvidence() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        reducer.consume(try event("subagent.started", agent: "worker", data: [
            "toolCallId": "spawn", "agentDisplayName": "Worker"
        ]))
        reducer.consume(try event("assistant.turn_start", agent: "worker", data: ["turnId": "worker-turn"]))
        let identity = UUID()
        let failed = try completion("shell_detached_completed", shell: "owned", code: 1, id: identity, agent: "worker")
        reducer.consume(failed)
        let first = reducer.value()
        reducer.consume(failed)
        reducer.consume(try completion("shell_completed", shell: "owned", code: 0, agent: "worker"))
        let state = reducer.value()
        let child = try shell("owned", in: state)
        try check(child.parentID == "worker" && child.state == .failed, "Exact owner and stronger failure must survive duplicate/late success")
        try check(child.terminalEvent?.id == identity && child.attention?.count == 1, "Duplicate must preserve original outcome identity")
        try check(first == state, "Late weaker completion must not mutate accepted evidence")
        try check(state.children.first { $0.id == "worker" }?.state == .working, "Shell failure must not classify worker task outcome")
    }

    private static func ignoresUnrelatedNotificationsAndRejectsMalformedExitCodes() throws {
        var unrelated = CopilotEventReducer(sessionID: UUID())
        unrelated.consume(try event("system.notification", data: [
            "kind": ["type": "other_notification", "shellId": "unrelated", "exitCode": 143]
        ]))
        try check(unrelated.value().children.isEmpty && unrelated.issues.isEmpty, "Unrelated notification must not create shell work")
        var malformed = CopilotEventReducer(sessionID: UUID())
        malformed.consume(try event("system.notification", data: [
            "kind": ["type": "shell_completed", "shellId": "malformed", "exitCode": "143"]
        ]))
        try check(malformed.value().children.isEmpty && malformed.issues == [.malformedData],
                  "Malformed code must not become a successful or cancelled shell")
    }

    private static func keepsInvocationFailureSeparateFromBackgroundExit() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        reducer.consume(try event("tool.execution_start", data: ["toolCallId": "invocation", "toolName": "bash"]))
        reducer.consume(try event("tool.execution_complete", data: ["toolCallId": "invocation", "success": false]))
        reducer.consume(try completion("shell_completed", shell: "separate-process", code: 0))
        let state = reducer.value()
        let background = try shell("separate-process", in: state)
        try check(state.children.first { $0.id == "shell:invocation" }?.state == .failed, "Invocation failure must remain its own row")
        try check(background.state == .completed, "Structured process outcome must not borrow invocation failure")
        try check(state.children.count == 2, "No guessed invocation/process identity join")
    }
}
