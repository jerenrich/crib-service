import SwiftUI
import WatchKit
import UserNotifications

@main struct BabyCryWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup { WatchHomeView().environment(WatchModel.shared) }
        #if WATCH_SYSTEM_NOTIFICATIONS
        // No scene for this category: watchOS renders its native long look and
        // the same registered Snooze action. No custom rendering callback exists.
        #elseif WATCH_MINIMAL_NOTIFICATIONS
        WKNotificationScene(controller: MinimalCryNotificationController.self, category: WatchNotification.category)
        #else
        WKNotificationScene(controller: CryNotificationController.self, category: WatchNotification.category)
        #endif
    }
}

@MainActor final class WatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        NotificationCallbackJournal.shared.lifecycle(.launch)
        NotificationCallbackJournal.shared.presentationProfile()
        NotificationCallbackJournal.shared.checkpoint()
        UNUserNotificationCenter.current().delegate = self
        let action = UNNotificationAction(identifier: WatchNotification.acknowledge, title: "Snooze", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: WatchNotification.category, actions: [action], intentIdentifiers: [], options: [.customDismissAction])
        ])
        #if !WATCH_MINIMAL_NOTIFICATIONS
        _ = WatchModel.shared
        #endif
    }
    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        WatchModel.shared.registered(deviceToken)
    }
    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        WatchModel.shared.registrationFailed(error)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        let observedAt = Date(), started = ContinuousClock.now
        // Request OS presentation before parsing, model initialization, a main-actor
        // hop or diagnostic disk I/O. None of those should hold up banner/sound.
        completionHandler([.banner, .list, .sound])
        let presentationMS = DiagnosticTiming.elapsedMS(since: started)
        let alert = WatchCryAlert.notification(notification.request.content)
        let hasSound = notification.request.content.sound != nil
        let deliveredAt = notification.date
        let interruptionLevel = Int(exactly: notification.request.content.interruptionLevel.rawValue)
        let callbackID = UUID(), collapse = alert.map { notification.diagnosticCollapseScope($0) }
        let journalMS = alert.map { NotificationCallbackJournal.shared.record(WatchAlertTrace(alert: $0, phase: .foreground,
            deliveredAt: deliveredAt, observedAt: observedAt, interruptionLevel: interruptionLevel,
            callbackID: callbackID, collapseScope: collapse)) }
        let queued = ContinuousClock.now
        Task { @MainActor in
            let actorWaitMS = DiagnosticTiming.elapsedMS(since: queued), handling = ContinuousClock.now
            let model = WatchModel.shared
            if let alert {
                model.receive(alert)
                model.log.watchAlert(WatchAlertTrace(alert: alert, phase: .foreground, deliveredAt: deliveredAt, observedAt: observedAt,
                    applicationState: model.diagnosticApplicationState,
                    timing: .init(presentationRequestMS: presentationMS, mainActorWaitMS: actorWaitMS, handlingMS: DiagnosticTiming.elapsedMS(since: handling), journalWriteMS: journalMS),
                    interruptionLevel: interruptionLevel, callbackID: callbackID, collapseScope: collapse))
            } else {
                model.log.record("watch_payload_unrecognized", code: 1)
                model.log.record("watch_foreground_notification", code: hasSound ? 1 : 0)
            }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let cutoff = Date()
        if response.actionIdentifier == UNNotificationDismissActionIdentifier {
            if response.notification.request.content.categoryIdentifier == WatchNotification.category {
                await WatchModel.shared.clearReceivedNotifications(deliveredBefore: cutoff)
            }
            return
        }
        let alert = WatchCryAlert.notification(response.notification.request.content)
        let acknowledge = response.actionIdentifier == WatchNotification.acknowledge
        let deliveredAt = response.notification.date, observedAt = Date(), callbackID = UUID()
        let collapse = alert.map { response.notification.diagnosticCollapseScope($0) }
        if let alert {
            NotificationCallbackJournal.shared.record(WatchAlertTrace(alert: alert, phase: acknowledge ? .acknowledged : .opened,
                deliveredAt: deliveredAt, observedAt: observedAt, callbackID: callbackID,
                collapseScope: collapse))
        }
        await MainActor.run {
            if let alert {
                WatchModel.shared.log.watchAlert(WatchAlertTrace(alert: alert, phase: acknowledge ? .acknowledged : .opened,
                                                               deliveredAt: deliveredAt, observedAt: observedAt, callbackID: callbackID,
                                                               collapseScope: collapse))
                WatchModel.shared.handleNotification(alert, acknowledging: acknowledge)
            } else { WatchModel.shared.log.record("watch_payload_unrecognized", code: 2) }
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
        return WatchCryAlert(eventId: id, episodeId: episode, startedAt: startedAt, createdAt: createdAt, duration: duration, isTest: info["isTest"] as? Bool == true,
                             type: info["type"] as? String,
                             diagnosticRef: DiagnosticCorrelation.reference(info["diagnosticRef"] as? String),
                             deliveryAttempt: DiagnosticCorrelation.attempt(info["deliveryAttempt"] as? Int))
    }
}

