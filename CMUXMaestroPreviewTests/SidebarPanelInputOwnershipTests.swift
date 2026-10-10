import Foundation
import CoreGraphics
#if !PANEL_INPUT_PURE_CHECK
import Testing
#endif

nonisolated struct SidebarPanelInputOwnershipTests {
    typealias Ownership = SidebarPanelInputOwnership
    private final class Identity {}

#if !PANEL_INPUT_PURE_CHECK
    @Test func strictCompanionOwnershipControls() {
        #expect(Self.failures().isEmpty)
    }
#endif

    // The standalone runner compiles these same value-only controls, without AppKit or a test host.
    static func failures() -> [String] {
        let objects = (0..<8).map { _ in Identity() }
        let ids = objects.map { ObjectIdentifier($0) }
        let scope = Ownership.Scope(
            caseID: UUID(), fixture: ids[0], owner: ids[1], window: ids[1], windowNumber: 47,
            panel: ids[2], anchor: ids[3], content: ids[4], rows: [ids[3], ids[5]]
        )
        let point = CGPoint(x: 350, y: 250)
        let screen = CGPoint(x: 450, y: 350)
        let mouse = Ownership.Mouse(
            point: point, screenPoint: screen, unflippedPoint: screen,
            contentBounds: CGRect(x: 0, y: 0, width: 360, height: 260),
            panelBounds: CGRect(x: 130, y: 135, width: 180, height: 60),
            rowBounds: [CGRect(x: 10, y: 190, width: 330, height: 46),
                        CGRect(x: 10, y: 110, width: 330, height: 46)],
            visibleScreen: CGRect(x: 0, y: 60, width: 1024, height: 677),
            button: 0, clicks: 1, pressure: 1
        )
        let pointer = Ownership(
            token: 99, scope: scope, kind: .leftMouseDown, shownAt: 100,
            expectedPoint: point, expectedScreenPoint: screen
        )
        let escape = Ownership(
            token: 100, scope: scope, kind: .keyDown, shownAt: 100,
            expectedPoint: nil, expectedScreenPoint: nil
        )
        let valid = Ownership.Sample(
            tag: 99, scope: scope, lifetime: .visible, kind: .leftMouseDown, flags: 0,
            timestamp: 100, elapsed: .zero, mouse: mouse, keyCode: nil, isRepeat: nil
        )
        var key = valid
        key.tag = 100
        key.kind = .keyDown
        key.mouse = nil
        key.keyCode = 53
        key.isRepeat = false
        var failures: [String] = []
        func check(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }
        func rejects(_ label: String, base: Ownership.Sample = valid,
                     owner: Ownership = pointer, _ mutate: (inout Ownership.Sample) -> Void) {
            var sample = base
            mutate(&sample)
            var candidate = owner
            check(!candidate.accept(sample), label)
            check(!candidate.consumed, label + ": rejection consumed reservation")
        }
        var positive = pointer
        check(positive.accept(valid), "real pointer positive")
        check(positive.consumed, "positive must transition state")
        check(!positive.accept(valid), "duplicate consumption")
        var escapePositive = escape
        check(escapePositive.accept(key), "real Escape positive")
        check(!escapePositive.accept(key), "duplicate Escape consumption")

        rejects("missing tag") { $0.tag = nil }
        rejects("zero tag") { $0.tag = 0 }
        rejects("wrong tag, otherwise same window/type/time") { $0.tag = 98 }
        let zero = Ownership(token: 0, scope: scope, kind: .leftMouseDown, shownAt: 100,
                             expectedPoint: point, expectedScreenPoint: screen)
        rejects("zero reservation cannot authenticate zero", owner: zero) { $0.tag = 0 }
        rejects("nil window") { $0.scope = nil }
        rejects("wrong window, reused numeric ID") { $0.scope?.window = ids[6] }
        rejects("wrong numeric window ID") { $0.scope?.windowNumber += 1 }
        rejects("wrong owner") { $0.scope?.owner = ids[6] }
        rejects("wrong fixture") { $0.scope?.fixture = ids[6] }
        rejects("wrong panel") { $0.scope?.panel = ids[6] }
        rejects("wrong anchor") { $0.scope?.anchor = ids[6] }
        rejects("wrong content") { $0.scope?.content = ids[6] }
        rejects("wrong row identity") { $0.scope?.rows[0] = ids[6] }
        rejects("stale case lifetime") { $0.scope?.caseID = UUID() }
        rejects("closed panel") { $0.lifetime = .closed }
        rejects("lost panel parent/anchor lifetime") { $0.lifetime = .invalid }
        rejects("missing mouse payload") { $0.mouse = nil }
        rejects("wrong point by smallest representable increment") { $0.mouse?.point.x = point.x.nextUp }
        rejects("wrong converted screen point") { $0.mouse?.screenPoint.y = screen.y.nextDown }
        rejects("missing CGEvent location") { $0.mouse?.unflippedPoint = nil }
        rejects("wrong CGEvent location") { $0.mouse?.unflippedPoint?.x = screen.x.nextUp }
        rejects("outside content") { $0.mouse?.contentBounds.size.width = 349 }
        rejects("content upper edge excluded") { $0.mouse?.contentBounds.size.width = 350 }
        rejects("content just below point excluded") { $0.mouse?.contentBounds.size.height = point.y.nextDown }
        var edge = valid
        edge.mouse?.contentBounds = CGRect(x: 350, y: 250, width: 1, height: 1)
        check(pointer.canAccept(edge), "content lower edge included")
        edge.mouse?.contentBounds = CGRect(x: 0, y: 0, width: point.x.nextUp, height: point.y.nextUp)
        check(pointer.canAccept(edge), "content just within upper edge")
        rejects("inside panel") { $0.mouse?.panelBounds = CGRect(x: 449, y: 349, width: 2, height: 2) }
        rejects("panel lower edge included") { $0.mouse?.panelBounds = CGRect(x: 450, y: 350, width: 2, height: 2) }
        edge = valid
        edge.mouse?.panelBounds = CGRect(x: 449, y: 349, width: 1, height: 1)
        check(pointer.canAccept(edge), "panel upper edge outside")
        rejects("empty panel bounds") { $0.mouse?.panelBounds = .zero }
        rejects("inside row") { $0.mouse?.rowBounds[0] = CGRect(x: 349, y: 249, width: 2, height: 2) }
        rejects("row lower edge included") { $0.mouse?.rowBounds[1] = CGRect(x: 350, y: 250, width: 2, height: 2) }
        edge = valid
        edge.mouse?.rowBounds[0] = CGRect(x: 349, y: 249, width: 1, height: 1)
        check(pointer.canAccept(edge), "row upper edge outside")
        rejects("missing row bounds") { $0.mouse?.rowBounds = [] }
        rejects("empty row bounds") { $0.mouse?.rowBounds[0] = .zero }
        rejects("outside visible screen") { $0.mouse?.visibleScreen = .zero }
        rejects("wrong button") { $0.mouse?.button = 1 }
        rejects("wrong click count") { $0.mouse?.clicks = 2 }
        rejects("wrong pressure") { $0.mouse?.pressure = 0 }
        rejects("wrong kind") { $0.kind = .other }
        rejects("wrong pointer flags") { $0.flags = 1 }
        rejects("pre-opening timestamp") { $0.timestamp = 100.0.nextDown }
        rejects("nonfinite timestamp") { $0.timestamp = .infinity }
        rejects("NaN timestamp") { $0.timestamp = .nan }
        rejects("negative monotonic elapsed") { $0.elapsed = .nanoseconds(-1) }
        rejects("exact two second deadline") { $0.elapsed = .seconds(2) }
        rejects("expired deadline") { $0.elapsed = .seconds(2) + .nanoseconds(1) }
        edge = valid
        edge.elapsed = .seconds(2) - .nanoseconds(1)
        check(pointer.canAccept(edge), "one nanosecond before deadline")
        check(pointer.canAccept(valid), "timestamp equality and zero elapsed accepted")
        rejects("Escape missing tag", base: key, owner: escape) { $0.tag = nil }
        rejects("Escape wrong window", base: key, owner: escape) { $0.scope?.window = ids[6] }
        rejects("Escape wrong key", base: key, owner: escape) { $0.keyCode = 52 }
        rejects("Escape missing key", base: key, owner: escape) { $0.keyCode = nil }
        rejects("Escape repeat", base: key, owner: escape) { $0.isRepeat = true }
        rejects("Escape missing repeat", base: key, owner: escape) { $0.isRepeat = nil }
        rejects("Escape keyUp", base: key, owner: escape) { $0.kind = .other }
        rejects("Escape flags", base: key, owner: escape) { $0.flags = 1 }
        rejects("Escape wrong payload kind", base: key, owner: escape) { $0.mouse = mouse }
        rejects("Escape deadline", base: key, owner: escape) { $0.elapsed = .seconds(2) }

        // Cleanup is an independent failure path, not a deadline/lifetime bypass for acceptance.
        var pending = pointer
        var late = valid
        late.elapsed = .seconds(3)
        late.lifetime = .closed
        check(!pending.accept(late), "closed expired event never accepted")
        check(pending.cleanup(late) == .removeAndFail, "exact expired queued input recovered as failure")
        check(!pending.accept(valid), "recovery cannot later become success")
        check(pending.cleanup(late) == .retainAndFail, "duplicate recovery retained and failed")
        var invalid = valid
        invalid.lifetime = .invalid
        pending = pointer
        check(pending.cleanup(invalid) == .retainAndFail, "lost lifetime prevents cleanup")
        var wrongTag = valid
        wrongTag.tag = 98
        var missingTag = valid
        missingTag.tag = nil
        var wrongWindow = valid
        wrongWindow.scope?.window = ids[6]
        var unrelated = valid
        unrelated.tag = 200
        unrelated.scope?.window = ids[7]
        unrelated.scope?.windowNumber = 99
        pending = pointer
        var kept: [Int] = []
        var removed: [Int] = []
        var failuresReported = 0
        let queue = [unrelated, wrongTag, missingTag, wrongWindow, late, unrelated, late]
        for (index, sample) in queue.enumerated() {
            switch pending.cleanup(sample) {
            case .removeAndFail: removed.append(index); failuresReported += 1
            case .retainAndFail: kept.append(index); failuresReported += 1
            case .unrelated: kept.append(index)
            }
        }
        check(removed == [4], "only exact queued ownership removed")
        check(kept == [0, 1, 2, 3, 5, 6], "unrelated and ambiguous queue ordering preserved")
        check(failuresReported == 5, "ambiguity and recovery explicitly fail")

        // Exercise the same state used by native notifications/sampling, not injected lifetime labels.
        let lifecycle = Ownership.Lifecycle(owner: ids[1], foreign: ids[6], panel: ids[2])
        var foreignScope = scope
        foreignScope.window = ids[6]
        foreignScope.windowNumber = 48
        let foreignPointer = Ownership(
            token: 99, scope: foreignScope, kind: .leftMouseDown, shownAt: 100,
            expectedPoint: point, expectedScreenPoint: screen
        )
        var foreignInput = valid
        foreignInput.scope = foreignScope
        func sample(_ state: inout Ownership.Lifecycle, closed: Bool,
                    fixtureIntact: Bool = true, panelIntact: Bool = true) -> Ownership.Sample {
            var result = foreignInput
            result.lifetime = state.sample(
                fixtureIntact: fixtureIntact,
                panelVisibleAttached: !closed && panelIntact,
                panelHiddenDetached: closed && panelIntact
            )
            return result
        }
        func close(_ state: inout Ownership.Lifecycle) {
            state.beginPanelClose()
            check(!state.windowClosed(ids[2]), "only our exact panel close is expected")
            state.endPanelClose()
        }
        var normal = lifecycle
        var accepted = foreignPointer
        check(accepted.accept(sample(&normal, closed: false)), "lifecycle visible acceptance")
        close(&normal)
        let closed = sample(&normal, closed: true)
        check(normal.observing && !normal.invalidated && closed.lifetime == .closed,
              "normal panel close retains valid fixture observation")
        check(accepted.canReceiveAfterClose(closed, previousReceipts: 0), "normal post-close receipt")
        check(!accepted.canReceiveAfterClose(closed, previousReceipts: 1), "duplicate post-close receipt")
        check(!foreignPointer.canReceiveAfterClose(closed, previousReceipts: 0), "receipt requires prior acceptance")
        check(!foreignPointer.canAccept(closed), "normal closed fixture never authorizes acceptance")
        pending = foreignPointer
        check(pending.cleanup(closed) == .removeAndFail, "normal close permits failure-only recovery")
        check(pending.cleanup(closed) == .retainAndFail, "normal close duplicate recovery retained")
        check(!pending.canAccept(foreignInput), "post-close recovery cannot become acceptance")
        var acceptedThenRecovered = accepted
        check(acceptedThenRecovered.cleanup(closed) == .removeAndFail, "accepted duplicate recovered as failure")
        check(!acceptedThenRecovered.canReceiveAfterClose(closed, previousReceipts: 0),
              "recovery cannot become post-close receipt")
        var lateReceipt = closed
        lateReceipt.elapsed = .seconds(2)
        check(!accepted.canReceiveAfterClose(lateReceipt, previousReceipts: 0), "post-close receipt deadline")
        lateReceipt = closed
        lateReceipt.tag = 98
        check(!accepted.canReceiveAfterClose(lateReceipt, previousReceipts: 0), "post-close receipt exact payload")

        // Both notification orders inside reentrant panel.close must latch loss, as must later loss.
        for timing in ["before-panel-notification", "after-panel-notification", "after-close"] {
            for loss in ["owner-close", "foreign-close", "app-resign", "panel-focus"] {
                var state = lifecycle
                state.beginPanelClose()
                if timing != "before-panel-notification" {
                    _ = state.windowClosed(ids[2])
                }
                if timing == "after-close" { state.endPanelClose() }
                switch loss {
                case "owner-close":
                    check(state.windowClosed(ids[1]), "\(timing) owner notification invalidates")
                case "foreign-close":
                    check(state.windowClosed(ids[6]), "\(timing) foreign notification invalidates")
                default:
                    check(state.invalidate(), "\(timing) \(loss) invalidates")
                }
                if timing == "before-panel-notification" { _ = state.windowClosed(ids[2]) }
                if timing != "after-close" { state.endPanelClose() }
                let lost = sample(&state, closed: true)
                let label = "\(timing) \(loss)"
                check(state.observing && state.invalidated && lost.lifetime == .invalid, label + " latched")
                check(!accepted.canReceiveAfterClose(lost, previousReceipts: 0), label + " receipt rejected")
                pending = foreignPointer
                check(!pending.accept(lost), label + " acceptance rejected")
                check(pending.cleanup(lost) == .retainAndFail, label + " recovery retained")
                check(pending.cleanup(lost) == .retainAndFail && !pending.recovered,
                      label + " duplicate retained without recovery")
            }
        }
        for closedPanel in [false, true] {
            for loss in ["fixture-detach-or-replacement", "panel-detach-or-replacement"] {
                var state = lifecycle
                if closedPanel { close(&state) }
                let lost = sample(&state, closed: closedPanel,
                                  fixtureIntact: loss != "fixture-detach-or-replacement",
                                  panelIntact: loss != "panel-detach-or-replacement")
                let label = "\(closedPanel ? "closed" : "visible") \(loss)"
                check(lost.lifetime == .invalid, label + " derived invalid")
                check(sample(&state, closed: closedPanel).lifetime == .invalid, label + " stays invalid")
                check(!accepted.canReceiveAfterClose(lost, previousReceipts: 0), label + " receipt rejected")
                pending = foreignPointer
                check(!pending.accept(lost), label + " acceptance rejected")
                check(pending.cleanup(lost) == .retainAndFail, label + " recovery retained")
            }
        }
        var unexpected = lifecycle
        check(unexpected.windowClosed(ids[2]), "unrequested panel close invalidates")
        check(sample(&unexpected, closed: false).lifetime == .invalid, "unexpected close stays invalid")
        unexpected = normal
        check(unexpected.windowClosed(ids[2]), "post-close duplicate panel notification invalidates")
        check(sample(&unexpected, closed: true).lifetime == .invalid, "duplicate close stays invalid")
        unexpected = lifecycle
        unexpected.beginPanelClose()
        _ = unexpected.windowClosed(ids[2])
        check(unexpected.windowClosed(ids[2]), "reentrant duplicate panel notification invalidates")
        unexpected.endPanelClose()
        check(sample(&unexpected, closed: true).lifetime == .invalid, "reentrant duplicate stays invalid")
        unexpected = lifecycle
        unexpected.beginPanelClose()
        unexpected.endPanelClose()
        check(sample(&unexpected, closed: true).lifetime == .invalid, "missing close notification invalidates")
        var unrelatedLifecycle = normal
        check(!unrelatedLifecycle.windowClosed(ids[7]), "unrelated window notification ignored")
        check(sample(&unrelatedLifecycle, closed: true).lifetime == .closed, "unrelated window preserves lifetime")
        for var state in [lifecycle, normal, unexpected] {
            state.stopObserving()
            check(!state.observing && !state.windowClosed(ids[1]) && !state.invalidate(),
                  "final stop disables callbacks, including early failure")
            check(sample(&state, closed: true).lifetime == .invalid, "final stop cannot authorize input")
        }
        withExtendedLifetime(objects) {}
        return failures
    }
}
