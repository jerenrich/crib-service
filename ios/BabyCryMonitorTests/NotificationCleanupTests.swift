#if !canImport(MonitorCore)
import XCTest
import UserNotifications
@testable import BabyCryMonitor

final class NotificationCleanupTests: XCTestCase {
    func content(isTest: Bool = false, event: UUID = UUID(), episode: UUID = UUID()) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = WatchNotification.category
        content.userInfo = ["eventId": event.uuidString, "episodeId": episode.uuidString, "isTest": isTest]
        return content
    }
    func testSnoozeClearsCryingAcrossEpisodesAndPreservesTestsAndConnectionWarnings() {
        XCTAssertTrue(NotificationCleanup.shouldDismiss(content(), testEventID: nil))
        XCTAssertTrue(NotificationCleanup.shouldDismiss(content(), testEventID: nil))
        XCTAssertFalse(NotificationCleanup.shouldDismiss(content(isTest: true), testEventID: nil))
        let connection = content()
        connection.categoryIdentifier = "listener-connection"
        XCTAssertFalse(NotificationCleanup.shouldDismiss(connection, testEventID: nil))
        let malformed = content(); malformed.userInfo = [:]
        XCTAssertFalse(NotificationCleanup.shouldDismiss(malformed, testEventID: nil))
    }
    func testTestAcknowledgementOnlyClearsMatchingTest() {
        let event = UUID()
        XCTAssertTrue(NotificationCleanup.shouldDismiss(content(isTest: true, event: event), testEventID: event))
        XCTAssertFalse(NotificationCleanup.shouldDismiss(content(isTest: true), testEventID: event))
        XCTAssertFalse(NotificationCleanup.shouldDismiss(content(event: event), testEventID: event))
    }
    func testCompleteSnapshotKeepsActiveAlertsAndConcurrentDeliveryAndClearsSettledOnes() {
        let cutoff = Date(), episode = UUID(), test = UUID()
        let relevance = NotificationRelevance(cryEpisodeIDs: [episode], testEventIDs: [test])
        func stale(_ content: UNNotificationContent, at time: Date) -> Bool {
            NotificationCleanup.isIrrelevant(content, deliveredAt: time, using: relevance, deliveredBefore: cutoff)
        }
        XCTAssertFalse(stale(content(episode: episode), at: cutoff.addingTimeInterval(-60)))
        XCTAssertFalse(stale(content(isTest: true, event: test), at: cutoff))
        XCTAssertTrue(stale(content(), at: cutoff))
        XCTAssertTrue(stale(content(isTest: true), at: cutoff))
        XCTAssertFalse(stale(content(), at: cutoff.addingTimeInterval(1)))
        let connection = content(); connection.categoryIdentifier = "listener-connection"
        XCTAssertFalse(stale(connection, at: cutoff))
    }
}
#endif
