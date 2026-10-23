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
    let alertSetup = WatchAlertSetup()
    var notificationsAllowed: Bool { alertSetup.notificationsAllowed }
    private(set) var refreshing = false
    var acknowledgementPending: Bool { alertState.acknowledgementPending }
    var notice: String?
    private let alertState = WatchAlertState()

    override private init() {
        super.init()
        log.record("app_launched")
        if let data = UserDefaults.standard.data(forKey: "watchSnapshot") {
            do { snapshot = try JSONDecoder().decode(WatchSnapshot.self, from: data) }
            catch { log.record("watch_snapshot_failed", error: error) }
        }
        alertState.sendAcknowledgement = { [weak self] command in
            self?.log.record("watch_command_queued")
            self?.send(command, durable: true)
        }
        alertSetup.sendRegistration = { [weak self] command in
            self?.send(command, durable: true) ?? false
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func foreground() async {
        log.record("foreground")
        alertState.retryPendingAcknowledgement()
        if alertSetup.phase != .requestingPermission {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            alertSetup.updateAuthorization(settings.authorizationStatus == .authorized,
                                           denied: settings.authorizationStatus == .denied,
                                           registeredOnPhone: snapshot.watchPushRegistered)
            if notificationsAllowed {
                if !alertSetup.hasToken { alertSetup.beginPushRegistration() }
                WKApplication.shared().registerForRemoteNotifications()
            }
            alertSetup.retryRegistration()
        }
        refresh()
    }
    func enableAlerts() async {
        guard alertSetup.phase != .requestingPermission else { return }
        do {
            let allowed = try await alertSetup.requestPermission {
                try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            }
            log.record(notificationsAllowed ? "notification_permission_allowed" : "notification_permission_denied")
            if allowed {
                WKApplication.shared().registerForRemoteNotifications()
            } else {
                alertSetup.updateAuthorization(false, registeredOnPhone: snapshot.watchPushRegistered)
            }
        } catch { log.record("notification_permission_failed", error: error) }
    }
    func registered(_ data: Data) {
        log.record("push_token_received")
        alertSetup.receivedToken(data.map { String(format: "%02x", $0) }.joined())
    }
    func registrationFailed(_ error: Error) {
        log.record("push_registration_failed", error: error)
        alertSetup.fail("Could not register this Watch with Apple. Check its internet connection, then tap Retry setup.")
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
    func previewHaptic() async {
        await WatchAlertHaptics.play(for: .seconds(4.5)) { self.alert == nil }
    }

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
        } catch { notice = "Could not schedule the wrist test. Try again."; log.record("local_notification_failed", error: error) }
    }

    private func accept(_ value: WatchSnapshot) {
        // Confirmation remains valid even if a newer status snapshot arrived first.
        alertState.confirmAcknowledgement(value.acknowledgedEventId)
        guard value.updatedAt >= snapshot.updatedAt || !snapshot.parentMode else { return }
        snapshot = value
        alertSetup.accept(value)
        log.record("watch_snapshot_received")
        do { UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: "watchSnapshot") }
        catch { log.record("watch_snapshot_failed", error: error) }
        notice = value.message
        alertState.acceptAlert(from: value)
    }

    @discardableResult private func send(_ command: WatchCommand, durable: Bool = false) -> Bool {
        guard WCSession.isSupported() else { return false }
        let data: Data
        do { data = try JSONEncoder().encode(command) }
        catch { log.record("watch_command_failed", error: error); return false }
        let session = WCSession.default
        guard session.activationState == .activated else {
            notice = "Connecting to your iPhone. Keep the Parent app open and try again."
            return false
        }
        if durable { session.transferUserInfo(["command": data]) }
        guard session.isReachable else {
            if command.kind == .refresh { notice = "Open Parent mode on the paired iPhone to refresh. Registered push alerts use the Watch's internet connection." }
            else { notice = "Queued for your iPhone. Open the Parent app to finish syncing." }
            return durable
        }
        refreshing = true
        // WatchConnectivity invokes these callbacks on a background queue. Mark
        // them Sendable so Swift does not infer the enclosing MainActor isolation.
        session.sendMessage(["command": data], replyHandler: { @Sendable reply in
            let data = reply["snapshot"] as? Data
            Task { @MainActor in
                self.refreshing = false
                if let data { self.receiveSnapshot(data) }
            }
        }, errorHandler: { @Sendable error in
            Task { @MainActor in self.refreshing = false; self.notice = "iPhone sync unavailable. Open the Parent app and try again."; self.log.record("watch_sync_failed", error: error) }
        })
        return true
    }

    private func receiveSnapshot(_ data: Data) {
        do { accept(try JSONDecoder().decode(WatchSnapshot.self, from: data)) }
        catch { log.record("watch_snapshot_failed", error: error) }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let data = session.receivedApplicationContext["snapshot"] as? Data
        Task { @MainActor in
            self.log.record(error == nil ? "watch_activated" : "watch_activation_failed", error: error)
            if let data { self.receiveSnapshot(data) }
            self.alertState.retryPendingAcknowledgement()
            self.alertSetup.retryRegistration()
            self.refresh()
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["snapshot"] as? Data else { return }
        Task { @MainActor in self.receiveSnapshot(data) }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.alertState.retryPendingAcknowledgement()
            self.alertSetup.retryRegistration()
            self.refresh()
        }
    }
}

@MainActor enum WatchAlertHaptics {
    /// Three distinct notification haptics, then a pause before the next burst.
    /// Leave time for each system haptic to finish; rapid calls cut it short.
    static func play(for duration: Duration, while shouldContinue: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        let spacing: [Duration] = [.seconds(1.5), .seconds(1.5), .seconds(2.5)]
        do {
            while clock.now < deadline {
                for delay in spacing {
                    guard !Task.isCancelled, clock.now < deadline,
                          WKApplication.shared().applicationState == .active,
                          shouldContinue() else { return }
                    WKInterfaceDevice.current().play(.notification)
                    try await clock.sleep(until: min(clock.now.advanced(by: delay), deadline))
                }
            }
        } catch {
            // SwiftUI cancels the task on acknowledgement, navigation, or inactivity.
        }
    }
}
