import Foundation
import Observation
import WatchKit
import UserNotifications
@preconcurrency import WatchConnectivity

@MainActor @Observable final class WatchModel: NSObject, WCSessionDelegate {
    static let shared = WatchModel()
    private(set) var snapshot = WatchSnapshot()
    private(set) var alert: WatchCryAlert?
    private(set) var notificationsAllowed = false
    private(set) var refreshing = false
    private(set) var acknowledgementPending = false
    var notice: String?
    private var token: String?
    private var localAlert: WatchCryAlert?
    private var pendingAcknowledgement: UUID?
    private var acknowledgedEpisodes: Set<UUID> = []

    override private init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "watchSnapshot"), let saved = try? JSONDecoder().decode(WatchSnapshot.self, from: data) {
            snapshot = saved
        }
        acknowledgedEpisodes = Set((UserDefaults.standard.stringArray(forKey: "acknowledgedEpisodes") ?? []).compactMap(UUID.init(uuidString:)))
        pendingAcknowledgement = UserDefaults.standard.string(forKey: "pendingAcknowledgement").flatMap(UUID.init(uuidString:))
        acknowledgementPending = pendingAcknowledgement != nil
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func foreground() async {
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
            if notificationsAllowed { WKApplication.shared().registerForRemoteNotifications() }
            else { notice = "Allow notifications for Crib Service in Watch notification settings." }
        } catch { notice = "Could not request notification permission. Try again." }
    }
    func registered(_ data: Data) {
        token = data.map { String(format: "%02x", $0) }.joined()
        send(WatchCommand(kind: .registerToken, token: token), durable: true)
    }
    func refresh() { send(WatchCommand(kind: .refresh)) }

    func receive(_ value: WatchCryAlert) {
        guard !acknowledgedEpisodes.contains(value.episodeId) else { return }
        localAlert = value
        alert = value
    }
    func acknowledge() {
        guard let alert else { return }
        // Silence this wrist immediately, but distinguish a queued acknowledgement
        // from server confirmation. WCSession persists the queued command offline.
        acknowledgedEpisodes.insert(alert.episodeId)
        UserDefaults.standard.set(Array(acknowledgedEpisodes.suffix(100)).map(\.uuidString), forKey: "acknowledgedEpisodes")
        acknowledgementPending = true
        pendingAcknowledgement = alert.eventId
        UserDefaults.standard.set(alert.eventId.uuidString, forKey: "pendingAcknowledgement")
        self.alert = nil; localAlert = nil
        send(WatchCommand(kind: .acknowledge, eventId: alert.eventId), durable: true)
    }
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
            notice = "Test in 10 seconds. Lower your wrist. Use Silent Mode for vibration only."
        } catch { notice = "Could not schedule the wrist test. Try again." }
    }

    private func accept(_ value: WatchSnapshot) {
        guard value.updatedAt >= snapshot.updatedAt || !snapshot.parentMode else { return }
        snapshot = value
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: "watchSnapshot") }
        notice = value.message
        if let incoming = value.alert, !acknowledgedEpisodes.contains(incoming.episodeId) {
            if localAlert == nil || incoming.createdAt >= localAlert!.createdAt { alert = incoming }
        } else if value.statusAvailable && (localAlert == nil || value.updatedAt >= localAlert!.createdAt) {
            alert = nil; localAlert = nil
        }
        if let pendingAcknowledgement, value.acknowledgedEventId == pendingAcknowledgement {
            acknowledgementPending = false
            self.pendingAcknowledgement = nil
            UserDefaults.standard.removeObject(forKey: "pendingAcknowledgement")
        }
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
            Task { @MainActor in self.refreshing = false; self.notice = "iPhone sync unavailable. Open the Parent app and try again." }
        })
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let data = session.receivedApplicationContext["snapshot"] as? Data
        Task { @MainActor in
            if let data, let value = try? JSONDecoder().decode(WatchSnapshot.self, from: data) { self.accept(value) }
            self.refresh()
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["snapshot"] as? Data, let value = try? JSONDecoder().decode(WatchSnapshot.self, from: data) else { return }
        Task { @MainActor in self.accept(value) }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            if let token = self.token { self.send(WatchCommand(kind: .registerToken, token: token), durable: true) }
            else { self.refresh() }
        }
    }
}
