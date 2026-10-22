import AppKit
import SwiftUI
import Testing

/// #78 background processes and #75 listeners on the agent hover (ADR 0029).
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

    @Test func portsShareOneWrappingField() {
        let result = lines(file())
        #expect(result.filter { $0.title == "Ports" }.map(\.value) == [
            ":5173 (python3.12); *:3000 (python3.12); 192.168.1.20:8080 (python3.12); :9000 (node)"
        ])
        #expect(!result.contains { $0.title.hasPrefix("Listening") || $0.title == "More listeners" })
    }

    @Test func ownedProcessesListenersAndHelpersAreLabelledWithCopyablePIDsAndEndpoints() throws {
        let result = lines(file())
        let processes = try #require(result.first)
        #expect(processes == .init(
            title: "Processes",
            value: "PID 4242 (python3.12); PID 4243 (zsh); PID 4300 (server) · Detached",
            copyableValue: "4242\n4243"
        ))
        #expect(result.filter { $0.title == "Processes" }.count == 1)
        #expect(!result.contains { ["python3.12", "zsh", "server", "build", "More background processes"].contains($0.title) })
        // Helpers are counted, never listed; their listeners still show.
        #expect(result.contains(.init(title: "Copilot helpers", value: "2")))
        #expect(!result.contains { $0.title == "node" })
        let ports = try #require(result.first { $0.title == "Ports" })
        #expect(ports.copyableValue == "127.0.0.1:5173\n*:3000\n192.168.1.20:8080\n[::1]:9000")
        #expect(ports.linkedValue?.runs.compactMap(\.link).map(\.absoluteString) == [
            "http://localhost:5173", "http://localhost:3000", "http://192.168.1.20:8080", "http://[::1]:9000"
        ])
        #expect(ports.help == "127.0.0.1:5173 · TCP · python3.12 4242\n*:3000 · TCP · python3.12 4242\n192.168.1.20:8080 · TCP · python3.12 4242\n[::1]:9000 · TCP · node 4100")
        #expect(!result.contains { $0.value.contains("http") })
        #expect(Set(result.map(\.id)).count == result.count)
    }

    @Test func processFieldPreservesOrderAndFoldsDisplayAndProbeOverflow() throws {
        let current = (1...10).map {
            #"{"pid":\#($0),"startMicros":\#($0),"name":"node","group":"separate","state":"owned-current","listeners":[]}"#
        }.joined(separator: ",")
        let processes = current + "," + exitedProcess
        let result = lines(file(processes: processes, omitted: 3))
        #expect(result == [.init(
            title: "Processes",
            value: "PID 1 (node); PID 2 (node); PID 3 (node); PID 4 (node); PID 5 (node); PID 6 (node); PID 7 (node); PID 8 (node); +5",
            copyableValue: "1\n2\n3\n4\n5\n6\n7\n8"
        ), .init(title: "Ports", value: "Scan incomplete")])
    }

    @Test func staleIncompleteDeniedAndUnprovenStatesNeverClaimACurrentList() {
        let stale = lines(file(), at: now.addingTimeInterval(61))
        #expect(stale.first?.value == "2 · Stale; PID 4242 (python3.12); PID 4243 (zsh); PID 4300 (server) · Detached")
        #expect(stale.allSatisfy { $0.copyableValue == nil })
        #expect(stale.allSatisfy { $0.linkedValue == nil })
        #expect(stale.last?.value == "Stale; :5173 (python3.12); *:3000 (python3.12); 192.168.1.20:8080 (python3.12); :9000 (node)")
        #expect(lines(file(), at: now.addingTimeInterval(301)) == [.init(title: "Processes", value: "Unavailable")])
        let incomplete = lines(file(state: "scan-incomplete", processes: ""))
        #expect(incomplete == [.init(title: "Processes", value: "Scan incomplete"),
                               .init(title: "Ports", value: "Scan incomplete")])
        #expect(lines(file(processes: "")) == [
            .init(title: "Processes", value: "None"), .init(title: "Ports", value: "None"),
        ])
        #expect(lines(file(state: "denied", processes: "")) == [.init(title: "Processes", value: "Denied")])
        for state in ["no-custody", "ambiguous"] {
            #expect(lines(file(state: state, processes: "")) == [.init(title: "Processes", value: "Unavailable")])
        }
        #expect(SidebarProcessPresentation.lines(nil, now: now) == [.init(title: "Processes", value: "Not observed")])
    }

    @Test func anIncompleteScanWithOnlyOmittedWorkNeverClaimsZero() {
        let result = lines(file(state: "scan-incomplete", processes: "", omitted: 4))
        #expect(result == [.init(title: "Processes", value: "4 · Scan incomplete; +4"),
                           .init(title: "Ports", value: "Scan incomplete")])
    }

    private var exitedProcess: String {
        #"{"pid":4301,"startMicros":4301,"name":"build","group":"separate","state":"exited","since":"2027-01-15T08:00:00Z","listeners":[]}"#
    }

    @Test(arguments: [
        ("owned-current", 0, "None", "None"),
        ("owned-current", 61, "Stale", "Stale"),
        ("scan-incomplete", 0, "Scan incomplete", "Scan incomplete"),
        ("scan-incomplete", 61, "Scan incomplete · Stale", "Scan incomplete; Stale"),
        ("exited", 0, "Session ended", "Session ended"),
        ("exited", 61, "Session ended · Stale", "Session ended; Stale"),
    ])
    func exitedOnlyProcessesPreserveObservationQualifiers(state: String, age: Int, expected: String, expectedPorts: String) {
        let result = lines(file(state: state, processes: exitedProcess), at: now.addingTimeInterval(Double(age)))
        #expect(result.first == .init(title: "Processes", value: expected))
        #expect(result.filter { $0.title == "Ports" } == [.init(title: "Ports", value: expectedPorts)])
    }

    @Test func exitedProcessesDoNotHideCurrentOrDetachedProcesses() {
        let current = #"{"pid":7,"startMicros":7,"name":"worker","group":"separate","state":"owned-current","listeners":[]}"#
        #expect(lines(file(processes: exitedProcess + "," + current)).first == .init(
            title: "Processes", value: "PID 7 (worker)", copyableValue: "7"
        ))
        let detached = #"{"pid":8,"startMicros":8,"name":"server","group":"separate","state":"escaped","since":"2027-01-15T08:00:00Z","listeners":[]}"#
        #expect(lines(file(processes: exitedProcess + "," + detached)).first == .init(
            title: "Processes", value: "PID 8 (server) · Detached"
        ))
        #expect(lines(file(state: "exited", processes: exitedProcess + "," + detached)).first == .init(
            title: "Processes", value: "Session ended; PID 8 (server) · Detached"
        ))
    }

    @Test func retainedHelpersAreNeverListed() {
        let helper = #"{"pid":9,"startMicros":9,"name":"mcp","group":"provider","state":"exited","since":"2027-01-15T08:00:00Z","listeners":[]}"#
        let result = lines(file(processes: helper))
        #expect(!result.contains { $0.value.contains("PID 9") })
        #expect(!result.contains { $0.title == "More background processes" })
    }

    @Test func anIncompleteScanNeverOffersCopies() {
        let result = lines(file(state: "scan-incomplete"))
        #expect(result.first?.value == "2 · Scan incomplete; PID 4242 (python3.12); PID 4243 (zsh); PID 4300 (server) · Detached")
        #expect(result.last?.value == "Scan incomplete; :5173 (python3.12); *:3000 (python3.12); 192.168.1.20:8080 (python3.12); :9000 (node)")
        #expect(result.allSatisfy { $0.copyableValue == nil })
        #expect(result.allSatisfy { $0.linkedValue == nil })
    }

    @Test func skippedHelpersMeanListenersAreUnknownNotNone() {
        let data = Data(String(decoding: file(processes: ""), as: UTF8.self)
            .replacingOccurrences(of: #""omittedCount":0"#, with: #""omittedCount":0,"omittedHelperCount":1"#).utf8)
        let result = lines(data)
        #expect(result.contains(.init(title: "Copilot helpers", value: "1")))
        #expect(result.last == .init(title: "Ports", value: "Scan incomplete"))
    }

    @Test func nodeStatesAndTheirListsMustAgree() {
        let owned = #"{"pid":7,"startMicros":7,"name":"w","group":"separate","state":"owned-current","listeners":[]}"#
        #expect(snapshot(file(state: "exited", processes: owned)).processes.isEmpty)
        for state in ["denied", "no-custody", "ambiguous"] {
            #expect(snapshot(file(state: state, processes: owned)).processes.isEmpty)
        }
        let detached = #"{"pid":7,"startMicros":7,"name":"w","group":"separate","state":"escaped","since":"2027-01-15T08:00:00Z","listeners":[]}"#
        #expect(snapshot(file(state: "exited", processes: detached)).processes[nodeID] != nil)
    }

    @Test func omittedHelpersAreCountedAsHelpersNotBackgroundWork() {
        let data = Data(String(decoding: file(omitted: 3), as: UTF8.self)
            .replacingOccurrences(of: #""omittedCount":3"#, with: #""omittedCount":3,"omittedHelperCount":5"#).utf8)
        let result = lines(data)
        #expect(result.first?.value == "PID 4242 (python3.12); PID 4243 (zsh); PID 4300 (server) · Detached; +3")
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
            #"{"pid":1,"startMicros":1,"name":"x","group":"separate","state":"owned-current","listeners":[{"protocol":"tcp","address":"+1.2.3.4","port":80,"scope":"other"}]}"#,
            #"{"pid":1,"startMicros":1,"name":"x","group":"separate","state":"owned-current","listeners":[{"protocol":"tcp","address":"127.0.0.1","port":80,"scope":"loopback"},{"protocol":"tcp","address":"127.0.0.1","port":80,"scope":"loopback"}]}"#,
            #"{"pid":1,"startMicros":1,"name":"x","group":"separate","state":"owned-current","listeners":[{"protocol":"tcp","address":"[....]","port":80,"scope":"other"}]}"#,
            #"{"pid":1,"startMicros":1,"name":"x","group":"separate","state":"owned-current","listeners":[{"protocol":"tcp","address":"[:::]","port":80,"scope":"other"}]}"#,
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
        #expect(card.lines.filter { $0.title == "Processes" }.map(\.copyableValue) == ["4242\n4243"])
        #expect(card.lines.contains { $0.title == "Ports" && $0.linkedValue != nil })
        let unavailable = try #require(SidebarAgentHoverContent.card(
            for: .managed(nodeID, generation: 2), hierarchy: fixtures.hierarchy(), connected: true,
            tree: .init(availability: .ready, sessions: [], issues: [], generatedAt: now),
            managed: snapshot(file()), availability: .unavailable, now: now
        ))
        #expect(unavailable.lines.allSatisfy { $0.copyableValue == nil })
        #expect(unavailable.lines.allSatisfy { $0.linkedValue == nil })
    }

    @Test(arguments: [
        ("127.0.0.1", "http://localhost:8137"), ("*", "http://localhost:8137"),
        ("0.0.0.0", "http://localhost:8137"), ("[::]", "http://[::1]:8137"),
        ("[::1]", "http://[::1]:8137"), ("127.0.0.2", "http://127.0.0.2:8137"),
        ("192.168.1.20", "http://192.168.1.20:8137"), ("[2001:db8::1]", "http://[2001:db8::1]:8137"),
        ("192.168.001.020", "http://192.168.1.20:8137")
    ])
    func browserURLsPreserveReachableBindings(_ address: String, _ url: String) {
        let listener = SidebarProcessObservation.Listener(
            protocol: "tcp", address: address, port: 8137, scope: SidebarProcessObservation.scope(of: address)
        )
        #expect(listener.browserURL?.absoluteString == url)
        #expect(SidebarProcessObservation.Listener(protocol: "tcp", address: address, port: 0,
                                                   scope: listener.scope).browserURL == nil)
        #expect(SidebarProcessObservation.Listener(protocol: "udp", address: address, port: 8137,
                                                   scope: listener.scope).browserURL == nil)
    }

    @Test func duplicatePortsCollapseOnlyWithinTheExactProcessAndOverflowCountsGroups() throws {
        let process = """
        {"pid":7,"startMicros":7,"name":"node","group":"separate","state":"owned-current","listeners":[
        {"protocol":"tcp","address":"127.0.0.1","port":8137,"scope":"loopback"},
        {"protocol":"tcp","address":"[::1]","port":8137,"scope":"loopback"},
        {"protocol":"tcp","address":"*","port":8137,"scope":"any"}]}
        """
        let single = try #require(lines(file(processes: process)).last)
        #expect(single.value == "*:8137 (node)")
        #expect(single.copyableValue == "127.0.0.1:8137\n[::1]:8137\n*:8137")
        #expect(single.linkedValue?.runs.compactMap(\.link).map(\.absoluteString) == ["http://localhost:8137"])
        let others = (8...16).map {
            #"{"pid":\#($0),"startMicros":\#($0),"name":"vite","group":"separate","state":"owned-current","listeners":[{"protocol":"tcp","address":"127.0.0.1","port":8137,"scope":"loopback"}]}"#
        }.joined(separator: ",")
        let ports = try #require(lines(file(processes: process + "," + others)).last)
        #expect(ports.value == "*:8137 (node); :8137 (vite); :8137 (vite); :8137 (vite); :8137 (vite); :8137 (vite); :8137 (vite); :8137 (vite); +2")
        #expect(ports.linkedValue?.runs.compactMap(\.link).count == 8)
    }

    @Test func multipleNetworkBindingsStayVisibleAndIncompleteOrStaleEmptyNeverSaysNone() {
        let process = """
        {"pid":7,"startMicros":7,"name":"node","group":"separate","state":"owned-current","listeners":[
        {"protocol":"tcp","address":"192.168.1.20","port":8137,"scope":"other"},
        {"protocol":"tcp","address":"[2001:db8::1]","port":8137,"scope":"other"}]}
        """
        #expect(lines(file(processes: process)).last?.value == "192.168.1.20,[2001:db8::1]:8137 (node)")
        #expect(lines(file(processes: ""), at: now.addingTimeInterval(61)).last?.value == "Stale")
        #expect(lines(file(state: "scan-incomplete", processes: ""), at: now.addingTimeInterval(61)).last?.value == "Scan incomplete; Stale")
        #expect(lines(file(state: "exited", processes: "")).last?.value == "Session ended")
        #expect(lines(file(), at: now.addingTimeInterval(60)).last?.linkedValue != nil)
        #expect(lines(file(), at: now.addingTimeInterval(61)).last?.linkedValue == nil)
    }

    @Test(SidebarAppKitTestScope())
    func syntheticPortsHoverEvidence() throws {
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/ports-evidence")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let oldLines: [SidebarDetailLine] = [
            .init(title: "Listening (loopback)", value: "127.0.0.1:5173 · TCP · python3.12 4242",
                  copyableValue: "127.0.0.1:5173"),
            .init(title: "Listening (all interfaces)", value: "*:3000 · TCP · python3.12 4242",
                  copyableValue: "*:3000"),
            .init(title: "Listening (network)", value: "192.168.1.20:8080 · TCP · python3.12 4242",
                  copyableValue: "192.168.1.20:8080"),
            .init(title: "Listening (loopback)", value: "[::1]:9000 · TCP · node 4100",
                  copyableValue: "[::1]:9000")
        ]
        let before = oldLines.enumerated().map { index, line in
            var line = line
            line.lineID = "before-\(index)"
            return line
        }
        for (name, values) in [("before", before), ("after", lines(file()).filter { $0.title == "Ports" })] {
            let frame = NSRect(x: 0, y: 0, width: 340, height: 300)
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            let view = NSHostingView(rootView: SidebarHoverCard(
                data: .init(id: "synthetic-ports", category: "Agent preview", title: "Synthetic agent", lines: values),
                close: {}, copyValue: { _ in Issue.record("Rendering must not copy"); return false }, intrinsic: true
            ).environment(\.openURL, OpenURLAction { _ in
                Issue.record("Rendering must not open a browser"); return .handled
            }).frame(width: 340, height: 300, alignment: .topLeading).background(Color.white))
            window.contentView = view
            defer { window.contentView = nil; window.close() }
            view.frame = frame
            view.layoutSubtreeIfNeeded()
            #expect(!window.isVisible)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: destination.appendingPathComponent("\(name).png"))
        }
    }

    @Test(SidebarAppKitTestScope(), arguments: ["current", "stale", "incomplete"])
    func portLinksExposeAccessibleActionsAndOpenOnlyWhenPressed(_ state: String) throws {
        let ports = try #require(lines(file(state: state == "incomplete" ? "scan-incomplete" : "owned-current"),
                                      at: now.addingTimeInterval(state == "stale" ? 61 : 0)).last)
        var opened: [URL] = []
        let frame = NSRect(x: 0, y: 0, width: 340, height: 200)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SidebarHoverCard(
            data: .init(id: "ports-actions", category: "Agent preview", title: "Synthetic agent", lines: [ports]),
            close: {}, copyValue: { _ in false }, intrinsic: true
        ).environment(\.openURL, OpenURLAction { opened.append($0); return .handled })
            .environment(\.accessibilityEnabled, true))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        var pending: [NSObject] = [host]
        var visited: Set<ObjectIdentifier> = []
        var links: [NSObject] = []
        while let object = pending.popLast(), visited.count < 256 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if (object as AnyObject).accessibilityRole?() == .link { links.append(object) }
            let children = (object as AnyObject).accessibilityChildren?() ?? []
            pending += NSAccessibility.unignoredChildren(from: children).compactMap { $0 as? NSObject }
        }
        #expect(pending.isEmpty)
        #expect(opened.isEmpty)
        try #require(links.count == (state == "current" ? 4 : 0),
                     "Only current ports may expose accessible links")
        if state != "current" { return }
        #expect(Set(links.compactMap { ($0 as AnyObject).accessibilityLabel?() }) == [
            ":5173 (python3.12)", "*:3000 (python3.12)", "192.168.1.20:8080 (python3.12)", ":9000 (node)"
        ])
        for link in links {
            #expect((link as AnyObject).accessibilityPerformPress?() == true)
        }
        #expect(Set(opened.map(\.absoluteString)) == [
            "http://localhost:5173", "http://localhost:3000", "http://192.168.1.20:8080", "http://[::1]:9000"
        ])
        #expect(!window.isVisible)
    }
}
