import Foundation

/// Bounded, read-only observations of the fixture's real production controls.
struct RowInputEvidence: Codable {
    struct Invalidation: Codable {
        enum Reason: String, Codable {
            case overlappingMenu, windowClosed, applicationResigned, screenParametersChanged
        }

        let reason: Reason
        let uptime: TimeInterval
        let setupComplete: Bool
        let applicationActive: Bool
        let ownerKey: Bool
    }

    struct Lifetime: Codable {
        let invalidated: Bool
        let firstInvalidation: Invalidation?
        let applicationActive: Bool
        let ownerVisible: Bool
        let foreignVisible: Bool
        let ownerReceiverAttached: Bool
        let foreignReceiverAttached: Bool
        let evidenceAttached: Bool
        let failedRowIDs: [String]
    }

    struct Row: Codable {
        let id: String
        let windowNumber: Int
        let keyboard: Bool
        let focused: Bool
        let eligible: Bool
        let focusedControls: Int
        let titleIsResponder: Bool
        let exteriorFocusRing: Bool
        let bordered: Bool
        let frame: CGRect
        let titleFrame: CGRect
    }

    struct Input: Codable {
        let window: String
        let type: UInt
        let timestamp: TimeInterval
        let point: CGPoint?
    }

    let version: Int
    let caseID: UUID
    let live: Bool
    let lifetime: Lifetime
    let rows: [Row]
    let ownerFrame: CGRect
    let foreignFrame: CGRect
    let ownerKey: Bool
    let opens: Int
    let closes: Int
    let tracking: Bool
    let actions: Int
    let activations: Int
    let dismissals: Int
    let ownerDown: Int
    let ownerUp: Int
    let foreignDown: Int
    let foreignUp: Int
    let inputs: [Input]
    let overflow: Bool
}
