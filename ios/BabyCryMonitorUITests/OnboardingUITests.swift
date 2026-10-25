import XCTest
final class OnboardingUITests: XCTestCase {
    @MainActor func testActiveAlertUsesFixedNoticeAndSnoozeActionIsExplicit() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound", "--uitesting-active-alert"]
        app.launch()
        let chart = app.descendants(matching: .any)["soundLevelChart"].firstMatch
        let review = app.buttons["nightstandDetails"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertTrue(review.isHittable)
        XCTAssertFalse(app.buttons["activeAlertAction"].exists)
        let chartFrame = chart.frame
        let controlFrame = app.buttons["nightstandMonitoringControl"].frame
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Compact alert notice"; shot.lifetime = .keepAlways; add(shot)
        review.tap()
        let action = app.buttons["activeAlertAction"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertTrue(action.isHittable)
        XCTAssertEqual(action.label, "Snooze alerts for 1 min")
        app.buttons["Done"].tap()
        XCTAssertEqual(chart.frame, chartFrame)
        XCTAssertEqual(app.buttons["nightstandMonitoringControl"].frame, controlFrame)
    }

    @MainActor func testSnoozeAndChartRecoveryAreProminent() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound", "--uitesting-snoozed", "--uitesting-chart-paused"]
        app.launch()
        let details = app.buttons["nightstandDetails"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        XCTAssertTrue(details.isHittable)
        XCTAssertTrue(app.staticTexts["Crying alerts snoozed"].exists)
        XCTAssertTrue(app.staticTexts["nightstandState"].label == "Live chart paused")
        XCTAssertEqual(app.scrollViews.count, 0)
        details.tap()
        XCTAssertTrue(app.buttons["resumeAlerts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["resumeAlerts"].isHittable)
        let retry = app.buttons["retryConnection"]
        for _ in 0..<6 {
            if retry.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(retry.isHittable, app.debugDescription)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Snooze and connection recovery"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor func testQuickTimingEditorAndCompactDevices() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound"]
        app.launch()
        let timing = app.buttons["editAlertTiming"]
        XCTAssertTrue(timing.waitForExistence(timeout: 5))
        for _ in 0..<4 { if timing.isHittable { break }; app.swipeUp() }
        timing.tap()
        XCTAssertTrue(app.navigationBars["Alert timing"].waitForExistence(timeout: 5))
        app.buttons["30 sec"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(NSPredicate(format: "label CONTAINS %@", "00:30").evaluate(with: timing) || app.staticTexts["Requested 30 sec · Waiting for nursery confirmation"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["pairedDevice_listener"].exists)
        XCTAssertFalse(app.buttons["deviceSummary"].exists)
        app.tabBars.buttons["Devices"].tap()
        XCTAssertTrue(app.navigationBars["Devices"].waitForExistence(timeout: 5))
    }

    @MainActor func testCompactMonitorDoesNotScrollOrMoveAcrossStates() {
        let app = XCUIApplication()
        var baseline: [CGRect]?
        let scenarios: [[String]] = [[], ["--uitesting-active-alert"], ["--uitesting-snoozed"],
            ["--uitesting-chart-paused"], ["--uitesting-standby"]]
        for scenario in scenarios {
            app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound"] + scenario
            app.launch()
            let state = app.staticTexts["nightstandState"]
            XCTAssertTrue(state.waitForExistence(timeout: 5))
            XCTAssertEqual(app.scrollViews.count, 0)
            let chart = app.descendants(matching: .any)["soundLevelChart"].firstMatch
            let details = app.buttons["nightstandDetails"]
            let control = app.buttons["nightstandMonitoringControl"]
            let timing = app.buttons["editAlertTiming"]
            let ready = app.buttons["Ready for tonight?"]
            for action in [details, control, timing, ready] { XCTAssertTrue(action.isHittable, action.debugDescription) }
            XCTAssertGreaterThan(chart.frame.height, 30)
            XCTAssertLessThanOrEqual(state.frame.maxY, chart.frame.minY)
            XCTAssertLessThanOrEqual(chart.frame.maxY, details.frame.minY)
            XCTAssertLessThanOrEqual(details.frame.maxY, timing.frame.minY)
            XCTAssertLessThanOrEqual(ready.frame.maxY, app.tabBars.firstMatch.frame.minY)
            let frames = [state.frame, chart.frame, details.frame, control.frame, timing.frame, ready.frame, app.tabBars.firstMatch.frame]
            if let baseline {
                for (index, pair) in zip(frames, baseline).enumerated() {
                    let (actual, expected) = pair
                    XCTAssertEqual(actual.minX, expected.minX, accuracy: 1)
                    XCTAssertEqual(actual.minY, expected.minY, accuracy: 1)
                    // Accessibility reports the status text's glyph width,
                    // which naturally changes between Quiet and Standby.
                    if index != 0 { XCTAssertEqual(actual.width, expected.width, accuracy: 1) }
                    XCTAssertEqual(actual.height, expected.height, accuracy: 1)
                }
            } else { baseline = frames }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Compact \(scenario.first ?? "quiet")"; shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }

    @MainActor func testGuidedSetupRequiresWatchChecksAndReceiptBeforeMonitoring() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound"]
        app.launch()
        let ready = app.buttons["Ready for tonight?"]
        for _ in 0..<4 { if ready.isHittable { break }; app.swipeUp() }
        ready.tap()
        XCTAssertTrue(app.navigationBars["Overnight setup"].waitForExistence(timeout: 5))
        app.buttons["Continue to Watch setup"].tap()
        let focus = app.switches["overnightFocusChecked"]
        for _ in 0..<6 { if focus.exists && focus.isHittable && focus.frame.maxY < app.frame.maxY - 140 { break }; app.swipeUp() }
        focus.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(focus.value as? String, "1")
        let wrist = app.switches["overnightWristChecked"]
        for _ in 0..<6 { if wrist.exists && wrist.isHittable && wrist.frame.maxY < app.frame.maxY - 140 { break }; app.swipeUp() }
        wrist.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(wrist.value as? String, "1")
        let next = app.buttons["Continue to test"]
        for _ in 0..<4 { if next.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(next.isEnabled); next.tap()
        XCTAssertTrue(app.buttons["testWatchAlert"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["testWatchAlert"].isEnabled)
        XCTAssertFalse(app.buttons["Continue to monitoring"].isEnabled)
        XCTAssertFalse(app.buttons["confirmWatchAlert"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Guided wrist test"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor func testReturningSetupUsesShortNightlyCheck() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound", "--uitesting-setup-complete"]
        app.launch()
        let ready = app.buttons["Ready for tonight?"]
        for _ in 0..<4 { if ready.isHittable { break }; app.swipeUp() }
        ready.tap()
        XCTAssertTrue(app.navigationBars["Tonight's check"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["listenerPowerReadiness"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Short nightly check"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor func testBothModesShowPauseAndListenerPauseKeepsMicrophoneInStandby() {
        let app = XCUIApplication()
        for listener in [false, true] {
            app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound"]
            if listener { app.launchArguments.append("--uitesting-listener") }
            app.launch()
            let control = app.buttons["nightstandMonitoringControl"]
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            XCTAssertEqual(control.label, "Pause Monitoring")
            if listener {
                control.tap()
                XCTAssertEqual(app.staticTexts["nightstandState"].label, "Standby")
                XCTAssertEqual(control.label, "Start Monitoring")
                XCTAssertTrue(app.staticTexts["Microphone active · Detection paused"].exists)
                XCTAssertTrue(app.buttons["nightstandStopMicrophone"].exists)
            }
            app.terminate()
        }
    }

    @MainActor func testStandbyShowsActiveMicrophoneAndOffersResumeInBothModes() {
        let app = XCUIApplication()
        for listener in [false, true] {
            app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound", "--uitesting-standby"]
            if listener { app.launchArguments.append("--uitesting-listener") }
            app.launch()
            let state = app.staticTexts["nightstandState"]
            XCTAssertTrue(state.waitForExistence(timeout: 5))
            XCTAssertEqual(state.label, "Standby")
            XCTAssertTrue(app.staticTexts["Microphone active · Detection paused"].exists)
            let chart = app.descendants(matching: .any)["soundLevelChart"].firstMatch
            XCTAssertTrue((chart.value as? String)?.contains("Inactive") == true)
            let resume = app.buttons["Start Monitoring"]
            for _ in 0..<3 { if resume.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(resume.isEnabled)
            if listener {
                let stop = app.buttons["nightstandStopMicrophone"]
                XCTAssertTrue(stop.exists)
                for _ in 0..<3 { if stop.isHittable { break }; app.swipeUp() }
                stop.tap()
                XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 3))
                app.buttons["Cancel"].tap()
                XCTAssertEqual(state.label, "Standby")
                stop.tap()
                app.buttons.matching(identifier: "Stop microphone").firstMatch.tap()
                XCTAssertEqual(state.label, "Stopped")
            }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = listener ? "Listener microphone stopped" : "Parent standby"
            shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }
    @MainActor func testBothModesUseSameLiveSoundChart() {
        let app = XCUIApplication()
        var parentValue: String?
        var parentSize: CGSize?
        for listener in [false, true] {
            app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound"]
            if listener { app.launchArguments.append("--uitesting-listener") }
            app.launch()
            let chart = app.descendants(matching: .any)["soundLevelChart"].firstMatch
            XCTAssertTrue(chart.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["nightstandState"].exists)
            XCTAssertGreaterThan(chart.frame.height, 30)
            XCTAssertTrue(app.tabBars.buttons["Monitor"].exists)
            XCTAssertTrue(app.tabBars.buttons["Activity"].exists)
            XCTAssertTrue(app.tabBars.buttons["Devices"].exists)
            let value = chart.value as? String
            XCTAssertTrue(value?.contains("Trigger -45 dBFS") == true)
            XCTAssertFalse(value?.contains("Inactive") == true)
            if listener {
                XCTAssertEqual(value, parentValue)
                if let parentSize {
                    XCTAssertEqual(chart.frame.width, parentSize.width, accuracy: 0.5)
                    XCTAssertEqual(chart.frame.height, parentSize.height, accuracy: 0.5)
                } else { XCTFail("Parent chart was not measured") }
            } else { parentValue = value; parentSize = chart.frame.size }
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = listener ? "Nursery shared sound chart" : "Parent shared sound chart"
            image.lifetime = .keepAlways; add(image)
            if !listener {
                app.tabBars.buttons["Activity"].tap()
                XCTAssertTrue(app.navigationBars["Timeline"].waitForExistence(timeout: 5))
                app.tabBars.buttons["Monitor"].tap()
                XCTAssertEqual(chart.value as? String, parentValue)
                XCTAssertTrue(app.staticTexts["Live · From Listener"].exists)
                XCTAssertFalse(app.staticTexts["Waiting for live readings"].exists)
            }
            app.tabBars.buttons["Devices"].tap()
            XCTAssertTrue(app.navigationBars["Devices"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.descendants(matching: .any)["pairedDevice_listener"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["pairedDevice_parent"].exists)
            app.terminate()
        }
    }
    @MainActor func testParentWarningAndScreenPreferencesDefaultOffAndPersist() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline"]
        app.launch()
        let proceed = app.buttons["I understand · Continue"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 5))
        if !proceed.isHittable { app.swipeUp() }; proceed.tap()
        let parent = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Parent Mode")).firstMatch
        XCTAssertTrue(parent.waitForExistence(timeout: 5)); parent.tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        let form = app.descendants(matching: .any)["settingsForm"]
        let local = app.switches["localConnectionWarning"]
        let awake = app.switches["keepScreenAwake"]
        func reveal(_ toggle: XCUIElement) {
            for _ in 0..<16 {
                if toggle.exists && toggle.isHittable && toggle.frame.maxY < form.frame.maxY - 80 { return }
                scrollDown(in: form)
            }
        }
        reveal(local)
        XCTAssertTrue(local.exists && local.isHittable)
        XCTAssertEqual(local.value as? String, "0")
        local.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(NSPredicate(format: "value == '1'").evaluate(with: local))
        reveal(awake)
        XCTAssertEqual(awake.value as? String, "0")
        awake.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(NSPredicate(format: "value == '1'").evaluate(with: awake))
        app.terminate(); app.launchArguments = ["--uitesting-offline"]; app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5)); app.buttons["Settings"].tap()
        reveal(local)
        XCTAssertEqual(local.value as? String, "1")
        local.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        reveal(awake)
        XCTAssertEqual(awake.value as? String, "1")
        awake.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }


    @MainActor func testParentMonitoringFailureIsProminentAndRemainsVisible() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-timeline", "--uitesting-monitoring-rejected"]
        app.launch()
        let start = app.buttons["Start Monitoring"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        let chart = app.descendants(matching: .any)["soundLevelChart"].firstMatch
        let initialChartFrame = chart.frame
        let initialControlFrame = start.frame
        let initialTabFrame = app.tabBars.firstMatch.frame
        start.tap()
        let warning = app.alerts["Monitoring not confirmed"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertTrue(warning.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "could not be started or verified")).firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Parent monitoring failure"; screenshot.lifetime = .keepAlways; add(screenshot)
        warning.buttons["OK"].tap()
        XCTAssertTrue(app.staticTexts["Monitoring not confirmed"].exists)
        XCTAssertTrue(app.buttons["Pause Monitoring"].isEnabled)
        XCTAssertEqual(chart.frame.minY, initialChartFrame.minY, accuracy: 1)
        XCTAssertEqual(chart.frame.height, initialChartFrame.height, accuracy: 1)
        XCTAssertEqual(start.frame.minY, initialControlFrame.minY, accuracy: 1)
        XCTAssertEqual(app.tabBars.firstMatch.frame.minY, initialTabFrame.minY, accuracy: 1)
        let details = app.buttons["nightstandDetails"]
        for _ in 0..<4 {
            if details.isHittable && details.frame.maxY < start.frame.minY { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(details.isHittable)
        XCTAssertLessThan(details.frame.maxY, start.frame.minY)
        details.tap()
        XCTAssertTrue(app.navigationBars["Monitoring details"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "could not be started or verified")).firstMatch.exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Pause Monitoring"].isEnabled)
        let stableScreen = XCTAttachment(screenshot: app.screenshot())
        stableScreen.name = "Compact monitoring warning"; stableScreen.lifetime = .keepAlways; add(stableScreen)
    }
    @MainActor func testMonitorSupportsAccessibilityTextAndScrollableDetails() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.staticTexts["nightstandState"].waitForExistence(timeout: 5))
        let control = app.buttons["nightstandMonitoringControl"]
        let details = app.buttons["nightstandDetails"]
        for _ in 0..<12 { if details.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(details.isHittable)
        details.tap()
        XCTAssertTrue(app.navigationBars["Monitoring details"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Done"].isHittable)
        app.buttons["Done"].tap()
        for _ in 0..<12 { if control.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(control.isHittable)
        XCTAssertLessThanOrEqual(control.frame.maxY, app.tabBars.firstMatch.frame.minY)
        let largeText = XCTAttachment(screenshot: app.screenshot())
        largeText.name = "Compact monitor with accessibility text"; largeText.lifetime = .keepAlways; add(largeText)
    }
    @MainActor func testTimelineOverviewFilteringAndDetails() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-timeline"]
        app.launch()
        let timeline = app.tabBars.buttons["Activity"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5)); timeline.tap()
        XCTAssertTrue(app.navigationBars["Timeline"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Last 12 hours"].exists)
        XCTAssertTrue(app.buttons["timelineLegend_noHistory"].exists)
        XCTAssertTrue(app.buttons["timelineLegend_updatesMissing"].exists)
        XCTAssertTrue(app.buttons["timelineLegend_unavailable"].exists)
        let overview = XCTAttachment(screenshot: app.screenshot())
        overview.name = "Timeline coverage distinctions"; overview.lifetime = .keepAlways; add(overview)
        let gap = app.buttons.matching(identifier: "timelineCoverage_updatesMissing").firstMatch
        XCTAssertTrue(gap.exists); gap.tap()
        XCTAssertTrue(app.navigationBars["Timeline status"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Last Listener update:")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Updates resumed:")).firstMatch.exists)
        let gapDetail = XCTAttachment(screenshot: app.screenshot())
        gapDetail.name = "Missing Listener updates detail"; gapDetail.lifetime = .keepAlways; add(gapDetail)
        app.buttons["Done"].tap()
        let filter = app.buttons["timelineFilter"]
        for _ in 0..<4 { if filter.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(filter.isHittable); filter.tap()
        app.buttons["Connection"].tap()
        let missing = app.descendants(matching: .any)["timelineEvent_heartbeat_missing"]
        for _ in 0..<4 { if missing.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(missing.exists); missing.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "No heartbeat arrived")).firstMatch.waitForExistence(timeout: 3))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Timeline connection event detail"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    @MainActor func testParentReadinessAndDeletionConfirmation() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting-reset", "--uitesting-offline"]; app.launch()
        let proceed = app.buttons["I understand · Continue"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 5)); if !proceed.isHittable { app.swipeUp() }; proceed.tap()
        let parent = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Parent Mode")).firstMatch
        XCTAssertTrue(parent.waitForExistence(timeout: 5)); parent.tap()
        let ready = app.buttons["Ready for tonight?"]
        XCTAssertTrue(ready.waitForExistence(timeout: 5)); ready.tap()
        XCTAssertTrue(app.navigationBars["Overnight setup"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Step 1 of 4 · Pair phones"].exists)
        XCTAssertFalse(app.buttons["Continue to Watch setup"].isEnabled)
        app.buttons["Pair phones"].tap()
        XCTAssertTrue(app.navigationBars["Pair iPhones"].waitForExistence(timeout: 5))
        app.navigationBars["Pair iPhones"].buttons["Done"].tap()
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
        XCTAssertFalse(app.buttons["Check room sound"].exists)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save alert settings"].exists)
        XCTAssertFalse(app.buttons["Custom alert duration"].exists)
        let duration = app.buttons["alertDurationPicker"]
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        XCTAssertTrue(duration.label.contains("5 seconds") || duration.staticTexts["5 seconds"].exists, duration.debugDescription)
        XCTAssertFalse(app.buttons["Check room sound"].exists)
        duration.tap()
        app.buttons["30 seconds"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        XCTAssertTrue(duration.label.contains("30 seconds") || duration.staticTexts["30 seconds"].exists, duration.debugDescription)
        app.buttons["Done"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(duration.label.contains("30 seconds") || duration.staticTexts["30 seconds"].exists, duration.debugDescription)
        duration.tap()
        app.buttons["5 seconds"].tap()
        let threshold = app.buttons["soundThresholdPicker"]
        if !threshold.isHittable { app.swipeUp() }
        XCTAssertTrue(threshold.waitForExistence(timeout: 5)); threshold.tap()
        app.buttons["-45 dBFS"].tap()
        let snooze = app.buttons["snoozeDurationPicker"]
        if !snooze.isHittable { app.swipeUp() }
        XCTAssertTrue(snooze.waitForExistence(timeout: 5))
        XCTAssertTrue(snooze.label.contains("1 minute") || snooze.staticTexts["1 minute"].exists, snooze.debugDescription)
        snooze.tap(); app.buttons["2 minutes"].tap()
        // Terminate with Settings still open: saving must happen on selection.
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        XCTAssertTrue(duration.label.contains("5 seconds") || duration.staticTexts["5 seconds"].exists, duration.debugDescription)
        if !threshold.isHittable { app.swipeUp() }
        XCTAssertTrue(threshold.label.contains("-45 dBFS") || threshold.staticTexts["-45 dBFS"].exists, threshold.debugDescription)
        if !snooze.isHittable { app.swipeUp() }
        XCTAssertTrue(snooze.label.contains("2 minutes") || snooze.staticTexts["2 minutes"].exists, snooze.debugDescription)
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
