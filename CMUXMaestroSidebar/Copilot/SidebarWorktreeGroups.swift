import Foundation

/// How each workspace's agents are organized. Workspaces stay the top level in both.
enum SidebarProjection: String, CaseIterable, Identifiable {
    case worktrees, subAgents

    var id: Self { self }
    var title: String { self == .worktrees ? "Worktrees" : "Sub-agents" }
}

/// One Worktrees group. Keys come only from the exact session's current-worktree evidence
/// (ADR 0026), never from a title, branch label, pane or parent.
nonisolated enum SidebarWorktreeGroupKey: Hashable, Sendable {
    case worktree(String)
    /// Verified earlier; the session's directory record changed since or was not read live.
    case lastKnown(String)
    case nonRepository
    case unknown

    /// Stable layout-record identifier for this group's disclosure.
    var storageID: String {
        switch self {
        case .worktree(let key): "tree:\(key)"
        case .lastKnown(let key): "last:\(key)"
        case .nonRepository: "none"
        case .unknown: "unknown"
        }
    }

    static func validStorageID(_ value: String) -> Bool {
        if value == "none" || value == "unknown" { return true }
        for prefix in ["tree:", "last:"] where value.hasPrefix(prefix) {
            return CopilotWorktreeIdentity.validKey(String(value.dropFirst(prefix.count)))
        }
        return false
    }

    init(_ worktree: AgentSessionWorktree?) {
        switch worktree?.evidence {
        case .verified(let identity): self = worktree?.isCurrent == true ? .worktree(identity.key) : .lastKnown(identity.key)
        case .nonRepository: self = worktree?.isCurrent == true ? .nonRepository : .unknown
        case .unknown, nil: self = .unknown
        }
    }

    fileprivate var rank: Int {
        switch self {
        case .worktree: 0
        case .lastKnown: 1
        case .nonRepository: 2
        case .unknown: 3
        }
    }
}

struct SidebarWorktreeGroup<Member>: Identifiable {
    let key: SidebarWorktreeGroupKey
    /// Display identity for a verified group; nil for the label-only groups.
    let identity: CopilotWorktreeIdentity?
    /// The members' shared branch or detached commit; nil when their observations disagree.
    let head: CopilotWorktreeHead?
    let members: [Member]
    var id: SidebarWorktreeGroupKey { key }

    var title: String {
        if let identity { return identity.repository }
        return key == .nonRepository ? "No repository" : "Unknown"
    }

    /// `branch · tree`, `Detached HEAD · commit · tree`, or only `tree` when members disagree;
    /// nil for label-only groups.
    var detail: String? {
        guard let identity else { return nil }
        switch head {
        case .branch(let name): return "\(name) · \(identity.shortKey)"
        case .detached(let commit): return "Detached HEAD · \(commit) · \(identity.shortKey)"
        case nil: return identity.shortKey
        }
    }

    var isLastKnown: Bool { if case .lastKnown = key { true } else { false } }
}

enum SidebarWorktreeGrouping {
    /// Groups in display order: current worktrees, last-known worktrees, no repository, unknown.
    /// Members keep their given order. Verified groups sort by repository, branch, then key.
    static func groups<Member>(
        _ members: [Member], evidence: (Member) -> AgentSessionWorktree?
    ) -> [SidebarWorktreeGroup<Member>] {
        var order: [SidebarWorktreeGroupKey] = []
        var grouped: [SidebarWorktreeGroupKey: [Member]] = [:]
        var identities: [SidebarWorktreeGroupKey: CopilotWorktreeIdentity] = [:]
        var heads: [SidebarWorktreeGroupKey: Set<CopilotWorktreeHead>] = [:]
        for member in members {
            let worktree = evidence(member)
            let key = SidebarWorktreeGroupKey(worktree)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(member)
            if case .verified(let identity) = worktree?.evidence {
                if identities[key] == nil { identities[key] = identity }
                heads[key, default: []].insert(identity.head)
            }
        }
        return order.map { key in
            // Sessions observed at different times may report different heads; show none then.
            let shared = heads[key].flatMap { $0.count == 1 ? $0.first : nil }
            return SidebarWorktreeGroup(key: key, identity: identities[key], head: shared, members: grouped[key] ?? [])
        }.sorted { lhs, rhs in
            if lhs.key.rank != rhs.key.rank { return lhs.key.rank < rhs.key.rank }
            guard let left = lhs.identity, let right = rhs.identity else { return false }
            let repository = left.repository.localizedStandardCompare(right.repository)
            if repository != .orderedSame { return repository == .orderedAscending }
            return (lhs.head?.sortLabel ?? "", left.key) < (rhs.head?.sortLabel ?? "", right.key)
        }
    }
}

private extension CopilotWorktreeHead {
    var sortLabel: String {
        switch self {
        case .branch(let name): name
        case .detached(let commit): "~" + commit
        }
    }
}
