import Foundation

/// Enum-only authored expressions, never observed work, attention or completion evidence.
nonisolated struct SidebarMoodObservation: Decodable, Equatable, Sendable {
    enum Mood: String, Decodable, Sendable {
        case happy, celebrating, confused, clear

        var selfReportLabel: String? {
            switch self {
            case .happy:
                String(localized: "mood.selfReported.happy", defaultValue: "Self-reported: happy")
            case .celebrating:
                String(localized: "mood.selfReported.celebrating", defaultValue: "Self-reported: celebrating")
            case .confused:
                String(localized: "mood.selfReported.confused", defaultValue: "Self-reported: confused")
            case .clear: nil
            }
        }
    }

    struct Preview: Decodable, Equatable, Sendable {
        let startedAt: Int
        let active: Bool
        let reportSequence: Int
    }

    struct Playback: Equatable, Sendable {
        let sequence: Int
        let startedAt: Date
        static let step: TimeInterval = 5
        static let duration: TimeInterval = 75

        func isCurrent(at now: Date) -> Bool {
            now >= startedAt && now < startedAt.addingTimeInterval(Self.duration)
        }
    }

    struct Claim: Decodable, Equatable, Sendable {
        let nodeId: UUID
        let runId: UUID
        let sessionId: UUID
        let workspaceId: UUID
        let surfaceId: UUID
        let generation: Int
        let sequence: Int
        let source: String
        let mood: Mood
        let lastChangedAt: Int
        var preview: Preview? = nil

        var reportSequence: Int { preview?.reportSequence ?? sequence }
        var playback: Playback? {
            guard let preview, preview.active else { return nil }
            return .init(sequence: sequence, startedAt: Date(timeIntervalSince1970: Double(preview.startedAt) / 1000))
        }

        func matches(_ node: SidebarOrchestrationNode) -> Bool {
            nodeId == node.id && runId == node.runId && sessionId == node.copilotSessionId
                && workspaceId == node.workspaceId && surfaceId == node.surfaceId && generation == node.generation
        }
    }

    let version: Int
    let moods: [Claim]
    static let maximumBytes = 1_048_576
    static let maximumRecordBytes = 1024
    static let maximumNodes = 1024
    static let maximumWorkspaceNodes = 128
    static let maximumInteger = 9_007_199_254_740_991

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes, !data.contains(0),
              !SidebarBeatsState.containsByteOrderMark(data),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              SidebarBeatsState.isPlainJSON(data), Set(object.keys) == ["version", "moods"],
              let records = object["moods"] as? [[String: Any]], records.count <= maximumNodes
        else { throw CopilotFileError.changed }
        let fields: Set<String> = ["nodeId", "runId", "sessionId", "workspaceId", "surfaceId",
                                   "generation", "sequence", "source", "mood", "lastChangedAt"]
        for record in records {
            guard [fields, fields.union(["preview"])].contains(Set(record.keys)),
                  try JSONSerialization.data(withJSONObject: record).count <= maximumRecordBytes
            else { throw CopilotFileError.changed }
            if let preview = record["preview"] {
                guard let preview = preview as? [String: Any],
                      Set(preview.keys) == ["startedAt", "active", "reportSequence"]
                else { throw CopilotFileError.changed }
            }
            for field in ["nodeId", "runId", "sessionId", "workspaceId", "surfaceId"] {
                guard let raw = record[field] as? String, let id = UUID(uuidString: raw),
                      id.uuidString.lowercased() == raw else { throw CopilotFileError.changed }
            }
        }
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        guard decoded.version == 1, Set(decoded.moods.map(\.nodeId)).count == decoded.moods.count,
              Dictionary(grouping: decoded.moods, by: \.workspaceId).values.allSatisfy({
                  $0.count <= maximumWorkspaceNodes
              }), decoded.moods.allSatisfy({ claim in
                  claim.source == "self-report" && [ claim.generation, claim.sequence, claim.lastChangedAt ].allSatisfy {
                      (1...maximumInteger).contains($0)
                  } && (claim.preview.map { preview in
                      (1...(maximumInteger - 75_000)).contains(preview.startedAt)
                          && (1...claim.sequence).contains(preview.reportSequence)
                  } ?? true)
              }) else { throw CopilotFileError.changed }
        return decoded
    }

    /// Owned by the orchestration reader actor. Never evicts a high-water mark to admit a node.
    struct Cache {
        private var initialized = false
        private var seen: [UUID: Claim] = [:]
        private var eligible: Set<UUID> = []
        private var previewEligible: Set<UUID> = []
        private var decoded = SidebarOrchestrationReader.Decoded<SidebarMoodObservation>()

        mutating func resetForConnection() {
            initialized = false
            eligible.removeAll()
            previewEligible.removeAll()
        }

        mutating func applying(
            _ data: Data?, to base: SidebarOrchestrationSnapshot, now: Date = Date()
        ) -> SidebarOrchestrationSnapshot {
            var result = base
            result.nodes = result.nodes.map {
                var node = $0
                node.selfReportedMood = nil
                node.selfReportedMoodSequence = nil
                node.moodPreview = nil
                return node
            }
            let records: [Claim]
            do {
                records = try data.map { try decoded.value(for: $0, decode: SidebarMoodObservation.decode).moods } ?? []
                let newIDs = Set(records.map(\.nodeId)).subtracting(seen.keys)
                guard seen.count + newIDs.count <= maximumNodes else { throw CopilotFileError.tooLarge }
            } catch {
                result.moodsUnavailable = true
                eligible.removeAll()
                previewEligible.removeAll()
                return result
            }
            let currentIDs = Set(records.map(\.nodeId))
            eligible.formIntersection(currentIDs)
            previewEligible.formIntersection(currentIDs)
            let nodes = Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.id, $0) })
            for claim in records {
                let matches = nodes[claim.nodeId].map(claim.matches) ?? false
                if let previous = seen[claim.nodeId] {
                    if claim.sequence > previous.sequence {
                        seen[claim.nodeId] = claim
                        if initialized && matches && claim.mood != .clear {
                            if claim.reportSequence > previous.reportSequence { eligible.insert(claim.nodeId) }
                            else if claim.reportSequence != previous.reportSequence || claim.mood != previous.mood {
                                eligible.remove(claim.nodeId)
                            }
                        } else { eligible.remove(claim.nodeId) }
                        if initialized && matches && claim.playback?.isCurrent(at: now) == true {
                            previewEligible.insert(claim.nodeId)
                        } else { previewEligible.remove(claim.nodeId) }
                    } else if claim != previous || !matches {
                        eligible.remove(claim.nodeId)
                        previewEligible.remove(claim.nodeId)
                    }
                } else {
                    seen[claim.nodeId] = claim
                    if initialized && matches && claim.mood != .clear { eligible.insert(claim.nodeId) }
                    if initialized && matches && claim.playback?.isCurrent(at: now) == true {
                        previewEligible.insert(claim.nodeId)
                    }
                }
                if claim.playback?.isCurrent(at: now) != true { previewEligible.remove(claim.nodeId) }
            }
            initialized = true
            result.nodes = result.nodes.map { node in
                var updated = node
                guard let claim = seen[node.id], claim.matches(node), currentIDs.contains(node.id) else { return updated }
                updated.selfReportedMoodSequence = claim.reportSequence
                if eligible.contains(node.id) { updated.selfReportedMood = claim.mood }
                if previewEligible.contains(node.id) { updated.moodPreview = claim.playback }
                return updated
            }
            return result
        }
    }
}
