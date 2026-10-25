import Foundation
import UserNotifications

/// Delete only our crying/test category; connection warnings and other notices survive.
enum NotificationCleanup {
    static func removeIrrelevant(using relevance: NotificationRelevance, deliveredBefore: Date) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let identifiers = delivered.compactMap { notification -> String? in
            guard isIrrelevant(notification.request.content, deliveredAt: notification.date,
                               using: relevance, deliveredBefore: deliveredBefore) else { return nil }
            return notification.request.identifier
        }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    static func dismissCryingAlerts(testEventID: UUID? = nil) async {
        let center = UNUserNotificationCenter.current()
        let cutoff = Date()
        let delivered = await center.deliveredNotifications()
        let pending = await center.pendingNotificationRequests()
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter {
            $0.date <= cutoff && shouldDismiss($0.request.content, testEventID: testEventID)
        }.map { $0.request.identifier })
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { shouldDismiss($0.content, testEventID: testEventID) }.map(\.identifier))
    }

    static func isIrrelevant(_ content: UNNotificationContent, deliveredAt: Date,
                             using relevance: NotificationRelevance, deliveredBefore: Date) -> Bool {
        // A push arriving during a status fetch may not be in that response.
        guard deliveredAt <= deliveredBefore, let alert = identity(content) else { return false }
        return !relevance.contains(eventID: alert.eventID, episodeID: alert.episodeID, isTest: alert.isTest)
    }

    static func shouldDismiss(_ content: UNNotificationContent, testEventID: UUID?) -> Bool {
        guard let alert = identity(content) else { return false }
        if let testEventID { return alert.isTest && alert.eventID == testEventID }
        return !alert.isTest
    }

    private static func identity(_ content: UNNotificationContent) -> (eventID: UUID, episodeID: UUID, isTest: Bool)? {
        guard content.categoryIdentifier == WatchNotification.category,
              let event = (content.userInfo["eventId"] as? String).flatMap(UUID.init(uuidString:)),
              let episode = (content.userInfo["episodeId"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        return (event, episode, content.userInfo["isTest"] as? Bool == true)
    }
}
