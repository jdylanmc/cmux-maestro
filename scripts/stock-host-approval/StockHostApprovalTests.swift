import AppKit
import Darwin
import XCTest

// Initial hosted fixture consent only. Never invoked during acceptance or restoration.
final class StockHostApprovalTests: XCTestCase {
    private struct Context: Decodable {
        let schema: Int
        let runID: String
        let nonce: String
        let runnerUID: UInt32
        let hostPID: Int32
        let hostPath: String
        let extensionID: String
        let labels: [String]
        let terminalTitle: String
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
        let expectedTestBundle = "com.jdylanmc.CMUXMaestroPreview.HostApprovalTests"
        let expectedRunnerBundle = expectedTestBundle + ".xctrunner"
        let expectedContainer = "/Users/runner/Library/Containers/\(expectedRunnerBundle)/Data"
        let account = getpwuid(getuid())
        let accountUID = account?.pointee.pw_uid
        let accountName = account.map { String(cString: $0.pointee.pw_name) }
        let accountHome = account.map { String(cString: $0.pointee.pw_dir) }
        let actualRunnerBundle = Bundle.main.bundleIdentifier
        let actualTestBundle = Bundle(for: StockHostApprovalTests.self).bundleIdentifier
        let contextData = env["PROBE_APPROVAL_CONTEXT_JSON"].map { Data($0.utf8) }
        let hasContext = contextData.map { !$0.isEmpty && $0.count <= 8192 } == true
        let hasRunID = env["GITHUB_RUN_ID"]?.isEmpty == false
        var failedGuards: [String] = []
        if getuid() == 0 || getuid() != geteuid() { failedGuards.append("nonRootUID") }
        if accountUID != getuid() || accountName != "runner" || accountHome != "/Users/runner" {
            failedGuards.append("runnerAccount")
        }
        if actualRunnerBundle != expectedRunnerBundle { failedGuards.append("runnerBundle") }
        if actualTestBundle != expectedTestBundle { failedGuards.append("testBundle") }
        if home != expectedContainer { failedGuards.append("exactRunnerContainer") }
        if env["GITHUB_ACTIONS"] != "true" { failedGuards.append("GITHUB_ACTIONS") }
        if env["RUNNER_ENVIRONMENT"] != "github-hosted" { failedGuards.append("RUNNER_ENVIRONMENT") }
        if !hasContext { failedGuards.append("boundedContextJSON") }
        if !hasRunID { failedGuards.append("GITHUB_RUN_ID") }
        let diagnostic: [String: Any] = [
            "kind": "hosted-approval-guard", "actualHome": String(home.prefix(1024)),
            "uid": getuid(), "euid": geteuid(),
            "accountName": String((accountName ?? "(unavailable)").prefix(256)),
            "accountHome": String((accountHome ?? "(unavailable)").prefix(1024)),
            "runnerBundle": String((actualRunnerBundle ?? "(unavailable)").prefix(256)),
            "testBundle": String((actualTestBundle ?? "(unavailable)").prefix(256)),
            "containerMatches": home == expectedContainer,
            "githubActionsPresent": env["GITHUB_ACTIONS"] != nil,
            "githubActionsMatches": env["GITHUB_ACTIONS"] == "true",
            "runnerEnvironmentPresent": env["RUNNER_ENVIRONMENT"] != nil,
            "runnerEnvironmentMatches": env["RUNNER_ENVIRONMENT"] == "github-hosted",
            "boundedContextPresent": hasContext, "contextBytes": contextData?.count ?? 0,
            "runIDPresent": hasRunID,
            "failedGuards": failedGuards
        ]
        let diagnosticData = try JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys])
        FileHandle.standardOutput.write(Data("PROBE_APPROVAL_GUARD ".utf8) + diagnosticData + Data("\n".utf8))
        let attachment = XCTAttachment(data: diagnosticData, uniformTypeIdentifier: "public.json")
        attachment.name = "approval-guard"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard failedGuards.isEmpty, let contextData else {
            throw SetupFailure.unavailable("Hosted-only UI setup guard failed: \(failedGuards.joined(separator: ", "))")
        }
        let context = try JSONDecoder().decode(Context.self, from: contextData)
        guard context.schema == 1, context.runID == env["GITHUB_RUN_ID"],
              context.runnerUID == getuid(), UUID(uuidString: context.nonce) != nil,
              context.hostPID > 1,
              context.hostPath == "/Applications/cmux.app",
              context.extensionID == "com.jdylanmc.CMUXMaestroPreview.Extension",
              !context.labels.isEmpty, context.labels.count <= 8,
              context.labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              context.terminalTitle == "/usr/bin/env" else {
            throw SetupFailure.unavailable("Wrong fixture scope")
        }
        var result: [String: Any] = [
            "schema": 1, "nonce": context.nonce, "runnerUID": context.runnerUID,
            "scope": "first-time public UI fixture consent, not installer or update capability",
            "runID": context.runID, "hostPID": context.hostPID, "extensionID": context.extensionID,
            "status": "started", "stage": "verify-existing-stock"
        ]
        func save(_ stage: String) throws {
            result["stage"] = stage
            result["time"] = Date().timeIntervalSince1970
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "approval-result-\(stage)"
            attachment.lifetime = .keepAlways
            add(attachment)
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
            let description = XCTAttachment(string: hierarchy)
            description.name = "approval-hierarchy-\(stage)"
            description.lifetime = .keepAlways
            add(description)
            let image = app.screenshot()
            let attachment = XCTAttachment(screenshot: image)
            attachment.name = "approval-screenshot-\(stage)"
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
            func textValues(_ element: XCUIElement) -> [String] {
                [element.label, element.identifier] + ((element.value as? String).map { [$0] } ?? [])
            }
            func controls() -> [(toggle: XCUIElement, fixtureText: String)] {
                let rows = app.groups.allElementsBoundByIndex + app.tableRows.allElementsBoundByIndex
                return rows.compactMap { row -> (toggle: XCUIElement, fixtureText: String)? in
                    let names = row.children(matching: .staticText).allElementsBoundByIndex.compactMap {
                        textValues($0).first(where: { labels.contains($0) })
                    }
                    let toggles = row.children(matching: .checkBox).allElementsBoundByIndex
                        + row.children(matching: .switch).allElementsBoundByIndex
                    guard names.count == 1, toggles.count == 1 else { return nil }
                    return (toggles[0], names[0])
                }
            }
            guard wait(15, { controls().count == 1 }) else {
                try capture("unavailable-browser")
                throw SetupFailure.unavailable("No unique public approval toggle for the registered fixture")
            }
            try capture("browser")
            let associated = controls()
            guard associated.count == 1 else {
                throw SetupFailure.unavailable("Fixture row/toggle association changed or is ambiguous")
            }
            let toggle = associated[0].toggle
            guard toggle.isHittable, let before = state(toggle), before == 0 || before == 1 else {
                throw SetupFailure.unavailable("Fixture approval toggle has unknown state")
            }
            result["control"] = ["label": toggle.label, "identifier": toggle.identifier, "before": before,
                                 "fixtureText": associated[0].fixtureText,
                                 "association": "single toggle beside exact direct-child text in row Group"]
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
                            textValues(text).contains { value in labels.contains(where: { value.contains($0) }) }
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
            func hasExactText(_ value: String) -> Bool {
                let exact = NSPredicate(format: "label == %@ OR value == %@ OR identifier == %@",
                                        value, value, value)
                return app.descendants(matching: .any).matching(exact).firstMatch.exists
            }
            guard wait(15, { !hasExactText("An installed sidebar extension needs approval before CMUX can use it.") }) else {
                throw SetupFailure.unavailable("Stock still reports first-time approval required")
            }
            guard !hasExactText("Extension Blocked") else {
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
