import AlarmKit
import UIKit
import UserNotifications

/// Schedules the episode's AlarmKit alarm as the alert push is delivered, without
/// waiting for iOS to wake the app. The notification itself is never changed and
/// is always released within one second, so a slow or failed attempt cannot hold
/// back the alert or its forwarding to the Watch.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private static let deadline: TimeInterval = 1
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let startedAt = Date()
        lock.withLock { handler = contentHandler; content = request.content }
        let payload = request.content.userInfo
        guard payload["alarmExtension"] as? Bool == true else { release(); return }
        let flags = AlarmAttempt.flags(in: payload)
        let eventID = (payload["eventId"] as? String).flatMap(UUID.init(uuidString:))
        let episodeID = (payload["episodeId"] as? String).flatMap(UUID.init(uuidString:))
        let parsed = SilentCryAlarmRequest(payload: payload)
        let rejection = parsed == nil ? SilentCryAlarmRequest.payloadRejection(payload) : nil
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.deadline) { [weak self] in self?.release() }
        Task {
            let attempt = await Self.attempt(parsed, rejection: rejection, eventID: eventID, episodeID: episodeID,
                                             flags: flags, startedAt: startedAt)
            AlarmJournal.forMethod(.extension)?.append(attempt)
            release()
        }
    }

    override func serviceExtensionTimeWillExpire() { release() }

    private func release() {
        let pending: (((UNNotificationContent) -> Void), UNNotificationContent)? = lock.withLock {
            defer { handler = nil }
            guard let handler, let content else { return nil }
            return (handler, content)
        }
        if let (handler, content) = pending { handler(content) }
    }

    private static func attempt(_ request: SilentCryAlarmRequest?, rejection: SilentCryAlarmRequest.Rejection?,
                                eventID: UUID?, episodeID: UUID?, flags: [String], startedAt: Date) async -> AlarmAttempt {
        let conditions = await MainActor.run { Self.conditions() }
        func result(_ outcome: AlarmAttempt.Outcome, _ reason: String? = nil, alarmAt: Date? = nil) -> AlarmAttempt {
            AlarmAttempt(method: .extension, outcome: outcome, reason: reason, eventID: eventID, episodeID: episodeID,
                         isTest: request?.isTest ?? false, flags: flags, pushCreatedAt: request?.createdAt,
                         startedAt: startedAt, finishedAt: Date(), alarmAt: alarmAt, conditions: conditions)
        }
        guard let request else { return result(.rejected, (rejection ?? .malformed).rawValue) }
        // Unreadable before the first unlock after a restart: do nothing; the
        // notification still alerts.
        guard let snapshot = AlarmSnapshot.load() else { return result(.rejected, SilentCryAlarmRequest.Rejection.noSnapshot.rawValue) }
        if let reason = snapshot.ineligibilityReason(for: request, now: Date()) { return result(.rejected, reason.rawValue) }
        // The extension sees `notDetermined` even when the app is authorized, so
        // leave authorization to AlarmKit's own check when scheduling.
        guard SilentAlarmScheduling.assetAvailable else { return result(.rejected, SilentCryAlarmRequest.Rejection.missingAsset.rawValue) }
        do {
            if try AlarmManager.shared.alarms.contains(where: { $0.id == request.episodeID }) { return result(.duplicate) }
            let fireAt = Date().addingTimeInterval(SilentAlarmScheduling.delay)
            _ = try await AlarmManager.shared.schedule(id: request.episodeID,
                                                       configuration: SilentAlarmScheduling.configuration(for: request, at: fireAt))
            return result(.scheduled, alarmAt: fireAt)
        } catch {
            return result(.failed, String(describing: error))
        }
    }

    @MainActor private static func conditions() -> AlarmAttempt.Conditions {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        return .init(charging: device.batteryState == .unknown ? nil : device.batteryState == .charging || device.batteryState == .full,
                     batteryLevel: device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil,
                     lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, appActive: nil, protectedDataAvailable: nil)
    }
}
