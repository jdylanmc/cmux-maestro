import Darwin
import Foundation

/// The controller's optional `observer/processes.json` (ADR 0029): owned background processes and
/// their TCP listeners per managed node. Sanitized identities only; never argv or environment.
nonisolated struct SidebarProcessObservation: Codable, Equatable, Sendable {
    struct Listener: Codable, Equatable, Sendable {
        let `protocol`: String
        let address: String
        let port: Int
        let scope: String

        /// Exactly as bound: `127.0.0.1:5173`, `[::1]:5173`, `*:3000`. Never a URL.
        var endpoint: String { "\(address):\(port)" }

        /// An explicit browser attempt, not evidence that this TCP listener speaks HTTP.
        var browserURL: URL? {
            guard SidebarProcessObservation.valid(self) else { return nil }
            let host: String
            switch address {
            case "*", "0.0.0.0", "127.0.0.1": host = "localhost"
            case "[::]": host = "[::1]"
            default:
                // Preserve specific binds, including 127.0.0.2; avoid URL parsers' octal IPv4 notation.
                host = address.hasPrefix("[") ? address
                    : address.split(separator: ".").compactMap { Int($0).map(String.init) }.joined(separator: ".")
            }
            return URL(string: "http://\(host):\(port)")
        }
    }

    struct Process: Codable, Equatable, Sendable {
        let pid: Int
        let startMicros: Int64
        let name: String
        let group: String
        let state: String
        var since: Date? = nil
        let listeners: [Listener]
    }

    struct Node: Codable, Equatable, Sendable {
        let nodeId: UUID
        let copilotSessionId: UUID
        let generation: Int
        let state: String
        let observedAt: Date
        let processes: [Process]
        /// Background processes past the probe bound.
        let omittedCount: Int
        /// Copilot helpers past the probe bound; counted with the helpers, never as background work.
        var omittedHelperCount: Int? = nil
    }

    let version: Int
    let observedAt: Date
    let nodes: [Node]

    static let nodeStates: Set = ["owned-current", "scan-incomplete", "denied", "no-custody", "ambiguous", "exited"]
    static let processStates: Set = ["owned-current", "escaped", "exited"]
    static let maximumProcesses = 32
    static let maximumEvents = 16
    static let maximumListeners = 8
    static let maximumOmitted = Int(Int32.max)

    /// Entries for exactly the snapshot's node bindings; a malformed file contributes nothing.
    static func matching(_ data: Data, snapshot: SidebarOrchestrationSnapshot, now: Date) -> [UUID: Node] {
        guard let value = try? SidebarOrchestrationReader.decoder().decode(Self.self, from: data) else { return [:] }
        return value.matching(snapshot: snapshot, now: now)
    }

    func matching(snapshot: SidebarOrchestrationSnapshot, now: Date) -> [UUID: Node] {
        guard valid(now: now) else { return [:] }
        let bindings = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        var result: [UUID: Node] = [:]
        for entry in nodes {
            guard let node = bindings[entry.nodeId], node.copilotSessionId == entry.copilotSessionId,
                  node.generation == entry.generation else { continue }
            result[entry.nodeId] = entry
        }
        return result
    }

    func valid(now: Date) -> Bool {
        let future = now.addingTimeInterval(SidebarOrchestrationReader.futureTolerance)
        guard version == 1, nodes.count <= SidebarOrchestrationReader.maximumNodes, observedAt <= future,
              Set(nodes.map(\.nodeId)).count == nodes.count else { return false }
        return nodes.allSatisfy { node in
            let owned = node.processes.filter { $0.state == "owned-current" }
            // An ended provider keeps only retained events; an unproven node has no list.
            let listShape = switch node.state {
            case "exited": owned.isEmpty
            case "denied", "no-custody", "ambiguous": node.processes.isEmpty
            default: true
            }
            // Bounded counts: a malformed optional file must never trap the hover's arithmetic.
            return listShape && Self.nodeStates.contains(node.state) && node.observedAt <= future
                && (0...Self.maximumOmitted).contains(node.omittedCount)
                && (0...Self.maximumOmitted).contains(node.omittedHelperCount ?? 0)
                && node.generation >= 0 && owned.count <= Self.maximumProcesses
                && node.processes.count - owned.count <= Self.maximumEvents
                && Set(node.processes.map { "\($0.pid):\($0.startMicros)" }).count == node.processes.count
                && node.processes.allSatisfy(Self.valid)
        }
    }

    private static func valid(_ process: Process) -> Bool {
        (1...Int(Int32.max)).contains(process.pid) && process.startMicros > 0
            && !process.name.isEmpty && process.name.count <= 32
            && process.name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._ +-?".contains($0)) }
            && ["provider", "separate"].contains(process.group) && processStates.contains(process.state)
            && (process.state == "owned-current" ? process.since == nil : process.since != nil)
            && process.listeners.count <= maximumListeners
            && (process.state == "owned-current" || process.listeners.isEmpty)
            && process.listeners.allSatisfy(valid)
            // Each listener line is keyed by its endpoint; a repeat would collide in the card.
            && Set(process.listeners.map(\.endpoint)).count == process.listeners.count
    }

    private static func valid(_ listener: Listener) -> Bool {
        let address = listener.address
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        let ipv4 = octets.count == 4
            && octets.allSatisfy { (1...3).contains($0.count) && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) && UInt8($0) != nil }
        let shape = address == "*" || ipv4 || validIPv6(address)
        return shape && listener.protocol == "tcp" && (1...65_535).contains(listener.port)
            && listener.scope == scope(of: address)
    }

    /// `[addr]` whose inside parses as an IPv6 address.
    private static func validIPv6(_ address: String) -> Bool {
        guard address.count <= 47, address.hasPrefix("["), address.hasSuffix("]") else { return false }
        var storage = in6_addr()
        return inet_pton(AF_INET6, String(address.dropFirst().dropLast()), &storage) == 1
    }

    /// The controller's rule; a scope that contradicts the bound address is rejected.
    static func scope(of address: String) -> String {
        if ["*", "0.0.0.0", "[::]"].contains(address) { return "any" }
        if address.hasPrefix("127.") || address == "[::1]" { return "loopback" }
        return "other"
    }
}

