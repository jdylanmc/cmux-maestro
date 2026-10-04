import XCTest

#if !CMUX_GUIDE_UI_VALIDATION
#error("The public UI probe requires its dedicated validation target.")
#endif

final class GuideConsumerReadinessTests: XCTestCase {
    private enum ProbeFailure: Error {
        case failed(String)
    }

    @MainActor
    func testMinimalEventThenRealGuideIdentifiers() throws {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 180
        continueAfterFailure = false
        var phase = "venue"
        var window: XCUIElement?

        func remaining() throws -> TimeInterval {
            let value = deadline - ProcessInfo.processInfo.systemUptime
            guard value > 0 else { throw ProbeFailure.failed("180-second active-case deadline: \(phase)") }
            return value
        }
        func require(_ condition: Bool, _ message: String) throws {
            _ = try remaining()
            guard condition else { throw ProbeFailure.failed(message) }
        }
        func record(_ state: String) {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let attachment = XCTAttachment(string: "phase=\(phase) state=\(state) elapsedSeconds=\(elapsed)")
            attachment.name = "\(phase)-\(state)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        func begin(_ name: String) throws {
            phase = name
            record("started")
            _ = try remaining()
        }
        func wait(_ object: Any, _ predicate: NSPredicate) throws {
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: object)
            let result = XCTWaiter.wait(for: [expectation], timeout: try remaining())
            try require(result == .completed, "Public UI wait failed: \(phase), \(result.rawValue)")
        }
        func unique(_ query: XCUIElementQuery) throws -> XCUIElement {
            try wait(query, NSPredicate(format: "count == 1"))
            try require(query.count == 1, "Expected exactly one element: \(phase)")
            return query.element
        }
        func exact(_ root: XCUIElement, _ identifier: String) throws -> XCUIElement {
            try unique(root.descendants(matching: .any).matching(identifier: identifier))
        }

        do {
            record("started")
            let environment = ProcessInfo.processInfo.environment
            guard let githubActions = environment["GITHUB_ACTIONS"], githubActions == "true",
                  let runnerEnvironment = environment["RUNNER_ENVIRONMENT"], runnerEnvironment == "github-hosted" else {
                throw ProbeFailure.failed("Public UI execution requires original GitHub-hosted venue values.")
            }
            try require(Bundle(for: Self.self).bundleIdentifier
                        == "com.jdylanmc.CMUXMaestroPreview.Validation.Tests.GuideUITests",
                        "Unexpected UI test bundle.")
            guard let path = environment["CMUX_GUIDE_UI_HOST_PATH"] else {
                throw ProbeFailure.failed("Missing exact built guide host path.")
            }
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            try require(url.path == path && url.lastPathComponent == "CMUXMaestroGuideUIHost.app",
                        "Guide host must be the exact canonical built application.")
            try require(Bundle(url: url)?.bundleIdentifier
                        == "com.jdylanmc.CMUXMaestroPreview.Validation.Tests.GuideHost",
                        "Unexpected guide host bundle.")
            record("passed")

            try begin("launch")
            let app = XCUIApplication(url: url)
            app.launchEnvironment = [
                "GITHUB_ACTIONS": githubActions,
                "RUNNER_ENVIRONMENT": runnerEnvironment
            ]
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            // Public launch/click/query calls are synchronous; remaining-time waits cannot preempt them.
            app.launch()
            try require(app.wait(for: .runningForeground, timeout: try remaining()), "Host did not launch foreground.")
            record("passed")

            try begin("window-root")
            let subjectWindow = try unique(app.windows.matching(NSPredicate(
                format: "label == %@", "Synthetic CLI guide validation"
            )))
            window = subjectWindow
            try require(subjectWindow.frame.width > 0 && subjectWindow.frame.height > 0,
                        "Synthetic window has no visible frame.")
            let minimalRoot = try exact(subjectWindow, "guide-validation-minimal-root")
            record("passed")

            try begin("minimal")
            let counter = try exact(subjectWindow, "guide-validation-minimal-count")
            try wait(counter, NSPredicate(format: "label == %@", "Synthetic minimal count: 0"))
            let button = try exact(minimalRoot, "guide-validation-minimal-button")
            try require(button.elementType == .button, "Minimal element is not a public button.")
            try wait(button, NSPredicate(format: "enabled == true AND hittable == true"))
            try require(button.frame.width > 0 && button.frame.height > 0, "Minimal button has no frame.")
            button.click()
            _ = try remaining()
            try wait(counter, NSPredicate(format: "label == %@", "Synthetic minimal count: 1"))
            record("passed")

            try begin("guide-root")
            let guide = try exact(subjectWindow, "guide-validation-real-guide-root")
            try require(guide.frame.width > 0 && guide.frame.height > 0, "Guide root has no frame.")
            record("passed")

            try begin("guide-identifiers")
            let recheck = try exact(guide, "cli-integration-recheck")
            try require(recheck.elementType == .button && recheck.isEnabled && recheck.label == "Re-check",
                        "Real guide Re-check attributes differ.")
            for path in [".agents/skills/maestro/SKILL.md", ".copilot/skills/maestro/SKILL.md"] {
                let status = try exact(guide, "cli-integration-status-" + path)
                let text = status.label + "\n" + (status.value as? String ?? "")
                try require(text.contains("Missing") && text.contains("~/" + path)
                            && text.contains("No guide found at this location."),
                            "Real guide status lacks expected accessible text: \(path)")
            }
            let copyCounter = try exact(subjectWindow, "guide-validation-copy-count")
            try require(copyCounter.label == "Synthetic copy count: 0", "Initial probe unexpectedly invoked Copy.")
            let screenshot = XCTAttachment(screenshot: guide.screenshot())
            screenshot.name = "real-guide-initial-identifiers"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            _ = try remaining()
            record("passed")
        } catch {
            record("failed")
            if let window, window.exists {
                let screenshot = XCTAttachment(screenshot: window.screenshot())
                screenshot.name = "\(phase)-failure-synthetic-window"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
            XCTFail("Guide consumer probe failed in \(phase): \(error)")
            throw error
        }
    }
}
