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
    private(set) var notificationAlerts = "Checking…"
    private(set) var notificationSounds = "Checking…"
    private(set) var notificationTimeSensitive = "Checking…"
    private(set) var notificationWarning: String?
    private(set) var connectionWarningDeadline: Date?
    private(set) var connectionWarningError: String?
    @ObservationIgnored private var connectionWarningTask: Task<Void, Never>?
    @ObservationIgnored private var connectionWarningUpdatePending = false
    @ObservationIgnored private var recoveringNotificationHistory = false
    private static let scheduledWarningKey = "scheduledConnectionWarningDeadline"
    @ObservationIgnored private var lastClockProbeAt: ContinuousClock.Instant?
    private let alertState = WatchAlertState()

    override private init() {
        super.init()
        log.record("app_launched", code: DiagnosticLog.maximumLines)
        log.record("alert_pipeline_ready", code: 8)
        log.checkpointCoverage()
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
        // The pending OS notification survives suspension/relaunch. Do not
        // reschedule a previously delivered deadline merely by opening the app.
        let deadline = snapshot.localConnectionDeadline
        connectionWarningDeadline = deadline
        if deadline == nil || UserDefaults.standard.object(forKey: Self.scheduledWarningKey) as? Date != deadline {
            updateConnectionWarning(deadline, force: true)
        }
    }

    func foreground() async {
        NotificationCallbackJournal.shared.lifecycle(.foreground)
        log.record("foreground")
        log.checkpointCoverage()
        await recoverNotificationHistory()
        alertState.retryPendingAcknowledgement()
        if alertSetup.phase != .requestingPermission {
            let settings = await inspectNotificationSettings()
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
        if connectionWarningError != nil { updateConnectionWarning(connectionWarningDeadline, force: true) }
    }
    private func recoverNotificationHistory() async {
        guard !recoveringNotificationHistory else { return }
        recoveringNotificationHistory = true; defer { recoveringNotificationHistory = false }
        // Recover delivery dates while awake; never poll or replay background alerts.
        let notifications = await UNUserNotificationCenter.current().deliveredNotifications()
        recordDeliveredNotifications(notifications, source: .foreground)
        NotificationCallbackJournal.shared.checkpoint(historyCount: notifications.count)
    }
    private func recordDeliveredNotifications(_ notifications: [UNNotification], source: WatchAlertTrace.HistorySource = .cleanup) {
        let observedAt = Date()
        log.watchAlerts(notifications.sorted { $0.date < $1.date }.compactMap { notification in
            guard let alert = WatchCryAlert.notification(notification.request.content) else { return nil }
            return WatchAlertTrace(alert: alert, phase: .retained, deliveredAt: notification.date, observedAt: observedAt,
                applicationState: diagnosticApplicationState, interruptionLevel: Int(exactly: notification.request.content.interruptionLevel.rawValue),
                collapseScope: notification.diagnosticCollapseScope(alert), historySource: source)
        })
    }
    @discardableResult private func inspectNotificationSettings() async -> UNNotificationSettings {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        func label(_ value: UNNotificationSetting) -> String {
            switch value {
            case .enabled: "Enabled"
            case .disabled: "Disabled"
            case .notSupported: "Not supported"
            @unknown default: "Unknown"
            }
        }
        notificationAlerts = label(settings.alertSetting)
        notificationSounds = label(settings.soundSetting)
        notificationTimeSensitive = label(settings.timeSensitiveSetting)
        log.record("watch_notification_authorization", code: settings.authorizationStatus.rawValue)
        log.record("watch_alert_permission", code: settings.alertSetting.rawValue)
        log.record("watch_sound_permission", code: settings.soundSetting.rawValue)
        log.record("watch_time_sensitive_permission", code: settings.timeSensitiveSetting.rawValue)
        notificationWarning = settings.alertSetting == .disabled || settings.soundSetting == .disabled
            ? "Check Crib Service in your iPhone's Watch → Notifications settings. Allow notifications and check its sound/haptic options. Global Prominent Haptics does not change this app's notification permissions."
            : nil
        return settings
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
    func refresh() {
        calibrateClockIfNeeded()
        send(WatchCommand(kind: .refresh))
    }

    private func calibrateClockIfNeeded() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { log.clockCalibration(.unreachable); return }
        let started = ContinuousClock.now
        if let lastClockProbeAt, lastClockProbeAt.duration(to: started) < .seconds(60) { return }
        lastClockProbeAt = started
        let sentAt = Date()
        WCSession.default.sendMessage(["diagnosticClockProbe": true], replyHandler: { @Sendable reply in
            let finishedAt = Date()
            let relative = DiagnosticClockSample.estimate(localStarted: sentAt, localFinished: finishedAt,
                monotonicMS: DiagnosticTiming.elapsedMS(since: started),
                remoteReceivedMS: (reply["clockReceivedAtMS"] as? NSNumber)?.int64Value,
                remoteSentMS: (reply["clockSentAtMS"] as? NSNumber)?.int64Value)
            let phone = (reply["diagnosticClock"] as? Data).flatMap { try? JSONDecoder().decode(DiagnosticClockSample.self, from: $0) }
            let phoneSent = (reply["clockSentAtMS"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            let sample = relative.flatMap { relative in phoneSent.flatMap { phone?.bridged(to: relative, phoneSentAt: $0) } }
            let outcome: DiagnosticClockCalibration = relative == nil ? .relativeUnavailable : phone == nil ? .phoneUnavailable : sample == nil ? .stalePhone : .ok
            Task { @MainActor in
                self.log.clockCalibration(outcome)
                // An older live reply must not replace a newer estimate.
                if self.log.latestClockSample.map({ $0.sampledAt > finishedAt }) != true { self.log.observeClock(sample) }
            }
        }, errorHandler: { @Sendable _ in
            Task { @MainActor in self.log.clockCalibration(.transport) }
        })
    }

    var diagnosticApplicationState: WatchAlertTrace.ApplicationState {
        switch WKApplication.shared().applicationState {
        case .active: .active
        case .inactive: .inactive
        case .background: .background
        @unknown default: .unknown
        }
    }
    func receive(_ value: WatchCryAlert) {
        alertState.receive(value)
    }
    func handleNotification(_ value: WatchCryAlert, acknowledging: Bool) {
        alertState.handleNotification(value, acknowledging: acknowledging)
        if acknowledging {
            Task { [weak self] in await NotificationCleanup.dismissCryingAlerts(testEventID: value.isTest ? value.eventId : nil, beforeRemoving: { self?.recordDeliveredNotifications($0) }, log: self?.log) }
        }
    }
    func resumeAlerts() {
        guard let until = snapshot.alertsMutedUntil, until > Date() else { return }
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            notice = "Open the Parent app on your iPhone to resume alerts."
            return
        }
        notice = "Requesting resume. Waiting for iPhone confirmation."
        send(WatchCommand(kind: .resumeAlerts, snoozeDeadline: until))
    }
    func acknowledge() {
        if let alert {
            log.watchAlert(WatchAlertTrace(alert: alert, phase: .acknowledged))
            Task { [weak self] in await NotificationCleanup.dismissCryingAlerts(testEventID: alert.isTest ? alert.eventId : nil, beforeRemoving: { self?.recordDeliveredNotifications($0) }, log: self?.log) }
        }
        log.record("watch_acknowledgement_requested"); alertState.acknowledgeCurrent()
    }
    func previewHaptic() async {
        await WatchAlertHaptics.play(for: .seconds(4.5), log: log) { self.alert == nil }
    }

    func scheduleWristTest() async {
        await inspectNotificationSettings()
        if !notificationsAllowed { await enableAlerts() }
        guard notificationsAllowed else { return }
        let content = UNMutableNotificationContent()
        content.title = "Test · Crib Service"
        content.body = "This is a Watch-only vibration test. It does not test baby detection or remote delivery."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "watch-wrist-test-\(UUID().uuidString)", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)))
            log.record("local_notification_scheduled")
            notice = "Test in 10 seconds. Lower your wrist. Use Silent Mode for vibration only."
        } catch { notice = "Could not schedule the wrist test. Try again."; log.record("local_notification_failed", error: error) }
    }

    private func accept(_ value: WatchSnapshot) {
        // Confirmation remains valid even if a newer status snapshot arrived first.
        alertState.resolveAcknowledgements(from: value)
        guard value.updatedAt >= snapshot.updatedAt || !snapshot.parentMode else { return }
        snapshot = value
        updateConnectionWarning(value.localConnectionDeadline)
        alertSetup.accept(value)
        log.record("watch_snapshot_received")
        do { UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: "watchSnapshot") }
        catch { log.record("watch_snapshot_failed", error: error) }
        notice = value.message
        alertState.acceptAlert(from: value)
        if let alert = alertState.alert { log.watchAlert(WatchAlertTrace(alert: alert, phase: .snapshotReceived)) }
        if value.statusAvailable, let relevance = value.notificationRelevance, let checkedAt = value.notificationsCheckedAt {
            Task { [weak self] in await NotificationCleanup.removeIrrelevant(using: relevance, deliveredBefore: checkedAt, beforeRemoving: { self?.recordDeliveredNotifications($0) }, log: self?.log) }
        }
    }

    private func updateConnectionWarning(_ deadline: Date?, force: Bool = false) {
        guard force || deadline != connectionWarningDeadline || connectionWarningError != nil else { return }
        connectionWarningDeadline = deadline
        connectionWarningUpdatePending = true
        guard connectionWarningTask == nil else { return }
        connectionWarningTask = Task { [weak self] in
            guard let self else { return }
            while self.connectionWarningUpdatePending {
                let requested = self.connectionWarningDeadline
                self.connectionWarningUpdatePending = false
                do {
                    try await ConnectionWarningNotification.apply(deadline: requested, watch: true)
                    if let requested { UserDefaults.standard.set(requested, forKey: Self.scheduledWarningKey) }
                    else { UserDefaults.standard.removeObject(forKey: Self.scheduledWarningKey) }
                    if !self.connectionWarningUpdatePending { self.connectionWarningError = nil }
                    self.log.record(requested == nil ? "parent_connection_warning_cancelled" : "parent_connection_warning_armed")
                } catch {
                    if !self.connectionWarningUpdatePending { self.connectionWarningError = error.localizedDescription }
                    self.log.record("parent_connection_warning_failed", error: error)
                }
            }
            self.connectionWarningTask = nil
        }
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
            if command.kind == .refresh { notice = "Open Parent Mode on the paired iPhone to refresh. Registered push alerts use the Watch's internet connection." }
            else { notice = "Queued for your iPhone. Open the Parent app to finish syncing." }
            return durable
        }
        refreshing = true
        // WatchConnectivity invokes these callbacks on a background queue. Mark
        // them Sendable so Swift does not infer the enclosing MainActor isolation.
        let sentAt = Date(), clockStarted = ContinuousClock.now
        session.sendMessage(["command": data], replyHandler: { @Sendable reply in
            let data = reply["snapshot"] as? Data
            let finishedAt = Date(), elapsed = DiagnosticTiming.elapsedMS(since: clockStarted)
            let relativeClock = DiagnosticClockSample.estimate(localStarted: sentAt, localFinished: finishedAt, monotonicMS: elapsed,
                remoteReceivedMS: (reply["clockReceivedAtMS"] as? NSNumber)?.int64Value,
                remoteSentMS: (reply["clockSentAtMS"] as? NSNumber)?.int64Value)
            let phoneSent = (reply["clockSentAtMS"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            Task { @MainActor in
                self.refreshing = false
                if let data {
                    // Only a live round trip can calibrate the Watch; cached
                    // application contexts carry no phone↔Watch timing bound.
                    let sample = try? JSONDecoder().decode(WatchSnapshot.self, from: data).diagnosticClock
                    self.log.observeClock(relativeClock.flatMap { relative in phoneSent.flatMap { sample?.bridged(to: relative, phoneSentAt: $0) } })
                    self.receiveSnapshot(data)
                }
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
    static func play(for duration: Duration, log: DiagnosticLog? = nil, alert: WatchCryAlert? = nil, while shouldContinue: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        let spacing: [Duration] = [.seconds(1.5), .seconds(1.5), .seconds(2.5)]
        var requested = false
        log?.record("watch_haptic_started")
        do {
            while clock.now < deadline {
                for delay in spacing {
                    guard !Task.isCancelled, clock.now < deadline, shouldContinue() else {
                        log?.record("watch_haptic_stopped"); return
                    }
                    guard WKApplication.shared().applicationState == .active else {
                        log?.record("watch_haptic_inactive"); return
                    }
                    WKInterfaceDevice.current().play(.notification)
                    if !requested {
                        if let alert { log?.watchAlert(WatchAlertTrace(alert: alert, phase: .hapticRequested)) }
                        else { log?.record("watch_haptic_requested") }
                        requested = true
                    }
                    try await clock.sleep(until: min(clock.now.advanced(by: delay), deadline))
                }
            }
        } catch {
            log?.record("watch_haptic_stopped")
            // SwiftUI cancels the task on acknowledgement, navigation, or inactivity.
        }
    }
}
