import Foundation

extension SidebarInspection {
    /// Mutable observation fields are deliberately excluded from presentation identity.
    var pathDisclosureSubject: String {
        let subject: String
        switch target {
        case .managed(let node):
            subject = "managed-\(node.id)-\(node.generation)"
        case .unmanaged(let selection):
            switch selection {
            case .workspace(let id): subject = "workspace-\(id)"
            case .surface(let workspaceID, let surfaceID): subject = "surface-\(workspaceID)-\(surfaceID)"
            case .session(let id): subject = "session-\(id)"
            case .child(let sessionID, let childID): subject = "child-\(sessionID)-\(childID)"
            }
        }
        return "\(windowID)-\(workspaceID)-\(surfaceID?.uuidString ?? "none")-\(subject)"
    }
}
