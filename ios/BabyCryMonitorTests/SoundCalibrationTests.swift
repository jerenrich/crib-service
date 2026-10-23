import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class SoundCalibrationTests: XCTestCase {
    func testQuietSampleCanUseThresholdBelowOldFloor() {
        var check = SoundCalibration()
        for _ in 0..<40 { check.record(-65, background: true); check.record(-42, background: false) }
        XCTAssertEqual(check.recommendedThreshold, -45)
    }
    func testRecommendationRejectsNoisyBackgroundAndRequiresSustainedSample() {
        var check = SoundCalibration()
        for _ in 0..<40 { check.record(-40, background: true); check.record(-25, background: false) }
        XCTAssertEqual(check.recommendedThreshold, -30)
        check.record(-1, background: false)
        XCTAssertEqual(check.sampleLevel, -25)
        var noisy = SoundCalibration()
        for _ in 0..<40 { noisy.record(-20, background: true); noisy.record(-20, background: false) }
        XCTAssertNil(noisy.recommendedThreshold)
    }
    func testMeasurementsAreBoundedAndInvalidSamplesExcluded() {
        var check = SoundCalibration()
        check.record(.nan, background: true); check.record(.infinity, background: false)
        XCTAssertTrue(check.background.isEmpty); XCTAssertTrue(check.sample.isEmpty)
        for _ in 0..<1000 { check.record(-60, background: true); check.record(-10, background: false) }
        XCTAssertEqual(check.background.count, 80); XCTAssertEqual(check.sample.count, 80)
        XCTAssertEqual(check.recommendedThreshold, -15)
    }
    func testLoudRoomCanUseFixedThresholdWhenSampleHasEnoughSeparation() {
        var check = SoundCalibration()
        for _ in 0..<40 { check.record(-20, background: true); check.record(-3, background: false) }
        XCTAssertEqual(check.recommendedThreshold, -10)
    }
    func testRecommendationRequiresEnoughSamplesAndASelectableLevelWithHeadroom() {
        var check = SoundCalibration()
        for _ in 0..<19 { check.record(-65, background: true) }
        for _ in 0..<12 { check.record(-42, background: false) }
        XCTAssertNil(check.recommendedThreshold)
        check.record(-65, background: true)
        XCTAssertEqual(check.recommendedThreshold, -45)
        for (background, sample) in [(-80.0, -59.0), (-17, -3), (-40, -32)] {
            var unsuitable = SoundCalibration()
            for _ in 0..<40 { unsuitable.record(background, background: true); unsuitable.record(sample, background: false) }
            XCTAssertNil(unsuitable.recommendedThreshold)
        }
    }
    func testRecommendedThresholdMatchesActualDetector() throws {
        for (background, sample) in [(-65.0, -42.0), (-40, -25), (-20, -3)] {
            var check = SoundCalibration()
            for _ in 0..<40 { check.record(background, background: true); check.record(sample, background: false) }
            let threshold = try XCTUnwrap(check.recommendedThreshold)
            XCTAssertTrue(MonitoringConfiguration.soundThresholds.contains(threshold))
            var config = MonitoringConfiguration(); config.absoluteThreshold = threshold; config.alertDuration = 5
            var simulation = CrySessionTests.Simulation(); simulation.engine.configure(config)
            simulation.run(30, level: background)
            XCTAssertNil(simulation.engine.snapshot.current); XCTAssertTrue(simulation.emitted.isEmpty)
            simulation.run(10, level: sample)
            XCTAssertEqual(simulation.emitted.count, 1)
        }
    }
}
