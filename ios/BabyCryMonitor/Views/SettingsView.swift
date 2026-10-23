import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var config = MonitoringConfiguration()
    @State private var custom = "300"
    @State private var pairing = false
    private let alertDurations: [Double] = [5, 30, 60, 120, 180, 300, 600]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Alert after crying for", selection: $config.alertDuration) {
                        ForEach(alertDurations, id: \.self) { value in
                            Text(alertDurationText(value)).tag(value)
                        }
                        if !alertDurations.contains(config.alertDuration) {
                            Text("Custom · \(alertDurationText(config.alertDuration))").tag(config.alertDuration)
                        }
                    }
                    DisclosureGroup("Custom alert duration") {
                        LabeledContent("Seconds") {
                            TextField("5–3600", text: $custom)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .accessibilityLabel("Custom alert duration in seconds")
                        }
                        Button("Use this duration") {
                            if let value = Double(custom), value.isFinite, (5...3600).contains(value) {
                                config.alertDuration = value
                            } else {
                                model.error = "Enter 5–3600 seconds."
                            }
                        }
                    }
                } header: {
                    Text("Alert timing")
                } footer: {
                    Text("The timer starts after crying-like sound is confirmed. Sound is checked for a few seconds before the timer starts.")
                }
                Section {
                    Picker("Reset timer after quiet", selection: $config.quietResetDuration) {
                        ForEach([10.0, 20, 30, 60], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                    }
                } header: {
                    Text("When crying stops")
                } footer: {
                    Text("After \(Int(config.quietResetDuration)) seconds below the sound threshold, the crying timer resets. Shorter pauses keep the timer running.")
                }
                Section {
                    Picker("Sound threshold", selection: $config.sensitivity) {
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
                    Picker("Repeat alerts", selection: $config.repeatInterval) {
                        Text("Off").tag(Optional<Double>.none)
                        Text("Every 2 minutes").tag(Optional(120.0))
                        Text("Every 5 minutes").tag(Optional(300.0))
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    Text("Send another alert at this interval if the same crying episode continues after the first alert.")
                }
                Section {
                    Button("Save alert settings") { model.saveSettings(config); dismiss() }
                } footer: {
                    Text("Changes made on the Parent iPhone reach the Listener on its next update, normally within 60 seconds.")
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
                .onAppear { config = model.configuration; custom = String(Int(config.alertDuration)) }
                .sheet(isPresented: $pairing) { PairingView() }
        }.tint(Palette.mint)
    }

    private func alertDurationText(_ seconds: Double) -> String {
        if seconds.truncatingRemainder(dividingBy: 60) == 0 {
            let minutes = Int(seconds / 60)
            return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
        }
        return "\(seconds.formatted()) seconds"
    }
}
