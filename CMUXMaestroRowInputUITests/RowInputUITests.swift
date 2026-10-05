import XCTest

@MainActor
final class RowInputUITests: XCTestCase {
    private var application: XCUIApplication?
    private var caseID: UUID!
    private let fixtureID = "com.jdylanmc.CMUXMaestroPreview.Validation.RowInputFixture"

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true",
              environment["RUNNER_ENVIRONMENT"] == "github-hosted",
              Bundle(for: Self.self).bundleIdentifier ==
                "com.jdylanmc.CMUXMaestroPreview.Validation.RowInputUITests" else {
            throw NSError(domain: "RowInputVenue", code: 78, userInfo: [
                NSLocalizedDescriptionKey: "Refusing UI access outside the exact hosted validation namespace."
            ])
        }
        continueAfterFailure = false
        caseID = UUID()
        let app = XCUIApplication(bundleIdentifier: fixtureID)
        app.launchEnvironment = [
            "GITHUB_ACTIONS": environment["GITHUB_ACTIONS"]!,
            "RUNNER_ENVIRONMENT": environment["RUNNER_ENVIRONMENT"]!,
            "CMUX_ROW_INPUT_CASE": caseID.uuidString
        ]
        application = app
        app.launch()
        XCTAssertTrue(app.windows["row-input-owner"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.windows["row-input-foreign"].exists)
        let initial = try sample("initial")
        XCTAssertEqual(initial.opens, 0)
        XCTAssertEqual(initial.closes, 0)
        XCTAssertEqual(initial.actions, 0)
        XCTAssertEqual(initial.activations, 0)
        XCTAssertEqual(initial.dismissals, 0)
        XCTAssertFalse(try row("owner", in: initial).keyboard)
        XCTAssertTrue(try row("owner", in: initial).titleIsResponder)
    }

    override func tearDownWithError() throws {
        // Only the application constructed after the hosted guard belongs to this test.
        if let application {
            let attachment = XCTAttachment(screenshot: application.screenshot())
            attachment.name = "fixture-final"
            attachment.lifetime = .keepAlways
            add(attachment)
            application.terminate()
        }
        application = nil
    }

    func testEscapePreservesOwnerKeyboardModality() throws {
        let before = try openMenu()
        try app().typeKey(.escape, modifierFlags: [])
        let after = try closedMenu()
        try unchanged(before, after)
        XCTAssertTrue(try row("owner", in: after).keyboard)
        XCTAssertTrue(try row("sibling", in: after).keyboard)
        XCTAssertTrue(try row("owner", in: after).focused)
        XCTAssertTrue(try row("owner", in: after).titleIsResponder)
        XCTAssertTrue(after.ownerKey)
        XCTAssertEqual(after.actions, 0)
        XCTAssertEqual(after.activations, 0)
        XCTAssertEqual(after.dismissals, 2)
    }

    func testOwnerCompleteClickClearsOwnerAndSiblingModality() throws {
        let before = try openMenu()
        try clickOutsideMenu(window: "row-input-owner", receiver: "owner-click")
        let after = try closedMenu()
        try unchanged(before, after)
        XCTAssertFalse(try row("owner", in: after).keyboard)
        XCTAssertFalse(try row("owner", in: after).focused)
        XCTAssertFalse(try row("sibling", in: after).keyboard)
        XCTAssertEqual(after.actions, 0)
        XCTAssertEqual(after.activations, 0)
        XCTAssertEqual(after.dismissals, 2)
    }

    func testForeignCompleteClickPreservesOwnerModality() throws {
        let before = try openMenu()
        try clickOutsideMenu(window: "row-input-foreign", receiver: "foreign-click")
        let after = try closedMenu()
        try unchanged(before, after)
        XCTAssertTrue(try row("owner", in: after).keyboard)
        XCTAssertTrue(try row("sibling", in: after).keyboard)
        XCTAssertTrue(try row("owner", in: after).titleIsResponder)
        XCTAssertEqual(after.actions, 0)
        XCTAssertEqual(after.activations, 0)
        XCTAssertEqual(after.dismissals, 2)
    }

    func testNativeMenuKeyboardTraversalInvokesProductionAction() throws {
        let before = try openMenu()
        let app = try app()
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(app.menuItems["Count action"].waitForExistence(timeout: 2))
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        let after = try closedMenu()
        try unchanged(before, after)
        XCTAssertEqual(after.actions, 1)
        XCTAssertEqual(after.activations, 0)
        XCTAssertEqual(after.dismissals, 2)
        XCTAssertTrue(try row("owner", in: after).keyboard)
        XCTAssertTrue(try row("sibling", in: after).keyboard)
    }

    func testNativeTitleActivationAndTabTraversal() throws {
        let before = try sample("before-title")
        let app = try app()
        app.windows["row-input-owner"].typeKey(.space, modifierFlags: [])
        let activated = try sample("title-activated")
        XCTAssertEqual(activated.activations, 1)
        XCTAssertEqual(activated.dismissals, 1)
        XCTAssertTrue(try row("owner", in: activated).keyboard)
        app.windows["row-input-owner"].typeKey(.tab, modifierFlags: [])
        let traversed = try sample("tab-traversed")
        XCTAssertFalse(try row("owner", in: traversed).titleIsResponder)
        XCTAssertTrue(traversed.rows.contains { $0.id != "foreign" && $0.focused })
        XCTAssertEqual(traversed.activations, 1)
        XCTAssertEqual(traversed.actions, 0)
        XCTAssertEqual(traversed.opens, 0)
        try unchanged(before, traversed)
    }

