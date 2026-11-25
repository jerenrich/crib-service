import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class WakeReadinessTests: XCTestCase {
    func testReadySettingsHaveNoProblems() {
        XCTAssertEqual(WakeReadiness.problems(authorization: .authorized, alerts: true, sounds: true, timeSensitive: true), [])
    }
    func testEachSilencingSettingIsReported() {
        let problems = WakeReadiness.problems(authorization: .authorized, alerts: false, sounds: false, timeSensitive: false)
        XCTAssertEqual(problems.count, 3)
        XCTAssertTrue(problems[1].contains("sounds are off"))
        XCTAssertTrue(problems[2].contains("Time Sensitive"))
    }
    func testDeniedOrQuietDeliveryIsOneClearProblem() {
        XCTAssertEqual(WakeReadiness.problems(authorization: .denied, alerts: true, sounds: true, timeSensitive: true).count, 1)
        XCTAssertTrue(WakeReadiness.problems(authorization: .quiet, alerts: true, sounds: true, timeSensitive: true)[0].contains("quietly"))
    }
    func testWatchWarningIncludesTimeSensitive() {
        XCTAssertNil(WakeReadiness.watchWarning(alertsOff: false, soundsOff: false, timeSensitiveOff: false))
        let timeSensitive = WakeReadiness.watchWarning(alertsOff: false, soundsOff: false, timeSensitiveOff: true)
        XCTAssertEqual(timeSensitive?.hasPrefix("Crib Service Time Sensitive is off on this Watch. Without Time Sensitive, Sleep Focus"), true)
        let all = WakeReadiness.watchWarning(alertsOff: true, soundsOff: true, timeSensitiveOff: true)
        XCTAssertEqual(all?.hasPrefix("Crib Service notifications, sound/haptics and Time Sensitive are off on this Watch."), true)
        XCTAssertEqual(WakeReadiness.watchWarning(alertsOff: true, soundsOff: false, timeSensitiveOff: false)?.contains("Sleep Focus"), false)
    }
}