/// Agent hover lines for one node's background processes and listeners: labels and values only.
enum SidebarProcessPresentation {
    static let title = "Processes"
    static let helpersTitle = "Copilot helpers"
    static let listenersTitle = String(localized: "ports.title", defaultValue: "Ports")
    static let staleInterval: TimeInterval = 60
    static let unavailableInterval: TimeInterval = 300
    static let maximumLines = 8

    static func lines(_ entry: SidebarProcessObservation.Node?, now: Date) -> [SidebarDetailLine] {
        guard let entry else { return [.init(title: title, value: "Not observed")] }
        let age = now.timeIntervalSince(entry.observedAt)
        guard age <= unavailableInterval else { return [.init(title: title, value: "Unavailable")] }
        switch entry.state {
        case "denied": return [.init(title: title, value: "Denied")]
        case "no-custody", "ambiguous": return [.init(title: title, value: "Unavailable")]
        default: break
        }
        let stale = age > staleInterval
        let incomplete = entry.state == "scan-incomplete"
        let owned = entry.processes.filter { $0.state == "owned-current" }
        let separate = owned.filter { $0.group == "separate" }
        let helpers = owned.count - separate.count + (entry.omittedHelperCount ?? 0)
        let total = separate.count + entry.omittedCount
        // Only a complete, current scan can claim zero.
        var summary = entry.state == "exited" ? ["Session ended"]
            : total > 0 ? ["\(total)"] : incomplete || stale ? [] : ["None"]
        if incomplete { summary.append("Scan incomplete") }
        if stale { summary.append("Stale") }
        // Exited entries stay in the observation, but never in the list or its overflow count.
        let listed = separate + entry.processes.filter { $0.state == "escaped" && $0.group == "separate" }
        // Only a complete, current list was re-verified; a kept or partial list is not.
        let canCopy = entry.state == "owned-current" && !stale
        let visible = listed.prefix(maximumLines)
        var values = stale || incomplete || entry.state == "exited" || listed.isEmpty && total == 0
            ? [summary.joined(separator: " · ")] : []
        for process in visible {
            let state = process.state == "escaped" ? " · Detached" : ""
            values.append("PID \(process.pid) (\(process.name))\(state)")
        }
        let hidden = max(0, listed.count - maximumLines) + entry.omittedCount
        if hidden > 0 { values.append("+\(hidden)") }
        let pids = visible.filter { $0.state == "owned-current" }.map { String($0.pid) }
        var lines = [SidebarDetailLine(
            title: title, value: values.joined(separator: "; "),
            copyableValue: canCopy && !pids.isEmpty ? pids.joined(separator: "\n") : nil
        )]
        if helpers > 0 { lines.append(.init(title: helpersTitle, value: "\(helpers)")) }
        lines.append(portsLine(entry, owned: owned, stale: stale, canCopy: canCopy))
        return lines
    }

    private static func portsLine(
        _ entry: SidebarProcessObservation.Node, owned: [SidebarProcessObservation.Process],
        stale: Bool, canCopy: Bool
    ) -> SidebarDetailLine {
        var labels: [String] = []
        var linked = AttributedString()
        var endpoints: [String] = []
        var descriptions: [String] = []
        var count = 0
        let incomplete = entry.state == "scan-incomplete" || entry.omittedCount > 0
            || (entry.omittedHelperCount ?? 0) > 0

        func append(_ label: String, url: URL? = nil) {
            if !labels.isEmpty { linked += AttributedString("; ") }
            labels.append(label)
            var part = AttributedString(label)
            part.link = url
            linked += part
        }
        if entry.state == "exited" { append("Session ended") }
        if incomplete { append("Scan incomplete") }
        if stale { append("Stale") }
        for process in owned {
            var seen: Set<Int> = []
            for listener in process.listeners where seen.insert(listener.port).inserted {
                count += 1
                guard count <= maximumLines else { continue }
                let binds = process.listeners.filter { $0.port == listener.port }
                let nonLoopback = binds.filter { $0.scope != "loopback" }
                // One port per exact process; all distinct network binds remain visible.
                let addresses = nonLoopback.map { $0.scope == "any" ? "*" : $0.address }
                let unique = addresses.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                let prefix = unique.isEmpty ? "" : unique.joined(separator: ",")
                let label = "\(prefix):\(listener.port) (\(process.name))"
                append(label, url: canCopy ? (binds.first { $0.scope == "any" } ?? listener).browserURL : nil)
                endpoints += binds.map(\.endpoint)
                descriptions.append("\(binds.map(\.endpoint).joined(separator: ", ")) · TCP · \(process.name) \(process.pid)")
            }
        }
        if count > maximumLines { append("+\(count - maximumLines)") }
        if labels.isEmpty { append("None") }
        return .init(
            title: listenersTitle, value: labels.joined(separator: "; "),
            copyableValue: canCopy && !endpoints.isEmpty ? endpoints.joined(separator: "\n") : nil,
            help: descriptions.isEmpty ? nil : descriptions.joined(separator: "\n"),
            linkedValue: canCopy && !endpoints.isEmpty ? linked : nil
        )
    }
}
