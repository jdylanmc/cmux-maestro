import CryptoKit
import CoreGraphics
import Foundation
import ImageIO

/// Test-only measured primitives shared by the host, consumer and original-identity validators.
struct GuideAcceptanceEvidence: Codable {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Shared by the real producer and non-GUI controls of normally returning teardown.
    struct Finalization {
        private(set) var terminated = false

        mutating func terminate(_ action: () -> Void) {
            if !terminated {
                terminated = true
                action()
            }
        }

        mutating func finish(remaining: () throws -> Double, terminate action: () -> Void) throws {
            terminate(action)
            _ = try remaining()
        }
    }

    static func waitForObservation(remaining: () throws -> Double, evaluate: () -> Bool,
                                   pending: (Double) throws -> Bool) throws {
        let completed = try pending(remaining())
        _ = try remaining()
        try require(completed, "Native acceptance observation did not arrive")
    }

    struct Rect: Codable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(_ rect: CGRect) {
            x = rect.origin.x; y = rect.origin.y
            width = rect.width; height = rect.height
        }

        var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
        var positive: Bool {
            [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
        }
        func intersects(_ other: Rect) -> Bool {
            let intersection = cg.intersection(other.cg)
            return positive && other.positive && intersection.width > 0 && intersection.height > 0
        }
    }

    struct Node: Codable {
        var identifier: String
        var role: String
        var enabled: Bool
        var label: String
        var title: String
        var value: String?
        var frame: Rect
        var hittable: Bool?
        var text: String { [label, title, value ?? ""].joined(separator: "\n") }
    }

    struct Action: Codable {
        var identifier: String
        var node: Node
        var viewport: Rect
        var returned: Bool
        var before: Int
        var after: Int
        var sinkResult: Bool?
        var pendingRead: Bool
    }

    struct Image: Codable {
        var name: String
        var sha256: String
        var bytes: Int
        var pixelsWide: Int
        var pixelsHigh: Int
        var points: Rect
        var backingScale: Double
        var capturedAt: Double
    }

    struct Presentation: Codable {
        var running: Bool
        var active: Bool
        var policy: Int
        var visible: Bool
        var key: Bool
        var unoccluded: Bool
        var exactContentController: Bool
        var exactContentView: Bool
        var exactGuideParent: Bool
        var exactMinimalParent: Bool
        var exactGuideWindow: Bool
        var exactMinimalWindow: Bool
        var guideAppeared: Bool
        var minimalAppeared: Bool
        var guideFrame: Rect
        var minimalFrame: Rect
        var containerFrame: Rect
        var fittingWidth: Double
        var fittingHeight: Double
        var document: Rect
        var clip: Rect
        var flipped: Bool
        var clipScreen: Rect
        var minimalScreen: Rect
        var screenTop: Double
        var windowNumber: Int
        var modelIdentity: String
        var appearance: String
    }

    struct HostStage: Codable {
        var invocation: String
        var producer: String
        var sourceHead: String
        var sourceTree: String
        var scenario: String
        var appearance: String
        var stage: String
        var elapsed: Double
        var presentation: Presentation
        var copies: Int
        var minimalPresses: Int
        var readerCalls: Int
        var pendingRead: Bool
        var checking: Bool
        var observationInstalled: Bool
        var observationFired: Bool
        var actions: [Action]
        var recheck: Node?
        var controls: Controls
        var image: Image?
    }

    struct Controls: Codable {
        var omitted: Node
        var ignored: Node
        var omittedIsElement: Bool
        var ignoredIsElement: Bool
        var omittedInRawTree: Bool
        var ignoredInRawTree: Bool
        var omittedReturned: Bool
        var ignoredReturned: Bool
        var omittedPresses: Int
        var ignoredPresses: Int
        var exposedCountBefore: Int
        var exposedCountAfter: Int
        var noOp: Action
        var noOpPresses: Int
        var noOpReaderCalls: Int
        var noOpReaderPending: Bool
        var noOpWaitInstalled: Bool
        var noOpWaitRemaining: Bool
    }

