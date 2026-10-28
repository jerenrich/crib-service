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
            UNNotificationCategory(identifier: WatchNotification.category, actions: [UNNotificationAction(identifier: WatchNotification.acknowledge, title: "Snooze", options: [.foreground]), action], intentIdentifiers: [], options: [.customDismissAction])
        ])
    }
    func cleanUpAlerts(using relevance: NotificationRelevance, deliveredBefore: Date) async {
        await NotificationCleanup.removeIrrelevant(using: relevance, deliveredBefore: deliveredBefore,
            beforeRemoving: { [weak self] in self?.recordDelivered($0) }, log: log)
    }
    func dismissCryingAlerts(testEventID: UUID?) async {
        await NotificationCleanup.dismissCryingAlerts(testEventID: testEventID,
            beforeRemoving: { [weak self] in self?.recordDelivered($0) }, log: log)
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
            // permission so matching phone/Watch payloads can request system sound.
            let allowed = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            let settings = await center.notificationSettings()
            recordDelivered(await center.deliveredNotifications())
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
        content.interruptionLevel = .timeSensitive
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
        let content = notification.request.content
        let options = Self.foregroundOptions(for: content)
        let alarmCallback = notification.request.content.userInfo["silentCryAlarm"] as? Bool == true
            ? SilentCryAlarmRequest.Callback(payload: notification.request.content.userInfo) : nil
        await recordReceipt(Self.receipt(notification), phase: "foreground", payloadHasSound: content.sound != nil,
            presentationOptions: options.rawValue)
        if let alarmCallback {
            // The AlarmKit attempt includes a status request (up to its 5 s budget).
            // The app is active here, so run it alongside presentation instead of
            // holding this crying banner/sound until it finishes, as on the Watch.
            if #available(iOS 26.0, *) {
                Task { _ = await SilentCryAlarmService.shared.receive(alarmCallback, source: .foregroundNotification) }
            }
        }
        await refresh()
        return options
    }
    nonisolated static func foregroundOptions(for content: UNNotificationContent) -> UNNotificationPresentationOptions {
        // Honor the payload on both devices. Always dropping .sound here changes
        // the phone's forwarded bulletin even when APNs metadata matches.
        content.sound == nil ? [.banner, .list] : [.banner, .list, .sound]
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let cutoff = Date()
        let content = response.notification.request.content
        let action = response.actionIdentifier, crying = content.categoryIdentifier == WatchNotification.category
        let receipt = Self.receipt(response.notification)
        let eventID = (content.userInfo["eventId"] as? String).flatMap(UUID.init(uuidString:))
        let isTest = content.userInfo["isTest"] as? Bool == true
        // UIKit asserts that this completion runs on the main thread. The async
        // variant finished on a background executor and aborted after every tap.
        Task { @MainActor in
            await handleResponse(action: action, crying: crying, receipt: receipt, eventID: eventID, isTest: isTest, cutoff: cutoff)
            completionHandler()
        }
    }
    private func handleResponse(action: String, crying: Bool, receipt: (UUID, UUID, Date, Int)?,
                                eventID: UUID?, isTest: Bool, cutoff: Date) async {
        if action == UNNotificationDismissActionIdentifier {
            if crying { await clearReceivedCryingAlerts(deliveredBefore: cutoff) }
            return
        }
        recordReceipt(receipt, phase: "opened")
        if action == WatchNotification.acknowledge, let eventID {
            await dismissCryingAlerts(testEventID: isTest ? eventID : nil)
            await acknowledge(eventID)
        }
        refresh()
    }
    private func acknowledge(_ id: UUID) async { await onAcknowledge?(id) }
    private func clearReceivedCryingAlerts(deliveredBefore: Date) async {
        await NotificationCleanup.clearReceivedCryingAlerts(deliveredBefore: deliveredBefore,
            beforeRemoving: { [weak self] in self?.recordDelivered($0) }, log: log)
    }
    private nonisolated static func receipt(_ notification: UNNotification) -> (UUID, UUID, Date, Int)? {
        let info = notification.request.content.userInfo
        guard let event = (info["eventId"] as? String).flatMap(UUID.init(uuidString:)),
              let episode = (info["episodeId"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        return (event, episode, notification.date, Int(notification.request.content.interruptionLevel.rawValue))
    }
    private func recordReceipt(_ receipt: (UUID, UUID, Date, Int)?, phase: String,
        payloadHasSound: Bool? = nil, presentationOptions: UInt? = nil) {
        guard let receipt else { return }
        log?.phoneNotification(eventID: receipt.0, episodeID: receipt.1, deliveredAt: receipt.2,
            interruptionLevel: receipt.3, phase: phase, payloadHasSound: payloadHasSound,
            presentationOptions: presentationOptions,
            applicationState: phase == "foreground" ? UIApplication.shared.applicationState.rawValue : nil,
            protectedDataAvailable: phase == "foreground" ? UIApplication.shared.isProtectedDataAvailable : nil)
    }
    private func recordDelivered(_ notifications: [UNNotification]) {
        for notification in notifications { recordReceipt(Self.receipt(notification), phase: "retained") }
    }
    private func refresh() { onAlert?() }
}
@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
    var notifications: (any NotificationProviding)?
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        // Real and configured-test alarms share this one marker and path.
        guard userInfo["silentCryAlarm"] as? Bool == true else { return .noData }
        if #available(iOS 26.0, *) {
            return await SilentCryAlarmService.shared.receive(.init(payload: userInfo), source: .remoteNotification) ? .newData : .noData
        }
        return .noData
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) { notifications?.registered(deviceToken) }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        (notifications as? NotificationService)?.log?.record("push_registration_failed", error: error)
        notifications?.failed()
    }
}
