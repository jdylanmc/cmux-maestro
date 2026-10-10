import Foundation
import CoreGraphics

/// Cooperative test correlation only; object identifiers and tokens are not security credentials.
nonisolated struct SidebarPanelInputOwnership {
    enum Kind: Equatable { case leftMouseDown, keyDown, other }
    enum Lifetime: Equatable { case visible, closed, invalid }
    enum Cleanup: Equatable { case removeAndFail, retainAndFail, unrelated }

    /// Shared by native lifecycle callbacks and pure transition controls, through final recovery.
    struct Lifecycle {
        let owner: ObjectIdentifier
        let foreign: ObjectIdentifier
        let panel: ObjectIdentifier
        private(set) var observing = true
        private(set) var invalidated = false
        private var closingPanel = false
        private var expectedPanelCloseObserved = false
        private var panelClosed = false

        init(owner: ObjectIdentifier, foreign: ObjectIdentifier, panel: ObjectIdentifier) {
            self.owner = owner
            self.foreign = foreign
            self.panel = panel
        }

        mutating func beginPanelClose() {
            if closingPanel || panelClosed || !observing { invalidated = true }
            closingPanel = true
        }

        mutating func endPanelClose() {
            if !closingPanel || !expectedPanelCloseObserved { invalidated = true }
            closingPanel = false
            panelClosed = true
        }

        /// Only one exact panel notification inside our close call is expected, never fixture loss.
        mutating func windowClosed(_ window: ObjectIdentifier) -> Bool {
            guard observing else { return false }
            if window == panel, closingPanel, !expectedPanelCloseObserved {
                expectedPanelCloseObserved = true
                return false
            }
            guard window == owner || window == foreign || window == panel else { return false }
            return invalidate()
        }

        mutating func invalidate() -> Bool {
            guard observing else { return false }
            invalidated = true
            return true
        }

        mutating func sample(fixtureIntact: Bool, panelVisibleAttached: Bool,
                             panelHiddenDetached: Bool) -> Lifetime {
            if !fixtureIntact { invalidated = true }
            guard observing, !invalidated, !closingPanel else { return .invalid }
            if !panelClosed, panelVisibleAttached { return .visible }
            if panelClosed, panelHiddenDetached { return .closed }
            invalidated = true
            return .invalid
        }

        mutating func stopObserving() {
            observing = false
        }
    }

    struct Scope: Equatable {
        var caseID: UUID
        var fixture: ObjectIdentifier
        var owner: ObjectIdentifier
        var window: ObjectIdentifier
        var windowNumber: Int
        var panel: ObjectIdentifier
        var anchor: ObjectIdentifier
        var content: ObjectIdentifier
        var rows: [ObjectIdentifier]
    }

    struct Mouse {
        var point: CGPoint
        var screenPoint: CGPoint
        var unflippedPoint: CGPoint?
        var contentBounds: CGRect
        var panelBounds: CGRect
        var rowBounds: [CGRect]
        var visibleScreen: CGRect
        var button: Int
        var clicks: Int
        var pressure: Float
    }

    struct Sample {
        var tag: Int64?
        var scope: Scope?
        var lifetime: Lifetime
        var kind: Kind
        var flags: UInt
        var timestamp: TimeInterval
        var elapsed: Duration
        var mouse: Mouse?
        var keyCode: UInt16?
        var isRepeat: Bool?
    }

    let token: Int64
    let scope: Scope
    let kind: Kind
    let shownAt: TimeInterval
    let expectedPoint: CGPoint?
    let expectedScreenPoint: CGPoint?
    private(set) var consumed = false
    private(set) var recovered = false

    func ownsPayload(_ sample: Sample) -> Bool {
        guard token != 0, sample.tag == token, sample.scope == scope,
              sample.kind == kind, sample.flags == 0,
              sample.timestamp.isFinite, shownAt.isFinite,
              sample.timestamp >= shownAt else { return false }
        switch kind {
        case .leftMouseDown:
            guard let mouse = sample.mouse,
                  mouse.point == expectedPoint, mouse.screenPoint == expectedScreenPoint,
                  mouse.unflippedPoint == mouse.screenPoint,
                  mouse.button == 0, mouse.clicks == 1, mouse.pressure == 1,
                  mouse.rowBounds.count == scope.rows.count, !mouse.rowBounds.isEmpty,
                  mouse.contentBounds.contains(mouse.point),
                  mouse.visibleScreen.contains(mouse.screenPoint),
                  !mouse.panelBounds.isEmpty, !mouse.panelBounds.contains(mouse.screenPoint),
                  mouse.rowBounds.allSatisfy({ !$0.isEmpty && !$0.contains(mouse.point) }) else { return false }
            return true
        case .keyDown:
            return expectedPoint == nil && expectedScreenPoint == nil
                && sample.keyCode == 53 && sample.isRepeat == false && sample.mouse == nil
        case .other:
            return false
        }
    }

    func canAccept(_ sample: Sample) -> Bool {
        !consumed && !recovered && sample.lifetime == .visible
            && sample.elapsed >= .zero && sample.elapsed < .seconds(2) && ownsPayload(sample)
    }

    mutating func accept(_ sample: Sample) -> Bool {
        guard canAccept(sample) else { return false }
        consumed = true
        return true
    }

    func canReceiveAfterClose(_ sample: Sample, previousReceipts: Int) -> Bool {
        consumed && !recovered && previousReceipts == 0 && sample.lifetime == .closed
            && sample.elapsed >= .zero && sample.elapsed < .seconds(2) && ownsPayload(sample)
    }

    /// Recovery may run after the deadline/close, but can never become dispatch acceptance.
    mutating func cleanup(_ sample: Sample) -> Cleanup {
        if !recovered, sample.lifetime != .invalid, ownsPayload(sample) {
            recovered = true
            return .removeAndFail
        }
        if sample.tag == token || sample.scope?.window == scope.window
            || sample.scope?.windowNumber == scope.windowNumber {
            return .retainAndFail
        }
        return .unrelated
    }
}
