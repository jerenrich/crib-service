import Foundation
import Observation
import SwiftUI
import UserNotifications
import WatchKit

// Deliberately no companion, connectivity, custom notification scene or app haptics.
@main struct WatchLatencyProbeApp: App {
    @WKApplicationDelegateAdaptor(ProbeDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Wrist Probe").font(.headline)
                    Text("Standalone notification experiment").font(.caption)
                    Text(ProbeState.shared.status).font(.caption)
                    Button("Enable alerts") { Task { await ProbeState.shared.authorize() } }
                    Button("Local test in 10s") { Task { await ProbeState.shared.scheduleLocal() } }
                    Text("After scheduling, return to the watch face and lower your wrist. Default sound permits a tap; use Watch Silent Mode to mute audio.").font(.caption2)
                }.padding()
            }
        }
    }
}

@MainActor @Observable final class ProbeState {
    static let shared = ProbeState()
    var status = "Enable alerts, then run an isolated test."

    func authorize() async {
        do {
            let center = UNUserNotificationCenter.current()
            guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else {
                status = "Allow notifications in Settings."; return
            }
            let settings = await center.notificationSettings()
            ProbeJournal.shared.record("authorization", fields: [
                "authorization": settings.authorizationStatus.rawValue,
                "sound": settings.soundSetting.rawValue,
                "timeSensitive": settings.timeSensitiveSetting.rawValue
            ])
            WKApplication.shared().registerForRemoteNotifications()
            status = "Alerts enabled; registering direct push."
        } catch { status = "Could not enable alerts: \(error.localizedDescription)" }
    }

    func scheduleLocal() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else {
            status = "Enable alerts first."; return
        }
        // Each trial is isolated; replacing an untriggered local test is explicit.
        center.removeAllPendingNotificationRequests()
        let eventID = UUID().uuidString
        let content = UNMutableNotificationContent()
        content.title = "Test · Wrist Probe"
        content.body = "Standalone local notification"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["eventId": eventID, "isTest": true]
        do {
            let scheduledAt = Date()
            try await center.add(UNNotificationRequest(identifier: eventID, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)))
            ProbeJournal.shared.record("local_scheduled", fields: ["eventId": eventID,
                "expectedFireAtMS": scheduledAt.addingTimeInterval(10).timeIntervalSince1970 * 1000])
            status = "Test in 10 seconds. Return to the watch face."
        } catch { status = "Could not schedule: \(error.localizedDescription)" }
    }
}

@MainActor final class ProbeDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
        ProbeJournal.shared.record("launch", fields: ["watchOnly": true,
            "bundleID": Bundle.main.bundleIdentifier ?? "unknown"])
        Task {
            if await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized {
                WKApplication.shared().registerForRemoteNotifications()
            }
        }
    }
    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        do {
            // Private operator export; never include the token in callback logs.
            try ProbeJournal.shared.saveToken(deviceToken.map { String(format: "%02x", $0) }.joined())
            ProbeState.shared.status = "Direct push registered. Ready for local or remote tests."
            ProbeJournal.shared.record("push_registered")
        } catch { ProbeState.shared.status = "Could not save push registration." }
    }
    func didFailToRegisterForRemoteNotificationsWithError(_ error: any Error) {
        ProbeState.shared.status = "Push registration failed: \(error.localizedDescription)"
        ProbeJournal.shared.record("push_registration_failed")
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        let entry = Date()
        completionHandler([.banner, .list, .sound])
        ProbeJournal.shared.notification("foreground_entry", notification: notification, observedAt: entry)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let entry = Date()
        completionHandler()
        ProbeJournal.shared.notification("response_entry", notification: response.notification, observedAt: entry)
    }
}

// Small bounded journal, independent of the main actor. Callbacks are observations,
// not measurements of the physical motor or background notification arrival.
final class ProbeJournal: @unchecked Sendable {
    static let shared = ProbeJournal()
    private let lock = NSLock()
    private let processID = UUID().uuidString
    private let directory = URL.applicationSupportDirectory.appendingPathComponent("WatchLatencyProbe", isDirectory: true)

    func saveToken(_ token: String) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(token.utf8).write(to: directory.appendingPathComponent("push-token.txt"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func notification(_ phase: String, notification: UNNotification, observedAt: Date) {
        let content = notification.request.content
        var fields: [String: Any] = ["requestID": notification.request.identifier,
            "notificationDateMS": notification.date.timeIntervalSince1970 * 1000,
            "interruptionLevel": content.interruptionLevel.rawValue, "hasSound": content.sound != nil]
        if let eventID = content.userInfo["eventId"] as? String, UUID(uuidString: eventID) != nil { fields["eventId"] = eventID }
        record(phase, fields: fields, observedAt: observedAt)
    }
    func record(_ phase: String, fields: [String: Any] = [:], observedAt: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("callbacks.jsonl")
            var record = fields
            record["phase"] = phase; record["observedAtMS"] = observedAt.timeIntervalSince1970 * 1000
            record["processID"] = processID
            var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            line.append(0x0a)
            var existing = (try? Data(contentsOf: url)) ?? Data()
            if existing.count + line.count > 256 * 1024 {
                try existing.write(to: directory.appendingPathComponent("callbacks.previous.jsonl"), options: .atomic)
                existing = Data()
            }
            existing.append(line)
            try existing.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { /* Diagnostic writes never prevent notification presentation. */ }
    }
}
