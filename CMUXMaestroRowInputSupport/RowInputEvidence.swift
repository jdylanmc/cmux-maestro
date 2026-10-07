import Foundation

/// Bounded, read-only observations of the fixture's real production controls.
struct RowInputEvidence: Codable {
    enum FixtureWindow: String, Codable {
        case owner = "row-input-owner", foreign = "row-input-foreign"
    }

    struct Responder: Codable {
        enum Kind: String, Codable { case none, control, other }
        enum Control: String, Codable, CaseIterable {
            case ownerTitle = "owner-title", siblingTitle = "sibling-title", foreignTitle = "foreign-title"
            case ownerReceiver = "owner-click", foreignReceiver = "foreign-click"
            case ownerContent = "owner-content", foreignContent = "foreign-content"

            var window: FixtureWindow {
                [.foreignTitle, .foreignReceiver, .foreignContent].contains(self) ? .foreign : .owner
            }
        }
        let kind: Kind
        let control: Control?
        let window: FixtureWindow?
    }

    struct KeyView: Codable {
        let canBecomeKeyView: Bool
        let nextValidKeyView: Responder
    }

    struct Keyboard: Codable {
        let keyCode: UInt16
        let modifierFlags: UInt
    }

    struct Dispatch: Codable {
        let before: Responder
        let after: Responder
    }

    struct Display: Codable {
        let number: UInt32?
        let frame: CGRect
        let visibleFrame: CGRect
        let backingScaleFactor: CGFloat
        let colorProfileSHA256: String?
    }

    struct DisplayState: Codable {
        let uptime: TimeInterval
        let screens: [Display]
        let ownerScreenNumber: UInt32?
        let foreignScreenNumber: UInt32?
        let ownerBackingScaleFactor: CGFloat
        let foreignBackingScaleFactor: CGFloat
    }

    struct Invalidation: Codable {
        enum Reason: String, Codable {
            case overlappingMenu, windowClosed, applicationResigned, screenParametersChanged
        }

        let reason: Reason
        let uptime: TimeInterval
        let setupComplete: Bool
        let applicationActive: Bool
        let ownerKey: Bool
        let displays: DisplayState
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
        let displaysAtSetup: DisplayState?
        let displaysAtSample: DisplayState
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
        var keyView: KeyView? = nil
    }

    struct Input: Codable {
        let window: String
        let type: UInt
        let timestamp: TimeInterval
        let point: CGPoint?
        var keyboard: Keyboard? = nil
        var dispatch: Dispatch? = nil
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

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32_768,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw invalid("Invalid bounded row-input object")
        }
        try keys(object, allowed: [
            "version", "caseID", "live", "lifetime", "rows", "ownerFrame", "foreignFrame", "ownerKey",
            "opens", "closes", "tracking", "actions", "activations", "dismissals", "ownerDown", "ownerUp",
            "foreignDown", "foreignUp", "inputs", "overflow"
        ])
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard [3, 4].contains(value.version), value.inputs.count <= 64,
              let rows = object["rows"] as? [[String: Any]],
              let inputs = object["inputs"] as? [[String: Any]] else {
            throw invalid("Unsupported row-input version or input bound")
        }
        for (row, decoded) in zip(rows, value.rows) {
            try keys(row, allowed: [
                "id", "windowNumber", "keyboard", "focused", "eligible", "focusedControls",
                "titleIsResponder", "exteriorFocusRing", "bordered", "frame", "titleFrame", "keyView"
            ])
            if value.version == 3 {
                guard row["keyView"] == nil else { throw invalid("Version 3 cannot carry key-view diagnostics") }
            } else {
                guard let fields = row["keyView"] as? [String: Any], let keyView = decoded.keyView,
                      let next = fields["nextValidKeyView"] as? [String: Any] else {
                    throw invalid("Version 4 requires key-view diagnostics")
                }
                try keys(fields, allowed: ["canBecomeKeyView", "nextValidKeyView"])
                try validate(keyView.nextValidKeyView, object: next)
            }
        }
        for (input, decoded) in zip(inputs, value.inputs) {
            try keys(input, allowed: ["window", "type", "timestamp", "point", "keyboard", "dispatch"])
            if value.version == 3 {
                guard input["keyboard"] == nil, input["dispatch"] == nil else {
                    throw invalid("Version 3 cannot carry dispatch diagnostics")
                }
                continue
            }
            guard FixtureWindow(rawValue: decoded.window) != nil,
                  [1, 2, 10, 11].contains(decoded.type),
                  let fields = input["dispatch"] as? [String: Any], let dispatch = decoded.dispatch,
                  let before = fields["before"] as? [String: Any],
                  let after = fields["after"] as? [String: Any] else {
                throw invalid("Version 4 requires exact fixture dispatch diagnostics")
            }
            try keys(fields, allowed: ["before", "after"])
            try validate(dispatch.before, object: before)
            try validate(dispatch.after, object: after)
            if [10, 11].contains(decoded.type) {
                guard let keyboard = input["keyboard"] as? [String: Any],
                      decoded.keyboard != nil, input["point"] == nil else {
                    throw invalid("Key events require typed keys, not mouse coordinates")
                }
                try keys(keyboard, allowed: ["keyCode", "modifierFlags"])
            } else {
                guard input["keyboard"] == nil, decoded.point != nil else {
                    throw invalid("Mouse events cannot carry keyboard diagnostics")
                }
            }
        }
        return value
    }

    private static func validate(_ responder: Responder, object: [String: Any]) throws {
        try keys(object, allowed: ["kind", "control", "window"])
        switch responder.kind {
        case .none:
            guard responder.control == nil, responder.window == nil else {
                throw invalid("Absent responder cannot claim fixture identity")
            }
        case .control:
            guard let control = responder.control, responder.window == control.window else {
                throw invalid("Control responder must belong to its exact fixture window")
            }
        case .other:
            guard responder.control == nil else { throw invalid("Unknown responder cannot claim a control") }
        }
    }

    private static func keys(_ object: [String: Any], allowed: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else { throw invalid("Unknown diagnostic fields") }
    }

    private static func invalid(_ message: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: message))
    }
}
