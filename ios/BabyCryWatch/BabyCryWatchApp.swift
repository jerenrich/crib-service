import SwiftUI
import WatchKit
import UserNotifications

@main struct BabyCryWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @State private var model = WatchModel.shared

    var body: some Scene {
        WindowGroup { WatchHomeView().environment(model) }
        WKNotificationScene(controller: CryNotificationController.self, category: WatchNotification.category)
    }
}

@MainActor final class WatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
        let action = UNNotificationAction(identifier: WatchNotification.acknowledge, title: "I'm checking", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: WatchNotification.category, actions: [action], intentIdentifiers: [], options: [])
        ])
        _ = WatchModel.shared
    }
    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        WatchModel.shared.registered(deviceToken)
    }
    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        WatchModel.shared.log.record("push_registration_failed", code: (error as NSError).code)
        WatchModel.shared.notice = "Watch push registration failed. Check connectivity and try Enable alerts again."
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let alert = WatchCryAlert.notification(notification.request.content)
        await MainActor.run { if let alert { WatchModel.shared.receive(alert) } }
        return [.banner, .list, .sound]
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let alert = WatchCryAlert.notification(response.notification.request.content)
        let acknowledge = response.actionIdentifier == WatchNotification.acknowledge
        await MainActor.run {
            if let alert {
                WatchModel.shared.handleNotification(alert, acknowledging: acknowledge)
            }
        }
    }
}

extension WatchCryAlert {
    static func notification(_ content: UNNotificationContent) -> WatchCryAlert? {
        let info = content.userInfo
        guard let id = (info["eventId"] as? String).flatMap(UUID.init(uuidString:)),
              let episode = (info["episodeId"] as? String).flatMap(UUID.init(uuidString:)),
              let start = info["cryStartedAt"] as? String,
              let created = info["createdAt"] as? String,
              let duration = info["durationSeconds"] as? Double, duration.isFinite, duration >= 0 else { return nil }
        func date(_ string: String) -> Date? {
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = format.date(from: string) { return date }
            format.formatOptions = [.withInternetDateTime]
            return format.date(from: string)
        }
        guard let startedAt = date(start), let createdAt = date(created) else { return nil }
        return WatchCryAlert(eventId: id, episodeId: episode, startedAt: startedAt, createdAt: createdAt, duration: duration, isTest: info["isTest"] as? Bool == true)
    }
}

final class CryNotificationController: WKUserNotificationHostingController<CryNotificationView> {
    private var alert: WatchCryAlert?
    private var text = "Open the app for nursery status."
    override var body: CryNotificationView { CryNotificationView(alert: alert, text: text) }
    override func didReceive(_ notification: UNNotification) {
        alert = WatchCryAlert.notification(notification.request.content)
        text = notification.request.content.body
        if let alert { WatchModel.shared.receive(alert) }
    }
}

struct CryNotificationView: View {
    let alert: WatchCryAlert?
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.orange)
            Text(alert?.isTest == true ? "Test alert" : "Check on baby").font(.headline)
            Text(text).font(.footnote)
            if let alert { Text(alert.createdAt, style: .time).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 8)
    }
}
