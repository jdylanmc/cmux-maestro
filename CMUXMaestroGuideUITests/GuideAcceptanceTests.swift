import XCTest

#if !CMUX_GUIDE_UI_VALIDATION
#error("Acceptance producers require the dedicated public UI test target.")
#endif

final class GuideAcceptanceTests: XCTestCase {
    typealias Evidence = GuideAcceptanceEvidence

    @MainActor
    func testSyntheticStatusesRetainNativeSizeScrollingAndAccessibleActions() throws {
        try exercise("statuses")
    }

    @MainActor
    func testNativeRecheckDrivesCheckingChangedStatusAndRetry() throws {
        try exercise("recheck")
    }

    @MainActor
    private func exercise(_ caseName: String) throws {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 180
        continueAfterFailure = false
        func remaining() throws -> Double {
            let value = deadline - ProcessInfo.processInfo.systemUptime
            try Evidence.require(value > 0, "180-second entire native acceptance case exceeded")
            return value
        }
        func wait(_ object: Any, _ predicate: NSPredicate) throws {
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: object)],
                                       timeout: try remaining())
            _ = try remaining()
            try Evidence.require(result == .completed, "Native acceptance observation did not arrive")
        }
        func unique(_ query: XCUIElementQuery) throws -> XCUIElement {
            try wait(query, NSPredicate(format: "count == 1"))
            try Evidence.require(query.count == 1, "Missing/duplicate public element")
            _ = try remaining()
            return query.element
        }
        let environment = ProcessInfo.processInfo.environment
        try Evidence.require(environment["GITHUB_ACTIONS"] == "true"
                             && environment["RUNNER_ENVIRONMENT"] == "github-hosted"
                             && Bundle(for: Self.self).bundleIdentifier
                             == "com.jdylanmc.CMUXMaestroPreview.Validation.Tests.GuideUITests",
                             "Acceptance requires original hosted venue and exact UI bundle")
        guard let path = environment["CMUX_GUIDE_UI_HOST_PATH"],
              let directory = environment["CMUX_GUIDE_ACCEPTANCE_DIRECTORY"],
              let invocation = environment["CMUX_GUIDE_ACCEPTANCE_INVOCATION"],
              let head = environment["CMUX_GUIDE_ACCEPTANCE_HEAD"],
              let tree = environment["CMUX_GUIDE_ACCEPTANCE_TREE"],
              let producer = Evidence.producers[caseName] else {
            throw Evidence.Failure(description: "Missing runner-owned acceptance context")
        }
        let host = URL(fileURLWithPath: path)
        let output = URL(fileURLWithPath: directory)
        try Evidence.require(host.standardizedFileURL.resolvingSymlinksInPath().path == path
                             && host.lastPathComponent == "CMUXMaestroGuideUIHost.app"
                             && Bundle(url: host)?.bundleIdentifier
                             == "com.jdylanmc.CMUXMaestroPreview.Validation.Tests.GuideHost",
                             "Wrong canonical built host")
        let app = XCUIApplication(url: host)
        app.launchEnvironment = [
            "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
            "CMUX_GUIDE_ACCEPTANCE_CASE": caseName, "CMUX_GUIDE_ACCEPTANCE_DIRECTORY": directory,
            "CMUX_GUIDE_ACCEPTANCE_INVOCATION": invocation, "CMUX_GUIDE_ACCEPTANCE_HEAD": head,
            "CMUX_GUIDE_ACCEPTANCE_TREE": tree, "CMUX_GUIDE_ACCEPTANCE_STARTED": String(started)
        ]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        var stages: [Evidence.Stage] = []
        defer { app.terminate() }
        do {
            app.launch()
            _ = try remaining()
            try Evidence.require(app.wait(for: .runningForeground, timeout: try remaining()), "Host not foreground")
            let scenarios = (caseName == "statuses" ? Evidence.scenarios : ["recheck"])
                .flatMap { scenario in Evidence.appearances.map { (scenario, $0) } }
            let phases = caseName == "statuses" ? Evidence.statusStages : Evidence.recheckStages
            var ordinal = 0
            for (scenario, appearance) in scenarios {
                for stage in phases {
                    let windows = app.windows.matching(NSPredicate(
                        format: "identifier == %@ AND title == %@",
                        "guide-acceptance-window", "Synthetic CLI guide host calibration"))
                    let window = try unique(windows)
                    let observations = window.descendants(matching: .any)
                        .matching(identifier: "guide-acceptance-observation")
                    let observation = try unique(observations)
                    let prefix = "\(ordinal)|"
                    try wait(observation, NSPredicate { _, _ in
                        guard let value = observation.value as? String else { return false }
                        return value.hasPrefix(prefix) || value.hasPrefix("ERROR|")
                    })
                    guard let value = observation.value as? String, value.hasPrefix(prefix),
                          let data = Data(base64Encoded: String(value.dropFirst(prefix.count))) else {
                        throw Evidence.Failure(description: "Invalid/failed fixed host observation: \(observation.value ?? "")")
                    }
                    let measured = try JSONDecoder().decode(Evidence.HostStage.self, from: data)
                    try Evidence.require(measured.scenario == scenario && measured.appearance == appearance
                                         && measured.stage == stage && measured.invocation == invocation,
                                         "Host advanced outside fixed matrix")
                    // One complete snapshot per subject, not repeated expensive per-field queries.
                    let guideElement = try unique(window.descendants(matching: .any)
                        .matching(identifier: "guide-validation-real-guide-root"))
                    let minimalElement = try unique(window.descendants(matching: .any)
                        .matching(identifier: "guide-validation-minimal-root"))
                    let guideSnapshot = try guideElement.snapshot()
                    let minimalSnapshot = try minimalElement.snapshot()
                    let controlsElement = try unique(window.descendants(matching: .any)
                        .matching(identifier: "guide-acceptance-controls"))
                    let controlNodes = try flatten(controlsElement.snapshot())
                    var guideNodes = try flatten(guideSnapshot)
                    var minimalNodes = try flatten(minimalSnapshot)
                    let initial = stage == "initial-pre-readiness-diagnostic"
                        || stage == "initial-ready" || stage == "missing-ready"
                    if initial {
                        try addHittability("cli-integration-recheck", root: guideElement, nodes: &guideNodes)
                        try addHittability("guide-calibration-minimal-action", root: minimalElement, nodes: &minimalNodes)
                    }
                    let consumer = Evidence.Consumer(
                        windowIdentifier: window.identifier, windowTitle: window.title, windowFrame: .init(window.frame),
                        guide: node(guideSnapshot), minimal: node(minimalSnapshot), guideNodes: guideNodes,
                        minimalNodes: minimalNodes, controlNodes: controlNodes, complete: true,
                        elapsed: ProcessInfo.processInfo.systemUptime - started)
                    let record = Evidence.Stage(host: measured, consumer: consumer)
                    stages.append(record)
                    let attachment = XCTAttachment(data: try JSONEncoder().encode(record), uniformTypeIdentifier: "public.json")
                    attachment.name = "guide-stage-\(ordinal)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    _ = try remaining()
                    // Public observations must precede the fixture dispatch of the real exposed AX action.
                    let viewport = Evidence.consumerViewport(measured.presentation.clipScreen,
                                                              screenTop: measured.presentation.screenTop)
                    if stage == "initial-pre-readiness-diagnostic" {
                        try Evidence.ready(Evidence.unique(guideNodes, "cli-integration-recheck"),
                                           viewport: viewport, hittable: true)
                        try Evidence.ready(Evidence.unique(minimalNodes, "guide-calibration-minimal-action"),
                                           viewport: Evidence.consumerViewport(measured.presentation.minimalScreen,
                                                                                screenTop: measured.presentation.screenTop),
                                           hittable: true)
                        try Evidence.assertStatus(guideNodes, caseName == "statuses" ? scenario : "missing")
                    }
                    if stage == "scrolled-bottom" || stage == "copy-failure" {
                        try Evidence.ready(Evidence.unique(guideNodes, "cli-integration-copy-command"), viewport: viewport)
                    } else if caseName == "recheck" && (stage == "missing-ready" || stage == "unreadable-completed") {
                        try Evidence.ready(Evidence.unique(guideNodes, "cli-integration-recheck"), viewport: viewport)
                    }
                    if stage.hasSuffix("-checking") {
                        try Evidence.require(measured.pendingRead && measured.checking
                                             && !Evidence.unique(guideNodes, "cli-integration-recheck").enabled
                                             && !guideNodes.contains { $0.identifier.hasPrefix("cli-integration-status-") },
                                             "Release refused before actual pending/disabled/absent-status checks")
                        try Evidence.require(Evidence.unique(guideNodes, "cli-integration-checking").text
                            .contains("Checking guide content..."), "Missing checking text before release")
                    }
                    let next = try unique(window.buttons.matching(identifier: "guide-acceptance-next"))
                    try wait(next, NSPredicate(format: "enabled == true AND hittable == true"))
                    next.click()
                    _ = try remaining()
                    ordinal += 1
                }
            }
            try wait(app.windows.matching(identifier: "guide-acceptance-window"), NSPredicate(format: "count == 0"))
            // Closing the final observed window precedes reading this fixed completion artifact.
            let completion = try JSONDecoder().decode(Evidence.Completion.self,
                from: Data(contentsOf: output.appendingPathComponent(caseName + "-completion.json")))
            var evidence = Evidence(schemaVersion: 1, invocation: invocation, producer: producer,
                                    sourceHead: head, sourceTree: tree, elapsed: ProcessInfo.processInfo.systemUptime - started,
                                    stages: stages, completion: completion)
            try evidence.validate(caseName: caseName, expectedInvocation: invocation, head: head, tree: tree,
                                  imageDirectory: output.appendingPathComponent("images"))
            _ = try remaining()
            evidence.elapsed = ProcessInfo.processInfo.systemUptime - started
            let attachment = XCTAttachment(data: try JSONEncoder().encode(evidence), uniformTypeIdentifier: "public.json")
            attachment.name = "guide-acceptance-" + caseName
            attachment.lifetime = .keepAlways
            add(attachment)
            _ = try remaining()
        } catch {
            let failure = XCTAttachment(string: "case=\(caseName) observedStages=\(stages.count) error=\(error)")
            failure.name = "guide-acceptance-failure"
            failure.lifetime = .keepAlways
            add(failure)
            let abort = app.buttons.matching(identifier: "guide-acceptance-abort")
            if abort.count == 1 && abort.element.isHittable {
                abort.element.click()
                let time = max(0, deadline - ProcessInfo.processInfo.systemUptime)
                let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"),
                    object: app.windows.matching(identifier: "guide-acceptance-window"))
                let result = XCTWaiter.wait(for: [closed], timeout: time)
                if result != .completed {
                    XCTFail("Synthetic failure cleanup was not observed within the original case budget.")
                }
            }
            throw error
        }
    }

    @MainActor
    private func addHittability(_ id: String, root: XCUIElement, nodes: inout [Evidence.Node]) throws {
        let query = root.descendants(matching: .any).matching(identifier: id)
        try Evidence.require(query.count == 1, "Missing/duplicate public action for hittability")
        guard let index = nodes.firstIndex(where: { $0.identifier == id }) else {
            throw Evidence.Failure(description: "Action missing from complete snapshot")
        }
        nodes[index].hittable = query.element.isHittable
    }

    @MainActor
    private func node(_ snapshot: XCUIElementSnapshot) -> Evidence.Node {
        let role: String
        switch snapshot.elementType {
        case .button: role = "AXButton"
        case .scrollView: role = "AXScrollArea"
        default: role = String(snapshot.elementType.rawValue)
        }
        return .init(identifier: snapshot.identifier, role: role, enabled: snapshot.isEnabled,
                     label: snapshot.label, title: snapshot.title, value: snapshot.value as? String,
                     frame: .init(snapshot.frame), hittable: nil)
    }

    @MainActor
    private func flatten(_ root: XCUIElementSnapshot) throws -> [Evidence.Node] {
        var pending = root.children
        var nodes: [Evidence.Node] = []
        while !pending.isEmpty && nodes.count < 4_096 {
            let next = pending.removeLast()
            nodes.append(node(next))
            pending += next.children
        }
        try Evidence.require(pending.isEmpty, "Public snapshot exceeded 4096 nodes")
        return nodes
    }
}
