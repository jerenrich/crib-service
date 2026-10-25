import AlarmKit
import AppIntents
import Observation
import UIKit

@available(iOS 26.0, *)
@MainActor @Observable final class SilentCryAlarmService {
    static let shared = SilentCryAlarmService()
    private(set) var enabled = UserDefaults.standard.bool(forKey: "silentWatchAlarmsEnabled")
    private(set) var busy = false
    private(set) var status = "Off. Existing notifications remain enabled."
    weak var log: DiagnosticLog?
    private let defaults = UserDefaults.standard
    private let recordsKey = "silentCryAlarmRecords"
    private let pendingKey = "silentCryAlarmPendingAcknowledgements"
    private var receiving = false
    private var flushing = false
    private var revision = 0
    private struct Metadata: AlarmMetadata {}
    private struct Record: Codable { let episodeID: UUID; let eventID: UUID; let snoozeDuration: Double; let scheduledAt: Date }
    private var records: [Record] {
        get { (defaults.data(forKey: recordsKey)).flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: recordsKey) }
    }
    private init() {
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
        busy = true; defer { busy = false }
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
        await flushAcknowledgements(using: client)
        if defaults.bool(forKey: "silentWatchAlarmsSettingDirty") {
            do { try await client.silentWatchAlarms(enabled); defaults.set(false, forKey: "silentWatchAlarmsSettingDirty") }
            catch { trace("failed") }
        }
        // Never turn the feature on as a side effect of a server read.
        let settingChangedAt = defaults.object(forKey: "silentWatchAlarmsChangedAt") as? Date ?? .distantPast
        if checkedAt >= settingChangedAt, !server.paired || server.silentWatchAlarmsEnabled == false {
            if enabled { disableLocally() }
        }
        reconcile(server, checkedAt: checkedAt)
    }

    func receive(_ request: SilentCryAlarmRequest) async -> Bool {
        trace("received", request.eventID)
        guard enabled, !receiving else { return false }
        receiving = true; defer { receiving = false }
        let generation = revision
        do {
            let backend = try client()
            await flushAcknowledgements(using: backend)
            guard (defaults.stringArray(forKey: pendingKey) ?? []).isEmpty else { trace("ack_pending", request.eventID); return false }
            let checkedAt = Date()
            let server = try await backend.status()
            reconcile(server, checkedAt: checkedAt)
            guard generation == revision,
                  request.isEligible(enabled: enabled, serverEnabled: server.silentWatchAlarmsEnabled == true,
                    paired: server.paired, relevance: server.notificationRelevance,
                    mutedUntil: server.alertsMutedUntil, localMutedUntil: defaults.object(forKey: "silentCryAlarmMutedUntil") as? Date,
                    stoppedBefore: defaults.object(forKey: "silentCryAlarmStoppedBefore") as? Date, now: Date()),
                  AlarmManager.shared.authorizationState == .authorized,
                  Bundle.main.url(forResource: "AlarmTestSilence", withExtension: "caf") != nil else {
                trace("ignored", request.eventID); return false
            }
            let existing = try AlarmManager.shared.alarms
            // One alarm per episode. Reminder notifications never restart an active alarm.
            if existing.contains(where: { $0.id == request.episodeID }) { trace("duplicate", request.eventID); return false }
            let attributes = AlarmAttributes<Metadata>(presentation: AlarmPresentation(alert: .init(
                title: "Check on baby",
                stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle")
            )), metadata: Metadata(), tintColor: .mint)
            // Persist acknowledgement metadata before scheduling so an immediate Stop
            // can resolve the event even when the app has to relaunch for the intent.
            var saved = records.filter { $0.episodeID != request.episodeID }
            saved.append(Record(episodeID: request.episodeID, eventID: request.eventID, snoozeDuration: server.configuration.snoozeDuration, scheduledAt: Date()))
            records = Array(saved.suffix(64))
            let configuration = AlarmManager.AlarmConfiguration<Metadata>.alarm(
                schedule: .fixed(Date().addingTimeInterval(3)), attributes: attributes,
                stopIntent: SnoozeSilentCryAlarmIntent(episodeID: request.episodeID.uuidString),
                sound: .named("AlarmTestSilence.caf"))
            _ = try await AlarmManager.shared.schedule(id: request.episodeID, configuration: configuration)
            // A user can disable/snooze while the system scheduling call is suspended.
            if generation != revision || !enabled { try? AlarmManager.shared.cancel(id: request.episodeID); return false }
            status = "Silent crying alarm scheduled. Existing notifications continue."
            trace("scheduled", request.eventID)
            return true
        } catch { status = "Silent alarm unavailable; existing notifications continue."; trace("failed", request.eventID); return false }
    }

    func snooze(episodeID: UUID) async {
        guard let record = records.first(where: { $0.episodeID == episodeID }) else { return }
        snoozeLocally(eventID: record.eventID, duration: record.snoozeDuration)
        do { try await flushAcknowledgements(using: client()) } catch { trace("ack_pending", record.eventID) }
    }

    func snoozeLocally(eventID: UUID, duration: Double) {
        guard enabled || records.contains(where: { $0.eventID == eventID }) else { return }
        revision += 1
        defaults.set(Date(), forKey: "silentCryAlarmStoppedBefore")
        defaults.set(Date().addingTimeInterval(duration), forKey: "silentCryAlarmMutedUntil")
        var pending = defaults.stringArray(forKey: pendingKey) ?? []
        if !pending.contains(eventID.uuidString) { pending.append(eventID.uuidString) }
        defaults.set(Array(pending.suffix(100)), forKey: pendingKey)
        cancelAll()
        status = "Crying alarms snoozed. Acknowledgement syncs when connected."
        trace("snoozed", eventID)
    }

    func acknowledgeKnownEvent(_ eventID: UUID) {
        guard let record = records.first(where: { $0.eventID == eventID }) else { return }
        snoozeLocally(eventID: eventID, duration: record.snoozeDuration)
    }

    private func flushAcknowledgements(using client: any BackendServing) async {
        guard !flushing else { return }; flushing = true; defer { flushing = false }
        // Keep acknowledgement work bounded within the background execution budget.
        for text in (defaults.stringArray(forKey: pendingKey) ?? []).prefix(2) {
            guard let id = UUID(uuidString: text) else { continue }
            do { try await client.acknowledge(id) }
            catch BackendError.response(404, _) { /* Old/deleted pairing: discard only this old action. */ }
            catch { trace("ack_pending", id); return }
            var pending = defaults.stringArray(forKey: pendingKey) ?? []
            pending.removeAll { $0 == text }; defaults.set(pending, forKey: pendingKey)
            trace("acknowledged", id)
        }
    }

    private func reconcile(_ server: ParentStatus, checkedAt: Date) {
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
        guard !records.isEmpty else { return }
        do {
            let ids = Set(records.map(\.episodeID))
            for alarm in try AlarmManager.shared.alarms where ids.contains(alarm.id) { try AlarmManager.shared.cancel(id: alarm.id) }
        } catch { trace("failed") }
    }

    private func trace(_ phase: String, _ eventID: UUID? = nil) {
        (log ?? DiagnosticLog()).silentCryAlarm(phase: phase, eventID: eventID,
            appActive: UIApplication.shared.applicationState == .active)
    }
}

@available(iOS 26.0, *)
struct SnoozeSilentCryAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Snooze crying alerts" }
    @Parameter(title: "Episode") var episodeID: String
    init() {}
    init(episodeID: String) { self.episodeID = episodeID }
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: episodeID) { await SilentCryAlarmService.shared.snooze(episodeID: id) }
        return .result()
    }
}
