import XCTest
final class OnboardingUITests: XCTestCase {
    @MainActor func testOnboardingRolePersistenceAndUnpairedStartGuard() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting-reset"]; app.launch()
        let continueButton = app.buttons["I understand · Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        if !continueButton.isHittable { app.swipeUp() }
        continueButton.tap()
        let listener = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Listen to Baby")).firstMatch
        XCTAssertTrue(listener.waitForExistence(timeout: 5)); listener.tap()
        XCTAssertTrue(app.buttons["Pair with Parent"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Attention needed"].exists)
        let start = app.buttons["Start Monitoring"]
        let enabled = start.isEnabled; XCTAssertFalse(enabled)
        XCTAssertFalse(app.buttons["Send test push"].isEnabled)
        app.launchArguments = []; app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Crib Service"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pair with Parent"].exists)
        XCTAssertFalse(app.alerts["Attention needed"].exists)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.swipeUp()
        let diagnostics = app.buttons["Diagnostics & simulation"]
        if !diagnostics.isHittable { app.swipeUp() }
        XCTAssertTrue(diagnostics.exists); diagnostics.tap()
        XCTAssertTrue(app.navigationBars["Diagnostics"].waitForExistence(timeout: 5))
        let remoteTest = app.buttons["Send test push"]
        for _ in 0..<4 { if remoteTest.exists && remoteTest.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(remoteTest.exists)
        XCTAssertFalse(remoteTest.isEnabled)
        let trigger = app.buttons["Trigger Threshold"]
        for _ in 0..<4 { if trigger.exists && trigger.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(trigger.exists); trigger.tap()
        XCTAssertTrue(app.staticTexts["Generated events: 1"].waitForExistence(timeout: 5))
    }
}
