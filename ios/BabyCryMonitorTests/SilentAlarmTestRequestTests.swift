import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class SilentAlarmTestRequestTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func payload(age: TimeInterval = 0) -> [AnyHashable: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ["silentAlarmTest": true, "isTest": true, "eventId": UUID().uuidString,
                "createdAt": formatter.string(from: now.addingTimeInterval(-age))]
    }
    func testOnlyExplicitRecentTestPayloadsCanStartExperiment() {
        XCTAssertNotNil(SilentAlarmTestRequest(payload: payload(), now: now))
        var realCry = payload(); realCry["isTest"] = false
        XCTAssertNil(SilentAlarmTestRequest(payload: realCry, now: now))
        var normalTest = payload(); normalTest.removeValue(forKey: "silentAlarmTest")
        XCTAssertNil(SilentAlarmTestRequest(payload: normalTest, now: now))
        var malformed = payload(); malformed["eventId"] = "not-an-event"
        XCTAssertNil(SilentAlarmTestRequest(payload: malformed, now: now))
    }
    func testLateAndFutureNotificationsCannotReplayAlarm() {
        XCTAssertNotNil(SilentAlarmTestRequest(payload: payload(age: 59), now: now))
        XCTAssertNil(SilentAlarmTestRequest(payload: payload(age: 61), now: now))
        XCTAssertNil(SilentAlarmTestRequest(payload: payload(age: -6), now: now))
    }
    func testConfiguredRunSchedulesPromptlyAfterTheServerDelay() throws {
        var configured = payload()
        configured["configuredAlertTest"] = true
        XCTAssertEqual(try XCTUnwrap(SilentAlarmTestRequest(payload: configured, now: now)).schedulingDelay, 0.5)
        XCTAssertEqual(try XCTUnwrap(SilentAlarmTestRequest(payload: payload(), now: now)).schedulingDelay, 3)
    }

}
