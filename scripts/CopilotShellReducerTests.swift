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
            ("independent worker and invocation errors", preservesIndependentFailuresAndMatchingDisplayNames)
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
        print("PASS: compiled production shell decoder/reducer; 10 removal cases and 3 guard scenarios")
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
}
