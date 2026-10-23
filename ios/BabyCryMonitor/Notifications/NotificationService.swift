import UIKit
import UserNotifications
import Observation

@MainActor protocol NotificationProviding: AnyObject {
    var status: String { get }
    var authorizationAllowed: Bool { get }
    var onToken: ((String) -> Void)? { get set }
    var onAlert: (() -> Void)? { get set }
    func register() async
    func registered(_ token: Data)
    func failed()
    func simulate(_ alert: CryAlert) async throws
}
extension NotificationProviding { var authorizationAllowed: Bool { false } }
@MainActor @Observable final class NotificationService: NSObject, UNUserNotificationCenterDelegate, NotificationProviding {
    private(set) var status = "Notifications not enabled"
    private(set) var authorizationAllowed = false
    var onToken: ((String) -> Void)?
    var onAlert: (() -> Void)?
    weak var log: DiagnosticLog?
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        let action = UNNotificationAction(identifier: "OPEN_CRY", title: "Open nursery", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: WatchNotification.category, actions: [action], intentIdentifiers: [], options: [])
        ])
    }
    func register() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting-offline") { return }
        #endif
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge])
            let settings = await UNUserNotificationCenter.current().notificationSettings()
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
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.eventId.uuidString, content: content, trigger: nil))
            log?.record("local_notification_scheduled")
        } catch { log?.record("local_notification_failed", error: error); throw error }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await refresh(); return [.banner, .list]
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async { await refresh() }
    private func refresh() { onAlert?() }
}
@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
    var notifications: (any NotificationProviding)?
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) { notifications?.registered(deviceToken) }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        (notifications as? NotificationService)?.log?.record("push_registration_failed", error: error)
        notifications?.failed()
    }
}
