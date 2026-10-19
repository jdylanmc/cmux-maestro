import Foundation
import Testing

/// #78 background processes and #75 listeners on the agent hover (ADR 0026).
@MainActor
struct SidebarProcessObservationTests {
    private let fixtures = SidebarTreeFixtures()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let nodeID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!

    private func node(generation: Int = 2, session: UUID? = nil) -> SidebarOrchestrationNode {
        .init(
            id: nodeID, runId: fixtures.workspaceB, parentId: nil, role: "worker", label: "Synthetic agent",
            workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceA, generation: generation,
            phase: "turn-running", availability: "busy", copilotSessionId: session ?? fixtures.sessionID,
            executionMode: .interactive, createdAt: now, updatedAt: now
        )
    }

    /// Microseconds, like the controller's `isoformat()`.
    private func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date).replacingOccurrences(of: "Z", with: ".000007Z")
    }

    /// The shape `process-observe` writes, with synthetic identities.
    private func file(state: String = "owned-current", observedAt: Date? = nil, generation: Int = 2,
                      session: UUID? = nil, processes: String? = nil, omitted: Int = 0) -> Data {
        let observed = stamp(observedAt ?? now)
        let defaultProcesses = """
        {"pid":4242,"startMicros":1799999990000007,"name":"python3.12","group":"separate","state":"owned-current",
         "listeners":[{"protocol":"tcp","address":"127.0.0.1","port":5173,"scope":"loopback"},
                      {"protocol":"tcp","address":"*","port":3000,"scope":"any"},
                      {"protocol":"tcp","address":"192.168.1.20","port":8080,"scope":"other"}]},
        {"pid":4243,"startMicros":1799999990000008,"name":"zsh","group":"separate","state":"owned-current","listeners":[]},
        {"pid":4100,"startMicros":1799999980000001,"name":"node","group":"provider","state":"owned-current",
         "listeners":[{"protocol":"tcp","address":"[::1]","port":9000,"scope":"loopback"}]},
        {"pid":4101,"startMicros":1799999980000002,"name":"node","group":"provider","state":"owned-current","listeners":[]},
        {"pid":4300,"startMicros":1799999970000003,"name":"server","group":"separate","state":"escaped",
         "since":"\(observed)","listeners":[]},
        {"pid":4301,"startMicros":1799999970000004,"name":"build","group":"separate","state":"exited",
         "since":"\(observed)","listeners":[]}
        """
        return Data("""
        {"version":1,"observedAt":"\(observed)","nodes":[{"nodeId":"\(nodeID.uuidString.lowercased())",
         "copilotSessionId":"\((session ?? fixtures.sessionID).uuidString.lowercased())","generation":\(generation),
         "state":"\(state)","observedAt":"\(observed)","omittedCount":\(omitted),
         "processes":[\(processes ?? defaultProcesses)]}]}
        """.utf8)
    }

    private func snapshot(_ data: Data, node: SidebarOrchestrationNode? = nil) -> SidebarOrchestrationSnapshot {
        let node = node ?? self.node()
        var snapshot = SidebarOrchestrationSnapshot(version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: [node])
        snapshot.processes = SidebarProcessObservation.matching(data, snapshot: snapshot, now: now)
        return snapshot
    }

    private func lines(_ data: Data, at date: Date? = nil) -> [SidebarDetailLine] {
        SidebarProcessPresentation.lines(snapshot(data).processes[nodeID], now: date ?? now)
    }

    @Test func ownedProcessesListenersAndHelpersAreLabelledWithCopyablePIDsAndEndpoints() throws {
        let result = lines(file())
        #expect(result.first == .init(title: "Background processes", value: "2"))
        let python = try #require(result.first { $0.id == "process-4242-1799999990000007" })
        #expect((python.title, python.value, python.copyableValue) == ("python3.12", "PID 4242", "4242"))
        #expect(result.contains { $0.title == "zsh" && $0.copyableValue == "4243" })
        // Helpers are counted, never listed; their listeners still show.
        #expect(result.contains(.init(title: "Copilot helpers", value: "2")))
        #expect(!result.contains { $0.title == "node" })
        let listeners = result.filter { $0.title.hasPrefix("Listening") }
        #expect(listeners.map(\.title) == [
            "Listening (loopback)", "Listening (all interfaces)", "Listening (network)", "Listening (loopback)",
        ])
        #expect(listeners.map(\.copyableValue) == ["127.0.0.1:5173", "*:3000", "192.168.1.20:8080", "[::1]:9000"])
        #expect(listeners[0].value == "127.0.0.1:5173 · TCP · python3.12 4242")
        #expect(!result.contains { $0.value.contains("http") })
        #expect(Set(result.map(\.id)).count == result.count)
        let detached = try #require(result.first { $0.title == "server" })
        #expect((detached.value, detached.copyableValue) == ("PID 4300 · Detached", nil))
        #expect(result.contains { $0.title == "build" && $0.value == "PID 4301 · Exited" && $0.copyableValue == nil })
    }

    @Test func staleIncompleteDeniedAndUnprovenStatesNeverClaimACurrentList() {
        let stale = lines(file(), at: now.addingTimeInterval(61))
        #expect(stale.first?.value == "2 · Stale")
        #expect(stale.allSatisfy { $0.copyableValue == nil })
        #expect(lines(file(), at: now.addingTimeInterval(301)) == [.init(title: "Background processes", value: "Unavailable")])
        let incomplete = lines(file(state: "scan-incomplete", processes: ""))
        #expect(incomplete == [.init(title: "Background processes", value: "Scan incomplete")])
        #expect(lines(file(processes: "")) == [
            .init(title: "Background processes", value: "None"), .init(title: "Listening", value: "None"),
        ])
        #expect(lines(file(state: "denied", processes: "")) == [.init(title: "Background processes", value: "Denied")])
        for state in ["no-custody", "ambiguous"] {
            #expect(lines(file(state: state, processes: "")) == [.init(title: "Background processes", value: "Unavailable")])
        }
        #expect(SidebarProcessPresentation.lines(nil, now: now) == [.init(title: "Background processes", value: "Not observed")])
    }

    @Test func anIncompleteScanWithOnlyOmittedWorkNeverClaimsZero() {
        let result = lines(file(state: "scan-incomplete", processes: "", omitted: 4))
        #expect(result.first == .init(title: "Background processes", value: "4 · Scan incomplete"))
        #expect(result.contains(.init(title: "More background processes", value: "4")))
    }

    @Test func omittedHelpersAreCountedAsHelpersNotBackgroundWork() {
        let data = Data(String(decoding: file(omitted: 3), as: UTF8.self)
            .replacingOccurrences(of: #""omittedCount":3"#, with: #""omittedCount":3,"omittedHelperCount":5"#).utf8)
        let result = lines(data)
        #expect(result.first == .init(title: "Background processes", value: "5"))
        #expect(result.contains(.init(title: "More background processes", value: "3")))
        #expect(result.contains(.init(title: "Copilot helpers", value: "7")))
    }

    @Test func observationsMatchOnlyTheExactNodeBindingAndRejectUnsafeShapes() {
        #expect(snapshot(file()).processes[nodeID] != nil)
        #expect(snapshot(file(generation: 1)).processes.isEmpty)
        #expect(snapshot(file(session: fixtures.otherSessionID)).processes.isEmpty)
        for unsafe in [
            #"{"pid":1,"startMicros":1,"name":"/usr/bin/x --token","group":"separate","state":"owned-current","listeners":[]}"#,
            #"{"pid":1,"startMicros":1,"name":"x","group":"separate","state":"owned-current","listeners":[{"protocol":"http","address":"127.0.0.1","port":80,"scope":"loopback"}]}"#,
            #"{"pid":1,"startMicros":1,"name":"x","group":"separate","state":"owned-current","listeners":[{"protocol":"tcp","address":"localhost","port":80,"scope":"loopback"}]}"#,
            #"{"pid":1,"startMicros":1,"name":"x","group":"separate","state":"escaped","listeners":[]}"#,
            #"{"pid":1,"startMicros":1,"name":"x","group":"separate","state":"owned-current","listeners":[{"protocol":"tcp","address":"0.0.0.0","port":80,"scope":"loopback"}]}"#,
            #"{"pid":1,"startMicros":1,"name":"x","group":"separate","state":"owned-current","listeners":[{"protocol":"tcp","address":"999.1.1.1","port":80,"scope":"other"}]}"#,
        ] {
            #expect(snapshot(file(processes: unsafe)).processes.isEmpty, "\(unsafe)")
        }
        // Counts that would overflow the hover's arithmetic are refused, not trapped on.
        let nine = (1...9).map {
            #"{"pid":\#($0),"startMicros":\#($0),"name":"w","group":"separate","state":"owned-current","listeners":[]}"#
        }.joined(separator: ",")
        #expect(snapshot(file(processes: nine, omitted: Int.max)).processes.isEmpty)
        #expect(snapshot(file(processes: nine, omitted: 2)).processes[nodeID] != nil)
    }

    @Test func managedAgentHoverShowsTheMatchedProcessSection() throws {
        let card = try #require(SidebarAgentHoverContent.card(
            for: .managed(nodeID, generation: 2), hierarchy: fixtures.hierarchy(), connected: true,
            tree: .init(availability: .ready, sessions: [], issues: [], generatedAt: now),
            managed: snapshot(file()), availability: .ready, now: now
        ))
        #expect(card.lines.contains(.init(title: "Background processes", value: "2")))
        #expect(card.lines.contains { $0.copyableValue == "127.0.0.1:5173" })
        let unavailable = try #require(SidebarAgentHoverContent.card(
            for: .managed(nodeID, generation: 2), hierarchy: fixtures.hierarchy(), connected: true,
            tree: .init(availability: .ready, sessions: [], issues: [], generatedAt: now),
            managed: snapshot(file()), availability: .unavailable, now: now
        ))
        #expect(unavailable.lines.allSatisfy { $0.copyableValue == nil })
    }
}
