import Foundation

@main
nonisolated struct CopilotShellReducerTests {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() {
        var failures: [String] = []
        let scenarios: [(String, () throws -> Void)] = [
            ("all structured background completions removed", removesStructuredBackgroundCompletions),
            ("replay and reconstruction retain no synthetic shell outcomes", replayCannotRecreateSyntheticRowsOrAttention),
            ("unrelated and malformed notifications", ignoresUnrelatedNotificationsAndRejectsMalformedExitCodes),
            ("independent worker and invocation errors", preservesIndependentFailuresAndMatchingDisplayNames),
            ("real invocation retirement and lifecycle replay", realInvocationPressurePreservesRetirementAndReplayGuards),
            ("retired request placeholder and exact request replay", retiredRequestPlaceholderPreservesFreshRequest),
            ("saturated retired unknown owner", saturatedReplayCannotReattestRetiredUnknownOwner),
            ("128 bounded reconstructed lifecycles", repeatedLifecyclesKeepUnchangedBounds)
        ]
        for (name, test) in scenarios {
            do {
                try test()
                print("PASS: \(name)")
            } catch {
                failures.append("\(name): \(error)")
            }
        }
        if !failures.isEmpty {
            FileHandle.standardError.write(Data(("FAIL: " + failures.joined(separator: "\nFAIL: ") + "\n").utf8))
            exit(1)
        }
        print("PASS: compiled production shell decoder/reducer; 10 removal cases and 7 guard scenarios")
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

    private static func removesStructuredBackgroundCompletions() throws {
        var failures: [String] = []
        for type in ["shell_completed", "shell_detached_completed"] {
            for code in [0, 1, 137, 143, nil] as [Int?] {
                var reducer = CopilotEventReducer(sessionID: UUID())
                reducer.consume(try event("assistant.turn_start", data: ["turnId": "root-turn"]))
                let payload = try completion(type, shell: "exact-shell", code: code)
                let decoded = try JSONDecoder().decode(CopilotEventProjection.self, from: payload)
                try check(decoded.shellID == "exact-shell" && decoded.shellExitCode == code,
                          "\(type)/\(String(describing: code)): decoded structured identity/code")
                try check(decoded.cancelled == nil, "Numeric exit must not manufacture explicit cancellation metadata")
                reducer.consume(payload)
                let state = reducer.value()
                let signals = state.attention + state.children.flatMap { $0.attention ?? [] }
                if !state.children.isEmpty || !signals.isEmpty {
                    failures.append("\(type) code=\(code.map(String.init) ?? "missing"): expected no synthetic row or attention; rows=\(state.children.map(\.id)), signals=\(signals.map(\.kind))")
                } else {
                    print("PASS removal \(type) code=\(code.map(String.init) ?? "missing")")
                }
                try check(state.state == .working, "Removing synthetic shell metadata must not finish the root turn")
                try check(reducer.issues.isEmpty, "Valid notification must not create a decoding issue")
            }
        }
        try check(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private static func replayCannotRecreateSyntheticRowsOrAttention() throws {
        let session = UUID()
        let failed = try completion("shell_detached_completed", shell: "replayed", code: 1)
        let earlier = try completion("shell_completed", shell: "replayed", code: 0, timestamp: "2026-10-07T11:59:00Z")
        let signalCompatible = try completion("shell_completed", shell: "other", code: 143)
        let events = [
            failed, failed, earlier, signalCompatible,
            try event("session.resume", data: [:]), failed, earlier, signalCompatible
        ]
        var first = CopilotEventReducer(sessionID: session)
        var reconstructed = CopilotEventReducer(sessionID: session)
        for payload in events {
            first.consume(payload)
            reconstructed.consume(payload)
        }
        let value = first.value()
        try check(value.children.isEmpty && value.attention.isEmpty,
                  "Repeated, out-of-order and resumed history must not recreate synthetic rows or orphaned attention")
        try check(first.value() == reconstructed.value(), "Reconstruction must preserve removal semantics")
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

    private static func preservesIndependentFailuresAndMatchingDisplayNames() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        reducer.consume(try event("subagent.started", agent: "worker", data: [
            "toolCallId": "spawn", "agentDisplayName": "Background shell"
        ]))
        let workerFailure = UUID()
        reducer.consume(try event("subagent.failed", id: workerFailure, data: [
            "toolCallId": "spawn", "agentDisplayName": "Background shell"
        ]))
        reducer.consume(try event("tool.execution_start", data: ["toolCallId": "invocation", "toolName": "bash"]))
        reducer.consume(try event("tool.execution_complete", data: ["toolCallId": "invocation", "success": false]))
        let before = reducer.value()
        for code in [0, 1, 137, 143, nil] as [Int?] {
            reducer.consume(try completion("shell_completed", shell: "separate-process", code: code, agent: "worker"))
        }
        let state = reducer.value()
        guard let worker = state.children.first(where: { $0.id == "worker" }),
              let invocation = state.children.first(where: { $0.id == "shell:invocation" }) else {
            throw Failure(description: "Independent worker and real invocation rows must remain")
        }
        try check(worker.name == "Background shell" && worker.state == .failed, "Never suppress real worker errors by display name")
        try check(worker.terminalEvent?.id == workerFailure && worker.attention?.first?.kind == .error,
                  "Worker error must retain its own actual failure evidence")
        try check(invocation.kind == .shell && invocation.state == .failed && invocation.attention?.first?.kind == .error,
                  "Never suppress all shell-kind work or real invocation errors")
        try check(state == before, "Background process events must add no row, error, aborted signal or dismissal burden")
    }

    private static func realInvocationPressurePreservesRetirementAndReplayGuards() throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumWorkItems: 1)
        let oldStart = try event("subagent.started", agent: "worker", data: [
            "toolCallId": "old-spawn", "agentDisplayName": "Old worker"
        ])
        let oldFinish = try event("subagent.completed", data: [
            "toolCallId": "old-spawn", "agentDisplayName": "Old worker"
        ])
        reducer.consume(oldStart)
        reducer.consume(oldFinish)
        try check(reducer.value().children.first?.state == .completed, "Establish actual terminal worker before pressure")
        reducer.consume(try event("tool.execution_start", data: ["toolCallId": "pressure", "toolName": "bash"]))
        let retired = reducer.value()
        try check(retired.children.map(\.id) == ["shell:pressure"], "Real invocation admission must actually retire terminal worker")
        reducer.consume(try event("tool.execution_complete", data: ["toolCallId": "pressure", "success": true]))
        reducer.consume(oldStart)
        reducer.consume(oldFinish)
        try check(reducer.value().children.map(\.id) == ["shell:pressure"], "Old lifecycle replay must not recreate retired worker")
        reducer.consume(try event("subagent.started", agent: "worker", data: [
            "toolCallId": "new-spawn", "agentDisplayName": "Fresh worker"
        ]))
        let fresh = reducer.value()
        try check(fresh.children.count == 1 && fresh.children.first?.name == "Fresh worker",
                  "Fresh exact spawn must replace terminal pressure without inheriting old metadata")
        reducer.consume(oldStart)
        reducer.consume(oldFinish)
        try check(reducer.value() == fresh, "Old start/completion must not mutate newly admitted worker")
        try check(reducer.retentionCounts.work == 1 && reducer.issues.isEmpty, "Real pressure must preserve unchanged work bound without degradation")
    }

    private static func retiredRequestPlaceholderPreservesFreshRequest() throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumWorkItems: 1, maximumRelationships: 4)
        for payload in try [
            event("permission.requested", agent: "worker", data: ["requestId": "old"]),
            event("permission.completed", agent: "worker", data: ["requestId": "old"]),
            event("abort", agent: "worker", data: [:]),
            event("assistant.turn_start", data: ["turnId": "next"]),
            event("tool.execution_start", data: ["toolCallId": "retire-worker", "toolName": "bash"]),
            event("tool.execution_complete", data: ["toolCallId": "retire-worker", "success": true])
        ] { reducer.consume(payload) }
        try check(reducer.value().children.map(\.id) == ["shell:retire-worker"] && reducer.retentionCounts.work == 1,
                  "Request placeholder must actually retire under the original one-node bound")
        reducer.consume(try event("permission.requested", agent: "worker", data: ["requestId": "fresh"]))
        let fresh = reducer.value()
        guard let worker = fresh.children.first(where: { $0.id == "worker" }) else {
            throw Failure(description: "Fresh exact request must admit previously retired owner")
        }
        try check(worker.kind == .unknown && worker.state == .blocked && worker.attention?.map(\.kind) == [.permission],
                  "Fresh request must preserve blocking identity without inheriting aborted outcome")
        try check(reducer.issues.isEmpty, "Fresh request must retain original issue guard; actual issues=\(reducer.issues)")
        reducer.consume(try event("permission.requested", agent: "worker", data: ["requestId": "old"]))
        try check(reducer.value().children.first { $0.id == "worker" } == worker,
                  "Old resolved request must not mutate fresh worker; actual=\(reducer.value().children), issues=\(reducer.issues)")
        print("OBSERVATION retired request: original worker guard preserved; full-state-equal=\(reducer.value() == fresh), post-replay issues=\(reducer.issues)")
    }

    private static func saturatedReplayCannotReattestRetiredUnknownOwner() throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumWorkItems: 1,
                                          maximumLifecycleEvents: 16, maximumReplayFilterWords: 1)
        for payload in try [
            event("subagent.started", agent: "child", data: ["toolCallId": "spawn-child", "agentDisplayName": "Synthetic child"]),
            event("assistant.turn_start", agent: "child", data: ["turnId": "0", "interactionId": "A"]),
            event("assistant.turn_end", agent: "child", data: ["turnId": "0"]),
            event("subagent.completed", agent: "child", data: ["toolCallId": "spawn-child", "agentDisplayName": "Synthetic child"]),
            event("assistant.turn_start", agent: "child", data: ["turnId": "0", "interactionId": "B"]),
            event("abort", agent: "child", data: [:]),
            event("assistant.turn_start", data: ["turnId": "root", "interactionId": "root"]),
            event("tool.execution_start", data: ["toolCallId": "pressure", "toolName": "bash"]),
            event("tool.execution_complete", data: ["toolCallId": "pressure", "success": true])
        ] { reducer.consume(payload) }
        try check(reducer.value().children.allSatisfy { $0.id != "child" } && reducer.retentionCounts.work == 1,
                  "Saturation case must actually retire child before replay pressure")
        for _ in 0..<128 {
            reducer.consume(try event("session.model_change", data: ["newModel": "pressure"]))
        }
        for payload in try [
            event("subagent.started", agent: "child", data: ["toolCallId": "new-spawn", "agentDisplayName": "New child"]),
            event("subagent.configured", agent: "child", data: ["model": "synthetic-model", "multiTurn": true]),
            event("assistant.turn_start", agent: "child", data: ["turnId": "0", "interactionId": "new-A"])
        ] { reducer.consume(payload) }
        try check(reducer.value().children.allSatisfy { $0.id != "child" || $0.state == .unknown },
                  "Saturated replay must not reattest retired owner")
        try check(reducer.issues.contains(.readLimitReached) && reducer.retentionCounts.work <= 1
                    && reducer.retentionCounts.eventReplayWords == 1,
                  "Original saturation and one-node/one-word limits must remain enforced")
    }

    private static func repeatedLifecyclesKeepUnchangedBounds() throws {
        let session = UUID()
        var original = CopilotEventReducer(
            sessionID: session, maximumWorkItems: 1, maximumRelationships: 32, maximumLifecycleEvents: 8
        )
        var rebuilt = CopilotEventReducer(
            sessionID: session, maximumWorkItems: 1, maximumRelationships: 32, maximumLifecycleEvents: 8
        )
        for index in 0..<128 {
            let payloads = try [
                event("subagent.started", agent: "worker", data: [
                    "toolCallId": "spawn-\(index)", "agentDisplayName": "Worker", "parentId": "parent"
                ]),
                event("assistant.turn_start", agent: "worker", data: ["turnId": "turn-\(index)"]),
                event("permission.requested", agent: "worker", data: ["requestId": "request-\(index)"]),
                event("subagent.completed", data: ["toolCallId": "spawn-\(index)", "agentDisplayName": "Worker"]),
                event("tool.execution_start", data: ["toolCallId": "retire-\(index)", "toolName": "bash"]),
                event("tool.execution_complete", data: ["toolCallId": "retire-\(index)", "success": true])
            ]
            for payload in payloads { original.consume(payload); rebuilt.consume(payload) }
            try check(original.value().children.allSatisfy { $0.id != "worker" } && original.retentionCounts.work == 1,
                      "Lifecycle \(index) must genuinely retire worker without increasing capacity")
        }
        let fresh = try event("assistant.turn_start", agent: "worker", data: ["turnId": "last-fresh"])
        original.consume(fresh)
        rebuilt.consume(fresh)
        try check(original.value() == rebuilt.value() && original.value().children.first?.id == "worker"
                    && original.value().children.first?.state == .working && original.issues.isEmpty,
                  "128 lifecycle reconstruction must preserve fresh owner and unchanged guard behavior")
        let counts = original.retentionCounts
        try check(counts.work == 1 && counts.agents <= 1 && counts.tombstones <= 32 && counts.events <= 8
                    && counts.replayWords == 16_384 && counts.eventReplayWords == 16_384,
                  "Original work/relationship/lifecycle/replay budgets must not be relaxed")
    }
}
