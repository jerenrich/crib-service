import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class WatchMessagesTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testLivePresentationMatchesParentWithoutChangingRawHeartbeatOrWarningDeadline() throws {
        var snapshot = WatchSnapshot(updatedAt: now, parentMode: true, paired: true,
            lastHeartbeat: now.addingTimeInterval(-180), monitoring: false, state: .quiet)
        snapshot.monitoringDisplayState = "Monitoring"
        snapshot.monitoringObservedAt = now
        XCTAssertTrue(snapshot.nurseryOnline(at: now))
        XCTAssertNil(snapshot.nurseryDisplayState(at: now.addingTimeInterval(46)))
        XCTAssertFalse(snapshot.monitoring)
        XCTAssertNil(snapshot.localConnectionDeadline)
        snapshot = try JSONDecoder().decode(WatchSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertTrue(snapshot.nurseryOnline(at: now))
        snapshot.monitoringDisplayState = "Standby"
        XCTAssertFalse(snapshot.nurseryOnline(at: now))
        snapshot.monitoringDisplayState = "Pausing…"
        XCTAssertFalse(snapshot.nurseryOnline(at: now))
    }

    func testCachedStatusBecomesUnknownEvenWhenHeartbeatIsRecent() {
        var snapshot = WatchSnapshot(updatedAt: now, parentMode: true, paired: true,
                                     lastHeartbeat: now, monitoring: true, state: .quiet)
        XCTAssertTrue(snapshot.nurseryOnline(at: now.addingTimeInterval(30)))
        XCTAssertFalse(snapshot.nurseryOnline(at: now.addingTimeInterval(46)))
        snapshot.updatedAt = now.addingTimeInterval(151)
        XCTAssertFalse(snapshot.nurseryOnline(at: now.addingTimeInterval(151)))
    }
    func testUnpairedStoppedAndFutureDatedStatesAreUnknown() {
        var snapshot = WatchSnapshot(updatedAt: now, parentMode: true, paired: true, lastHeartbeat: now, monitoring: true)
        snapshot.paired = false
        XCTAssertFalse(snapshot.nurseryOnline(at: now))
        snapshot.paired = true; snapshot.monitoring = false
        XCTAssertFalse(snapshot.nurseryOnline(at: now))
        snapshot.monitoring = true; snapshot.lastHeartbeat = now.addingTimeInterval(60)
        XCTAssertFalse(snapshot.nurseryOnline(at: now))
    }
    func testOldAlertsNeverStartForegroundVibration() throws {
        let alert = WatchCryAlert(eventId: UUID(), episodeId: UUID(), startedAt: now, createdAt: now, duration: 30, isTest: true)
        XCTAssertTrue(alert.isRecent(at: now.addingTimeInterval(60)))
        XCTAssertFalse(alert.isRecent(at: now.addingTimeInterval(301)))
        XCTAssertFalse(alert.isRecent(at: now.addingTimeInterval(-60)))
        var snapshot = WatchSnapshot(updatedAt: now)
        snapshot.alert = alert
        XCTAssertEqual(try JSONDecoder().decode(WatchSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }
    func testTokenRemovalAndAcknowledgementCommandsRoundTrip() throws {
        let removal = WatchCommand(kind: .registerToken)
        let decoded = try JSONDecoder().decode(WatchCommand.self, from: JSONEncoder().encode(removal))
        XCTAssertEqual(decoded.kind, .registerToken)
        XCTAssertNil(decoded.token)
        let id = UUID()
        let acknowledgement = WatchCommand(kind: .acknowledge, eventId: id)
        XCTAssertEqual(try JSONDecoder().decode(WatchCommand.self, from: JSONEncoder().encode(acknowledgement)).eventId, id)
    }
}
