import XCTest

final class DockPriorityUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    @MainActor
    func testPriorityListAndTemporaryChoicesReflectStandardFixture() throws {
        launchStandardFixture()

        assertPriorityRow(1, contains: "Studio Display")
        assertPriorityRow(2, contains: "Projector")
        assertPriorityRow(2, contains: "Disconnected")
        assertPriorityRow(3, contains: "KVM Display")

        XCTAssertTrue(app.buttons["Show Dock temporarily on Studio Display"].exists)
        XCTAssertTrue(app.buttons["Show Dock temporarily on KVM Display"].exists)
        XCTAssertFalse(app.buttons["Show Dock temporarily on Projector"].exists)

        XCTAssertFalse(app.staticTexts["Profiles"].exists)
        XCTAssertFalse(app.buttons["Profiles"].exists)
        XCTAssertFalse(app.staticTexts["Default Anchor"].exists)
        XCTAssertFalse(app.buttons["Default Anchor"].exists)
    }

    @MainActor
    func testPriorityMoveChangesSavedRowOrder() throws {
        launchStandardFixture()

        let moveDown = app.buttons["priorityDown.1"]
        XCTAssertTrue(moveDown.waitForExistence(timeout: 2))
        moveDown.click()

        assertPriorityRow(1, contains: "Projector")
        assertPriorityRow(2, contains: "Studio Display")
        assertPriorityRow(3, contains: "KVM Display")
    }

    @MainActor
    func testTemporarySelectionAndReturnDoNotChangePriorityOrder() throws {
        launchStandardFixture()

        let temporaryKVM = app.buttons["Show Dock temporarily on KVM Display"]
        XCTAssertTrue(temporaryKVM.waitForExistence(timeout: 2))
        temporaryKVM.click()

        let returnButton = app.buttons["returnToPriorityButton"]
        XCTAssertTrue(returnButton.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Temporary"].waitForExistence(timeout: 2))
        assertPriorityRow(1, contains: "Studio Display")
        assertPriorityRow(2, contains: "Projector")
        assertPriorityRow(3, contains: "KVM Display")

        returnButton.click()
        XCTAssertTrue(app.staticTexts["Priority"].waitForExistence(timeout: 2))
        XCTAssertFalse(returnButton.exists)
        assertPriorityRow(1, contains: "Studio Display")
        assertPriorityRow(2, contains: "Projector")
        assertPriorityRow(3, contains: "KVM Display")
    }

    @MainActor
    func testProtectionCanStartAndStopWithStandardFixture() throws {
        launchStandardFixture()

        let toggle = app.buttons["protectionToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 2))
        XCTAssertEqual(toggle.label, "Start Protection")

        toggle.click()
        XCTAssertTrue(app.buttons["Stop Protection"].waitForExistence(timeout: 2))

        app.buttons["Stop Protection"].click()
        XCTAssertTrue(app.buttons["Start Protection"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testPermissionFixtureShowsAccessibilityGuidanceWithoutOpeningSettings() throws {
        app.launchArguments = ["--ui-test-fixture=permission"]
        app.launch()

        let toggle = app.buttons["protectionToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 2))
        toggle.click()

        XCTAssertTrue(app.buttons["openAccessibilitySettings"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Accessibility permission is required to locate and move the Dock."].exists)
    }

    @MainActor
    private func launchStandardFixture() {
        app.launchArguments = ["--ui-test-fixture=standard"]
        app.launch()
        XCTAssertTrue(app.otherElements["statusCard"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func assertPriorityRow(_ priority: Int, contains text: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.otherElements["priorityRow.\(priority)"]
        XCTAssertTrue(row.waitForExistence(timeout: 2), "Priority row \(priority) should exist", file: file, line: line)
        XCTAssertTrue(row.staticTexts[text].exists, "Priority row \(priority) should contain \(text)", file: file, line: line)
    }
}