    struct Consumer: Codable {
        var windowIdentifier: String
        var windowTitle: String
        var windowFrame: Rect
        var guide: Node
        var minimal: Node
        var guideNodes: [Node]
        var minimalNodes: [Node]
        var controlNodes: [Node]
        var complete: Bool
        var elapsed: Double
    }

    struct Stage: Codable {
        var host: HostStage
        var consumer: Consumer
    }

    struct Cleanup: Codable {
        var scenario: String
        var appearance: String
        var originalPolicy: Int
        var restoredPolicy: Int
        var policyChangeReturned: Bool?
        var policyRestoreReturned: Bool?
        var windowVisible: Bool
        var guideHasParent: Bool
        var minimalHasParent: Bool
        var readerPending: Bool
        var readerWaiting: Bool
        var elapsed: Double
    }

    struct Completion: Codable {
        var invocation: String
        var producer: String
        var cleanups: [Cleanup]
        var elapsed: Double
    }

    var schemaVersion: Int
    var invocation: String
    var producer: String
    var sourceHead: String
    var sourceTree: String
    var elapsed: Double
    var stages: [Stage]
    var completion: Completion

    static let paths = [".agents/skills/maestro/SKILL.md", ".copilot/skills/maestro/SKILL.md"]
    static let scenarios = ["missing", "unreadable", "different", "matching", "reference-unavailable"]
    static let appearances = ["light", "dark"]
    static let producers = [
        "statuses": "CMUXMaestroGuideUITests/GuideAcceptanceTests/testSyntheticStatusesRetainNativeSizeScrollingAndAccessibleActions()",
        "recheck": "CMUXMaestroGuideUITests/GuideAcceptanceTests/testNativeRecheckDrivesCheckingChangedStatusAndRetry()"
    ]
    static let statusStages = ["initial-pre-readiness-diagnostic", "initial-ready", "scrolled-bottom",
                               "copy-failure", "copy-success"]
    static let recheckStages = ["initial-pre-readiness-diagnostic", "missing-ready",
                                "unreadable-checking", "unreadable-completed",
                                "matching-checking", "matching-completed"]

    nonisolated static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func unique(_ nodes: [Node], _ id: String) throws -> Node {
        let matches = nodes.filter { $0.identifier == id }
        try require(matches.count == 1, "Missing/duplicate exposed identifier: \(id)")
        return matches[0]
    }

    static func ready(_ node: Node, viewport: Rect, hittable: Bool = false) throws {
        try require(node.role == "AXButton" && node.enabled && node.frame.intersects(viewport),
                    "Action is not an enabled exposed button in its actual viewport: \(node.identifier)")
        if hittable { try require(node.hittable == true, "Action is not publicly hittable") }
    }

    static func assertStatus(_ nodes: [Node], _ status: String) throws {
        let strings: [String: (String, String)] = [
            "missing": ("Missing", "No guide found at this location."),
            "unreadable": ("Unreadable", "Permission denied. Check access, then Re-check."),
            "different": ("Different from this build",
                          "Content may be newer or customized; different does not mean outdated."),
            "matching": ("Matches this build",
                         "Guide bytes match this build, not necessarily the latest upstream guide."),
            "reference-unavailable": ("Build reference unavailable.",
                                      "Guide content could not be compared. Nothing was changed.")
        ]
        guard let (title, detail) = strings[status] else { throw Failure(description: "Unknown status") }
        if status == "reference-unavailable" {
            let node = try unique(nodes, "cli-integration-reference-error")
            try require(node.text.contains(title) && node.text.contains(detail), "Wrong reference error text")
            try require(!nodes.contains { $0.identifier.hasPrefix("cli-integration-status-") },
                        "Unexpected checked rows in reference-unavailable")
        } else {
            for path in paths {
                let node = try unique(nodes, "cli-integration-status-" + path)
                try require(node.text.contains(title) && node.text.contains(detail)
                            && node.text.contains("~/" + path), "Wrong actual status text for \(path)")
            }
        }
    }

