import UIKit
import UserNotifications
import Observation

@MainActor protocol NotificationProviding: AnyObject {
    var status: String { get }
    var onToken: ((String) -> Void)? { get set }
    var onAlert: (() -> Void)? { get set }
    func register() async
    func registered(_ token: Data)
    func failed()
    func simulate(_ alert: CryAlert) async throws
}
@MainActor @Observable final class NotificationService: NSObject, UNUserNotificationCenterDelegate, NotificationProviding {
    private(set) var status = "Notifications not enabled"
    var onToken: ((String) -> Void)?
    var onAlert: (() -> Void)?
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        let action = UNNotificationAction(identifier: "OPEN_CRY", title: "Open nursery", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: WatchNotification.category, actions: [action], intentIdentifiers: [], options: [])
        ])
    }
    func register() async {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge])
            status = allowed ? "Registering for push notifications…" : "Notifications disabled. Enable them in iPhone Settings."
            if allowed { UIApplication.shared.registerForRemoteNotifications() }
        } catch { status = "Could not request notification permission." }
    }
    func registered(_ token: Data) {
        status = "Push token registered"
        onToken?(token.map { String(format: "%02x", $0) }.joined())
    }
    func failed() { status = "Push registration failed. Check signing and connectivity." }
    func simulate(_ alert: CryAlert) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Simulation · Baby is still crying"
        content.body = "Synthetic episode reached \(Int(alert.durationSeconds)) seconds."
        content.sound = nil
        content.categoryIdentifier = WatchNotification.category
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.eventId.uuidString, content: content, trigger: nil))
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
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) { notifications?.failed() }
}
