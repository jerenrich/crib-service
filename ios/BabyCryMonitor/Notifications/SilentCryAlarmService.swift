import AlarmKit
import AppIntents
import Observation
import UIKit

@available(iOS 26.0, *)
@MainActor @Observable final class SilentCryAlarmService {
    static let shared = SilentCryAlarmService()
    private(set) var enabled: Bool
    private(set) var busy = false
    private(set) var status = "Off. Existing notifications remain enabled."
    weak var log: DiagnosticLog?
    private let defaults: UserDefaults
    private static let alertSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = SilentCryAlarmExecutionBudget.requestTimeout
        configuration.timeoutIntervalForResource = SilentCryAlarmExecutionBudget.requestTimeout
        return URLSession(configuration: configuration)
    }()
    private let evidenceKey = "silentCryAlarmServerEvidence"
    private var serverEvidence: SilentCryAlarmRequest.ServerEvidence?
    private var snoozeDuration: TimeInterval
    private let recordsKey = "silentCryAlarmRecords"
    private let pendingKey = "silentCryAlarmPendingAcknowledgements"
    private var receiving = false
    private var flushingReceipts = false
    private var receiptRetry: (cycleID: UUID, afterUptime: Double)?
    private let receiptsKey = "silentCryAlarmSchedulingReceipts"
    private struct SchedulingReceipt: Codable { let episodeID: UUID; let eventID: UUID; let cycleID: UUID }
    private var pendingReceipts: [SchedulingReceipt] {
        get { defaults.data(forKey: receiptsKey).flatMap { try? JSONDecoder().decode([SchedulingReceipt].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: receiptsKey) }
    }
    private var flushing = false
    private var revision = 0
    private var lastReadinessUptime: Double?
    private struct Metadata: AlarmMetadata {}
    private struct Record: Codable { let episodeID: UUID; let eventID: UUID; let snoozeDuration: Double; let scheduledAt: Date }
    private var records: [Record] {
        get { (defaults.data(forKey: recordsKey)).flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: recordsKey) }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "silentWatchAlarmsEnabled")
        serverEvidence = defaults.data(forKey: evidenceKey).flatMap {
            try? JSONDecoder().decode(SilentCryAlarmRequest.ServerEvidence.self, from: $0)
        }
        snoozeDuration = (try? MetadataStore().load().configuration.snoozeDuration) ?? MonitoringConfiguration().snoozeDuration
        if enabled { status = "Enabled. Lock this iPhone for Watch delivery; existing notifications continue." }
    }

    private func client() throws -> BackendClient {
        guard defaults.string(forKey: "role") == "parent" else { throw BackendError.message("Choose Parent Mode first.") }
        let environment = defaults.string(forKey: "backendURL") ?? Bundle.main.object(forInfoDictionaryKey: "BackendURL") as? String ?? ""
        guard let url = URL(string: environment), !environment.isEmpty,
              let credential = try KeychainStore().load(role: .parent, environment: environment), credential.registered else {
            throw BackendError.message("Open Parent Mode and complete pairing first.")
        }
        var result = BackendClient(baseURL: url, credential: credential); result.log = log; result.requestTimeout = 8
        return result
    }

    func setEnabled(_ value: Bool, using client: any BackendServing) async {
        guard !busy else { return }
        busy = true; defer { busy = false; observeReadiness(source: .settingChange, force: true) }
        let generation = revision
        do {
            if value {
                guard try await AlarmManager.shared.requestAuthorization() == .authorized else {
                    status = "Allow alarms in iPhone Settings before enabling silent Watch alarms."; return
                }
                guard Bundle.main.url(forResource: "AlarmTestSilence", withExtension: "caf") != nil else {
                    status = "The silent tone is missing. Reinstall this app before enabling alarms."; return
                }
                try await client.silentWatchAlarms(true)
                guard generation == revision, defaults.string(forKey: "role") == "parent" else { return }
                enabled = true; revision += 1
                defaults.set(true, forKey: "silentWatchAlarmsEnabled")
                defaults.set(Date(), forKey: "silentWatchAlarmsChangedAt")
                defaults.set(false, forKey: "silentWatchAlarmsSettingDirty")
                status = "Enabled. Lock this iPhone for Watch delivery; existing notifications continue."
            } else {
                disableLocally()
                try await client.silentWatchAlarms(false)
                defaults.set(false, forKey: "silentWatchAlarmsSettingDirty")
                status = "Off. Existing notifications remain enabled."
            }
        } catch { status = value ? "Could not enable silent Watch alarms: \(error.localizedDescription)" : "Off on this iPhone. Server setting will sync when connected."; trace("failed") }
    }

    func disableLocally() {
        enabled = false; revision += 1
        defaults.set(false, forKey: "silentWatchAlarmsEnabled")
        defaults.set(Date(), forKey: "silentWatchAlarmsChangedAt")
        defaults.set(true, forKey: "silentWatchAlarmsSettingDirty")
        cancelAll()
    }

    func settingUnavailable() { status = enabled ? "Setting could not sync. Check the connection." : "Off on this iPhone. Server setting will sync when connected." }

    func synchronize(using client: any BackendServing, status server: ParentStatus, checkedAt: Date) async {
        remember(server, checkedAt: checkedAt)
        // This status was fetched before these uploads. An acknowledgement sent
        // here may start a snooze that the fetched status does not yet contain.
        let hadPendingAcknowledgements = !(defaults.stringArray(forKey: pendingKey) ?? []).isEmpty
        await flushAcknowledgements(using: client)
        await flushSchedulingReceipts(using: client)
        if defaults.bool(forKey: "silentWatchAlarmsSettingDirty") {
            do { try await client.silentWatchAlarms(enabled); defaults.set(false, forKey: "silentWatchAlarmsSettingDirty") }
            catch { trace("failed") }
        }
        // Never turn the feature on as a side effect of a server read.
        let settingChangedAt = defaults.object(forKey: "silentWatchAlarmsChangedAt") as? Date ?? .distantPast
        if checkedAt >= settingChangedAt, !server.paired || server.silentWatchAlarmsEnabled == false {
            if enabled { disableLocally() }
        }
        reconcile(server, checkedAt: checkedAt, canResumeLocalSnooze: !hadPendingAcknowledgements)
    }

    private func remember(_ server: ParentStatus, checkedAt: Date) {
        let observedAt = server.serverTime ?? checkedAt
        guard serverEvidence.map({ $0.observedAt <= observedAt }) ?? true else { return }
        let evidence = SilentCryAlarmRequest.ServerEvidence(observedAt: observedAt, paired: server.paired,
            enabled: server.silentWatchAlarmsEnabled, relevance: server.notificationRelevance,
            mutedUntil: server.alertsMutedUntil)
        let changed = serverEvidence.map { !$0.hasSameState(as: evidence) } ?? true
        serverEvidence = evidence
        // Normal status polling advances the in-memory timestamp. Persist only
        // state changes so this safeguard adds no write on every poll.
        if changed { defaults.set(try? JSONEncoder().encode(evidence), forKey: evidenceKey) }
        snoozeDuration = server.configuration.snoozeDuration
    }

    /// Called only when execution is already available; never requests permission,
    /// schedules a probe alarm or contacts the backend.
    func observeReadiness(source: SilentCryAlarmRequest.ObservationSource, force: Bool = false) {
        guard defaults.string(forKey: "role") == "parent", enabled || force else { return }
        let uptime = BackgroundBenchmark.continuousUptime
        guard force || lastReadinessUptime.map({ uptime - $0 >= 60 }) ?? true else { return }
        lastReadinessUptime = uptime
        let authorization: SilentCryAlarmRequest.Authorization = switch AlarmManager.shared.authorizationState {
        case .authorized: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
        var credentialsAvailable = false, alarmCount: Int?, failure: (any Error)?
        do { _ = try client(); credentialsAvailable = true } catch { failure = error }
        do { alarmCount = try AlarmManager.shared.alarms.count } catch { failure = error }
        (log ?? DiagnosticLog()).silentCryAlarmReadiness(source: source, enabled: enabled,
            authorization: authorization, assetAvailable: Bundle.main.url(forResource: "AlarmTestSilence", withExtension: "caf") != nil,
            credentialsAvailable: credentialsAvailable, acknowledgementPending: !(defaults.stringArray(forKey: pendingKey) ?? []).isEmpty,
            locallyMuted: (defaults.object(forKey: "silentCryAlarmMutedUntil") as? Date ?? .distantPast) > Date(),
            alarmCount: alarmCount, appActive: UIApplication.shared.applicationState == .active,
            protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable, error: failure)
    }

    func receive(_ callback: SilentCryAlarmRequest.Callback, source: SilentCryAlarmRequest.Source) async -> Bool {
        let attemptID = UUID(), start = callback.start
        let eventID = callback.eventID, episodeID = callback.episodeID
        attempt("entered", stage: .callback, source: source, attemptID: attemptID,
            eventID: eventID, episodeID: episodeID, start: start, callbackAt: callback.receivedAt)
        guard let request = callback.request else {
            attempt("rejected", stage: .callback, source: source, attemptID: attemptID,
                eventID: eventID, episodeID: episodeID, start: start,
                reason: callback.rejection ?? .malformed)
            return false
        }
        return await receive(request, source: source, attemptID: attemptID, start: start)
    }

    private func receive(_ request: SilentCryAlarmRequest, source: SilentCryAlarmRequest.Source,
                         attemptID: UUID, start: ContinuousClock.Instant) async -> Bool {
        var stage = SilentCryAlarmRequest.Stage.preflight
        func record(_ phase: String, reason: SilentCryAlarmRequest.Rejection? = nil, error: (any Error)? = nil) {
            attempt(phase, stage: stage, source: source, attemptID: attemptID, eventID: request.eventID,
                episodeID: request.episodeID, start: start, reason: reason,
                requestAgeMS: Int(Date().timeIntervalSince(request.createdAt) * 1000), error: error)
        }
        trace("received", request.eventID)
        guard enabled else { record("rejected", reason: .disabled); return false }
        guard !receiving else { record("rejected", reason: .busy); return false }
        receiving = true; defer { receiving = false }
        let generation = revision
        let budget = SilentCryAlarmExecutionBudget(startedAt: start)
        func fallbackRejection() -> SilentCryAlarmRequest.Rejection? {
            request.fallbackIneligibilityReason(enabled: enabled,
                acknowledgementPending: !(defaults.stringArray(forKey: pendingKey) ?? []).isEmpty,
                localMutedUntil: defaults.object(forKey: "silentCryAlarmMutedUntil") as? Date,
                stoppedBefore: defaults.object(forKey: "silentCryAlarmStoppedBefore") as? Date,
                evidence: serverEvidence, now: Date())
        }
        do {
            try budget.requireTime()
            guard AlarmManager.shared.authorizationState == .authorized else {
                record("rejected", reason: .unauthorized); return false
            }
            guard Bundle.main.url(forResource: "AlarmTestSilence", withExtension: "caf") != nil else {
                record("rejected", reason: .missingAsset); return false
            }
            var backend = try client()
            backend.session = Self.alertSession
            backend.requestTimeout = SilentCryAlarmExecutionBudget.requestTimeout
            stage = .acknowledgements
            // A pending Snooze takes a separate short sync path. Never continue
            // into status/fallback/scheduling from this same callback.
            if !(defaults.stringArray(forKey: pendingKey) ?? []).isEmpty {
                record("started")
                await flushAcknowledgements(using: backend, limit: 1)
                try budget.requireTime()
                trace("ack_pending", request.eventID); record("rejected", reason: .acknowledgementPending); return false
            }
            let snapshot: SilentCryAlarmStatusSnapshot<ParentStatus>?
            do {
                snapshot = try await SilentCryAlarmStatusSnapshot<ParentStatus>.load(budget: budget) {
                    stage = .status; record("started")
                    let server = try await backend.status()
                    record("completed")
                    return server
                }
            } catch {
                // A timeout is only a fallback opportunity while this callback
                // still has our own execution budget and the push is very recent.
                try budget.requireTime()
                guard SilentCryAlarmRequest.allowsStatusFallback(for: error) else { throw error }
                if let reason = fallbackRejection() { record("rejected", reason: reason); return false }
                record("fallback", error: error)
                snapshot = nil
            }
            if let snapshot {
                remember(snapshot.value, checkedAt: snapshot.checkedAt)
                reconcile(snapshot.value, checkedAt: snapshot.checkedAt)
            }
            stage = .eligibility
            let reason: SilentCryAlarmRequest.Rejection?
            if generation != revision { reason = .settingChanged }
            else if let snapshot { reason = request.ineligibilityReason(enabled: enabled, serverEnabled: snapshot.value.silentWatchAlarmsEnabled == true,
                paired: snapshot.value.paired, relevance: snapshot.value.notificationRelevance,
                mutedUntil: snapshot.value.alertsMutedUntil, localMutedUntil: defaults.object(forKey: "silentCryAlarmMutedUntil") as? Date,
                stoppedBefore: defaults.object(forKey: "silentCryAlarmStoppedBefore") as? Date, now: Date()) }
            else { reason = fallbackRejection() }
            if let reason { trace("ignored", request.eventID); record("rejected", reason: reason); return false }
            stage = .alarmLookup
            let existing = try AlarmManager.shared.alarms
            // One alarm per episode. Reminder notifications never restart an active alarm.
            if existing.contains(where: { $0.id == request.episodeID }) {
                trace("duplicate", request.eventID); record("duplicate")
                queueSchedulingReceipt(request)
                return false
            }
            let attributes = AlarmAttributes<Metadata>(presentation: AlarmPresentation(alert: .init(
                title: request.isDisconnected ? "Listener connection lost" : request.isMonitoringFailure ? "Nursery monitoring stopped" : "Check on baby",
                stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle")
            )), metadata: Metadata(), tintColor: .mint)
            // Persist acknowledgement metadata before scheduling so an immediate Stop
            // can resolve the event even when the app has to relaunch for the intent.
            var saved = records.filter { $0.episodeID != request.episodeID }
            saved.append(Record(episodeID: request.episodeID, eventID: request.eventID, snoozeDuration: snoozeDuration, scheduledAt: Date()))
            records = Array(saved.suffix(64))
            let configuration = AlarmManager.AlarmConfiguration<Metadata>.alarm(
                schedule: .fixed(Date().addingTimeInterval(3)), attributes: attributes,
                stopIntent: SnoozeSilentCryAlarmIntent(episodeID: request.episodeID.uuidString),
                sound: .named("AlarmTestSilence.caf"))
            stage = .schedule; record("started")
            // Local reconciliation, alarm lookup or persistence can also stall.
            // Recheck immediately before handing a new alarm to the system.
            try budget.requireTime()
            if let snapshot, !snapshot.isFresh() {
                throw SilentCryAlarmRequest.Rejection.staleStatus
            }
            if snapshot == nil, let reason = fallbackRejection() {
                record("rejected", reason: reason); return false
            }
            _ = try await AlarmManager.shared.schedule(id: request.episodeID, configuration: configuration)
            record("completed")
            // A user can disable/snooze while the system scheduling call is suspended.
            if generation != revision || !enabled {
                stage = .cancel; record("started", reason: .settingChanged)
                do {
                    try AlarmManager.shared.cancel(id: request.episodeID)
                    record("cancelled", reason: .settingChanged)
                } catch { record("failed", reason: .settingChanged, error: error) }
                return false
            }
            status = "Silent alert alarm scheduled. Existing notifications continue."
            trace("scheduled", request.eventID); record("scheduled")
            queueSchedulingReceipt(request)
            return true
        } catch SilentCryAlarmRequest.Rejection.budgetExpired {
            status = "Alarm attempt expired; existing notifications continue."
            trace("ignored", request.eventID); record("rejected", reason: .budgetExpired); return false
        } catch SilentCryAlarmRequest.Rejection.staleStatus {
            status = "Current alert status unavailable; existing notifications continue."
            trace("ignored", request.eventID); record("rejected", reason: .staleStatus); return false
        } catch {
            status = "Silent alarm unavailable; existing notifications continue."
            trace("failed", request.eventID); record("failed", error: error); return false
        }
    }

    private func attempt(_ phase: String, stage: SilentCryAlarmRequest.Stage, source: SilentCryAlarmRequest.Source,
                         attemptID: UUID, eventID: UUID?, episodeID: UUID?, start: ContinuousClock.Instant,
                         reason: SilentCryAlarmRequest.Rejection? = nil, requestAgeMS: Int? = nil,
                         callbackAt: Date? = nil, error: (any Error)? = nil) {
        let duration = start.duration(to: .now).components
        let elapsedMS = Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000)
        (log ?? DiagnosticLog()).silentCryAlarmAttempt(phase: phase, stage: stage, source: source,
            attemptID: attemptID, eventID: eventID, episodeID: episodeID, reason: reason, elapsedMS: elapsedMS,
            appActive: UIApplication.shared.applicationState == .active, protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
            backgroundTimeRemaining: UIApplication.shared.backgroundTimeRemaining, requestAgeMS: requestAgeMS,
            callbackAt: callbackAt, executionBudgetRemainingMS: SilentCryAlarmExecutionBudget(startedAt: start).remainingMilliseconds(), error: error)
    }

    func snooze(episodeID: UUID) async {
        guard let record = records.first(where: { $0.episodeID == episodeID }) else { return }
        snoozeLocally(eventID: record.eventID, duration: record.snoozeDuration)
        do { try await flushAcknowledgements(using: client()) } catch { trace("ack_pending", record.eventID) }
    }

    func snoozeLocally(eventID: UUID, duration: Double) {
        guard enabled || records.contains(where: { $0.eventID == eventID }) else { return }
        guard SilentCryAlarmSnooze(defaults: defaults).apply(eventID: eventID, duration: duration, now: Date()) else { return }
        revision += 1
        cancelAll()
        status = "Alerts snoozed. Acknowledgement syncs when connected."
        trace("snoozed", eventID)
    }

    func acknowledgeKnownEvent(_ eventID: UUID) {
        guard let record = records.first(where: { $0.eventID == eventID }) else { return }
        snoozeLocally(eventID: eventID, duration: record.snoozeDuration)
    }

    func flushAcknowledgements(using client: any BackendServing, limit: Int = 2) async {
        guard !flushing else { return }; flushing = true; defer { flushing = false }
        // Keep acknowledgement work bounded within the background execution budget.
        for text in (defaults.stringArray(forKey: pendingKey) ?? []).prefix(max(0, min(2, limit))) {
            guard let id = UUID(uuidString: text) else { continue }
            do { try await client.acknowledge(id, actedAt: SilentCryAlarmSnooze(defaults: defaults).actedAt(id)) }
            catch BackendError.response(404, _) { /* Old/deleted pairing: discard only this old action. */ }
            catch { trace("ack_pending", id); return }
            SilentCryAlarmSnooze(defaults: defaults).markHandled(id)
            defaults.removeObject(forKey: SilentCryAlarmSnooze.actedAtKey(id))
            var pending = defaults.stringArray(forKey: pendingKey) ?? []
            pending.removeAll { $0 == text }; defaults.set(pending, forKey: pendingKey)
            defaults.set(Date(), forKey: "silentCryAlarmAcknowledgementsSyncedAt")
            trace("acknowledged", id)
        }
    }

    private func reconcile(_ server: ParentStatus, checkedAt: Date, canResumeLocalSnooze: Bool = true) {
        // A fresh, unmuted server status confirms early Resume. Keep the cutoff
        // for old pushes, and never undo a newer or still-unsynced local Snooze.
        if canResumeLocalSnooze, server.paired,
           (server.alertsMutedUntil ?? .distantPast) <= Date(),
           (defaults.stringArray(forKey: pendingKey) ?? []).isEmpty,
           (defaults.object(forKey: "silentCryAlarmAcknowledgementsSyncedAt") as? Date ?? .distantPast) <= checkedAt,
           let stoppedBefore = defaults.object(forKey: "silentCryAlarmStoppedBefore") as? Date,
           stoppedBefore <= checkedAt,
           defaults.object(forKey: "silentCryAlarmMutedUntil") != nil {
            defaults.removeObject(forKey: "silentCryAlarmMutedUntil")
            if enabled { status = "Alerts resumed. Existing notifications continue." }
        }
        guard !records.isEmpty else { return }
        let muted = (server.alertsMutedUntil ?? .distantPast) > Date()
        let obsolete = records.filter { record in
            record.scheduledAt <= checkedAt && (!server.paired || muted ||
                server.notificationRelevance.map { !$0.cryEpisodeIDs.contains(record.episodeID) } == true)
        }
        do {
            let active = Set(try AlarmManager.shared.alarms.map(\.id))
            for record in obsolete where active.contains(record.episodeID) { try AlarmManager.shared.cancel(id: record.episodeID) }
        } catch { trace("failed") }
    }

    private func cancelAll() {
        pendingReceipts = []
        guard !records.isEmpty else { return }
        do {
            let ids = Set(records.map(\.episodeID))
            for alarm in try AlarmManager.shared.alarms where ids.contains(alarm.id) { try AlarmManager.shared.cancel(id: alarm.id) }
        } catch { trace("failed") }
    }

    private func queueSchedulingReceipt(_ request: SilentCryAlarmRequest) {
        guard let cycleID = request.cycleID else { return } // Legacy requests remain compatible.
        var pending = pendingReceipts
        if !pending.contains(where: { $0.cycleID == cycleID }) {
            let receipt = SchedulingReceipt(episodeID: request.episodeID, eventID: request.eventID, cycleID: cycleID)
            pending.append(receipt); pendingReceipts = Array(pending.suffix(64))
            receiptTrace("queued", receipt)
        }
    }

    // Retry at most one persisted receipt when the app already has execution.
    // A failed upload never cancels or delays an already scheduled alarm.
    private func flushSchedulingReceipts(using backend: any BackendServing) async {
        guard enabled, !flushingReceipts, let receipt = pendingReceipts.first else { return }
        if let retry = receiptRetry, retry.cycleID == receipt.cycleID, BackgroundBenchmark.continuousUptime < retry.afterUptime { return }
        flushingReceipts = true; defer { flushingReceipts = false }
        do {
            try await backend.confirmAlarmScheduled(episodeID: receipt.episodeID, eventID: receipt.eventID, cycleID: receipt.cycleID)
            pendingReceipts = pendingReceipts.filter { $0.cycleID != receipt.cycleID }
            receiptRetry = nil; receiptTrace("confirmed", receipt)
        } catch BackendError.response(409, _) {
            pendingReceipts = pendingReceipts.filter { $0.cycleID != receipt.cycleID }
            receiptRetry = nil; receiptTrace("discarded", receipt)
        } catch {
            receiptRetry = (receipt.cycleID, BackgroundBenchmark.continuousUptime + 30)
            receiptTrace("deferred", receipt)
        }
    }

    private func receiptTrace(_ phase: String, _ receipt: SchedulingReceipt) {
        (log ?? DiagnosticLog()).silentCryAlarmReceipt(phase: phase, episodeID: receipt.episodeID, eventID: receipt.eventID, cycleID: receipt.cycleID)
    }

    private func trace(_ phase: String, _ eventID: UUID? = nil) {
        (log ?? DiagnosticLog()).silentCryAlarm(phase: phase, eventID: eventID,
            appActive: UIApplication.shared.applicationState == .active)
    }
}

@available(iOS 26.0, *)
struct SnoozeSilentCryAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Snooze alerts" }
    @Parameter(title: "Episode") var episodeID: String
    init() {}
    init(episodeID: String) { self.episodeID = episodeID }
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: episodeID) { await SilentCryAlarmService.shared.snooze(episodeID: id) }
        return .result()
    }
}
