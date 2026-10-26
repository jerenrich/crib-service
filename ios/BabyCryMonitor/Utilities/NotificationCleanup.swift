import Foundation
import UserNotifications

/// Delete only our crying/test category; connection warnings and other notices survive.
enum NotificationCleanup {
    /// Clearing history never acknowledges an episode or removes pending alerts.
    /// Capture the cutoff at dismissal entry so newly arriving alerts survive.
    @MainActor static func clearReceivedCryingAlerts(deliveredBefore: Date,
                                                    beforeRemoving: (([UNNotification]) -> Void)? = nil, log: DiagnosticLog? = nil) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        beforeRemoving?(delivered)
        var removals: [DiagnosticNotificationRemoval] = []
        let identifiers = delivered.compactMap { notification -> String? in
            guard shouldClearReceived(notification.request.content, deliveredAt: notification.date,
                                      deliveredBefore: deliveredBefore) else { return nil }
            if let removal = removal(notification.request.content, reason: .cleared, pending: false) { removals.append(removal) }
            return notification.request.identifier
        }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        log?.notificationRemovals(removals)
    }

    static func shouldClearReceived(_ content: UNNotificationContent, deliveredAt: Date, deliveredBefore: Date) -> Bool {
        deliveredAt <= deliveredBefore && identity(content) != nil
    }

    @MainActor static func removeIrrelevant(using relevance: NotificationRelevance, deliveredBefore: Date,
                                           beforeRemoving: (([UNNotification]) -> Void)? = nil, log: DiagnosticLog? = nil) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        beforeRemoving?(delivered)
        var removals: [DiagnosticNotificationRemoval] = []
        let identifiers = delivered.compactMap { notification -> String? in
            guard isIrrelevant(notification.request.content, deliveredAt: notification.date,
                               using: relevance, deliveredBefore: deliveredBefore) else { return nil }
            if let removal = removal(notification.request.content, reason: .noLongerRelevant, pending: false) { removals.append(removal) }
            return notification.request.identifier
        }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        log?.notificationRemovals(removals)
    }

    @MainActor static func dismissCryingAlerts(testEventID: UUID? = nil,
                                              beforeRemoving: (([UNNotification]) -> Void)? = nil, log: DiagnosticLog? = nil) async {
        let center = UNUserNotificationCenter.current()
        let cutoff = Date()
        let delivered = await center.deliveredNotifications()
        beforeRemoving?(delivered)
        let pending = await center.pendingNotificationRequests()
        let reason: NotificationRemovalReason = testEventID == nil ? .snoozed : .testAcknowledged
        var removals: [DiagnosticNotificationRemoval] = []
        let deliveredIDs = delivered.compactMap { notification -> String? in
            guard notification.date <= cutoff, shouldDismiss(notification.request.content, testEventID: testEventID) else { return nil }
            if let removal = removal(notification.request.content, reason: reason, pending: false) { removals.append(removal) }
            return notification.request.identifier
        }
        let pendingIDs = pending.compactMap { request -> String? in
            guard shouldDismiss(request.content, testEventID: testEventID) else { return nil }
            if let removal = removal(request.content, reason: reason, pending: true) { removals.append(removal) }
            return request.identifier
        }
        center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
        center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
        log?.notificationRemovals(removals)
    }

    static func removal(_ content: UNNotificationContent, reason: NotificationRemovalReason, pending: Bool) -> DiagnosticNotificationRemoval? {
        guard let alert = identity(content) else { return nil }
        return DiagnosticNotificationRemoval(eventID: alert.eventID, episodeID: alert.episodeID,
            reference: content.userInfo["diagnosticRef"] as? String, attempt: content.userInfo["deliveryAttempt"] as? Int, reason: reason, pending: pending)
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