    func testCompleteClicksReachExactFixtureWindowsWithoutMenu() throws {
        let app = try app()
        app.windows["row-input-owner"].buttons["owner-click"].click()
        let owner = try sample("owner-complete-click")
        XCTAssertEqual(owner.ownerDown, 1)
        XCTAssertEqual(owner.ownerUp, 1)
        XCTAssertEqual(owner.foreignDown, 0)
        XCTAssertEqual(owner.foreignUp, 0)
        app.windows["row-input-foreign"].buttons["foreign-click"].click()
        let foreign = try sample("foreign-complete-click")
        XCTAssertEqual(foreign.ownerDown, 1)
        XCTAssertEqual(foreign.ownerUp, 1)
        XCTAssertEqual(foreign.foreignDown, 1)
        XCTAssertEqual(foreign.foreignUp, 1)
        XCTAssertEqual(foreign.opens, 0)
        XCTAssertEqual(foreign.actions, 0)
        XCTAssertEqual(foreign.activations, 0)
        try unchanged(owner, foreign)
    }

    private func app() throws -> XCUIApplication {
        try XCTUnwrap(application, "Hosted setup must succeed before any UI access")
    }

    private func row(_ id: String, in evidence: RowInputEvidence) throws -> RowInputEvidence.Row {
        try XCTUnwrap(evidence.rows.first { $0.id == id })
    }

    private func sample(_ name: String) throws -> RowInputEvidence {
        let app = try app()
        let element = app.windows["row-input-owner"].descendants(matching: .any)
            .matching(identifier: "row-input-evidence").element
        XCTAssertTrue(element.waitForExistence(timeout: 2))
        let text = try XCTUnwrap(element.value as? String)
        XCTAssertLessThanOrEqual(text.utf8.count, 32_768)
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name + "-render"
        image.lifetime = .keepAlways
        add(image)
        let result = try JSONDecoder().decode(RowInputEvidence.self, from: Data(text.utf8))
        XCTAssertEqual(result.version, 3)
        XCTAssertEqual(result.caseID, caseID)
        XCTAssertTrue(result.live)
        XCTAssertFalse(result.overflow)
        XCTAssertEqual(result.rows.map(\.id), ["owner", "sibling", "foreign"])
        XCTAssertEqual(Set(result.rows.map(\.windowNumber)).count, 2)
        XCTAssertEqual(try row("owner", in: result).windowNumber, try row("sibling", in: result).windowNumber)
        XCTAssertFalse(try row("foreign", in: result).keyboard)
        for row in result.rows {
            XCTAssertGreaterThan(row.windowNumber, 0)
            XCTAssertTrue(row.eligible)
            XCTAssertTrue(row.exteriorFocusRing)
            XCTAssertFalse(row.bordered)
            XCTAssertFalse(row.frame.isEmpty)
            XCTAssertTrue(row.frame.contains(row.titleFrame))
        }
        return result
    }

    private func openMenu() throws -> RowInputEvidence {
        let before = try sample("before-menu")
        let app = try app()
        app.windows["row-input-owner"].typeKey(.F10, modifierFlags: .shift)
        XCTAssertTrue(app.menuItems["Fixture actions"].waitForExistence(timeout: 2))
        let open = try sample("menu-open")
        XCTAssertEqual(open.opens, 1)
        XCTAssertEqual(open.closes, 0)
        XCTAssertTrue(open.tracking)
        XCTAssertTrue(try row("owner", in: open).keyboard)
        XCTAssertTrue(try row("sibling", in: open).keyboard)
        XCTAssertTrue(try row("owner", in: open).focused)
        XCTAssertTrue(try row("owner", in: open).titleIsResponder)
        XCTAssertEqual(open.dismissals, 2)
        try unchanged(before, open)
        return open
    }

    private func clickOutsideMenu(window: String, receiver: String) throws {
        let app = try app()
        let target = app.windows[window].buttons[receiver]
        XCTAssertTrue(target.exists && target.isHittable)
        XCTAssertTrue(app.windows[window].frame.contains(target.frame))
        for menu in app.menus.allElementsBoundByIndex where menu.exists {
            XCTAssertFalse(menu.frame.intersects(target.frame), "Click destination must be outside the actual NSMenu")
        }
        // XCUI synthesizes the complete gesture against this exact element, not a chosen screen point.
        target.click()
    }

    private func closedMenu() throws -> RowInputEvidence {
        let app = try app()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                            object: app.menuItems["Fixture actions"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 2), .completed)
        let result = try sample("menu-closed")
        XCTAssertFalse(result.tracking)
        XCTAssertEqual(result.opens, 1)
        XCTAssertEqual(result.closes, 1)
        return result
    }

    private func unchanged(_ before: RowInputEvidence, _ after: RowInputEvidence) throws {
        XCTAssertEqual(before.ownerFrame, after.ownerFrame)
        XCTAssertEqual(before.foreignFrame, after.foreignFrame)
        for id in ["owner", "sibling", "foreign"] {
            let lhs = try row(id, in: before)
            let rhs = try row(id, in: after)
            XCTAssertEqual(lhs.windowNumber, rhs.windowNumber)
            XCTAssertEqual(lhs.frame, rhs.frame)
            XCTAssertEqual(lhs.titleFrame, rhs.titleFrame)
        }
    }
}
