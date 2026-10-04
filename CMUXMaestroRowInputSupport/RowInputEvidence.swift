import Foundation

/// Bounded, read-only observations of the fixture's real production controls.
struct RowInputEvidence: Codable {
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
