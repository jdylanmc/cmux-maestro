import Foundation

// Location record schema 2: the branch fact plus the session's current worktree (ADR 0027).

extension CopilotSessionLocation {
    static let currentKeys: Set<String> = ["schemaVersion", "sessionID", "recordedAt", "current"]

    /// Schema 2 adds the session's current worktree; the branch fact stays optional.
    static func encode(
        sessionID: UUID, location: CopilotSessionLocation?, current: CopilotSessionWorktree, recordedAt: Date
    ) throws -> Data {
        var object: [String: Any] = [
            "schemaVersion": 2, "sessionID": sessionID.uuidString.lowercased(),
            "recordedAt": Int64((recordedAt.timeIntervalSince1970 * 1000).rounded()), "current": current.wire,
        ]
        if let location {
            object["branch"] = location.branch
            object["worktree"] = location.worktree
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

/// One decoded location record: the tool-path branch fact and, from schema 2, the current worktree.
nonisolated struct CopilotSessionLocationRecord: Equatable, Sendable {
    let location: CopilotSessionLocation?
    let current: CopilotSessionWorktree?

    static func decode(_ data: Data, sessionID: UUID) -> CopilotSessionLocationRecord? {
        guard data.count <= CopilotSessionLocation.maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = CopilotJSONValue.integer(object["schemaVersion"]),
              let session = object["sessionID"] as? String, session == session.lowercased(),
              UUID(uuidString: session) == sessionID,
              let recordedAt = CopilotJSONValue.integer(object["recordedAt"]), recordedAt > 0 else { return nil }
        let keys = Set(object.keys)
        let branch = object["branch"] as? String
        let worktree = CopilotJSONValue.boolean(object["worktree"])
        switch version {
        case 1:
            guard keys == CopilotSessionLocation.keys, let branch, let worktree,
                  CopilotSessionLocation.validBranch(branch) else { return nil }
            return .init(location: .init(branch: branch, worktree: worktree), current: nil)
        case 2:
            let legacy: CopilotSessionLocation?
            if keys == CopilotSessionLocation.currentKeys {
                legacy = nil
            } else if keys == CopilotSessionLocation.currentKeys.union(["branch", "worktree"]),
                      let branch, let worktree, CopilotSessionLocation.validBranch(branch) {
                legacy = .init(branch: branch, worktree: worktree)
            } else {
                return nil
            }
            guard let wire = object["current"] as? [String: Any],
                  let current = CopilotSessionWorktree(wire: wire) else { return nil }
            return .init(location: legacy, current: current)
        default:
            return nil
        }
    }
}

/// The worktree a session's own selected directory (`workspace.yaml` `cwd:`) is in, verified by
/// reading Git's plain files there (ADR 0027). Never derived from a title, branch, pane or parent.
nonisolated struct CopilotSessionWorktree: Equatable, Sendable {
    let evidence: CopilotWorktreeEvidence
    /// `workspace.yaml` as it was when observed. A different file now means the evidence is stale.
    let source: CopilotWorktreeSource?

    init(evidence: CopilotWorktreeEvidence, source: CopilotWorktreeSource?) {
        self.evidence = evidence
        self.source = source
    }

    fileprivate var wire: [String: Any] {
        var object: [String: Any]
        switch evidence {
        case .verified(let identity):
            object = ["status": "verified", "key": identity.key, "repository": identity.repository,
                      "linked": identity.linked]
            switch identity.head {
            case .branch(let name): object["branch"] = name
            case .detached(let commit): object["detached"] = commit
            }
        case .nonRepository: object = ["status": "nonRepository"]
        case .unknown: object = ["status": "unknown"]
        }
        if let source {
            object["source"] = [source.device, source.inode, source.size, source.modifiedSeconds,
                                source.modifiedNanoseconds].map { NSNumber(value: $0) }
        }
        return object
    }

    fileprivate init?(wire: [String: Any]) {
        let keys = Set(wire.keys)
        var source: CopilotWorktreeSource?
        if let raw = wire["source"] {
            guard let array = raw as? [Any], array.count == 5 else { return nil }
            let values = array.compactMap(CopilotJSONValue.integer)
            guard values.count == 5 else { return nil }
            source = .init(device: values[0], inode: values[1], size: values[2],
                           modifiedSeconds: values[3], modifiedNanoseconds: values[4])
        }
        let base: Set<String> = source == nil ? ["status"] : ["status", "source"]
        switch wire["status"] as? String {
        case "nonRepository":
            guard keys == base else { return nil }
            evidence = .nonRepository
        case "unknown":
            guard keys == base else { return nil }
            evidence = .unknown
        case "verified":
            guard let key = wire["key"] as? String, CopilotWorktreeIdentity.validKey(key),
                  let repository = wire["repository"] as? String, CopilotWorktreeIdentity.validLabel(repository),
                  let linked = CopilotJSONValue.boolean(wire["linked"]) else { return nil }
            let head: CopilotWorktreeHead
            if let branch = wire["branch"] as? String, CopilotSessionLocation.validBranch(branch),
               keys == base.union(["key", "repository", "linked", "branch"]) {
                head = .branch(branch)
            } else if let commit = wire["detached"] as? String, CopilotWorktreeHead.validCommit(commit),
                      keys == base.union(["key", "repository", "linked", "detached"]) {
                head = .detached(commit)
            } else {
                return nil
            }
            evidence = .verified(.init(key: key, repository: repository, head: head, linked: linked))
        default:
            return nil
        }
        self.source = source
    }
}

/// `workspace.yaml` identity, size and modification time; compared whole, never interpreted.
nonisolated struct CopilotWorktreeSource: Equatable, Sendable {
    let device: Int64
    let inode: Int64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    init(device: Int64, inode: Int64, size: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
    }

    init(_ stamp: CopilotFileStamp) {
        self.init(device: Int64(stamp.device), inode: Int64(bitPattern: stamp.inode), size: stamp.size,
                  modifiedSeconds: stamp.modifiedSeconds, modifiedNanoseconds: stamp.modifiedNanoseconds)
    }
}

/// `JSONSerialization` bridges numbers and booleans to one type; these keep them apart.
nonisolated enum CopilotJSONValue {
    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else { return nil }
        return number.int64Value
    }

    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
