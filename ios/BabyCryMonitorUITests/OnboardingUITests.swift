import XCTest
final class OnboardingUITests: XCTestCase {
    @MainActor func testNurserySoundSheetHasBothSoundsAndAllTimersOnParent() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound"]
        app.launch()
        let controls = app.buttons["nurserySoundControls"]
        XCTAssertTrue(controls.waitForExistence(timeout: 5)); XCTAssertTrue(controls.isHittable)
        controls.tap()
        XCTAssertTrue(app.buttons["nurserySound_whiteNoise"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["nurserySound_twinkleTwinkle"].exists)
        for minutes in [5, 10, 20, 30, 60] { XCTAssertTrue(app.buttons["nurserySoundTimer_\(minutes)"].exists) }
        XCTAssertFalse(app.sliders["nurserySoundVolume"].exists)
        XCTAssertFalse(app.buttons["nurserySoundPlayback"].isEnabled, "An offline Parent cannot claim it started playback")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Parent nursery sound sheet"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Done"].tap()
        XCTAssertTrue(controls.isHittable)
    }
    @MainActor func testTestAlertOpensConfigurationWithoutSending() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound"]
        app.launch()
        let test = app.buttons["nightstandTestAlert"]
        XCTAssertTrue(test.waitForExistence(timeout: 5))
        test.tap()
        XCTAssertTrue(app.navigationBars["Configure test alert"].waitForExistence(timeout: 5))
        // Delivery choices are checkbox-styled toggles, so match them by identifier only.
        let phone = app.descendants(matching: .any)["testSendToPhone"].firstMatch
        let watch = app.descendants(matching: .any)["testSendToWatch"].firstMatch
        XCTAssertTrue(app.descendants(matching: .any)["testUseAlarmKit"].firstMatch.exists)
        XCTAssertEqual(phone.value as? String, "Checked")
        XCTAssertEqual(watch.value as? String, "Checked")
        watch.tap()
        XCTAssertEqual(watch.value as? String, "Unchecked")
        let repeatToggle = app.switches["testRepeat"]
        XCTAssertTrue(repeatToggle.exists)
        repeatToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let form = app.collectionViews.firstMatch
        let interval = app.buttons["testRepeatInterval"]
        for _ in 0..<4 { if interval.isHittable { break }; form.swipeUp() }
        XCTAssertTrue(app.steppers["testRepeatCount"].exists)
        let share = app.descendants(matching: .any)["testShareNotificationIDs"].firstMatch
        for _ in 0..<4 { if share.isHittable { break }; form.swipeUp() }
        XCTAssertTrue(share.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Test alert configuration"; shot.lifetime = .keepAlways; add(shot)
        let start = app.buttons["startConfiguredAlertTest"]
        for _ in 0..<6 { if start.isHittable { break }; form.swipeUp() }
        XCTAssertTrue(start.exists)
        XCTAssertFalse(start.isEnabled) // Offline status must not imply a scheduled test.
        XCTAssertFalse(app.buttons["stopConfiguredAlertTest"].exists)
    }

    @MainActor func testTestAlertLeavesNurseryStatusAndControlsVisible() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound", "--uitesting-test-alert"]
        app.launch()
        XCTAssertTrue(app.buttons["nightstandTestAlert"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["nightstandTestAlert"].isHittable)
        XCTAssertTrue(app.buttons["nightstandMonitoringControl"].isHittable)
        XCTAssertEqual(app.staticTexts["nightstandState"].label, "Quiet")
        XCTAssertFalse(app.buttons["I received this test"].exists)
        XCTAssertFalse(app.buttons["nightstandSnooze"].exists)
        app.buttons["nightstandDetails"].tap()
        XCTAssertTrue(app.navigationBars["Monitoring details"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["activeAlertAction"].exists)
        XCTAssertFalse(app.staticTexts["Test notification"].exists)
    }

    @MainActor func testNurseryAlertCircleOffersSnoozeAndKeepsPauseVisible() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound", "--uitesting-listener", "--uitesting-active-alert"]
        app.launch()
        let snooze = app.buttons["nightstandSnooze"]
        XCTAssertTrue(snooze.waitForExistence(timeout: 5))
        XCTAssertTrue(snooze.isHittable)
        XCTAssertEqual(snooze.label, "Snooze alerts for 1 min")
        XCTAssertTrue(app.buttons["nightstandMonitoringControl"].isHittable)
        XCTAssertFalse(app.buttons["nightstandTestAlert"].exists)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(snooze.frame))
        XCTAssertTrue(app.descendants(matching: .any)["soundLevelChart"].firstMatch.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Nursery alert Snooze circle"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor func testStoppedNurseryCanSnoozeAnOutstandingAlertAndStillOffersStart() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound", "--uitesting-listener", "--uitesting-active-alert", "--uitesting-microphone-off"]
        app.launch()
        XCTAssertTrue(app.buttons["nightstandSnooze"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["nightstandSnooze"].isHittable)
        XCTAssertTrue(app.buttons["nightstandMonitoringControl"].isHittable)
        XCTAssertTrue(app.staticTexts["Microphone inactive"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Nursery keeps listening"].exists)
        XCTAssertFalse(app.buttons["nightstandStopAlerts"].exists)
    }

    @MainActor func testParentAndNurseryUseSnoozeWithoutASeparateStopAlertsButton() {
        let app = XCUIApplication()
        for role in [[], ["--uitesting-listener"]] {
            for scenario in [["--uitesting-active-alert"], ["--uitesting-active-alert", "--uitesting-snoozed"],
                             ["--uitesting-active-alert", "--uitesting-microphone-off"]] {
                app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound"] + role + scenario
                app.launch()
                let actionID = scenario.contains("--uitesting-snoozed") ? "nightstandResumeAlerts" : "nightstandSnooze"
                let action = app.buttons[actionID]
                XCTAssertTrue(action.waitForExistence(timeout: 5))
                XCTAssertTrue(action.isHittable)
                XCTAssertTrue(app.windows.firstMatch.frame.contains(action.frame))
                XCTAssertFalse(app.buttons["nightstandStopAlerts"].exists)
                app.terminate()
            }
        }
    }

    @MainActor func testNurserySnoozedCircleShowsResumeAndCountdown() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound", "--uitesting-listener", "--uitesting-snoozed"]
        app.launch()
        let resume = app.buttons["nightstandResumeAlerts"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertTrue(resume.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(resume.frame))
        XCTAssertFalse(app.buttons["nightstandSnooze"].exists)
        XCTAssertTrue(app.buttons["nightstandMonitoringControl"].isHittable)
        app.buttons["nightstandDetails"].tap()
        XCTAssertTrue(app.buttons["resumeAlerts"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Nursery snooze countdown"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor func testCompactCaregiverControlsFitWithoutScrolling() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound", "--uitesting-active-alert", "--uitesting-caregivers"]
        app.launch()
        let swap = app.buttons["swapCaregiverRoles"]
        XCTAssertTrue(swap.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch.frame
        for element in [swap, app.buttons["nightstandSnooze"], app.buttons["editAlertTiming"],
                        app.buttons["nightstandMonitoringControl"], app.switches["secondaryCaregiverEnabled"]] {
            XCTAssertTrue(element.isHittable, "Caregiver control is not visible: \(element)")
            XCTAssertTrue(window.contains(element.frame), "Caregiver control is outside the screen: \(element.frame)")
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Compact caregiver alert screen"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor func testCompactParentControlsFitWithoutScrolling() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound", "--uitesting-active-alert"]
        app.launch()
        let snooze = app.buttons["nightstandSnooze"]
        XCTAssertTrue(snooze.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "nightstandSnooze").count, 1)
        XCTAssertFalse(app.buttons["I’m on it"].exists)
        let window = app.windows.firstMatch.frame
        XCTAssertLessThan(app.buttons["nightstandDetails"].frame.minY, window.minY + 110,
                          "The compact screen should start near the top safe area")
        for element in [snooze, app.buttons["editAlertTiming"], app.buttons["nightstandMonitoringControl"],
                        app.descendants(matching: .any)["soundLevelChart"].firstMatch] {
            XCTAssertTrue(element.isHittable, "Essential control is not visible: \(element)")
            XCTAssertTrue(window.contains(element.frame), "Essential control extends beyond the screen: \(element.frame)")
        }
        XCTAssertGreaterThanOrEqual(snooze.frame.width, 44)
        XCTAssertLessThan(snooze.frame.width, 180, "Snooze should be the compact status circle")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Compact Parent layout"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor func testActiveAlertOffersOneTapSnoozeOnMonitor() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound", "--uitesting-active-alert"]
        app.launch()
        let chart = app.descendants(matching: .any)["soundLevelChart"].firstMatch
        let snooze = app.buttons["nightstandSnooze"]
        XCTAssertTrue(snooze.waitForExistence(timeout: 5))
        XCTAssertTrue(snooze.isHittable)
        XCTAssertEqual(snooze.label, "Snooze alerts for 1 min")
        XCTAssertEqual(app.staticTexts["nightstandState"].label, "Check on baby")
        XCTAssertTrue(app.buttons["Pause Monitoring"].isHittable, "Pausing must remain available during an alert")
        let chartFrame = chart.frame
        let snoozeFrame = snooze.frame
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Alert with one-tap snooze"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["nightstandDetails"].tap()
        let action = app.buttons["activeAlertAction"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertEqual(action.label, "Snooze alerts for 1 min")
        app.buttons["Done"].tap()
        XCTAssertEqual(chart.frame, chartFrame)
        XCTAssertEqual(snooze.frame, snoozeFrame)
    }

    @MainActor func testSnoozeAndChartRecoveryAreProminent() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound", "--uitesting-snoozed", "--uitesting-chart-paused"]
        app.launch()
        let details = app.buttons["nightstandDetails"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        XCTAssertTrue(details.isHittable)
        XCTAssertEqual(app.staticTexts["nightstandState"].label, "Alerts snoozed")
        XCTAssertTrue(app.buttons["nightstandResumeAlerts"].isHittable)
        XCTAssertTrue(app.staticTexts["Live chart paused · Last readings"].exists)
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

    @MainActor func testTimingEditsPersistAndDevicesTabOpens() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound"]
        app.launch()
        let timing = app.buttons["editAlertTiming"]
        XCTAssertTrue(timing.waitForExistence(timeout: 5))
        for _ in 0..<4 { if timing.isHittable { break }; app.swipeUp() }
        timing.tap()
        XCTAssertTrue(app.navigationBars["Alert timing"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["The timer counts from the start of sustained loud sound, including the initial sound check. Brief noises are filtered out."].exists)
        app.buttons["30 sec"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(timing.label.contains("30 sec"), timing.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["pairedDevice_listener"].exists)
        XCTAssertFalse(app.buttons["deviceSummary"].exists)
        app.tabBars.buttons["Devices"].tap()
        XCTAssertTrue(app.navigationBars["Devices"].waitForExistence(timeout: 5))
    }

    @MainActor func testCompactMonitorControlsStayReachableAcrossStates() {
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
            let timing = app.buttons["editAlertTiming"]
            let actions = app.descendants(matching: .any)["nightstandActions"].firstMatch
            let sounds = app.buttons["nurserySoundControls"]
            for action in [details, timing] { XCTAssertTrue(action.isHittable, action.debugDescription) }
            for control in [sounds, app.buttons.matching(identifier: "nightstandMonitoringControl").firstMatch] {
                XCTAssertTrue(control.isHittable)
                XCTAssertTrue(app.windows.firstMatch.frame.contains(control.frame))
            }
            XCTAssertTrue(app.buttons.matching(identifier: "nightstandMonitoringControl").firstMatch.isHittable)
            XCTAssertGreaterThan(chart.frame.height, 30)
            XCTAssertLessThanOrEqual(details.frame.maxY, state.frame.minY)
            XCTAssertLessThanOrEqual(state.frame.maxY, timing.frame.minY)
            XCTAssertLessThanOrEqual(chart.frame.maxY, timing.frame.minY)
            XCTAssertLessThanOrEqual(timing.frame.maxY, app.buttons["nurserySoundControls"].frame.minY)
            XCTAssertLessThanOrEqual(app.buttons["nurserySoundControls"].frame.maxY, actions.frame.minY)
            XCTAssertLessThanOrEqual(actions.frame.maxY, app.tabBars.firstMatch.frame.minY)
            let frames = [details.frame, timing.frame, chart.frame, actions.frame, app.tabBars.firstMatch.frame]
            if let baseline {
                for (actual, expected) in zip(frames, baseline) {
                    XCTAssertEqual(actual.minX, expected.minX, accuracy: 1)
                    XCTAssertEqual(actual.width, expected.width, accuracy: 1)
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
        app.tabBars.buttons["Devices"].tap()
        let guided = app.buttons["Guided overnight setup & watch test"]
        for _ in 0..<4 { if guided.isHittable { break }; app.swipeUp() }
        guided.tap()
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

    @MainActor func testLiveStartStaysConsistentAcrossParentScreensAfterChartGap() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound",
            "--uitesting-listener-started", "--uitesting-standby", "--uitesting-live-once"]
        app.launch()
        let control = app.buttons["nightstandMonitoringControl"]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        XCTAssertEqual(control.label, "Pause Monitoring")
        app.tabBars.buttons["Devices"].tap()
        let nursery = app.descendants(matching: .any)["pairedDevice_listener"].firstMatch
        XCTAssertTrue(nursery.waitForExistence(timeout: 5))
        XCTAssertTrue(nursery.label.contains("Monitoring"))
        XCTAssertFalse(nursery.label.contains("Standby"))
        app.tabBars.buttons["Activity"].tap()
        XCTAssertTrue(app.staticTexts["Monitoring"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Monitor"].tap()
        XCTAssertEqual(control.label, "Pause Monitoring", "An expired chart frame must not restore the old Standby control")
        XCTAssertFalse(app.buttons["Start Monitoring"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["nurseryMonitoringInstruction"].exists)
    }

    @MainActor func testLiveReadingsOfferPauseBeforeListenerStatusRefreshes() {
        let app = XCUIApplication()
        for status in ["--uitesting-standby", "--uitesting-microphone-off", "--uitesting-listener-stale"] {
            app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound",
                "--uitesting-listener-started", status]
            app.launch()
            let control = app.buttons["nightstandMonitoringControl"]
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            XCTAssertEqual(control.label, "Pause Monitoring")
            XCTAssertTrue(control.isEnabled)
            XCTAssertEqual(app.staticTexts["nightstandState"].label, "Quiet")
            app.terminate()
        }
    }

    @MainActor func testParentStartIsDisabledUnlessListenerHasRecentStandbyHeartbeat() {
        let app = XCUIApplication()
        for state in ["--uitesting-standby", "--uitesting-microphone-off", "--uitesting-listener-stale"] {
            app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound", state]
            app.launch()
            let control = app.buttons["nightstandMonitoringControl"]
            if state == "--uitesting-standby" {
                XCTAssertTrue(control.waitForExistence(timeout: 5))
                XCTAssertEqual(control.label, "Start Monitoring")
                XCTAssertTrue(control.isEnabled)
            } else if state == "--uitesting-listener-stale" {
                XCTAssertTrue(app.buttons["nightstandRetryConnection"].waitForExistence(timeout: 5))
                XCTAssertEqual(app.staticTexts["nightstandState"].label, "Can't reach nursery")
                XCTAssertFalse(control.exists)
            } else {
                let instruction = app.descendants(matching: .any)["nurseryMonitoringInstruction"].firstMatch
                XCTAssertTrue(instruction.waitForExistence(timeout: 5))
                XCTAssertTrue(instruction.label.contains("Use the nursery iPhone"))
                XCTAssertTrue(instruction.label.contains("Open Crib Service and tap Start Monitoring."))
                XCTAssertFalse(control.exists)
                XCTAssertFalse(app.buttons["nurseryMonitoringInstruction"].exists)
            }
            if state == "--uitesting-listener-stale" {
                XCTAssertTrue(app.buttons["Pause Monitoring"].isEnabled, "Cancelling alerts must remain available")
            }
            app.terminate()
        }
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
    @MainActor func testParentDimsOnlyWithKeepAwakeAndBrightensForAlerts() {
        let app = XCUIApplication()
        let base = ["--uitesting-reset", "--uitesting-offline", "--uitesting-live-sound", "--uitesting-fast-dim"]
        let overlay = app.descendants(matching: .any)["nightDimOverlay"].firstMatch
        app.launchArguments = base + ["--uitesting-keep-awake"]
        app.launch()
        XCTAssertTrue(overlay.waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Dimmed Parent"; shot.lifetime = .keepAlways; add(shot)
        overlay.tap()
        XCTAssertTrue(app.buttons["nightstandMonitoringControl"].waitForExistence(timeout: 5))
        XCTAssertFalse(overlay.exists)
        app.terminate()
        // An active alert keeps the screen bright and the Snooze action reachable.
        app.launchArguments = base + ["--uitesting-keep-awake", "--uitesting-active-alert"]
        app.launch()
        XCTAssertTrue(app.buttons["nightstandSnooze"].waitForExistence(timeout: 5))
        XCTAssertFalse(overlay.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["nightstandSnooze"].isHittable)
        app.terminate()
        // Without Keep screen awake the phone locks normally, so it never dims itself.
        app.launchArguments = base
        app.launch()
        XCTAssertTrue(app.staticTexts["nightstandState"].waitForExistence(timeout: 5))
        XCTAssertFalse(overlay.waitForExistence(timeout: 5))
        app.terminate()
        // The nursery Listener runs locked and never dims itself.
        app.launchArguments = base + ["--uitesting-keep-awake", "--uitesting-listener"]
        app.launch()
        XCTAssertTrue(app.staticTexts["nightstandState"].waitForExistence(timeout: 5))
        XCTAssertFalse(overlay.waitForExistence(timeout: 5))
    }

    @MainActor func testRecentActivitySummaryOpensActivity() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-offline", "--uitesting-timeline", "--uitesting-listener", "--uitesting-live-sound"]
        app.launch()
        let summary = app.buttons["nightstandSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertEqual(summary.label, "Last 12 h · 1 sound episode · 1 alert · 1 connection gap")
        summary.tap()
        XCTAssertTrue(app.navigationBars["Timeline"].waitForExistence(timeout: 5))
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
                    // Parent intentionally uses a compact chart; both retain
                    // identical readings, scale, width, and accessible content.
                    XCTAssertGreaterThanOrEqual(chart.frame.height, parentSize.height)
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
        let start = app.buttons["nightstandMonitoringControl"]
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
        let instruction = app.descendants(matching: .any)["nurseryMonitoringInstruction"].firstMatch
        XCTAssertTrue(instruction.isHittable)
        XCTAssertTrue(instruction.frame.intersects(initialControlFrame))
        XCTAssertEqual(app.tabBars.firstMatch.frame.minY, initialTabFrame.minY, accuracy: 1)
        let details = app.buttons["nightstandDetails"]
        for _ in 0..<4 {
            if details.isHittable && details.frame.maxY < instruction.frame.minY { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(details.isHittable)
        XCTAssertLessThan(details.frame.maxY, instruction.frame.minY)
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
    @MainActor func testUnpairedParentPairsFromMonitorAndConfirmsDeletion() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting-reset", "--uitesting-offline"]; app.launch()
        let proceed = app.buttons["I understand · Continue"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 5)); if !proceed.isHittable { app.swipeUp() }; proceed.tap()
        let parent = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Parent Mode")).firstMatch
        XCTAssertTrue(parent.waitForExistence(timeout: 5)); parent.tap()
        let pair = app.buttons["Pair iPhones"]
        XCTAssertTrue(pair.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["nightstandState"].label, "Not paired")
        XCTAssertFalse(app.buttons["Ready for tonight?"].exists)
        pair.tap()
        XCTAssertTrue(app.navigationBars["Pair iPhones"].waitForExistence(timeout: 5))
        app.navigationBars["Pair iPhones"].buttons["Done"].tap()
        app.buttons["Settings"].tap()
        let delete = app.buttons["Delete device & shared history"]
        // Settings is long; swipe within its form until the destructive section appears.
        let form = app.descendants(matching: .any)["settingsForm"]
        for _ in 0..<20 { if delete.exists && delete.isHittable { break }; form.swipeUp() }
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
        XCTAssertFalse(app.buttons["Start Monitoring"].exists)
        XCTAssertFalse(app.buttons["Send test push"].exists)
        app.launchArguments = ["--uitesting-offline"]; app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["nightstandState"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["nightstandState"].label, "Not paired")
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
        let settingsForm = app.descendants(matching: .any)["settingsForm"]
        func reveal(_ element: XCUIElement) {
            for _ in 0..<12 {
                if element.exists && element.isHittable && element.frame.maxY < settingsForm.frame.maxY - 50 { return }
                scrollDown(in: settingsForm)
            }
        }
        let threshold = app.buttons["soundThresholdPicker"]
        reveal(threshold)
        XCTAssertTrue(threshold.waitForExistence(timeout: 5)); threshold.tap()
        let thresholdOption = app.buttons["-45 dBFS"]
        XCTAssertTrue(thresholdOption.waitForExistence(timeout: 5))
        thresholdOption.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        XCTAssertTrue(NSPredicate(format: "label CONTAINS %@", "-45 dBFS").evaluate(with: threshold))
        let snooze = app.buttons["snoozeDurationPicker"]
        reveal(snooze)
        XCTAssertTrue(snooze.waitForExistence(timeout: 5))
        XCTAssertTrue(snooze.label.contains("1 minute") || snooze.staticTexts["1 minute"].exists, snooze.debugDescription)
        snooze.tap(); app.buttons["2 minutes"].tap()
        // Terminate with Settings still open: saving must happen on selection.
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        XCTAssertTrue(duration.label.contains("5 seconds") || duration.staticTexts["5 seconds"].exists, duration.debugDescription)
        reveal(threshold)
        XCTAssertTrue(threshold.label.contains("-45 dBFS") || threshold.staticTexts["-45 dBFS"].exists, threshold.debugDescription)
        reveal(snooze)
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
