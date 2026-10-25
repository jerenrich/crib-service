import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class WatchAlertTraceTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_800_000_000)
    private func alert() -> WatchCryAlert {
        WatchCryAlert(eventId: UUID(), episodeId: UUID(), startedAt: created.addingTimeInterval(-5),
                      createdAt: created, duration: 5, isTest: false)
    }
    func testOpeningLaterRetainsActualDeliveryTime() throws {
        let value = alert()
        let trace = WatchAlertTrace(alert: value, phase: .opened,
                                   deliveredAt: created.addingTimeInterval(1.125), observedAt: created.addingTimeInterval(31.625))
        let entry = try XCTUnwrap(trace.entry)
        XCTAssertTrue(entry.contains("delivered_at_ms=1800000001125"))
        XCTAssertTrue(entry.contains("delivery_age_ms=1125"))
        XCTAssertTrue(entry.contains("callback_lag_ms=30500"))
        XCTAssertTrue(entry.contains("event_id=\(value.eventId.uuidString.lowercased())"))
        XCTAssertTrue(entry.contains("episode_id=\(value.episodeId.uuidString.lowercased())"))
        XCTAssertEqual(WatchAlertTrace.key(in: "2027-01-15T08:00:31.625Z " + entry), trace.key)
    }
    func testHapticAndAppAcknowledgementNeverInventDeliveryDates() throws {
        for phase in [WatchAlertTrace.Phase.hapticRequested, .acknowledged] {
            let entry = try XCTUnwrap(WatchAlertTrace(alert: alert(), phase: phase, observedAt: created).entry)
            XCTAssertFalse(entry.contains("delivered_at_ms="))
            XCTAssertFalse(entry.contains("delivery_age_ms="))
            XCTAssertFalse(entry.contains("callback_lag_ms="))
        }
    }
    func testClockReversalRemainsVisibleRatherThanBecomingZeroLatency() throws {
        let entry = try XCTUnwrap(WatchAlertTrace(alert: alert(), phase: .retained,
            deliveredAt: created.addingTimeInterval(-2), observedAt: created.addingTimeInterval(-3)).entry)
        XCTAssertTrue(entry.contains("delivery_age_ms=-2000"))
        XCTAssertTrue(entry.contains("callback_lag_ms=-1000"))
        XCTAssertTrue(entry.contains("clock_order=check"))
    }
    func testMalformedDatesAndUntrustedDeduplicationKeysAreRejected() {
        XCTAssertNil(WatchAlertTrace(alert: alert(), phase: .foreground, deliveredAt: Date(timeIntervalSince1970: .nan)).entry)
        XCTAssertNil(WatchAlertTrace(alert: alert(), phase: .foreground, observedAt: Date(timeIntervalSince1970: .infinity)).entry)
        XCTAssertNil(WatchAlertTrace(alert: alert(), phase: .foreground, deliveredAt: Date(timeIntervalSince1970: 1e20)).entry)
        XCTAssertNil(WatchAlertTrace.key(in: "timestamp watch_alert phase=foreground event_id=private-token"))
        XCTAssertNil(WatchAlertTrace.key(in: "timestamp watch_alert phase=private-url event_id=\(UUID())"))
        XCTAssertNil(WatchAlertTrace.key(in: "timestamp watch_push_received"))
    }
    func testPhasesAndReminderEventIDsHaveDistinctKeys() {
        let value = alert()
        let first = WatchAlertTrace(alert: value, phase: .foreground)
        XCTAssertNotEqual(first.key, WatchAlertTrace(alert: value, phase: .opened).key)
        let reminder = WatchCryAlert(eventId: UUID(), episodeId: value.episodeId, startedAt: value.startedAt,
                                     createdAt: created.addingTimeInterval(5), duration: value.duration, isTest: false)
        XCTAssertNotEqual(first.key, WatchAlertTrace(alert: reminder, phase: .foreground).key)
    }
}