final class CryNotificationController: WKUserNotificationHostingController<CryNotificationView> {
    private var alert: WatchCryAlert?
    private var deliveredAt: Date?
    private var activatedAt: Date?
    private var activationRecorded = false
    private var text = "Open the app for nursery status."
    override class var isInteractive: Bool { true }
    override var body: CryNotificationView {
        let deliveredAt = self.deliveredAt
        return CryNotificationView(alert: alert, deliveredAt: deliveredAt, text: text) { [weak self, alert] in
            guard let alert else { return }
            let trace = WatchAlertTrace(alert: alert, phase: .acknowledged, deliveredAt: deliveredAt, callbackID: UUID())
            NotificationCallbackJournal.shared.record(trace)
            WatchModel.shared.log.watchAlert(trace)
            WatchModel.shared.handleNotification(alert, acknowledging: true)
            self?.performDismissAction()
        }
    }
    override func willActivate() {
        super.willActivate()
        let now = Date(); activatedAt = now; activationRecorded = false
        if let alert, let deliveredAt {
            activationRecorded = true
            let trace = WatchAlertTrace(alert: alert, phase: .controllerActivated, deliveredAt: deliveredAt, observedAt: now, callbackID: UUID())
            NotificationCallbackJournal.shared.record(trace)
            Task { @MainActor in
                await Task.yield()
                WatchModel.shared.log.watchAlert(trace)
            }
        }
    }
    override func didDeactivate() {
        super.didDeactivate()
        let now = Date()
        if let alert, let deliveredAt {
            let trace = WatchAlertTrace(alert: alert, phase: .controllerDeactivated, deliveredAt: deliveredAt, observedAt: now, callbackID: UUID())
            NotificationCallbackJournal.shared.record(trace)
            Task { @MainActor in
                await Task.yield()
                WatchModel.shared.log.watchAlert(trace)
            }
        }
        activatedAt = nil
    }
    override func didReceive(_ notification: UNNotification) {
        let observedAt = Date(), started = ContinuousClock.now
        alert = WatchCryAlert.notification(notification.request.content)
        deliveredAt = notification.date
        text = notification.request.content.body
        if let alert {
            notificationActions = []
            let deliveredAt = notification.date, activatedAt = activationRecorded ? nil : self.activatedAt
            activationRecorded = true
            let preparedMS = DiagnosticTiming.elapsedMS(since: started)
            let callbackID = UUID(), collapse = notification.diagnosticCollapseScope(alert)
            let journalMS = NotificationCallbackJournal.shared.record(WatchAlertTrace(alert: alert, phase: .controllerReceived,
                deliveredAt: deliveredAt, observedAt: observedAt, callbackID: callbackID, collapseScope: collapse))
            let activationTrace = activatedAt.map { WatchAlertTrace(alert: alert, phase: .controllerActivated, deliveredAt: deliveredAt, observedAt: $0, callbackID: UUID()) }
            if let activationTrace { NotificationCallbackJournal.shared.record(activationTrace) }
            let queued = ContinuousClock.now
            let level = Int(exactly: notification.request.content.interruptionLevel.rawValue)
            // The bounded entry journal is appended before the deferred model
            // task, so a missing main-actor log cannot hide callback entry.
            Task { @MainActor in
                await Task.yield()
                let actorWaitMS = DiagnosticTiming.elapsedMS(since: queued), handling = ContinuousClock.now
                let model = WatchModel.shared
                model.receive(alert)
                var traces = [WatchAlertTrace(alert: alert, phase: .controllerReceived, deliveredAt: deliveredAt, observedAt: observedAt,
                    applicationState: model.diagnosticApplicationState,
                    timing: .init(mainActorWaitMS: actorWaitMS, handlingMS: preparedMS + DiagnosticTiming.elapsedMS(since: handling), journalWriteMS: journalMS),
                    interruptionLevel: level, callbackID: callbackID, collapseScope: collapse)]
                if let activationTrace { traces.append(activationTrace) }
                model.log.watchAlerts(traces)
            }
        } else {
            Task { @MainActor in await Task.yield(); WatchModel.shared.log.record("watch_payload_unrecognized", code: 3) }
        }
    }

}

