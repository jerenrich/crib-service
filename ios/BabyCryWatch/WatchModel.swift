import Foundation
import Observation
import WatchKit
import UserNotifications
@preconcurrency import WatchConnectivity

@MainActor @Observable final class WatchModel: NSObject, WCSessionDelegate {
    static let shared = WatchModel()
    let log = DiagnosticLog()
    private(set) var snapshot = WatchSnapshot()
    var alert: WatchCryAlert? { alertState.alert }
    private(set) var notificationsAllowed = false
    private(set) var refreshing = false
    var acknowledgementPending: Bool { alertState.acknowledgementPending }
    var notice: String?
    private var token: String?
    private let alertState = WatchAlertState()

    override private init() {
        super.init()
        log.record("app_launched")
        if let data = UserDefaults.standard.data(forKey: "watchSnapshot"), let saved = try? JSONDecoder().decode(WatchSnapshot.self, from: data) {
            snapshot = saved
        }
        alertState.sendAcknowledgement = { [weak self] command in
            self?.log.record("watch_command_queued")
            self?.send(command, durable: true)
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func foreground() async {
        log.record("foreground")
        alertState.retryPendingAcknowledgement()
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAllowed = settings.authorizationStatus == .authorized
        if notificationsAllowed { WKApplication.shared().registerForRemoteNotifications() }
        else if token != nil || snapshot.watchPushRegistered {
            token = nil
            send(WatchCommand(kind: .registerToken), durable: true)
        }
        refresh()
    }
    func enableAlerts() async {
        do {
            notificationsAllowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            log.record(notificationsAllowed ? "notification_permission_allowed" : "notification_permission_denied")
            if notificationsAllowed { WKApplication.shared().registerForRemoteNotifications() }
            else { notice = "Allow notifications for Crib Service in Watch notification settings." }
        } catch { notice = "Could not request notification permission. Try again."; log.record("notification_permission_failed", code: (error as NSError).code) }
    }
    func registered(_ data: Data) {
        token = data.map { String(format: "%02x", $0) }.joined()
        log.record("push_token_received")
        send(WatchCommand(kind: .registerToken, token: token), durable: true)
    }
    func refresh() { send(WatchCommand(kind: .refresh)) }

    func receive(_ value: WatchCryAlert) {
        log.record("watch_push_received")
        alertState.receive(value)
    }
    func handleNotification(_ value: WatchCryAlert, acknowledging: Bool) {
        log.record("watch_push_received")
        alertState.handleNotification(value, acknowledging: acknowledging)
    }
    func acknowledge() { alertState.acknowledgeCurrent() }
    func previewHaptic() { WKInterfaceDevice.current().play(.notification) }

    func scheduleWristTest() async {
        if !notificationsAllowed { await enableAlerts() }
        guard notificationsAllowed else { return }
        let content = UNMutableNotificationContent()
        content.title = "Test · Crib Service"
        content.body = "This is a Watch-only vibration test. It does not test baby detection or remote delivery."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "watch-wrist-test", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)))
            log.record("local_notification_scheduled")
            notice = "Test in 10 seconds. Lower your wrist. Use Silent Mode for vibration only."
        } catch { notice = "Could not schedule the wrist test. Try again."; log.record("local_notification_failed", code: (error as NSError).code) }
    }

    private func accept(_ value: WatchSnapshot) {
        // Confirmation remains valid even if a newer status snapshot arrived first.
        alertState.confirmAcknowledgement(value.acknowledgedEventId)
        guard value.updatedAt >= snapshot.updatedAt || !snapshot.parentMode else { return }
        snapshot = value
        log.record("watch_snapshot_received")
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: "watchSnapshot") }
        notice = value.message
        alertState.acceptAlert(from: value)
    }

    private func send(_ command: WatchCommand, durable: Bool = false) {
        guard WCSession.isSupported(), let data = try? JSONEncoder().encode(command) else { return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            notice = "Connecting to your iPhone. Keep the Parent app open and try again."
            return
        }
        if durable { session.transferUserInfo(["command": data]) }
        guard session.isReachable else {
            if command.kind == .refresh { notice = "Open Parent mode on the paired iPhone to refresh. Registered push alerts use the Watch's internet connection." }
            else { notice = "Queued for your iPhone. Open the Parent app to finish syncing." }
            return
        }
        refreshing = true
        // WatchConnectivity invokes these callbacks on a background queue. Mark
        // them Sendable so Swift does not infer the enclosing MainActor isolation.
        session.sendMessage(["command": data], replyHandler: { @Sendable reply in
            let data = reply["snapshot"] as? Data
            Task { @MainActor in
                self.refreshing = false
                if let data, let value = try? JSONDecoder().decode(WatchSnapshot.self, from: data) { self.accept(value) }
            }
        }, errorHandler: { @Sendable _ in
            Task { @MainActor in self.refreshing = false; self.notice = "iPhone sync unavailable. Open the Parent app and try again."; self.log.record("watch_sync_failed") }
        })
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let data = session.receivedApplicationContext["snapshot"] as? Data
        let code = (error as NSError?)?.code
        Task { @MainActor in
            self.log.record(code == nil ? "watch_activated" : "watch_activation_failed", code: code)
            if let data, let value = try? JSONDecoder().decode(WatchSnapshot.self, from: data) { self.accept(value) }
            self.alertState.retryPendingAcknowledgement()
            self.refresh()
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["snapshot"] as? Data, let value = try? JSONDecoder().decode(WatchSnapshot.self, from: data) else { return }
        Task { @MainActor in self.accept(value) }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.alertState.retryPendingAcknowledgement()
            if let token = self.token { self.send(WatchCommand(kind: .registerToken, token: token), durable: true) }
            else { self.refresh() }
        }
    }
}
