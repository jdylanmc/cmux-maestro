import Darwin
import Foundation

nonisolated struct SidebarNotificationTargetVerifier: Sendable {
    var verifier = CopilotIdentityVerifier()

    func verify(_ target: MaestroNotificationTarget) throws {
        try verify(target, snapshot: SidebarOrchestrationReader.read(),
                   bindings: CopilotPaths.bindingDirectory(), sessions: CopilotPaths.sessionStateRoot(), now: Date())
    }

    func verify(
        _ target: MaestroNotificationTarget, snapshot: SidebarOrchestrationSnapshot,
        bindings bindingRoot: URL, sessions sessionRoot: URL, now: Date
    ) throws {
        guard Self.matches(target, snapshot: snapshot, now: now) else { throw CopilotFileError.changed }
        let bindings = try CopilotFileAccess.openDirectory(bindingRoot, owner: getuid())
        defer { close(bindings) }
        let name = target.sessionId.uuidString.lowercased() + ".json"
        let (record, stamp) = try CopilotFileAccess.readIdentity(at: bindings, filename: name, owner: getuid())
        guard record.sessionID == target.sessionId, record.surfaceID == target.surfaceId,
              record.launchWorkspaceID == target.workspaceId else { throw CopilotFileError.changed }
        let sessions = try CopilotFileAccess.openDirectory(sessionRoot, owner: getuid())
        defer { close(sessions) }
        let session = try CopilotFileAccess.openDirectory(
            at: sessions, name: target.sessionId.uuidString.lowercased(), owner: getuid()
        )
        defer { close(session) }
        let evidence = try verifier.inspect(record: record, sessionDirectory: session)
        guard evidence.status == .alive,
              try verifier.verifyStable(evidence, record: record, sessionDirectory: session).status == .alive,
              try CopilotFileAccess.statEntry(at: bindings, name: name) == stamp else {
            throw CopilotFileError.changed
        }
    }

    static func matches(_ target: MaestroNotificationTarget, snapshot: SidebarOrchestrationSnapshot, now: Date) -> Bool {
        guard snapshot.complete, (0...60).contains(now.timeIntervalSince(snapshot.generatedAt)) else { return false }
        let nodes = snapshot.nodes.filter { $0.surfaceId == target.surfaceId && $0.isActive }
        guard nodes.count == 1, let node = nodes.first else { return false }
        return node.id == target.nodeId && node.copilotSessionId == target.sessionId
            && node.workspaceId == target.workspaceId && node.generation == target.generation
            && node.executionMode == .interactive && target.generation > 0
    }
}
