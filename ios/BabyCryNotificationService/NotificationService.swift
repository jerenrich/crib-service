import AlarmKit
import OSLog
import UIKit
import UserNotifications

/// Schedules the episode's AlarmKit alarm as the alert push is delivered, without
/// waiting for iOS to wake the app. The notification itself is never changed and
/// is always released within one second, so a slow or failed attempt cannot hold
/// back the alert or its forwarding to the Watch.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private static let deadline: TimeInterval = 1
    /// The system log keeps a copy of every attempt, including any the journal could not store.
    private static let logger = Logger(subsystem: "com.jordanerenrich.cribservice", category: "alarm-extension")
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNNotificationContent?
    /// Guarded by `lock`: whichever of the attempt and the cut-off finishes first wins.
    private var attemptFinished = false
    private var cutOff = false

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
        let journal = AlarmJournal.forMethod(.extension)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.deadline) { [weak self] in
            guard let self else { return }
            let late = lock.withLock { () -> Bool in
                guard !attemptFinished else { return false }
                cutOff = true; return true
            }
            // Record the cut-off now: iOS may end the extension once it is released.
            if late {
                let conditions = MainActor.assumeIsolated { Self.conditions() }
                Self.record(AlarmAttempt(method: .extension, outcome: .timedOut, reason: nil, eventID: eventID,
                    episodeID: episodeID, isTest: parsed?.isTest ?? false, flags: flags, pushCreatedAt: parsed?.createdAt,
                    startedAt: startedAt, finishedAt: Date(), alarmAt: nil, conditions: conditions), in: journal)
            }
            release()
        }
        Task {
            var attempt = await Self.attempt(parsed, rejection: rejection, eventID: eventID, episodeID: episodeID,
                                             flags: flags, startedAt: startedAt)
            let afterCutOff = lock.withLock { () -> Bool in attemptFinished = true; return cutOff }
            if afterCutOff { attempt.reason = attempt.reason.map { "after_cutoff+" + $0 } ?? "after_cutoff" }
            Self.record(attempt, in: journal)
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

    private static func record(_ attempt: AlarmAttempt, in journal: AlarmJournal?) {
        let ids = "event_id=\(attempt.eventID?.uuidString.lowercased() ?? "none") episode_id=\(attempt.episodeID?.uuidString.lowercased() ?? "none")"
        logger.notice("alarm_attempt outcome=\(attempt.outcome.rawValue, privacy: .public) reason=\(attempt.reason ?? "none", privacy: .public) detail=\(attempt.detail ?? "none", privacy: .public) \(ids, privacy: .public) handler_ms=\(attempt.handlerMS, privacy: .public) push_to_alarm_ms=\(attempt.pushToAlarmMS.map(String.init) ?? "unknown", privacy: .public)")
        guard let journal else { logger.error("alarm_journal_failed reason=app_group_unavailable"); return }
        do { try journal.append(attempt) }
        catch { logger.error("alarm_journal_failed reason=\(String(describing: error), privacy: .public) \(ids, privacy: .public)") }
    }

    private static func attempt(_ request: SilentCryAlarmRequest?, rejection: SilentCryAlarmRequest.Rejection?,
                                eventID: UUID?, episodeID: UUID?, flags: [String], startedAt: Date) async -> AlarmAttempt {
        let conditions = await MainActor.run { Self.conditions() }
        var snapshotAgeMS: Int?, evidenceApplied: Bool?
        func result(_ outcome: AlarmAttempt.Outcome, _ reason: String? = nil, detail: String? = nil, alarmAt: Date? = nil) -> AlarmAttempt {
            AlarmAttempt(method: .extension, outcome: outcome, reason: reason, eventID: eventID, episodeID: episodeID,
                         isTest: request?.isTest ?? false, flags: flags, pushCreatedAt: request?.createdAt,
                         startedAt: startedAt, finishedAt: Date(), alarmAt: alarmAt, conditions: conditions,
                         detail: detail, snapshotAgeMS: snapshotAgeMS, evidenceApplied: evidenceApplied)
        }
        guard let request else { return result(.rejected, (rejection ?? .malformed).rawValue) }
        // Unreadable before the first unlock after a restart: do nothing; the
        // notification still alerts.
        let snapshot: AlarmSnapshot
        switch AlarmSnapshot.read() {
        case .success(let value): snapshot = value
        case .failure(let issue): return result(.rejected, SilentCryAlarmRequest.Rejection.noSnapshot.rawValue, detail: issue.rawValue)
        }
        snapshotAgeMS = Int(Date().timeIntervalSince(snapshot.publishedAt) * 1000)
        evidenceApplied = snapshot.evidenceApplies(to: request)
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
            // Domain and code only: error descriptions can carry arbitrary text.
            let error = error as NSError
            return result(.failed, detail: "\(error.domain)#\(error.code)")
        }
    }

    @MainActor private static func conditions() -> AlarmAttempt.Conditions {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        return .init(charging: device.batteryState == .unknown ? nil : device.batteryState == .charging || device.batteryState == .full,
                     batteryLevel: device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil,
                     lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, appActive: nil,
                     protectedDataAvailable: AlarmShared.protectedDataAvailable())
    }
}
