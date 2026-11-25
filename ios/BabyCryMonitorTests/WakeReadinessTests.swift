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
}
