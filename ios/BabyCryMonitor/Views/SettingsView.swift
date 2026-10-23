import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = false
    private let alertDurations: [Double] = [5, 30, 60, 120, 180, 300, 600]

    var body: some View {
        NavigationStack {
            Form {
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
                    Picker("Sound threshold", selection: setting(\.sensitivity)) {
                        ForEach(Sensitivity.allCases.reversed(), id: \.self) { sensitivity in
                            Text("Background + \(Int(sensitivity.margin)) dB").tag(sensitivity)
                        }
                    }
                } header: {
                    Text("Sound detection")
                } footer: {
                    Text("How far above background noise sound must be: 8 dB detects quieter sounds; 16 dB requires louder sounds. A minimum microphone level also applies, so this may have little effect in a quiet room. Other loud noises can also trigger detection.")
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
                Section("Privacy & supervision") {
                    Text("Audio never leaves the Listener iPhone. No recordings, audio streams, or audio features are uploaded.")
                    Text("Sound detection only. Cannot detect breathing problems, movement problems, silent distress, medical emergencies, or unsafe sleep conditions. Adult supervision is required; this is not a medical monitor.").font(.footnote).foregroundStyle(.secondary)
                }
                Section { NavigationLink("Diagnostics & simulation") { DebugView() } }
            }.navigationTitle("Settings")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .sheet(isPresented: $pairing) { PairingView() }
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
