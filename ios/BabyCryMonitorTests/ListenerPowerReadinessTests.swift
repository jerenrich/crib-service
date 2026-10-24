import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class ListenerPowerReadinessTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/London")!
        return value
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func check(_ level: Double?, at time: String, powered: Bool? = false, fresh: Bool = true) -> ListenerPowerReadiness {
        ListenerPowerReadiness(batteryLevel: level, powerConnected: powered, fresh: fresh, now: date(time), calendar: calendar)
    }
    func testPlentyOfChargeDoesNotRequireExternalPower() {
        XCTAssertEqual(check(0.90, at: "2026-10-24T21:00:00Z").state, .onBattery)
        // Even a currently high charge warns if the remaining horizon is too long.
        XCTAssertTrue(check(0.80, at: "2026-10-24T07:00:00Z").needsPower)
    }
    func testLowChargeWarnsWhenEstimatedRuntimeFallsShort() {
        let value = check(0.19, at: "2026-10-24T01:00:00Z")
        XCTAssertTrue(value.needsPower)
        XCTAssertTrue(value.title.contains("7:00 am"))
        XCTAssertTrue(value.detail.contains("19%"))
    }
    func testChargeAboveTwentyPassesOnlyIfReserveLastsUntilWakeup() {
        XCTAssertEqual(check(0.22, at: "2026-10-24T05:45:00Z").state, .onBattery) // 06:45 BST
        XCTAssertEqual(check(0.225, at: "2026-10-24T05:30:00Z").state, .onBattery) // exactly 20% at wakeup
        XCTAssertTrue(check(0.225, at: "2026-10-24T05:29:00Z").needsPower)
    }
    func testTenPMBoundaryUsesFivePercentPerHourAndTwentyPercentReserve() {
        // Normal nine-hour night, 22:00 BST -> 07:00 BST.
        let value = check(Double(Float(0.65)), at: "2026-10-23T21:00:00Z")
        XCTAssertFalse(value.needsPower)
        XCTAssertEqual(value.projectedBatteryLevel!, 0.20, accuracy: 0.000001)
        XCTAssertTrue(check(0.649, at: "2026-10-23T21:00:00Z").needsPower)
        XCTAssertTrue(check(0.649, at: "2026-10-23T21:00:00Z").detail.contains("estimated 19%"))
        XCTAssertTrue(check(0.50, at: "2026-10-23T21:00:00Z").needsPower)
    }
    func testConnectedLowBatteryPasses() {
        XCTAssertEqual(check(0.01, at: "2026-10-24T01:00:00Z", powered: true).state, .connected)
        XCTAssertEqual(check(nil, at: "2026-10-24T01:00:00Z", powered: true).state, .connected)
    }
    func testStaleUnknownAndInvalidValuesAreNeutral() {
        XCTAssertEqual(check(0.01, at: "2026-10-24T01:00:00Z", fresh: false).state, .unavailable)
        XCTAssertEqual(check(0.01, at: "2026-10-24T01:00:00Z", powered: nil).state, .unavailable)
        for level: Double? in [nil, -1, 1.1, .nan, .infinity] {
            let value = check(level, at: "2026-10-24T01:00:00Z")
            XCTAssertEqual(value.state, .unavailable)
            XCTAssertFalse(value.needsPower)
        }
    }
    func testWakeupUsesLocalTimeAndRollsOverAtSeven() {
        XCTAssertEqual(check(0.9, at: "2026-10-24T05:59:59Z").wakeup, date("2026-10-24T06:00:00Z"))
        XCTAssertEqual(check(0.9, at: "2026-10-24T06:00:00Z").wakeup, date("2026-10-25T07:00:00Z"))
        XCTAssertEqual(check(0.9, at: "2026-10-24T23:00:00Z").wakeup, date("2026-10-25T07:00:00Z"))
    }
    func testDaylightSavingChangesUseElapsedHoursUntilLocalSeven() {
        // Spring: 23:00 to 07:00 is seven elapsed hours. Autumn: nine hours.
        let spring = check(0.2, at: "2026-03-28T23:00:00Z")
        let autumn = check(0.2, at: "2026-10-24T22:00:00Z")
        XCTAssertEqual(spring.wakeup.timeIntervalSince(date("2026-03-28T23:00:00Z")), 7 * 3600)
        XCTAssertEqual(autumn.wakeup.timeIntervalSince(date("2026-10-24T22:00:00Z")), 9 * 3600)
        // At 22:00 on the autumn transition night there are ten elapsed hours.
        XCTAssertTrue(check(0.65, at: "2026-10-24T21:00:00Z").needsPower)
        XCTAssertFalse(check(0.70, at: "2026-10-24T21:00:00Z").needsPower)
    }
}