struct CryNotificationView: View {
    let alert: WatchCryAlert?
    let deliveredAt: Date?
    let text: String
    let acknowledge: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if alert != nil {
                Button("Snooze", action: acknowledge)
                    .buttonStyle(.borderedProminent).tint(Color(red: 0.62, green: 0.90, blue: 0.79)).foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
            }
            Label(alert?.isTest == true ? "Test alert" : alert?.isDisconnected == true ? "Listener connection lost" : "Check on baby", systemImage: "waveform")
                .font(.headline).foregroundStyle(.orange)
            Text(text).font(.footnote)
            if let alert { Text(alert.createdAt, style: .time).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 8).onAppear {
            if let alert {
                let observedAt = Date(), callbackID = UUID()
                let trace = WatchAlertTrace(alert: alert, phase: .viewAppeared, deliveredAt: deliveredAt, observedAt: observedAt, callbackID: callbackID)
                NotificationCallbackJournal.shared.record(trace)
                Task { @MainActor in
                    await Task.yield()
                    WatchModel.shared.log.watchAlert(trace)
                }
            }
        }
    }
}

// Never log the arbitrary request identifier; retain its relationship to known IDs.
extension UNNotification {
    func diagnosticCollapseScope(_ alert: WatchCryAlert) -> WatchAlertTrace.CollapseScope {
        let id = UUID(uuidString: request.identifier)
        if id == alert.eventId { return .event }
        if id == alert.episodeId { return .episode }
        return .other
    }
}

/// Experiment: payload-only, noninteractive content plus the system's category
/// actions. Entry/view traces use the independent journal; neither callback
/// initializes WatchModel, starts connectivity, or waits for a model logger.
final class MinimalCryNotificationController: WKUserNotificationHostingController<MinimalCryNotificationView> {
    private var title = "Crib Service"
    private var text = "Check on baby."
    private var alert: WatchCryAlert?
    private var deliveredAt: Date?
    override var body: MinimalCryNotificationView {
        MinimalCryNotificationView(title: title, text: text, alert: alert, deliveredAt: deliveredAt)
    }
    override func didReceive(_ notification: UNNotification) {
        let observedAt = Date(), started = ContinuousClock.now
        title = notification.request.content.title
        text = notification.request.content.body
        alert = WatchCryAlert.notification(notification.request.content)
        deliveredAt = notification.date
        guard let alert else { return }
        NotificationCallbackJournal.shared.record(WatchAlertTrace(alert: alert, phase: .controllerReceived,
            deliveredAt: notification.date, observedAt: observedAt,
            timing: .init(handlingMS: DiagnosticTiming.elapsedMS(since: started)),
            interruptionLevel: Int(exactly: notification.request.content.interruptionLevel.rawValue),
            callbackID: UUID(), collapseScope: notification.diagnosticCollapseScope(alert)))
    }
}

struct MinimalCryNotificationView: View {
    let title: String
    let text: String
    let alert: WatchCryAlert?
    let deliveredAt: Date?
    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            Text(text).font(.footnote)
        }.onAppear {
            guard let alert else { return }
            NotificationCallbackJournal.shared.record(WatchAlertTrace(alert: alert, phase: .viewAppeared,
                deliveredAt: deliveredAt, callbackID: UUID()))
        }
    }
}