    static func imageName(caseName: String, scenario: String, appearance: String, stage: String) -> String? {
        if caseName == "statuses" {
            let suffixes = ["initial-pre-readiness-diagnostic": "", "initial-ready": "",
                            "scrolled-bottom": "-scrolled", "copy-failure": "-copy-failure",
                            "copy-success": "-copy-success"]
            guard let suffix = suffixes[stage] else { return nil }
            return "cli-guide-\(scenario)-\(appearance)\(suffix).png"
        }
        guard stage.hasSuffix("-checking") || stage.hasSuffix("-completed") else { return nil }
        let parts = stage.split(separator: "-")
        return "cli-guide-recheck-\(parts[0])-\(appearance)-\(parts[1]).png"
    }

    func validate(caseName: String, expectedInvocation: String, head: String, tree: String,
                  imageDirectory: URL) throws {
        try Self.require(schemaVersion == 1 && invocation == expectedInvocation
                         && UUID(uuidString: invocation) != nil && producer == Self.producers[caseName]
                         && sourceHead == head && sourceTree == tree && head.count == 40 && tree.count == 40,
                         "Wrong acceptance envelope/identity/source")
        let names = caseName == "statuses" ? Self.scenarios : ["recheck"]
        let phases = caseName == "statuses" ? Self.statusStages : Self.recheckStages
        let expected = names.flatMap { name in Self.appearances.flatMap { appearance in
            phases.map { (name, appearance, $0) }
        } }
        try Self.require(stages.count == expected.count, "Missing/extra acceptance stages")
        var elapsed = -1.0
        var previous: Stage?
        for (record, key) in zip(stages, expected) {
            let h = record.host, c = record.consumer, p = h.presentation
            let precedingElapsed = elapsed
            try Self.require(h.scenario == key.0 && h.appearance == key.1 && h.stage == key.2,
                             "Wrong/duplicate/out-of-order stage")
            try Self.require(h.invocation == invocation && h.producer == producer
                             && h.sourceHead == head && h.sourceTree == tree, "Stage provenance differs")
            try Self.require(h.elapsed.isFinite && c.elapsed.isFinite && h.elapsed >= 0 && h.elapsed >= elapsed
                             && c.elapsed >= h.elapsed && c.elapsed < 180, "Late/nonmonotonic stage")
            elapsed = c.elapsed
            try Self.require(c.complete && c.guideNodes.count < 4_096 && c.minimalNodes.count < 4_096
                             && c.controlNodes.count < 4_096,
                             "Incomplete public snapshot")
            try Self.require(c.windowIdentifier == "guide-acceptance-window"
                             && c.windowTitle == "Synthetic CLI guide host calibration"
                             && c.windowFrame.positive && c.guide.identifier == "guide-validation-real-guide-root"
                             && c.guide.role == "AXScrollArea"
                             && c.minimal.identifier == "guide-validation-minimal-root",
                             "Wrong consumer window/root identity")
            let controls = h.controls
            try Self.require(controls.omittedIsElement && !controls.ignoredIsElement
                             && controls.omittedInRawTree && controls.ignoredInRawTree
                             && controls.omittedReturned && controls.ignoredReturned
                             && controls.omittedPresses == 1 && controls.ignoredPresses == 1
                             && controls.exposedCountBefore == 0 && controls.exposedCountAfter == 1,
                             "Raw omitted/ignored controls did not discriminate exposure")
            for raw in [controls.omitted, controls.ignored] {
                try Self.require(raw.identifier == "guide-acceptance-oracle-action" && raw.enabled
                                 && raw.role == "AXButton" && raw.frame.positive,
                                 "Omitted/ignored control lacks the formerly accepted attributes")
            }
            let exposed = try Self.unique(c.controlNodes, "guide-acceptance-oracle-action")
            try Self.require(exposed.text.contains("Exposed") && !exposed.text.contains("Omitted")
                             && !exposed.text.contains("Ignored"), "Consumer accepted a raw omitted/ignored node")
            try Self.require(controls.noOp.returned && controls.noOp.before == 0 && controls.noOp.after == 0
                             && controls.noOpPresses == 1 && controls.noOpReaderCalls == 0
                             && !controls.noOpReaderPending && controls.noOpWaitInstalled
                             && !controls.noOpWaitRemaining, "No-op read-start cancellation discriminator failed")
            do {
                try Self.assertAction(controls.noOp, id: "guide-acceptance-oracle-action", before: 0, after: 1)
                throw Failure(description: "No-op was accepted by the actual hybrid action predicate")
            } catch let error as Failure {
                try Self.require(error.description == "False/no-op/wrong AXPress", "No-op rejection was not effect-based")
            }
            try Self.require(p.running && p.active && p.policy == 0 && p.visible && p.key && p.unoccluded
                             && p.exactContentController && p.exactContentView && p.exactGuideParent
                             && p.exactMinimalParent && p.exactGuideWindow && p.exactMinimalWindow
                             && p.guideAppeared && p.minimalAppeared, "Host presentation/lifecycle is not exact")
            try Self.require(p.guideFrame == Rect(CGRect(x: 0, y: 0, width: 600, height: 350))
                             && p.minimalFrame == Rect(CGRect(x: 0, y: 350, width: 600, height: 64))
                             && p.containerFrame.width == 600 && p.containerFrame.height == 414
                             && p.appearance == key.1, "Calibration geometry/appearance differs")
            try Self.require(p.fittingWidth == 600 && p.fittingHeight == 350,
                             "Actual fittingSize differs (public frame is not a substitute)")
            try Self.require(p.document.positive && p.clip.positive, "Missing actual document/clip geometry")
            if caseName == "statuses" && h.stage == "initial-ready" {
                try Self.require(p.document.width <= p.clip.width + 1 && p.document.height > p.clip.height,
                                 "Actual document/clip geometry differs")
            }
            let viewport = Self.consumerViewport(p.clipScreen, screenTop: p.screenTop)
            let minimalViewport = Self.consumerViewport(p.minimalScreen, screenTop: p.screenTop)
            try Self.require(viewport.intersects(c.guide.frame) && viewport.intersects(c.windowFrame),
                             "Actual clip viewport disagrees with public guide/window")
            let prepared = h.stage == "initial-pre-readiness-diagnostic"
            let initial = prepared || h.stage == "initial-ready" || h.stage == "missing-ready"
            if initial {
                let recheck = try Self.unique(c.guideNodes, "cli-integration-recheck")
                if !prepared {
                    try Self.require(h.recheck?.identifier == "cli-integration-recheck"
                                     && h.recheck?.role == "AXButton" && h.recheck?.enabled == true,
                                     "Real host Re-check role/enabled differs")
                }
                try Self.ready(recheck, viewport: viewport, hittable: true)
                let minimal = try Self.unique(c.minimalNodes, "guide-calibration-minimal-action")
                try Self.ready(minimal, viewport: minimalViewport, hittable: true)
                try Self.require(h.copies == 0 && h.readerCalls == 1 && !h.checking && !h.pendingRead,
                                 "Setup/readiness invoked an unintended operation")
                try Self.assertStatus(c.guideNodes, caseName == "statuses" ? key.0 : "missing")
                try Self.require(h.minimalPresses == (prepared ? 0 : 1), "Minimal effect differs")
                try Self.require(h.actions.count == (prepared ? 0 : 1), "Missing/extra readiness action")
                if !prepared { try Self.assertAction(h.actions[0], id: "guide-calibration-minimal-action",
                                                     before: 0, after: 1) }
            }
            if let previous, previous.host.scenario == key.0 && previous.host.appearance == key.1 {
                try Self.require(p.modelIdentity == previous.host.presentation.modelIdentity
                                 && p.windowNumber == previous.host.presentation.windowNumber,
                                 "Mounted model/window replaced during scenario")
            }
            if caseName == "statuses" && !initial {
                try Self.require(h.readerCalls == 1 && !h.pendingRead && !h.checking && h.minimalPresses == 1,
                                 "Status scenario reader/minimal changed")
                if h.stage == "scrolled-bottom" {
                    guard let previous else { throw Failure(description: "Missing pre-scroll observation") }
                    try Self.require(p.clip.x != previous.host.presentation.clip.x
                                     || p.clip.y != previous.host.presentation.clip.y, "Bottom scroll had no effect")
                    try Self.require(h.copies == 0 && h.actions.isEmpty, "Scroll invoked Copy")
                } else {
                    guard let previous else { throw Failure(description: "Missing public pre-action observation") }
                    let previousViewport = Self.consumerViewport(previous.host.presentation.clipScreen,
                                                                  screenTop: previous.host.presentation.screenTop)
                    try Self.ready(Self.unique(previous.consumer.guideNodes, "cli-integration-copy-command"),
                                   viewport: previousViewport)
                    let succeeds = h.stage == "copy-success"
                    let count = succeeds ? 2 : 1
                    try Self.require(h.copies == count && h.actions.count == 1, "Missing/extra Copy effect")
                    try Self.assertAction(h.actions[0], id: "cli-integration-copy-command",
                                          before: count - 1, after: count)
                    try Self.require(h.actions[0].sinkResult == succeeds, "Wrong actual Copy sink result")
                    let notice = succeeds ? "Copied. Run the command in your terminal when ready."
                        : "Could not copy the command. Select and copy the text above."
                    let feedback = try Self.unique(c.guideNodes, "cli-integration-copy-feedback")
                    let copy = try Self.unique(c.guideNodes, "cli-integration-copy-command")
                    try Self.require(feedback.text.contains(notice) && feedback.frame.intersects(viewport)
                                     && copy.value == notice && copy.frame.intersects(viewport),
                                     "Wrong/nonvisible feedback or actual Copy value")
                }
                let bottom = p.flipped ? max(p.document.y, p.document.y + p.document.height - p.clip.height)
                    : p.document.y
                try Self.require(abs(p.clip.y - bottom) <= 1, "Not at actual document bottom")
            }
            if caseName == "recheck" && !initial {
                let recheck = try Self.unique(c.guideNodes, "cli-integration-recheck")
                let calls = h.stage.hasPrefix("unreadable") ? 2 : 3
                try Self.require(h.copies == 0 && h.minimalPresses == 1 && h.readerCalls == calls,
                                 "Retry reader/copy/minimal counts differ")
                if h.stage.hasSuffix("-checking") {
                    guard let previous else { throw Failure(description: "Missing public pre-Re-check observation") }
                    try Self.ready(Self.unique(previous.consumer.guideNodes, "cli-integration-recheck"),
                                   viewport: Self.consumerViewport(previous.host.presentation.clipScreen,
                                                                  screenTop: previous.host.presentation.screenTop))
                    try Self.require(h.pendingRead && h.checking && !recheck.enabled && h.actions.count == 1,
                                     "No real pending read/disabled Re-check")
                    try Self.assertAction(h.actions[0], id: "cli-integration-recheck",
                                          before: calls - 1, after: calls)
                    try Self.require(h.actions[0].pendingRead, "True/no-op press did not start read")
                    let checking = try Self.unique(c.guideNodes, "cli-integration-checking")
                    try Self.require(checking.text.contains("Checking guide content...")
                                     && !c.guideNodes.contains { $0.identifier.hasPrefix("cli-integration-status-") },
                                     "Checking absent or stale status still exposed")
                } else {
                    try Self.require(!h.pendingRead && !h.checking && recheck.enabled && h.actions.isEmpty
                                     && h.observationInstalled && h.observationFired,
                                     "Original view-started read completion not observed")
                    try Self.assertStatus(c.guideNodes, h.stage.hasPrefix("unreadable") ? "unreadable" : "matching")
                }
            }
            let name = Self.imageName(caseName: caseName, scenario: key.0, appearance: key.1, stage: key.2)
            if let name {
                guard let image = h.image else { throw Failure(description: "Missing cacheDisplay capture") }
                try Self.require(image.name == name && image.bytes > 0 && image.pixelsWide > 0
                                 && image.pixelsHigh > 0 && image.backingScale.isFinite && image.backingScale > 0
                                 && image.points == Rect(CGRect(x: 0, y: 0, width: 600, height: 350))
                                 && image.capturedAt <= h.elapsed && image.capturedAt >= 0
                                 && image.capturedAt >= precedingElapsed
                                 && image.sha256.count == 64, "Malformed capture provenance/dimensions")
                // Initial diagnostic is deliberately overwritten by the ready capture, as in the original.
                if !prepared {
                    let url = imageDirectory.appendingPathComponent(name)
                    try Self.require(url.resolvingSymlinksInPath() == url, "Symlink image is not fresh evidence")
                    let data = try Data(contentsOf: url)
                    try Self.require(data.count == image.bytes && Self.digest(data) == image.sha256
                                     && data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
                                     "Missing/mutated/non-PNG capture")
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                        throw Failure(description: "CacheDisplay image cannot be decoded")
                    }
                    try Self.require(decoded.width == image.pixelsWide && decoded.height == image.pixelsHigh,
                                     "Actual PNG dimensions differ from capture observation")
                }
            } else { try Self.require(h.image == nil, "Unexpected image stage") }
            previous = record
        }
        try Self.require(self.elapsed.isFinite && self.elapsed >= completion.elapsed && self.elapsed < 180
                         && completion.invocation == invocation && completion.producer == producer
                         && completion.elapsed >= elapsed && completion.elapsed < 180
                         && completion.cleanups.count == names.count * 2, "Missing/late cleanup evidence")
        for (cleanup, key) in zip(completion.cleanups, names.flatMap { n in Self.appearances.map { (n, $0) } }) {
            try Self.require(cleanup.scenario == key.0 && cleanup.appearance == key.1
                             && cleanup.originalPolicy == cleanup.restoredPolicy
                             && cleanup.policyChangeReturned != false && cleanup.policyRestoreReturned != false
                             && !cleanup.windowVisible && !cleanup.guideHasParent && !cleanup.minimalHasParent
                             && !cleanup.readerPending && !cleanup.readerWaiting
                             && cleanup.elapsed >= 0 && cleanup.elapsed < 180, "Cleanup/lifetime not preserved")
        }
    }

    static func consumerViewport(_ rect: Rect, screenTop: Double) -> Rect {
        Rect(CGRect(x: rect.x, y: screenTop - rect.y - rect.height, width: rect.width, height: rect.height))
    }

    static func assertAction(_ action: Action, id: String, before: Int, after: Int) throws {
        try require(action.identifier == id && action.node.identifier == id && action.returned
                    && action.before == before && action.after == after, "False/no-op/wrong AXPress")
        try ready(action.node, viewport: action.viewport)
    }

    static func validateCurrentInvocation(_ caseName: String) throws {
        let env = ProcessInfo.processInfo.environment
        try require(env["GITHUB_ACTIONS"] == "true" && env["RUNNER_ENVIRONMENT"] == "github-hosted"
                    && Bundle.main.bundleIdentifier == "com.jdylanmc.CMUXMaestroPreview.Validation.Tests",
                    "Original validator requires its exact integrated venue")
        guard let directory = env["CMUX_GUIDE_ACCEPTANCE_DIRECTORY"],
              let invocation = env["CMUX_GUIDE_ACCEPTANCE_INVOCATION"],
              let head = env["CMUX_GUIDE_ACCEPTANCE_HEAD"],
              let tree = env["CMUX_GUIDE_ACCEPTANCE_TREE"],
              let expectedHash = env["CMUX_GUIDE_ACCEPTANCE_" + caseName.uppercased() + "_SHA256"] else {
            throw Failure(description: "Missing same-invocation native acceptance evidence")
        }
        let url = URL(fileURLWithPath: directory)
        try require(url.path == url.standardizedFileURL.resolvingSymlinksInPath().path
                    && url.lastPathComponent == "guide-acceptance"
                    && url.deletingLastPathComponent().lastPathComponent == "scopes-" + invocation,
                    "Acceptance path is not this runner-owned fresh invocation")
        let data = try Data(contentsOf: url.appendingPathComponent(caseName + ".json"))
        try require(data.count < 16_777_216 && digest(data) == expectedHash, "Changed/oversized native evidence")
        let evidence = try JSONDecoder().decode(Self.self, from: data)
        try evidence.validate(caseName: caseName, expectedInvocation: invocation, head: head, tree: tree,
                              imageDirectory: url.appendingPathComponent("images"))
    }
}
