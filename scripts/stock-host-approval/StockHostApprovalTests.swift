import AppKit
import XCTest

// Initial hosted fixture consent only. Never invoked during acceptance or restoration.
final class StockHostApprovalTests: XCTestCase {
    private struct Context: Decodable {
        let runID: String
        let hostPID: Int32
        let hostPath: String
        let extensionID: String
        let labels: [String]
        let terminalTitle: String
        let evidence: String
    }

    private enum SetupFailure: Error {
        case unavailable(String)
    }

    @MainActor
    func testApproveOwnedNativeFixture() throws {
        continueAfterFailure = false
        executionTimeAllowance = 90
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let contextPath = env["PROBE_APPROVAL_CONTEXT"]
        let hasContext = contextPath?.isEmpty == false
        let hasRunID = env["GITHUB_RUN_ID"]?.isEmpty == false
        var failedGuards: [String] = []
        if home != "/Users/runner" { failedGuards.append("home") }
        if env["GITHUB_ACTIONS"] != "true" { failedGuards.append("GITHUB_ACTIONS") }
        if env["RUNNER_ENVIRONMENT"] != "github-hosted" { failedGuards.append("RUNNER_ENVIRONMENT") }
        if !hasContext { failedGuards.append("PROBE_APPROVAL_CONTEXT") }
        if !hasRunID { failedGuards.append("GITHUB_RUN_ID") }
        let fixturePath = contextPath.flatMap { path -> String? in
            guard path.hasPrefix("/Users/runner/"),
                  path.hasSuffix("/stock-host-update/ui-approval-context.json"),
                  URL(fileURLWithPath: path).standardizedFileURL.path == path else { return nil }
            return String(path.prefix(1024))
        }
        if hasContext && fixturePath == nil { failedGuards.append("contextPathShape") }
        let diagnostic: [String: Any] = [
            "kind": "hosted-approval-guard", "actualHome": String(home.prefix(1024)),
            "homeMatches": home == "/Users/runner",
            "githubActionsPresent": env["GITHUB_ACTIONS"] != nil,
            "githubActionsMatches": env["GITHUB_ACTIONS"] == "true",
            "runnerEnvironmentPresent": env["RUNNER_ENVIRONMENT"] != nil,
            "runnerEnvironmentMatches": env["RUNNER_ENVIRONMENT"] == "github-hosted",
            "contextPathPresent": hasContext, "runIDPresent": hasRunID,
            "contextPath": fixturePath ?? "(missing or invalid fixture path)",
            "contextFileReadable": home == "/Users/runner"
                && fixturePath.map { FileManager.default.isReadableFile(atPath: $0) } == true,
            "failedGuards": failedGuards
        ]
        let diagnosticData = try JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys])
        FileHandle.standardOutput.write(Data("PROBE_APPROVAL_GUARD ".utf8) + diagnosticData + Data("\n".utf8))
        let attachment = XCTAttachment(data: diagnosticData, uniformTypeIdentifier: "public.json")
        attachment.name = "hosted-approval-guard"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard failedGuards.isEmpty, let path = contextPath else {
            throw SetupFailure.unavailable("Hosted-only UI setup guard failed: \(failedGuards.joined(separator: ", "))")
        }
        let context = try JSONDecoder().decode(Context.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard context.runID == env["GITHUB_RUN_ID"],
              context.hostPath == "/Applications/cmux.app",
              context.extensionID == "com.jdylanmc.CMUXMaestroPreview.Extension",
              !context.labels.isEmpty,
              context.evidence == URL(fileURLWithPath: path).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("stock-host-update-evidence").path else {
            throw SetupFailure.unavailable("Wrong fixture scope")
        }
        let output = URL(fileURLWithPath: context.evidence)
        let resultPath = output.appendingPathComponent("approval-result.json")
        var result: [String: Any] = [
            "scope": "first-time public UI fixture consent, not installer or update capability",
            "runID": context.runID, "hostPID": context.hostPID, "extensionID": context.extensionID,
            "status": "started", "stage": "verify-existing-stock"
        ]
        func save(_ stage: String) throws {
            result["stage"] = stage
            result["time"] = Date().timeIntervalSince1970
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: resultPath, options: .atomic)
        }
        func verifyHost() throws {
            guard let host = NSRunningApplication(processIdentifier: context.hostPID),
                  host.bundleIdentifier == "com.cmuxterm.app",
                  host.bundleURL?.standardizedFileURL.path == context.hostPath else {
                throw SetupFailure.unavailable("Declared stock process was lost; no relaunch")
            }
        }
        try save("verify-existing-stock")
        try verifyHost()
        let app = XCUIApplication(url: URL(fileURLWithPath: context.hostPath))
        func capture(_ stage: String) throws {
            try save(stage)
            let hierarchy = String(app.debugDescription.prefix(262_144))
            try hierarchy.write(to: output.appendingPathComponent("approval-\(stage).txt"),
                                atomically: true, encoding: .utf8)
            let image = app.screenshot()
            try image.pngRepresentation.write(to: output.appendingPathComponent("approval-\(stage).png"))
            let attachment = XCTAttachment(screenshot: image)
            attachment.name = stage
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        func wait(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            repeat {
                if condition() { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            } while Date() < deadline
            return false
        }
        func state(_ element: XCUIElement) -> Int? {
            if let value = element.value as? NSNumber { return value.intValue }
            if let value = element.value as? String { return Int(value) }
            return nil
        }
        do {
            try save("activate-existing-stock-setup-only")
            app.activate() // Public API preserves an already-running instance, unlike launch().
            try verifyHost()
            try capture("before")
            let manage = app.buttons.matching(identifier: "Manage")
            guard manage.firstMatch.waitForExistence(timeout: 10), manage.count == 1,
                  manage.firstMatch.isHittable else {
                throw SetupFailure.unavailable("Stock Manage control unavailable or ambiguous")
            }
            try save("open-stock-extension-browser")
            manage.firstMatch.click()
            let labels = Set(context.labels)
            func controls() -> [XCUIElement] {
                let toggles = app.checkBoxes.allElementsBoundByIndex + app.switches.allElementsBoundByIndex
                let direct = toggles.filter { labels.contains($0.label) || labels.contains($0.identifier) }
                if !direct.isEmpty { return direct }
                let rows = app.tableRows.allElementsBoundByIndex.filter { row in
                    row.staticTexts.allElementsBoundByIndex.contains { labels.contains($0.label) }
                }
                guard rows.count == 1 else { return [] }
                return rows[0].checkBoxes.allElementsBoundByIndex + rows[0].switches.allElementsBoundByIndex
            }
            guard wait(15, { controls().count == 1 }) else {
                try capture("unavailable-browser")
                throw SetupFailure.unavailable("No unique public approval toggle for the registered fixture")
            }
            try capture("browser")
            let toggle = controls()[0]
            guard toggle.isHittable, let before = state(toggle), before == 0 || before == 1 else {
                throw SetupFailure.unavailable("Fixture approval toggle has unknown state")
            }
            result["control"] = ["label": toggle.label, "identifier": toggle.identifier, "before": before]
            try save("approve-only-owned-fixture")
            if before == 0 { toggle.click() }
            // Only a stock-owned, explicitly named fixture confirmation may be accepted.
            var confirmationHandled = false
            var confirmationFailure: String?
            let enabled = wait(15) {
                if state(toggle) == 1 { return true }
                let dialogs = (app.alerts.allElementsBoundByIndex + app.dialogs.allElementsBoundByIndex)
                    .filter { alert in
                        alert.staticTexts.allElementsBoundByIndex.contains { text in
                            labels.contains(where: { text.label.contains($0) })
                        }
                    }
                if dialogs.count == 1 && !confirmationHandled {
                    if dialogs[0].secureTextFields.count != 0 {
                        confirmationFailure = "Public approval requires credentials; none will be used"
                        return true
                    }
                    let allow = dialogs[0].buttons.matching(identifier: "Allow")
                    if allow.count == 1 && allow.firstMatch.isHittable {
                        allow.firstMatch.click()
                        confirmationHandled = true
                    }
                }
                return false
            }
            guard enabled && confirmationFailure == nil && state(toggle) == 1 else {
                throw SetupFailure.unavailable(confirmationFailure ?? "Public fixture approval did not become enabled")
            }
            result["confirmationHandled"] = confirmationHandled
            result["after"] = state(toggle)
            try capture("enabled")
            let terminal = app.buttons.matching(identifier: context.terminalTitle)
            guard terminal.count == 1 && terminal.firstMatch.isHittable else {
                throw SetupFailure.unavailable("Cannot return to the declared terminal tab without guessing")
            }
            try save("return-to-original-terminal-setup-only")
            terminal.firstMatch.click()
            let approvalRequired = app.staticTexts[
                "An installed sidebar extension needs approval before CMUX can use it."
            ]
            guard wait(15, { !approvalRequired.exists }) else {
                throw SetupFailure.unavailable("Stock still reports first-time approval required")
            }
            guard !app.staticTexts["Extension Blocked"].exists else {
                throw SetupFailure.unavailable("Approval changed, but stock reports a blocked extension")
            }
            try verifyHost()
            try capture("returned-terminal")
            result["status"] = "enabled-via-public-ui"
            result["requiresKernelLoadedProof"] = true
            try save("setup-ui-complete")
        } catch {
            result["status"] = "failed"
            result["failedStage"] = result["stage"]
            result["error"] = String(describing: error)
            try save("setup-ui-failed")
            throw error
        }
    }
}
