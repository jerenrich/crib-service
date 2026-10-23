import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class SoundCalibrationTests: XCTestCase {
    func testQuietSampleCannotClearAbsoluteFloor() {
        var check = SoundCalibration()
        for _ in 0..<40 { check.record(-65, background: true); check.record(-42, background: false) }
        XCTAssertNil(check.recommendedSensitivity)
        XCTAssertEqual(check.threshold(for: .high), -35)
    }
    func testRecommendationRejectsNoisyBackgroundAndRequiresSustainedSample() {
        var check = SoundCalibration()
        for _ in 0..<40 { check.record(-40, background: true); check.record(-25, background: false) }
        XCTAssertEqual(check.recommendedSensitivity, .medium)
        check.record(-1, background: false)
        XCTAssertEqual(check.sampleLevel, -25)
        var noisy = SoundCalibration()
        for _ in 0..<40 { noisy.record(-20, background: true); noisy.record(-20, background: false) }
        XCTAssertNil(noisy.recommendedSensitivity)
    }
    func testMeasurementsAreBoundedAndInvalidSamplesExcluded() {
        var check = SoundCalibration()
        check.record(.nan, background: true); check.record(.infinity, background: false)
        XCTAssertTrue(check.background.isEmpty); XCTAssertTrue(check.sample.isEmpty)
        for _ in 0..<1000 { check.record(-60, background: true); check.record(-10, background: false) }
        XCTAssertEqual(check.background.count, 80); XCTAssertEqual(check.sample.count, 80)
        XCTAssertEqual(check.recommendedSensitivity, .low)
    }
    func testLoudRoomDoesNotProduceMisleadingSensitivityRecommendation() {
        var check = SoundCalibration()
        for _ in 0..<40 { check.record(-20, background: true); check.record(-3, background: false) }
        XCTAssertNil(check.recommendedSensitivity)
    }
}
