import XCTest
final class OnboardingUITests: XCTestCase {
    @MainActor func testParentReadinessAndDeletionConfirmation() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting-reset", "--uitesting-offline"]; app.launch()
        let proceed = app.buttons["I understand · Continue"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 5)); if !proceed.isHittable { app.swipeUp() }; proceed.tap()
        let parent = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Parent Alerts")).firstMatch
        XCTAssertTrue(parent.waitForExistence(timeout: 5)); parent.tap()
        let ready = app.buttons["Ready for tonight?"]
        XCTAssertTrue(ready.waitForExistence(timeout: 5)); ready.tap()
        XCTAssertTrue(app.navigationBars["Tonight's check"].waitForExistence(timeout: 5))
        app.swipeUp()
        let testPush = app.buttons["Send real test notification"]
        if !testPush.exists { app.swipeUp() }
        XCTAssertTrue(testPush.exists); XCTAssertFalse(testPush.isEnabled)
        app.buttons["Done"].tap()
        app.buttons["Settings"].tap()
        let delete = app.buttons["Delete device & shared history"]
        for _ in 0..<8 { if delete.exists && delete.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(delete.isHittable); delete.tap()
        XCTAssertTrue(app.staticTexts["Delete device and shared history?"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].exists)
    }
    @MainActor func testOnboardingSettingsPersistenceAndUnpairedStartGuard() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting-reset", "--uitesting-offline"]; app.launch()
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
        app.launchArguments = ["--uitesting-offline"]; app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Crib Service"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pair with Parent"].exists)
        XCTAssertFalse(app.alerts["Attention needed"].exists)
        app.buttons["Check room sound"].tap()
        XCTAssertTrue(app.navigationBars["Check room sound"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Measure background"].exists)
        XCTAssertFalse(app.buttons["Measure sample sound"].isEnabled)
        app.buttons["Done"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save alert settings"].exists)
        XCTAssertFalse(app.buttons["Custom alert duration"].exists)
        let duration = app.buttons["alertDurationPicker"]
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        duration.tap()
        app.buttons["30 seconds"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        XCTAssertTrue(duration.label.contains("30 seconds") || duration.staticTexts["30 seconds"].exists, duration.debugDescription)
        app.buttons["Done"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(duration.label.contains("30 seconds") || duration.staticTexts["30 seconds"].exists, duration.debugDescription)
        duration.tap()
        app.buttons["5 seconds"].tap()
        // Terminate with Settings still open: saving must happen on selection.
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        XCTAssertTrue(duration.label.contains("5 seconds") || duration.staticTexts["5 seconds"].exists, duration.debugDescription)
        app.swipeUp()
        let diagnostics = app.buttons["Diagnostics & simulation"]
        if !diagnostics.isHittable { app.swipeUp() }
        XCTAssertTrue(diagnostics.exists); diagnostics.tap()
        XCTAssertTrue(app.navigationBars["Diagnostics"].waitForExistence(timeout: 5))
        let form = app.descendants(matching: .any)["diagnosticsForm"]
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        let remoteTest = app.buttons["diagnosticsSendTestPush"]
        // Disabled controls need not be hittable. Scope scrolling to the active
        // form and use identifiers so the underlying Listener cannot match.
        for _ in 0..<10 { if remoteTest.exists { break }; scrollDown(in: form) }
        XCTAssertTrue(remoteTest.exists)
        XCTAssertFalse(remoteTest.isEnabled)
        let trigger = app.buttons["simulationTriggerThreshold"]
        for _ in 0..<10 { if trigger.exists && trigger.isHittable { break }; scrollDown(in: form) }
        guard trigger.exists && trigger.isHittable else { XCTFail("Simulation threshold control is not visible"); return }
        trigger.tap()
        // Form rows are virtualized. The event count is above the trigger and
        // may have scrolled out of the accessibility tree while finding it.
        for _ in 0..<5 {
            if app.staticTexts["Generated events: 1"].exists { break }
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)))
        }
        XCTAssertTrue(app.staticTexts["Generated events: 1"].waitForExistence(timeout: 5))
    }
    @MainActor private func scrollDown(in element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.05, thenDragTo: element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
    }
}
