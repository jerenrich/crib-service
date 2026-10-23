import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = false
    @State private var calibration = false
    @State private var readiness = false
    @State private var removal = Removal.unpair
    @State private var confirmRemoval = false
    private enum Removal { case unpair, delete }
    private let alertDurations: [Double] = [5, 30, 60, 120, 180, 300, 600]

    var body: some View {
        NavigationStack {
            Form {
                Section("Settings status") { Text(model.settingsSyncStatus) }
                Section {
                    Picker("Alert after crying for", selection: setting(\.alertDuration)) {
                        ForEach(alertDurations, id: \.self) { value in
                            Text(alertDurationText(value)).tag(value)
                        }
                        // Keep previously saved durations visible until a preset is chosen.
                        if !alertDurations.contains(model.configuration.alertDuration) {
                            Text(alertDurationText(model.configuration.alertDuration)).tag(model.configuration.alertDuration)
                        }
                    }
                    .accessibilityIdentifier("alertDurationPicker")
                } header: {
                    Text("Alert timing")
                } footer: {
                    Text("The timer starts after crying-like sound is confirmed. Sound is checked for a few seconds before the timer starts.")
                }
                Section {
                    Picker("Reset timer after quiet", selection: setting(\.quietResetDuration)) {
                        ForEach([10.0, 20, 30, 60], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                    }
                } header: {
                    Text("When crying stops")
                } footer: {
                    Text("After \(Int(model.configuration.quietResetDuration)) seconds below the sound threshold, the crying timer resets. Shorter pauses keep the timer running.")
                }
                Section {
                    Picker("Sound threshold", selection: setting(\.absoluteThreshold)) {
                        ForEach(MonitoringConfiguration.soundThresholds, id: \.self) { value in
                            Text("\(Int(value)) dBFS").tag(value)
                        }
                        if !MonitoringConfiguration.soundThresholds.contains(model.configuration.absoluteThreshold) {
                            Text("\(model.configuration.absoluteThreshold.formatted()) dBFS").tag(model.configuration.absoluteThreshold)
                        }
                    }
                    .accessibilityIdentifier("soundThresholdPicker")
                } header: {
                    Text("Sound detection")
                } footer: {
                    Text("A fixed microphone level. −60 dBFS detects quieter sounds; −10 dBFS requires louder sounds. The threshold stays fixed as room noise changes. dBFS is a microphone reading, not a calibrated room loudness measurement. Other loud noises can also trigger detection.")
                }
                if model.role == .listener {
                    Section { Button("Check room sound") { calibration = true } }
                }
                Section {
                    Picker("Repeat alerts", selection: setting(\.repeatInterval)) {
                        Text("Off").tag(Optional<Double>.none)
                        Text("Every 2 minutes").tag(Optional(120.0))
                        Text("Every 5 minutes").tag(Optional(300.0))
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    Text("Send another alert at this interval if the same crying episode continues after the first alert. Changes save automatically. Changes made on the Parent iPhone reach the Listener on its next update, normally within 15 seconds.")
                }
                Section("This iPhone") {
                    Picker("Mode", selection: Binding(get: { model.role ?? .listener }, set: { model.selectRole($0) })) { Text("Listener").tag(DeviceRole.listener); Text("Parent").tag(DeviceRole.parent) }
                    Button(model.paired ? "Pairing details" : "Pair iPhones") { pairing = true }
                    if model.role == .parent { Button("Enable notifications") { Task { await model.notifications.register() } } }
                }
                if model.role == .parent {
                    Section {
                        Button("Ready for tonight?") { readiness = true }
                        Toggle("Connection-loss alerts", isOn: Binding(get: { model.parentStatus?.connectionAlertsEnabled == true }, set: { value in Task { await model.setConnectionAlerts(value) } }))
                            .disabled(model.changingConnectionAlerts || model.parentStatus == nil || !model.paired)
                    } header: { Text("Monitoring connection") } footer: {
                        Text("When enabled, the server sends one notice after at least 3 minutes without an active Listener update, plus a recovery notice. It also reports a Listener that stops monitoring. The minute check can add up to a minute. Delivery requires the receiving device to have internet and allow notifications.")
                    }
                }
                Section {
                    Button("Unpair or replace a phone", role: .destructive) { removal = .unpair; confirmRemoval = true }.disabled(model.managingDevice)
                    Button("Delete device & shared history", role: .destructive) { removal = .delete; confirmRemoval = true }.disabled(model.managingDevice)
                } header: { Text("Device management") } footer: {
                    Text("Unpairing stops this iPhone's monitoring and removes the pair's server episode history, alerts, and connection history. Both phones can then pair with a replacement. Deleting also removes this device's server registration and resets its local history. The other phone's local data and restricted server diagnostic records are not erased remotely.")
                }
                Section("Privacy & supervision") {
                    Text("Audio never leaves the Listener iPhone. No recordings, audio streams, or audio features are uploaded.")
                    Text("Sound detection only. Cannot detect breathing problems, movement problems, silent distress, medical emergencies, or unsafe sleep conditions. Adult supervision is required; this is not a medical monitor.").font(.footnote).foregroundStyle(.secondary)
                }
                Section { NavigationLink("Diagnostics & simulation") { DebugView() } }
            }.navigationTitle("Settings")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .sheet(isPresented: $pairing) { PairingView() }
                .sheet(isPresented: $calibration) { CalibrationView() }
                .sheet(isPresented: $readiness) { ReadinessView() }
                .alert(removal == .delete ? "Delete device and shared history?" : "Unpair these phones?", isPresented: $confirmRemoval) {
                    Button(removal == .delete ? "Delete device & shared history" : "Unpair and clear shared history", role: .destructive) {
                        let deleteDevice = removal == .delete
                        Task { await model.removePairing(deleteDevice: deleteDevice); if model.role == nil { dismiss() } }
                    }
                    Button("Cancel", role: .cancel) { confirmRemoval = false }
                } message: { Text("Queued notifications are cancelled. A notification already accepted by Apple may still arrive. Monitoring on this iPhone will stop.") }
                .disabled(model.managingDevice)
        }.tint(Palette.mint)
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<MonitoringConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { model.configuration[keyPath: keyPath] },
            set: { value in
                var config = model.configuration
                config[keyPath: keyPath] = value
                model.saveSettings(config)
            }
        )
    }

    private func alertDurationText(_ seconds: Double) -> String {
        if seconds.truncatingRemainder(dividingBy: 60) == 0 {
            let minutes = Int(seconds / 60)
            return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
        }
        return "\(seconds.formatted()) seconds"
    }
}
