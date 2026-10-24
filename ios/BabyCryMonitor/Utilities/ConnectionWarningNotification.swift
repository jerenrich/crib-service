import Foundation
import UserNotifications

enum ConnectionWarningNotification {
    static let timeout: TimeInterval = 180
    static let identifier = "parent-connection-check"

    static func request(deadline: Date, now: Date = Date(), watch: Bool = false) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Monitoring connection check overdue"
        content.body = "No verified connection check for 3 minutes. Check both phones. Internet may be unavailable, or iOS may have paused Parent Mode. Open Crib Service to check."
        content.sound = .default
        content.interruptionLevel = watch ? .timeSensitive : .active
        content.threadIdentifier = "parent-connection"
        content.userInfo = ["localConnectionWarning": true]
        return UNNotificationRequest(identifier: identifier, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, deadline.timeIntervalSince(now)), repeats: false))
    }

    static func apply(deadline: Date?, watch: Bool = false) async throws {
        // Notification cancellation makes synchronous system-service calls.
        // Keep those off the UI actor so a stalled service cannot freeze the app.
        let center = UNUserNotificationCenter.current()
        guard let deadline else {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            return
        }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized, settings.alertSetting == .enabled else {
            throw PermissionError()
        }
        try await center.add(request(deadline: deadline, watch: watch))
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private struct PermissionError: LocalizedError {
        var errorDescription: String? { "Allow Crib Service notifications in device Settings to receive the local connection warning." }
    }
}
