#if !canImport(MonitorCore)
import XCTest
import UserNotifications
@testable import BabyCryMonitor

final class NotificationCleanupTests: XCTestCase {
    func testForegroundPresentationHonorsPayloadSoundForCryAndConnectionAlerts() {
        let notification = content()
        XCTAssertEqual(NotificationService.foregroundOptions(for: notification), [.banner, .list])
        notification.sound = .default
        XCTAssertEqual(NotificationService.foregroundOptions(for: notification), [.banner, .list, .sound])
        notification.userInfo = ["localConnectionWarning": true]
        XCTAssertTrue(NotificationService.foregroundOptions(for: notification).contains(.sound))
        notification.sound = nil
        XCTAssertFalse(NotificationService.foregroundOptions(for: notification).contains(.sound))
    }
    @MainActor func testCleanupLogsOnlyValidatedIdentityAndTheActualRemovalRequest() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory),event = UUID(),episode = UUID(),notification = content(event: event, episode: episode)
        notification.userInfo["diagnosticRef"] = String(repeating: "b", count: 64);notification.userInfo["deliveryAttempt"] = 2
        notification.userInfo["private"] = "private-token";notification.body = "private-body"
        log.notificationRemovals([NotificationCleanup.removal(notification, reason: .snoozed, pending: false)].compactMap { $0 })
        XCTAssertTrue(log.lines[0].contains("reason=snoozed location=delivered action=removal_requested"))
        XCTAssertTrue(log.lines[0].contains("delivery_attempt=2"));XCTAssertFalse(log.export.contains("private-"))
        notification.categoryIdentifier = "connection-warning"
        log.notificationRemovals([NotificationCleanup.removal(notification, reason: .noLongerRelevant, pending: false)].compactMap { $0 })
        XCTAssertEqual(log.lines.count, 1)
    }
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
    func testExplicitDismissalClearsReceivedCryAndTestHistoryAcrossEpisodesButPreservesNewArrivals() {
        let cutoff = Date()
        for notification in [content(), content(), content(isTest: true)] {
            XCTAssertTrue(NotificationCleanup.shouldClearReceived(notification, deliveredAt: cutoff.addingTimeInterval(-60), deliveredBefore: cutoff))
            XCTAssertTrue(NotificationCleanup.shouldClearReceived(notification, deliveredAt: cutoff, deliveredBefore: cutoff))
            XCTAssertFalse(NotificationCleanup.shouldClearReceived(notification, deliveredAt: cutoff.addingTimeInterval(0.001), deliveredBefore: cutoff))
        }
        let connection = content(); connection.categoryIdentifier = "listener-connection"
        XCTAssertFalse(NotificationCleanup.shouldClearReceived(connection, deliveredAt: cutoff, deliveredBefore: cutoff))
        let malformed = content(); malformed.userInfo = [:]
        XCTAssertFalse(NotificationCleanup.shouldClearReceived(malformed, deliveredAt: cutoff, deliveredBefore: cutoff))
    }
    @MainActor func testClearingHistoryIsLoggedSeparatelyFromSnoozing() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        log.notificationRemovals([NotificationCleanup.removal(content(), reason: .cleared, pending: false)].compactMap { $0 })
        XCTAssertEqual(log.lines.count, 1)
        XCTAssertTrue(log.lines[0].contains("reason=cleared location=delivered action=removal_requested"))
        XCTAssertFalse(log.export.contains("snoozed"))
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
