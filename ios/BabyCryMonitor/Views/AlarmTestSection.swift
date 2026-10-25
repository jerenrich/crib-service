import AlarmKit
import SwiftUI

/// A single, manually requested system alarm, independent of monitoring and push tests.
@available(iOS 26.0, *)
@MainActor struct AlarmTestSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var alarm: Alarm?
    @State private var busy = false
    @State private var loaded = false
    @State private var denied = false
    @State private var status = "No test alarm scheduled."
    @State private var error: String?

    // A stable ID lets Settings recover the test after dismissal or app relaunch.
    private static let alarmID = UUID(uuidString: "3B1550D8-D918-4B64-9BE6-A8A28B31ACD1")!
    private struct TestMetadata: AlarmMetadata {}

    var body: some View {
        Section {
            if alarm != nil {
                Button("Cancel / stop test alarm", role: .destructive) { cancel() }
                    .accessibilityIdentifier("cancelAlarmTest")
                    .disabled(busy)
            } else {
                Button("Test alarm in 5 seconds") {
                    Task { await schedule() }
                }
                .accessibilityIdentifier("startAlarmTest")
                .disabled(busy || !loaded)
            }
            Text(status).font(.footnote)
                .accessibilityIdentifier("alarmTestStatus")
            if busy { ProgressView() }
            if denied {
                Button("Open Settings to allow alarms") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            if let error { Text(error).foregroundStyle(.orange) }
            if !loaded && !busy {
                Button("Retry alarm status") { refresh() }
            }
        } header: {
            Text("System alarm test")
        } footer: {
            Text("Schedules one alarm five seconds after permission is granted. It may sound on this iPhone, even in Silent Mode or Focus. Wear your paired Watch to check its vibration and sound; Apple controls delivery and haptics. The alarm remains scheduled if you close Settings or lock this iPhone. Stop it in the alarm alert or return here to cancel. This test does not trigger from crying.")
        }
        .task {
            let updates = AlarmManager.shared.alarmUpdates
            refresh()
            for await alarms in updates {
                guard !Task.isCancelled else { return }
                update(alarms)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
    }

    private func update(_ alarms: [Alarm]) {
        let previous = alarm
        alarm = alarms.first { $0.id == Self.alarmID }
        loaded = true
        if let alarm {
            status = alarm.state == .alerting
                ? "Test alarm is alerting. Check your iPhone and Watch."
                : "Test alarm scheduled. Check your iPhone and Watch when it fires."
        } else if previous != nil {
            status = "Test alarm ended."
        }
    }

    private func refresh() {
        let authorization = AlarmManager.shared.authorizationState
        denied = authorization == .denied
        // Listing alarms may require permission; keep the first test available so
        // its explicit tap can request authorization.
        guard authorization == .authorized else {
            alarm = nil
            loaded = true
            error = nil
            status = denied ? "Alarm permission is required. No test alarm scheduled." : "No test alarm scheduled."
            return
        }
        do {
            update(try AlarmManager.shared.alarms)
            error = nil
        } catch {
            self.error = "Could not check test alarm: \(error.localizedDescription)"
        }
    }

    private func schedule() async {
        guard !busy, loaded, alarm == nil else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let manager = AlarmManager.shared
            let authorization = try await manager.requestAuthorization()
            denied = authorization == .denied
            guard authorization == .authorized else {
                status = "Alarm permission is required. No test alarm scheduled."
                return
            }
            // Schedule after the permission prompt, so the parent gets all five seconds.
            let presentation = AlarmPresentation(alert: .init(
                title: "Crib Service test alarm",
                stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle")
            ))
            let attributes = AlarmAttributes<TestMetadata>(presentation: presentation, metadata: TestMetadata(), tintColor: .mint)
            let configuration = AlarmManager.AlarmConfiguration<TestMetadata>.alarm(
                schedule: .fixed(Date().addingTimeInterval(5)),
                attributes: attributes,
                sound: .default
            )
            alarm = try await manager.schedule(id: Self.alarmID, configuration: configuration)
            status = "Test alarm scheduled for five seconds from now."
        } catch {
            status = "Test alarm could not be scheduled."
            self.error = error.localizedDescription
        }
    }

    private func cancel() {
        guard !busy else { return }
        error = nil
        do {
            // Recheck because the system Stop button may already have removed it.
            if try AlarmManager.shared.alarms.contains(where: { $0.id == Self.alarmID }) {
                try AlarmManager.shared.cancel(id: Self.alarmID)
            }
            alarm = nil
            status = "Test alarm cancelled."
        } catch {
            self.error = "Could not cancel test alarm: \(error.localizedDescription)"
        }
    }
}
