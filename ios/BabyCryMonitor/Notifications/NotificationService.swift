import UIKit
import UserNotifications
import Observation

@MainActor protocol NotificationProviding: AnyObject {
    var status: String { get }
    var authorizationAllowed: Bool { get }
    var onToken: ((String) -> Void)? { get set }
    var onAlert: (() -> Void)? { get set }
    var onAcknowledge: ((UUID) async -> Void)? { get set }
    func cleanUpAlerts(using relevance: NotificationRelevance, deliveredBefore: Date) async
    func dismissCryingAlerts(testEventID: UUID?) async
    func register() async
    func registered(_ token: Data)
    func failed()
    func simulate(_ alert: CryAlert) async throws
    func setParentConnectionDeadline(_ deadline: Date?) async throws
}
extension NotificationProviding {
    func cleanUpAlerts(using relevance: NotificationRelevance, deliveredBefore: Date) async {}
    func dismissCryingAlerts(testEventID: UUID?) async {}
    var authorizationAllowed: Bool { false }
    var onAcknowledge: ((UUID) async -> Void)? { get { nil } set {} }
}
@MainActor @Observable final class NotificationService: NSObject, UNUserNotificationCenterDelegate, NotificationProviding {
    private(set) var status = "Notifications not enabled"
    private(set) var authorizationAllowed = false
    var onToken: ((String) -> Void)?
    var onAlert: (() -> Void)?
    var onAcknowledge: ((UUID) async -> Void)?
    weak var log: DiagnosticLog?
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        let action = UNNotificationAction(identifier: "OPEN_CRY", title: "Open nursery", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: WatchNotification.category, actions: [UNNotificationAction(identifier: WatchNotification.acknowledge, title: "Snooze", options: [.foreground]), action], intentIdentifiers: [], options: [])
        ])
    }
    func cleanUpAlerts(using relevance: NotificationRelevance, deliveredBefore: Date) async {
        await NotificationCleanup.removeIrrelevant(using: relevance, deliveredBefore: deliveredBefore, log: log)
    }
    func dismissCryingAlerts(testEventID: UUID?) async {
        await NotificationCleanup.dismissCryingAlerts(testEventID: testEventID, log: log)
    }
    func register() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting-offline") { return }
        #endif
        do {
            let center = UNUserNotificationCenter.current()
            let previous = await center.notificationSettings()
            log?.record("notification_sound_permission_before_request", code: previous.soundSetting.rawValue)
            // Watch notification settings can mirror this authorization. The iOS target
            // also needs the Time Sensitive entitlement; the Watch entitlement alone
            // does not enable that setting on the companion. Request sound
            // permission even though our iPhone payloads deliberately omit sound.
            let allowed = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            let settings = await center.notificationSettings()
            log?.record("notification_alert_permission", code: settings.alertSetting.rawValue)
            log?.record("notification_sound_permission", code: settings.soundSetting.rawValue)
            log?.record("notification_time_sensitive_permission", code: settings.timeSensitiveSetting.rawValue)
            authorizationAllowed = allowed && settings.alertSetting == .enabled
            status = allowed ? "Registering for push notifications…" : "Notifications disabled. Enable them in iPhone Settings."
            log?.record(allowed ? "notification_permission_allowed" : "notification_permission_denied")
            if allowed { UIApplication.shared.registerForRemoteNotifications() }
        } catch { status = "Could not request notification permission."; log?.record("notification_permission_failed", error: error) }
    }
    func registered(_ token: Data) {
        status = "Push token registered"
        onToken?(token.map { String(format: "%02x", $0) }.joined())
    }
    func failed() { status = "Push registration failed. Check signing and connectivity."; log?.record("push_registration_failed") }
    func simulate(_ alert: CryAlert) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Simulation · Baby is still crying"
        content.body = "Synthetic episode reached \(Int(alert.durationSeconds)) seconds."
        content.sound = nil
        content.categoryIdentifier = WatchNotification.category
        content.userInfo = ["eventId": alert.eventId.uuidString, "episodeId": alert.episodeId.uuidString, "isTest": true]
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.eventId.uuidString, content: content, trigger: nil))
            log?.record("local_notification_scheduled")
        } catch { log?.record("local_notification_failed", error: error); throw error }
    }
    /// The OS owns this deadline, so delivery does not require internet or app execution.
    /// AppModel serializes updates so a late schedule cannot undo a cancellation.
    func setParentConnectionDeadline(_ deadline: Date?) async throws {
        try await ConnectionWarningNotification.apply(deadline: deadline)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if let request = SilentAlarmTestRequest(payload: notification.request.content.userInfo) {
            if #available(iOS 26.0, *) { _ = await SilentAlarmExperiment.shared.receive(request) }
            return []
        }
        await refresh()
        return notification.request.content.userInfo["localConnectionWarning"] as? Bool == true
            ? [.banner, .list, .sound] : [.banner, .list]
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.actionIdentifier == WatchNotification.acknowledge,
           let rawID = response.notification.request.content.userInfo["eventId"] as? String,
           let id = UUID(uuidString: rawID) {
            let isTest = response.notification.request.content.userInfo["isTest"] as? Bool == true
            await dismissCryingAlerts(testEventID: isTest ? id : nil)
            await acknowledge(id)
        }
        await refresh()
    }
    private func acknowledge(_ id: UUID) async { await onAcknowledge?(id) }
    private func refresh() { onAlert?() }
}
@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
    var notifications: (any NotificationProviding)?
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let request = SilentAlarmTestRequest(payload: userInfo) else { return .noData }
        if #available(iOS 26.0, *) {
            return await SilentAlarmExperiment.shared.receive(request) ? .newData : .noData
        }
        return .noData
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) { notifications?.registered(deviceToken) }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        (notifications as? NotificationService)?.log?.record("push_registration_failed", error: error)
        notifications?.failed()
    }
}
