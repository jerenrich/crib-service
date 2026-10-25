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
        let action = UNNotificationAction(identifier: WatchNotification.acknowledge, title: "Snooze", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: WatchNotification.category, actions: [action], intentIdentifiers: [], options: [])
        ])
        _ = WatchModel.shared
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
        let deliveredAt = notification.date, queued = ContinuousClock.now
        let interruptionLevel = Int(exactly: notification.request.content.interruptionLevel.rawValue)
        Task { @MainActor in
            let actorWaitMS = DiagnosticTiming.elapsedMS(since: queued), handling = ContinuousClock.now
            let model = WatchModel.shared
            if let alert {
                model.receive(alert)
                model.log.watchAlert(WatchAlertTrace(alert: alert, phase: .foreground, deliveredAt: deliveredAt, observedAt: observedAt,
                    applicationState: model.diagnosticApplicationState,
                    timing: .init(presentationRequestMS: presentationMS, mainActorWaitMS: actorWaitMS, handlingMS: DiagnosticTiming.elapsedMS(since: handling)),
                    interruptionLevel: interruptionLevel))
            } else {
                model.log.record("watch_payload_unrecognized", code: 1)
                model.log.record("watch_foreground_notification", code: hasSound ? 1 : 0)
            }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let alert = WatchCryAlert.notification(response.notification.request.content)
        let acknowledge = response.actionIdentifier == WatchNotification.acknowledge
        let deliveredAt = response.notification.date, observedAt = Date()
        await MainActor.run {
            if let alert {
                WatchModel.shared.log.watchAlert(WatchAlertTrace(alert: alert, phase: acknowledge ? .acknowledged : .opened,
                                                               deliveredAt: deliveredAt, observedAt: observedAt))
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
                             diagnosticRef: DiagnosticCorrelation.reference(info["diagnosticRef"] as? String),
                             deliveryAttempt: DiagnosticCorrelation.attempt(info["deliveryAttempt"] as? Int))
    }
}

final class CryNotificationController: WKUserNotificationHostingController<CryNotificationView> {
    private var alert: WatchCryAlert?
    private var deliveredAt: Date?
    private var activatedAt: Date?
    private var text = "Open the app for nursery status."
    override class var isInteractive: Bool { true }
    override var body: CryNotificationView {
        let deliveredAt = self.deliveredAt
        return CryNotificationView(alert: alert, deliveredAt: deliveredAt, text: text) { [weak self, alert] in
            guard let alert else { return }
            WatchModel.shared.log.watchAlert(WatchAlertTrace(alert: alert, phase: .acknowledged, deliveredAt: deliveredAt))
            WatchModel.shared.handleNotification(alert, acknowledging: true)
            self?.performDismissAction()
        }
    }
    override func willActivate() {
        super.willActivate()
        let now = Date(); activatedAt = now
        if let alert, let deliveredAt {
            Task { @MainActor in
                await Task.yield()
                WatchModel.shared.log.watchAlert(WatchAlertTrace(alert: alert, phase: .controllerActivated, deliveredAt: deliveredAt, observedAt: now,
                    applicationState: WatchModel.shared.diagnosticApplicationState))
            }
        }
    }
    override func didDeactivate() {
        super.didDeactivate()
        let now = Date()
        if let alert, let deliveredAt {
            Task { @MainActor in
                await Task.yield()
                WatchModel.shared.log.watchAlert(WatchAlertTrace(alert: alert, phase: .controllerDeactivated, deliveredAt: deliveredAt, observedAt: now,
                    applicationState: WatchModel.shared.diagnosticApplicationState))
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
            let deliveredAt = notification.date, activatedAt = self.activatedAt
            let preparedMS = DiagnosticTiming.elapsedMS(since: started), queued = ContinuousClock.now
            let level = Int(exactly: notification.request.content.interruptionLevel.rawValue)
            // Render from the payload alone. No model/disk/phone work is required
            // to return this controller's notification content to watchOS.
            Task { @MainActor in
                await Task.yield()
                let model = WatchModel.shared
                model.receive(alert)
                var traces = [WatchAlertTrace(alert: alert, phase: .controllerReceived, deliveredAt: deliveredAt, observedAt: observedAt,
                    applicationState: model.diagnosticApplicationState,
                    timing: .init(mainActorWaitMS: DiagnosticTiming.elapsedMS(since: queued), handlingMS: preparedMS), interruptionLevel: level)]
                if let activatedAt { traces.append(WatchAlertTrace(alert: alert, phase: .controllerActivated, deliveredAt: deliveredAt, observedAt: activatedAt,
                    applicationState: model.diagnosticApplicationState)) }
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
            Label(alert?.isTest == true ? "Test alert" : "Check on baby", systemImage: "waveform")
                .font(.headline).foregroundStyle(.orange)
            Text(text).font(.footnote)
            if let alert { Text(alert.createdAt, style: .time).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 8).onAppear {
            if let alert {
                let observedAt = Date()
                Task { @MainActor in
                    await Task.yield()
                    WatchModel.shared.log.watchAlert(WatchAlertTrace(alert: alert, phase: .viewAppeared, deliveredAt: deliveredAt, observedAt: observedAt,
                        applicationState: WatchModel.shared.diagnosticApplicationState))
                }
            }
        }
    }
}
