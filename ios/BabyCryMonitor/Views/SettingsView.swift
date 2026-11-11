import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = false
    @State private var caregivers = false
    @State private var removal = Removal.unpair
    @State private var confirmRemoval = false
    private enum Removal { case unpair, delete }

    var body: some View {
        NavigationStack {
            Form {
                Section("Settings status") { Text(model.settingsSyncStatus) }
                Section {
                    SteppedSlider(title: "Observation window", stops: MonitoringConfiguration.alertDurations,
                                  value: model.configuration.alertDuration, label: alertDurationText,
                                  lowLabel: "Faster alerts", highLabel: "Fewer false alarms",
                                  identifier: "alertDurationSlider") { model.saveSetting(\.alertDuration, $0) }
                } header: {
                    Text("Alert timing")
                } footer: {
                    Text("Each detector observes the full selected window. An alert requires qualifying sound for at least 80% of that window and 80% of the latest 5 seconds, with a qualifying latest reading. Sound qualifies by reaching your volume threshold or, independently, an Apple baby-cry score of at least \(CryConfidenceDetector.thresholdDescription). The detectors share one alert episode.")
                }
                Section {
                    Picker("Reset timer after quiet", selection: model.setting(\.quietResetDuration)) {
                        ForEach([10.0, 20, 30, 60], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                    }
                } header: {
                    Text("When crying stops")
                } footer: {
                    Text("An episode resets after both detectors have settled for \(Int(model.configuration.quietResetDuration)) seconds. This groups related activity; it does not add crying time. Isolated sound spikes cannot repeatedly restart settling. Brief low readings use the 20% tolerance. Missing audio contributes no qualifying time, and capture gaps restart the affected detector's observation window.")
                }
                Section {
                    SteppedSlider(title: "Sound threshold", stops: MonitoringConfiguration.soundThresholds,
                                  value: model.configuration.absoluteThreshold, label: { $0 == $0.rounded() ? "\(Int($0)) dBFS" : "\($0.formatted()) dBFS" },
                                  lowLabel: "Quieter sounds", highLabel: "Louder only",
                                  identifier: "soundThresholdSlider") { model.saveSetting(\.absoluteThreshold, $0) }
                } header: {
                    Text("Sound detection")
                } footer: {
                    Text("A fixed microphone level. −60 dBFS detects quieter sounds; −10 dBFS requires louder sounds. The threshold stays fixed as room noise changes. dBFS is a microphone reading, not a calibrated room loudness measurement. Other loud noises can also trigger detection.")
                }
                Section {
                    Picker("Repeat alerts", selection: model.setting(\.repeatInterval)) {
                        Text("Standard · Every 5 seconds").tag(TimeInterval?.some(5))
                        Text("Frequent · Every 2 seconds").tag(TimeInterval?.some(2))
                    }
                    .accessibilityIdentifier("repeatIntervalPicker")
                    SteppedSlider(title: "Snooze after acknowledgement", stops: MonitoringConfiguration.snoozeDurations,
                                  value: model.configuration.snoozeDuration, label: alertDurationText,
                                  lowLabel: "1 min", highLabel: "15 min",
                                  identifier: "snoozeDurationSlider") { model.saveSetting(\.snoozeDuration, $0) }
                } header: {
                    Text("Repeat alerts")
                } footer: {
                    Text("Crying and Listener connection-loss alerts repeat every \(Int(model.configuration.repeatInterval ?? 5)) seconds until you snooze one on your iPhone or Watch, or the Listener confirms quiet or reconnects. Acknowledging snoozes both kinds of alerts for \(alertDurationText(model.configuration.snoozeDuration)). Snooze clears existing alert notifications on that device. Opening the app clears alerts that have settled or been snoozed. If the Listener is still disconnected when snooze ends, alerts resume. Frequent alerts request more notifications; watchOS controls background wrist taps, so a tap every two seconds is not guaranteed. Notification delivery depends on connectivity and your device settings.")
                }
                Section("This iPhone") {
                    Picker("Mode", selection: Binding(get: { model.role ?? .listener }, set: { model.selectRole($0) })) { Text("Listener").tag(DeviceRole.listener); Text("Parent").tag(DeviceRole.parent) }
                    if model.role == .parent { Button("Caregivers & duty") { caregivers = true } }
                    Button(model.paired ? "Pairing details" : "Pair iPhones") { pairing = true }
                    if model.role == .parent { Button("Enable notifications") { Task { await model.notifications.register() } } }
                }
                if model.role == .parent {
                    if #available(iOS 26.0, *) {
                        SilentWatchAlarmSettingsSection()
                    }
                    Section {
                        if let enabled = model.parentStatus?.connectionAlertsEnabled {
                            Toggle("Server connection alerts", isOn: Binding(get: { model.parentStatus?.connectionAlertsEnabled ?? enabled }, set: { value in Task { await model.setConnectionAlerts(value) } }))
                                .disabled(model.changingConnectionAlerts || !model.paired)
                                .accessibilityIdentifier("serverConnectionAlerts")
                            if let delay = model.adjustableConnectionAlertDelay {
                                SteppedSlider(title: "Alert after no update for", stops: AppModel.connectionAlertDelays,
                                              value: delay, label: alertDurationText,
                                              lowLabel: "1 min", highLabel: "20 min",
                                              identifier: "connectionAlertDelaySlider") { await model.setConnectionAlertDelay($0) }
                                .disabled(model.changingConnectionAlerts || !model.paired)
                            }
                        } else {
                            LabeledContent("Server connection alerts", value: model.paired ? "Status unavailable" : "On by default")
                        }
                    } header: { Text("Monitoring connection") } footer: {
                        Text("On by default for new registrations. The server alerts you when the Listener stops unexpectedly, or when it sends no update for \(model.connectionAlertDelay.map { "\(alertDurationText($0)) (checked each minute, so up to a minute later)" } ?? "about 3 minutes"), for example during an internet outage. This works even while Parent Mode is closed or the phone is locked. Missing-update alerts repeat at your chosen alert frequency until snoozed or the Listener reconnects, and use Silent Watch alarms when enabled. Snooze pauses crying and connection-loss alerts together. Receiving these alerts requires internet and allowed notifications.")
                    }
                    Section {
                        Toggle("Local overdue-check warning", isOn: Binding(get: { model.localConnectionWarningEnabled }, set: { model.setLocalConnectionWarning($0) }))
                            .accessibilityIdentifier("localConnectionWarning")
                        if model.localConnectionWarningEnabled {
                            if let failure = model.parentConnectionWarningError {
                                Text("Warning unavailable: \(failure)").foregroundStyle(.orange)
                            } else if let deadline = model.parentConnectionDeadline {
                                Text(model.now >= deadline ? "Server check overdue. Open Parent Mode to check." : "Armed · Warns after 3 minutes without a successful server check.")
                                    .foregroundStyle(model.now >= deadline ? .orange : .secondary)
                            } else {
                                Text("Waiting for a successful server check with monitoring active.").foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        Text("Optional · Off by default. During monitoring, warns on this iPhone and its Watch after 3 minutes without a successful Parent server check. Works without internet once armed. Locking the phone or leaving the app can pause checks and trigger it on a healthy network. Independent of server connection alerts. Notification, Focus and haptic settings still apply.")
                    }
                    Section {
                        Toggle("Keep screen awake", isOn: Binding(get: { model.keepScreenAwake }, set: { model.setKeepScreenAwake($0) }))
                            .accessibilityIdentifier("keepScreenAwake")
                    } footer: {
                        Text("Prevents automatic screen locking while Parent Mode is open. Uses more battery; connect power for extended use. You can still lock the phone manually, which may pause checks.")
                    }
                }
                Section {
                    Button("Unpair or replace a phone", role: .destructive) { removal = .unpair; confirmRemoval = true }.disabled(model.managingDevice)
                    Button("Delete device & shared history", role: .destructive) { removal = .delete; confirmRemoval = true }.disabled(model.managingDevice)
                } header: { Text("Device management") } footer: {
                    Text("Unpairing stops this iPhone's monitoring and removes the pair's server episode history, alerts, and connection history. Both phones can then pair with a replacement. Deleting also removes this device's server registration and resets its local history. Calibration audio is removed separately with Delete saved audio. The other phone's local data and restricted server diagnostic records are not erased remotely.")
                }
                Section("Privacy & supervision") {
                    Text("Audio is processed on the Listener iPhone. Optional calibration recordings stay on that iPhone unless you explicitly export and share them. Numeric sound-level readings are relayed to the paired Parent for the live chart and are not saved by the connection service. No recordings or audio streams are automatically uploaded.")
                    Text("Sound detection only. Cannot detect breathing problems, movement problems, silent distress, medical emergencies, or unsafe sleep conditions. Adult supervision is required; this is not a medical monitor.").font(.footnote).foregroundStyle(.secondary)
                }
                if model.role == .listener, let recording = model.calibrationAudio {
                    CalibrationAudioSection(recording: recording)
                }
                Section {
                    NavigationLink("Diagnostics & simulation") { DebugView() }
                } footer: {
                    Text(model.role == .parent ? "Includes Watch alert testing and alarm delivery experiments." : "Includes test pushes and local simulation.")
                }
            }.accessibilityIdentifier("settingsForm").navigationTitle("Settings")
                // Leaving Settings, including Diagnostics, stops a Watch test.
                .onDisappear { model.stopWatchTest() }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .sheet(isPresented: $pairing) { PairingView() }
        .sheet(isPresented: $caregivers) { CaregiverConnectionView() }
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


    private func alertDurationText(_ seconds: Double) -> String {
        if seconds.truncatingRemainder(dividingBy: 60) == 0 {
            let minutes = Int(seconds / 60)
            return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
        }
        return "\(seconds.formatted()) seconds"
    }
}

/// A focused editor shared by both Monitor roles. Existing synchronization applies on selection.
struct AlertTimingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SteppedSlider(title: "Observation window", stops: MonitoringConfiguration.alertDurations,
                                  value: model.configuration.alertDuration, label: spokenDuration,
                                  lowLabel: "Faster alerts", highLabel: "Fewer false alarms",
                                  identifier: "quickAlertDuration") { model.saveSetting(\.alertDuration, $0) }
                } footer: {
                    Text("After a full observation window, either detector can alert when at least 80% of that window qualifies, including 80% of the latest 5 seconds and a qualifying latest reading. Missing audio contributes no qualifying time. The detectors share one alert episode.")
                }
                if let duty = model.caregiverDuty, duty.secondary != nil {
                    Section("Secondary caregiver") {
                        Picker("Escalate after first alert", selection: Binding(get: { duty.escalationSeconds }, set: { delay in
                            Task { await model.updateCaregiverDuty(escalationSeconds: delay) }
                        })) {
                            ForEach([60, 120, 180, 300], id: \.self) { Text(spokenDuration(Double($0))).tag($0) }
                        }.disabled(model.changingCaregiverDuty || duty.secondary?.secondaryEnabled != true)
                        Text("Duty changes apply to future cry alerts. Turning secondary alerts off also stops escalation to that person for an ongoing alert.").font(.footnote)
                        if let error = model.caregiverError {
                            Text(error).font(.footnote).foregroundStyle(Palette.amber)
                        }
                    }
                }
                Section("Reminders & snooze") {
                    Picker("Repeat unanswered alerts", selection: model.setting(\.repeatInterval)) {
                        Text("Every 5 seconds").tag(TimeInterval?.some(5))
                        Text("Every 2 seconds").tag(TimeInterval?.some(2))
                    }.accessibilityIdentifier("quickRepeatInterval")
                    SteppedSlider(title: "Snooze duration", stops: MonitoringConfiguration.snoozeDurations,
                                  value: model.configuration.snoozeDuration, label: spokenDuration,
                                  lowLabel: "1 min", highLabel: "15 min",
                                  identifier: "quickSnoozeDuration") { model.saveSetting(\.snoozeDuration, $0) }
                }
                Section {
                    Text("Tap the orange circle on Monitor to snooze an active alert. Snooze clears current alert notifications and silences alerts for your chosen duration. While snoozed, tap Resume in the circle to end the snooze early. The nursery keeps listening.")
                    Text(model.settingsSyncStatus)
                }
            }.navigationTitle("Alert timing")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(Palette.lavender).preferredColorScheme(.dark)
    }
}

extension AppModel {
    /// Saves one monitoring setting, keeping the rest of the configuration.
    func saveSetting<Value>(_ keyPath: WritableKeyPath<MonitoringConfiguration, Value>, _ value: Value) {
        var config = configuration
        config[keyPath: keyPath] = value
        saveSettings(config)
    }
    func setting<Value>(_ keyPath: WritableKeyPath<MonitoringConfiguration, Value>) -> Binding<Value> {
        Binding(get: { self.configuration[keyPath: keyPath] }, set: { self.saveSetting(keyPath, $0) })
    }
}
