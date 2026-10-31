import AlarmKit
import AppIntents
import Observation
import UIKit

@available(iOS 26.0, *)
@MainActor @Observable final class SilentCryAlarmService {
    static let shared = SilentCryAlarmService()
    private(set) var enabled: Bool
    /// Delivery methods for comparing on device; the server sends only the selected markers.
    private(set) var appWakeEnabled: Bool
    private(set) var extensionEnabled: Bool
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
    private var receivingEventID: UUID?
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
    private typealias Record = SilentAlarmRecord
    /// Who turned alarms off, for the diagnostic log.
    enum ChangeSource: String { case user, server, serverResume = "server_resume", roleChange = "role_change", backendChanged = "backend_changed", unpaired }
    private var records: [Record] {
        get { (defaults.data(forKey: recordsKey)).flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: recordsKey) }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "silentWatchAlarmsEnabled")
        appWakeEnabled = defaults.object(forKey: "alarmMethodAppWake") as? Bool ?? true
        extensionEnabled = defaults.bool(forKey: "alarmMethodExtension")
        serverEvidence = defaults.data(forKey: evidenceKey).flatMap {
            try? JSONDecoder().decode(SilentCryAlarmRequest.ServerEvidence.self, from: $0)
        }
        snoozeDuration = (try? MetadataStore().load().configuration.snoozeDuration) ?? MonitoringConfiguration().snoozeDuration
        if enabled { status = "Enabled. Lock this iPhone for Watch delivery; existing notifications continue." }
        publishSnapshot()
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
                    setting("enable_blocked", source: .user, reason: "unauthorized")
                    status = "Allow alarms in iPhone Settings before enabling silent Watch alarms."; return
                }
                guard Bundle.main.url(forResource: "AlarmTestSilence", withExtension: "caf") != nil else {
                    setting("enable_blocked", source: .user, reason: "missing_asset")
                    status = "The silent tone is missing. Reinstall this app before enabling alarms."; return
                }
                try await client.silentWatchAlarms(true, appWake: appWakeEnabled, extensionMethod: extensionEnabled)
                guard generation == revision, defaults.string(forKey: "role") == "parent" else { return }
                enabled = true; revision += 1
                defaults.set(true, forKey: "silentWatchAlarmsEnabled")
                defaults.set(Date(), forKey: "silentWatchAlarmsChangedAt")
                defaults.set(false, forKey: "silentWatchAlarmsSettingDirty")
                status = "Enabled. Lock this iPhone for Watch delivery; existing notifications continue."
                setting("enabled", source: .user)
                publishSnapshot()
            } else {
                disableLocally(source: .user)
                try await client.silentWatchAlarms(false, appWake: appWakeEnabled, extensionMethod: extensionEnabled)
                defaults.set(false, forKey: "silentWatchAlarmsSettingDirty")
                status = "Off. Existing notifications remain enabled."
            }
        } catch { status = value ? "Could not enable silent Watch alarms: \(error.localizedDescription)" : "Off on this iPhone. Server setting will sync when connected."; trace("failed", operation: "set_enabled", error: error) }
    }

    func disableLocally(source: ChangeSource) {
        if enabled { setting("disabled", source: source) }
        enabled = false; revision += 1
        defaults.set(false, forKey: "silentWatchAlarmsEnabled")
        defaults.set(Date(), forKey: "silentWatchAlarmsChangedAt")
        defaults.set(true, forKey: "silentWatchAlarmsSettingDirty")
        cancelAll(reason: source == .unpaired ? "unpaired" : "disabled")
        publishSnapshot()
    }

    /// Changes take effect on the next push; the service learns them on sync.
    func setMethods(appWake: Bool, extensionMethod: Bool, using client: any BackendServing) async {
        appWakeEnabled = appWake; extensionEnabled = extensionMethod
        defaults.set(appWake, forKey: "alarmMethodAppWake"); defaults.set(extensionMethod, forKey: "alarmMethodExtension")
        defaults.set(Date(), forKey: "alarmMethodsChangedAt")
        defaults.set(true, forKey: "silentWatchAlarmsSettingDirty")
        setting("methods_changed", source: .user, appWake: appWake, extensionMethod: extensionMethod)
        publishSnapshot()
        do {
            try await client.silentWatchAlarms(enabled, appWake: appWake, extensionMethod: extensionMethod)
            defaults.set(false, forKey: "silentWatchAlarmsSettingDirty")
        } catch { status = "Alarm method change will sync when connected."; trace("failed", operation: "set_methods", error: error) }
    }

    func settingUnavailable() { status = enabled ? "Setting could not sync. Check the connection." : "Off on this iPhone. Server setting will sync when connected." }

    func synchronize(using client: any BackendServing, status server: ParentStatus, checkedAt: Date) async {
        defer { publishSnapshot() }
        mergeExtensionAttempts()
        remember(server, checkedAt: checkedAt)
        // This status was fetched before these uploads. An acknowledgement sent
        // here may start a snooze that the fetched status does not yet contain.
        let hadPendingAcknowledgements = !(defaults.stringArray(forKey: pendingKey) ?? []).isEmpty
        await flushAcknowledgements(using: client)
        await flushSchedulingReceipts(using: client)
        await uploadAttempts(using: client)
        if defaults.bool(forKey: "silentWatchAlarmsSettingDirty") {
            do {
                try await client.silentWatchAlarms(enabled, appWake: appWakeEnabled, extensionMethod: extensionEnabled)
                defaults.set(false, forKey: "silentWatchAlarmsSettingDirty")
            } catch { trace("failed", operation: "setting_sync", error: error) }
        } else if let methods = server.alarmMethods,
                  checkedAt >= (defaults.object(forKey: "alarmMethodsChangedAt") as? Date ?? .distantPast),
                  methods.appWake != appWakeEnabled || methods.extensionMethod != extensionEnabled {
            // Adopt the stored choice, e.g. after reinstalling the app.
            appWakeEnabled = methods.appWake; extensionEnabled = methods.extensionMethod
            defaults.set(methods.appWake, forKey: "alarmMethodAppWake"); defaults.set(methods.extensionMethod, forKey: "alarmMethodExtension")
            setting("methods_changed", source: .server, appWake: methods.appWake, extensionMethod: methods.extensionMethod)
        }
        // Never turn the feature on as a side effect of a server read.
        let settingChangedAt = defaults.object(forKey: "silentWatchAlarmsChangedAt") as? Date ?? .distantPast
        if checkedAt >= settingChangedAt, !server.paired || server.silentWatchAlarmsEnabled == false {
            if enabled { disableLocally(source: .server) }
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
            journal(.rejected, reason: (callback.rejection ?? .malformed).rawValue, eventID: eventID, episodeID: episodeID,
                    isTest: false, callback: callback)
            return false
        }
        return await receive(request, source: source, attemptID: attemptID, callback: callback)
    }

    private func receive(_ request: SilentCryAlarmRequest, source: SilentCryAlarmRequest.Source,
                         attemptID: UUID, callback: SilentCryAlarmRequest.Callback) async -> Bool {
        let start = callback.start
        var stage = SilentCryAlarmRequest.Stage.preflight
        func record(_ phase: String, reason: SilentCryAlarmRequest.Rejection? = nil, error: (any Error)? = nil) {
            attempt(phase, stage: stage, source: source, attemptID: attemptID, eventID: request.eventID,
                episodeID: request.episodeID, start: start, reason: reason,
                requestAgeMS: Int(Date().timeIntervalSince(request.createdAt) * 1000), error: error)
        }
        // One journal entry per attempt, whatever the exit.
        var outcome = AlarmAttempt.Outcome.failed, outcomeReason: String?, alarmAt: Date?, journaled = true
        defer { if journaled { journal(outcome, reason: outcomeReason, eventID: request.eventID, episodeID: request.episodeID,
                        isTest: request.isTest, callback: callback, pushCreatedAt: request.createdAt, alarmAt: alarmAt) } }
        func reject(_ reason: SilentCryAlarmRequest.Rejection) -> Bool {
            record("rejected", reason: reason); outcome = .rejected; outcomeReason = reason.rawValue; return false
        }
        trace("received", request.eventID)
        guard appWakeEnabled else { return reject(.methodDisabled) }
        guard enabled else { return reject(.disabled) }
        guard !receiving else {
            // iOS can hand one push to both the foreground and the background callback.
            // The attempt already running speaks for it; journaling this one would
            // count a failure that did not happen.
            if receivingEventID == request.eventID { journaled = false }
            return reject(.busy)
        }
        receiving = true; receivingEventID = request.eventID
        defer { receiving = false; receivingEventID = nil }
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
            try Task.checkCancellation()
            guard AlarmManager.shared.authorizationState == .authorized else {
                return reject(.unauthorized)
            }
            guard Bundle.main.url(forResource: "AlarmTestSilence", withExtension: "caf") != nil else {
                return reject(.missingAsset)
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
                trace("ack_pending", request.eventID); return reject(.acknowledgementPending)
            }
            let snapshot: SilentCryAlarmStatusSnapshot<ParentStatus>?
            do {
                let statusCheckedAt = Date()
                snapshot = try await SilentCryAlarmStatusSnapshot<ParentStatus>.load(budget: budget) {
                    stage = .status; record("started")
                    let server = try await backend.status()
                    // Even a delayed response can supply a newer negative fact.
                    // Preserve it before the snapshot loader rejects old timing.
                    remember(server, checkedAt: statusCheckedAt)
                    record("completed")
                    return server
                }
            } catch {
                // Our deadline limits network work, never an otherwise eligible
                // alarm. A resumed callback can still use a recent real push.
                try Task.checkCancellation()
                let unavailable: Bool
                if case BackendError.response(let status, _) = error {
                    unavailable = SilentCryAlarmRequest.allowsStatusFallback(forHTTPStatus: status)
                } else { unavailable = SilentCryAlarmRequest.allowsStatusFallback(for: error) }
                guard unavailable else { throw error }
                if let reason = fallbackRejection() { return reject(reason) }
                record("fallback", error: error)
                snapshot = nil
            }
            if let snapshot {
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
            if let reason { trace("ignored", request.eventID); return reject(reason) }
            stage = .alarmLookup
            let existing = try AlarmManager.shared.alarms
            // One alarm per episode. Reminder notifications never restart an active alarm.
            if existing.contains(where: { $0.id == request.episodeID }) {
                trace("duplicate", request.eventID); record("duplicate"); outcome = .duplicate
                queueSchedulingReceipt(request)
                return false
            }
            // Persist acknowledgement metadata before scheduling so an immediate Stop
            // can resolve the event even when the app has to relaunch for the intent.
            var saved = records.filter { $0.episodeID != request.episodeID }
            let fireAt = Date().addingTimeInterval(SilentAlarmScheduling.delay)
            saved.append(Record(episodeID: request.episodeID, eventID: request.eventID, snoozeDuration: snoozeDuration, scheduledAt: Date(),
                                isTest: request.isTest ? true : nil, alarmAt: fireAt))
            records = Array(saved.suffix(64))
            let configuration = SilentAlarmScheduling.configuration(for: request, at: fireAt)
            stage = .schedule; record("started")
            // Local processing can also stall. Discard expired validation and
            // fall back to the push, still honoring all newer negative evidence.
            try Task.checkCancellation()
            if let reason = fallbackRejection() {
                return reject(reason)
            }
            if let snapshot, !snapshot.isFresh() {
                record("fallback", reason: .staleStatus)
            }
            _ = try await AlarmManager.shared.schedule(id: request.episodeID, configuration: configuration)
            record("completed")
            // A user can disable/snooze while the system scheduling call is suspended.
            if generation != revision || !enabled {
                stage = .cancel; record("started", reason: .settingChanged)
                do {
                    try AlarmManager.shared.cancel(id: request.episodeID)
                    record("cancelled", reason: .settingChanged)
                    (log ?? DiagnosticLog()).silentCryAlarmCancelled(episodeID: request.episodeID, eventID: request.eventID, reason: "setting_changed")
                } catch { record("failed", reason: .settingChanged, error: error) }
                outcome = .rejected; outcomeReason = SilentCryAlarmRequest.Rejection.settingChanged.rawValue
                return false
            }
            status = request.isTest ? "Test alarm scheduled." : "Silent alert alarm scheduled. Existing notifications continue."
            trace("scheduled", request.eventID); record("scheduled"); outcome = .scheduled; alarmAt = fireAt
            queueSchedulingReceipt(request)
            return true
        } catch {
            status = "Silent alarm unavailable; existing notifications continue."
            trace("failed", request.eventID); record("failed", error: error)
            outcomeReason = String(describing: type(of: error)); return false
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

    func snooze(episodeID: UUID, eventID: UUID? = nil, isTest: Bool? = nil) async {
        mergeExtensionAttempts()
        let record = records.first(where: { $0.episodeID == episodeID })
        (log ?? DiagnosticLog()).silentCryAlarmStop(episodeID: episodeID, eventID: record?.eventID, isTest: record.map { $0.isTest == true },
            sinceAlarmMS: record.flatMap(Self.sinceAlarmMS), appActive: UIApplication.shared.applicationState == .active)
        guard let target = eventID ?? record?.eventID else { return }
        if (isTest ?? record?.isTest) == true {
            // Stopping a test alarm acknowledges only that test; it never snoozes real alerts.
            trace("acknowledged", target)
            do { try await client().acknowledge(target, actedAt: Date()) } catch { trace("failed", target, operation: "test_acknowledge", error: error) }
            return
        }
        snoozeLocally(eventID: target, duration: record?.snoozeDuration ?? snoozeDuration)
        do { try await flushAcknowledgements(using: client()) } catch { trace("ack_pending", target) }
    }

    func snoozeLocally(eventID: UUID, duration: Double, actedAt: Date? = nil) {
        mergeExtensionAttempts()
        defer { publishSnapshot() }
        guard enabled || records.contains(where: { $0.eventID == eventID }) else { return }
        guard SilentCryAlarmSnooze(defaults: defaults).apply(eventID: eventID, duration: duration, now: actedAt ?? Date()) else { return }
        revision += 1
        cancelAll(reason: "snoozed")
        status = "Alerts snoozed. Acknowledgement syncs when connected."
        trace("snoozed", eventID)
    }

    func acknowledgeKnownEvent(_ eventID: UUID) {
        mergeExtensionAttempts()
        guard let record = records.first(where: { $0.eventID == eventID }) else { return }
        guard record.isTest != true else { cancelTestAlarms(); return }
        snoozeLocally(eventID: eventID, duration: record.snoozeDuration)
    }

    func flushAcknowledgements(using client: any BackendServing, limit: Int = 2) async {
        guard !flushing else { return }; flushing = true; defer { flushing = false; publishSnapshot() }
        // Keep acknowledgement work bounded within the background execution budget.
        for text in (defaults.stringArray(forKey: pendingKey) ?? []).prefix(max(0, min(2, limit))) {
            guard let id = UUID(uuidString: text) else { continue }
            do { try await client.acknowledge(id, actedAt: SilentCryAlarmSnooze(defaults: defaults).actedAt(id)) }
            catch BackendError.response(404, _) { /* Old/deleted pairing: discard only this old action. */ }
            catch { trace("ack_pending", id, operation: "acknowledge", error: error); return }
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
            setting("local_mute_cleared", source: .serverResume)
            if enabled { status = "Alerts resumed. Existing notifications continue." }
        }
        guard !records.isEmpty else { return }
        let muted = (server.alertsMutedUntil ?? .distantPast) > Date()
        let obsolete = records.filter { record in
            let isTest = record.isTest == true
            return record.scheduledAt <= checkedAt && (!server.paired || (muted && !isTest) ||
                server.notificationRelevance.map { !$0.contains(eventID: record.eventID, episodeID: record.episodeID, isTest: isTest) } == true)
        }
        do {
            let active = Set(try AlarmManager.shared.alarms.map(\.id))
            for record in obsolete where active.contains(record.episodeID) {
                try AlarmManager.shared.cancel(id: record.episodeID)
                let reason = !server.paired ? "unpaired" : muted && record.isTest != true ? "server_muted" : "irrelevant"
                (log ?? DiagnosticLog()).silentCryAlarmCancelled(episodeID: record.episodeID, eventID: record.eventID, reason: reason)
            }
        } catch { trace("failed", operation: "reconcile_cancel", error: error) }
    }

    func cancelEpisodes(_ ids: Set<UUID>) {
        mergeExtensionAttempts()
        cancel(ids, reason: "irrelevant", operation: "stop_alerts")
    }

    /// Stopping or acknowledging a test ends its alarm without touching real ones.
    func cancelTestAlarms() {
        mergeExtensionAttempts()
        let ids = Set(records.filter { $0.isTest == true }.map(\.episodeID))
        guard !ids.isEmpty else { return }
        cancel(ids, reason: "test_stopped", operation: "cancel_tests")
    }

    private func cancelAll(reason: String) {
        mergeExtensionAttempts()
        pendingReceipts = []
        guard !records.isEmpty else { return }
        cancel(Set(records.map(\.episodeID)), reason: reason, operation: "cancel_all")
    }

    private func cancel(_ ids: Set<UUID>, reason: String, operation: String) {
        do {
            for alarm in try AlarmManager.shared.alarms where ids.contains(alarm.id) {
                try AlarmManager.shared.cancel(id: alarm.id)
                (log ?? DiagnosticLog()).silentCryAlarmCancelled(episodeID: alarm.id,
                    eventID: records.first(where: { $0.episodeID == alarm.id })?.eventID, reason: reason)
            }
        } catch { trace("failed", operation: operation, error: error) }
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

    private func trace(_ phase: String, _ eventID: UUID? = nil, operation: String? = nil, error: (any Error)? = nil) {
        (log ?? DiagnosticLog()).silentCryAlarm(phase: phase, eventID: eventID,
            appActive: UIApplication.shared.applicationState == .active, operation: operation, error: error)
    }

    private func setting(_ change: String, source: ChangeSource, appWake: Bool? = nil, extensionMethod: Bool? = nil, reason: String? = nil) {
        (log ?? DiagnosticLog()).silentCryAlarmSetting(change: change, source: source.rawValue, appWake: appWake, extensionMethod: extensionMethod, reason: reason)
    }

    nonisolated private static func sinceAlarmMS(_ record: Record) -> Int? {
        record.alarmAt.map { Int(Date().timeIntervalSince($0) * 1000) }
    }

    // MARK: Alarm state

    private var stateObserver: Task<Void, Never>?
    private var observedStates: [UUID: String] = [:]

    /// Logs AlarmKit state changes for alarms this app owns. Updates arrive only
    /// while the app runs, so an alarm that alerts while it is suspended is seen
    /// on the next launch or not at all; the system log (mobiletimerd) has the rest.
    func observeAlarmStates() {
        guard stateObserver == nil else { return }
        stateObserver = Task { [weak self] in
            for await alarms in AlarmManager.shared.alarmUpdates {
                guard let self, !Task.isCancelled else { return }
                self.logStates(alarms)
            }
        }
    }

    private func logStates(_ alarms: [Alarm]) {
        mergeExtensionAttempts()
        let owned = Dictionary(records.map { ($0.episodeID, $0) }, uniquingKeysWith: { $1 })
        var current: [UUID: String] = [:]
        for alarm in alarms where owned[alarm.id] != nil {
            current[alarm.id] = switch alarm.state {
            case .scheduled: "scheduled"
            case .countdown: "countdown"
            case .paused: "paused"
            case .alerting: "alerting"
            @unknown default: "unknown"
            }
        }
        let appActive = UIApplication.shared.applicationState == .active
        for (id, state) in current where observedStates[id] != state {
            (log ?? DiagnosticLog()).silentCryAlarmState(episodeID: id, eventID: owned[id]?.eventID, state: state,
                sinceAlarmMS: owned[id].flatMap(Self.sinceAlarmMS), appActive: appActive)
        }
        for id in observedStates.keys where current[id] == nil {
            (log ?? DiagnosticLog()).silentCryAlarmState(episodeID: id, eventID: owned[id]?.eventID, state: "removed",
                sinceAlarmMS: owned[id].flatMap(Self.sinceAlarmMS), appActive: appActive)
        }
        observedStates = current
    }

    // MARK: Shared state for the notification extension

    private var lastSnapshot: AlarmSnapshot?

    /// The only writer of the snapshot. The extension applies the same push-only
    /// rules the app uses when it cannot reach the service.
    func publishSnapshot() {
        var snapshot = AlarmSnapshot(enabled: enabled && defaults.string(forKey: "role") == "parent",
            extensionEnabled: extensionEnabled,
            acknowledgementPending: !(defaults.stringArray(forKey: pendingKey) ?? []).isEmpty,
            localMutedUntil: defaults.object(forKey: "silentCryAlarmMutedUntil") as? Date,
            stoppedBefore: defaults.object(forKey: "silentCryAlarmStoppedBefore") as? Date,
            evidence: serverEvidence, snoozeDuration: snoozeDuration, publishedAt: .distantPast,
            handledExtensionStopKeys: defaults.stringArray(forKey: "alarmExtensionConsumedStopKeys") ?? [])
        // Polling refreshes only the evidence timestamp; rewrite when anything else changes.
        if let last = lastSnapshot {
            var comparable = snapshot; comparable.evidence = last.evidence
            let sameEvidence = switch (snapshot.evidence, last.evidence) {
            case (nil, nil): true
            case let (new?, old?): new.hasSameState(as: old)
            default: false
            }
            if sameEvidence && comparable == last { return }
        }
        let unstamped = snapshot
        snapshot.publishedAt = Date()
        guard let directory = AlarmShared.directory else {
            (log ?? DiagnosticLog()).record("alarm_snapshot_unavailable"); return
        }
        AlarmShared.writeLockProbe(to: directory)
        // Remember only a saved state, so a failed write is retried on the next change or sync.
        do {
            try snapshot.save(to: directory); lastSnapshot = unstamped
        } catch { (log ?? DiagnosticLog()).record("alarm_snapshot_failed", error: error) }
    }

    /// Adopt alarms the extension scheduled, so Stop, acknowledgement and cleanup
    /// find them, and apply any Stop iOS ran in the extension.
    private func mergeExtensionAttempts() {
        // Entries are tracked by key for a window behind the newest one, so an entry
        // written after a later-finishing one is still merged, exactly once.
        let floorKey = "alarmExtensionMergedThrough", keysKey = "alarmExtensionMergedKeys"
        let floor = defaults.object(forKey: floorKey) as? Date ?? .distantPast
        let entries: [AlarmAttempt]
        do { entries = try AlarmJournal.forMethod(.extension)?.entries() ?? [] }
        catch { (log ?? DiagnosticLog()).record("alarm_journal_failed", error: error); return }
        var merged = Set(defaults.stringArray(forKey: keysKey) ?? [])
        let new = entries.filter { $0.finishedAt > floor && !merged.contains($0.key) }
        guard !new.isEmpty else { return }
        // Saved before applying, so a nested call finds nothing new.
        merged.formUnion(new.map(\.key))
        let window = (entries.map(\.finishedAt).max() ?? floor).addingTimeInterval(-600)
        let newFloor = max(floor, window)
        defaults.set(newFloor, forKey: floorKey)
        defaults.set(entries.filter { $0.finishedAt > newFloor && merged.contains($0.key) }.map(\.key), forKey: keysKey)
        var saved = records, stopped: [AlarmAttempt] = []
        for attempt in new {
            (log ?? DiagnosticLog()).alarmAttempt(attempt)
            guard attempt.episodeID != nil else { continue }
            saved = Record.merging(attempt, into: saved, snoozeDuration: snoozeDuration)
            if attempt.outcome == .stopped { stopped.append(attempt) }
        }
        records = Array(saved.suffix(64))
        // Keep consumed Stop identities separately from the moving merge window.
        // Otherwise an old journal Stop could reapply its mute after early Resume.
        let consumed = defaults.stringArray(forKey: "alarmExtensionConsumedStopKeys") ?? []
        defaults.set(Array((consumed + stopped.map(\.key)).suffix(AlarmJournal.capacity)), forKey: "alarmExtensionConsumedStopKeys")
        queueUpload(new)
        for attempt in stopped {
            guard let episodeID = attempt.episodeID else { continue }
            let record = records.first(where: { $0.episodeID == episodeID })
            (log ?? DiagnosticLog()).silentCryAlarmStop(episodeID: episodeID, eventID: record?.eventID, isTest: record.map { $0.isTest == true },
                sinceAlarmMS: record.flatMap(Self.sinceAlarmMS), appActive: UIApplication.shared.applicationState == .active)
            if !attempt.isTest, let target = attempt.eventID ?? record?.eventID {
                snoozeLocally(eventID: target, duration: record?.snoozeDuration ?? snoozeDuration, actedAt: attempt.startedAt)
            } else if attempt.isTest, let target = attempt.eventID ?? record?.eventID {
                Task { try? await client().acknowledge(target, actedAt: attempt.startedAt) }
            }
        }
    }

    // MARK: Attempt reports to the service

    private let uploadKey = "alarmAttemptsPendingUpload"
    private var uploadingAttempts = false

    private func queueUpload(_ attempts: [AlarmAttempt]) {
        guard !attempts.isEmpty else { return }
        let pending = (defaults.data(forKey: uploadKey).flatMap { try? JSONDecoder().decode([AlarmAttempt].self, from: $0) } ?? []) + attempts
        defaults.set(try? JSONEncoder().encode(Array(pending.suffix(40))), forKey: uploadKey)
    }

    /// Foreground only, so it never spends a background wake. Reports are
    /// diagnostics: a rejected batch is dropped, never retried forever.
    private func uploadAttempts(using client: any BackendServing) async {
        guard !uploadingAttempts, UIApplication.shared.applicationState == .active,
              let pending = defaults.data(forKey: uploadKey).flatMap({ try? JSONDecoder().decode([AlarmAttempt].self, from: $0) }),
              !pending.isEmpty else { return }
        uploadingAttempts = true; defer { uploadingAttempts = false }
        let batch = Array(pending.prefix(20))
        do { try await client.reportAlarmAttempts(batch) }
        catch BackendError.response(let status, _) where (400..<500).contains(status) && status != 429 {
            (log ?? DiagnosticLog()).record("alarm_attempts_upload_discarded", code: status)
        } catch { return }
        let keys = Set(batch.map(\.key))
        let remaining = (defaults.data(forKey: uploadKey).flatMap { try? JSONDecoder().decode([AlarmAttempt].self, from: $0) } ?? [])
            .filter { !keys.contains($0.key) }
        defaults.set(try? JSONEncoder().encode(remaining), forKey: uploadKey)
    }

    private func journal(_ outcome: AlarmAttempt.Outcome, reason: String?, eventID: UUID?, episodeID: UUID?, isTest: Bool,
                         callback: SilentCryAlarmRequest.Callback, pushCreatedAt: Date? = nil, alarmAt: Date? = nil) {
        let attempt = AlarmAttempt(method: .app, outcome: outcome, reason: reason, eventID: eventID, episodeID: episodeID,
            isTest: isTest, flags: callback.flags, pushCreatedAt: pushCreatedAt, startedAt: callback.receivedAt,
            finishedAt: Date(), alarmAt: alarmAt, conditions: Self.conditions())
        do { try AlarmJournal.forMethod(.app)?.append(attempt) }
        catch { (log ?? DiagnosticLog()).record("alarm_journal_failed", error: error) }
        (log ?? DiagnosticLog()).alarmAttempt(attempt)
        queueUpload([attempt])
    }

    static func conditions() -> AlarmAttempt.Conditions {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        return .init(charging: device.batteryState == .unknown ? nil : device.batteryState == .charging || device.batteryState == .full,
                     batteryLevel: device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil,
                     lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                     appActive: UIApplication.shared.applicationState == .active,
                     protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable)
    }
}
