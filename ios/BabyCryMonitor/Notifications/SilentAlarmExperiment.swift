import AlarmKit
import Observation
import UIKit

/// Explicitly armed, test-only background delivery experiment. Never handles real cries.
@available(iOS 26.0, *)
@MainActor @Observable final class SilentAlarmExperiment {
    static let shared = SilentAlarmExperiment()
    private(set) var status: String
    private(set) var busy = false
    weak var log: DiagnosticLog?
    private let defaults = UserDefaults.standard
    private let deadlineKey = "silentAlarmExperimentUntil"
    private let idsKey = "silentAlarmExperimentScheduledIDs"
    private let statusKey = "silentAlarmExperimentStatus"
    private var inFlight: Set<UUID> = []
    private struct Metadata: AlarmMetadata {}

    private init() { status = UserDefaults.standard.string(forKey: "silentAlarmExperimentStatus") ?? "Not armed. No remote test alarm scheduled." }
    var armedUntil: Date? { defaults.object(forKey: deadlineKey) as? Date }
    var armed: Bool { armedUntil.map { $0 > Date() } ?? false }

    func arm() async {
        guard !busy, defaults.string(forKey: "role") == "parent" else { return }
        busy = true
        defer { busy = false }
        do {
            guard try await AlarmManager.shared.requestAuthorization() == .authorized else {
                save("Alarm permission required. Experiment not armed."); return
            }
            guard Bundle.main.url(forResource: "AlarmTestSilence", withExtension: "caf") != nil else {
                save("Silent tone missing. Experiment not armed."); return
            }
            defaults.set(Date().addingTimeInterval(600), forKey: deadlineKey)
            save("Armed for 10 minutes. Lock this iPhone, then send the silent alarm test from the Listener.")
            trace("armed")
        } catch { save("Could not arm: \(error.localizedDescription)"); trace("failed") }
    }

    func disarm() {
        defaults.removeObject(forKey: deadlineKey)
        save("Disarmed. Any alarm already scheduled can be stopped with Cancel remote test alarms.")
        trace("disarmed")
    }

    func receive(_ request: SilentAlarmTestRequest) async -> Bool {
        trace("received", id: request.eventID)
        guard defaults.string(forKey: "role") == "parent", armed,
              Date().timeIntervalSince(request.createdAt) <= 60 else { trace("ignored", id: request.eventID); return false }
        var ids = defaults.stringArray(forKey: idsKey) ?? []
        guard !ids.contains(request.eventID.uuidString), !inFlight.contains(request.eventID) else { trace("duplicate", id: request.eventID); return false }
        inFlight.insert(request.eventID)
        defer { inFlight.remove(request.eventID) }
        do {
            guard AlarmManager.shared.authorizationState == .authorized,
                  Bundle.main.url(forResource: "AlarmTestSilence", withExtension: "caf") != nil else {
                save("Remote test received, but alarm permission or silent tone is unavailable.")
                trace("failed", id: request.eventID); return false
            }
            // Only one remote test alarm at a time; keep earlier IDs for replay protection.
            for alarm in try AlarmManager.shared.alarms where ids.contains(alarm.id.uuidString) {
                try AlarmManager.shared.cancel(id: alarm.id)
            }
            let attributes = AlarmAttributes<Metadata>(presentation: AlarmPresentation(alert: .init(
                title: "Listener → Watch silent alarm test",
                stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle")
            )), metadata: Metadata(), tintColor: .mint)
            let configuration = AlarmManager.AlarmConfiguration<Metadata>.alarm(
                schedule: .fixed(Date().addingTimeInterval(3)), attributes: attributes,
                sound: .named("AlarmTestSilence.caf"))
            _ = try await AlarmManager.shared.schedule(id: request.eventID, configuration: configuration)
            ids.append(request.eventID.uuidString)
            defaults.set(Array(ids.suffix(50)), forKey: idsKey)
            save("Listener test received; silent alarm scheduled. Check wrist taps and both speakers.")
            trace("scheduled", id: request.eventID)
            return true
        } catch {
            save("Remote test received, but scheduling failed: \(error.localizedDescription)")
            trace("failed", id: request.eventID)
            return false
        }
    }

    func cancelAlarms() {
        do {
            let ids = Set(defaults.stringArray(forKey: idsKey) ?? [])
            for alarm in try AlarmManager.shared.alarms where ids.contains(alarm.id.uuidString) {
                try AlarmManager.shared.cancel(id: alarm.id)
            }
            save("Remote test alarms cancelled.")
            trace("cancelled")
        } catch { save("Could not cancel remote test alarms: \(error.localizedDescription)"); trace("failed") }
    }

    private func save(_ value: String) { status = value; defaults.set(value, forKey: statusKey) }
    private func trace(_ phase: String, id: UUID? = nil) {
        let logger = log ?? DiagnosticLog()
        logger.silentAlarmTest(phase: phase, eventID: id,
                              appActive: UIApplication.shared.applicationState == .active,
                              protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable)
    }
}
