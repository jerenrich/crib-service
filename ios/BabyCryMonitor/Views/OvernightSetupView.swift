import SwiftUI
import UIKit

struct OvernightSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var pairing = false
    @State private var focusChecked = false
    @State private var wristChecked = false
    @State private var testRequestedAt: Date?
    @State private var confirmedAt: Date?
    @State private var needsTroubleshooting = false
    private let steps = ["Pair phones", "Enable Watch alerts", "Test your wrist alert", "Start monitoring"]

    var body: some View {
        Form {
            Section {
                Text("Step \(step + 1) of 4 · \(steps[step])").font(.headline)
                ProgressView(value: Double(step + 1), total: 4).tint(Palette.mint)
            }
            switch step {
            case 0: pairStep
            case 1: watchStep
            case 2: testStep
            default: monitoringStep
            }
            if step > 0 {
                Section { Button("Back") { step -= 1 } }
            }
        }
        .id(step)
        .navigationTitle("Overnight setup")
        .sheet(isPresented: $pairing) { PairingView() }
        .task { await model.refreshParent() }
        .onChange(of: focusChecked) { _, _ in resetConfirmation() }
        .onChange(of: wristChecked) { _, _ in resetConfirmation() }
        .onChange(of: model.parentStatus?.pairingID) { _, _ in resetConfirmation(); step = 0 }
        .onChange(of: model.parentStatus?.watchPushRegistered) { _, _ in resetConfirmation(); if step > 1 { step = 1 } }
    }

    private var pairStep: some View {
        Section {
            Text("Keep this Parent iPhone with you. On the nursery iPhone, choose Listen to Baby and enter the code shown here.")
            if model.paired {
                Label("iPhones paired", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.mint)
            } else {
                Button("Pair phones") { pairing = true }
            }
            Button("Continue to Watch setup") { step = 1 }.disabled(!model.paired)
        }
    }

    private var watchStep: some View {
        Group {
            Section("Enable notifications") {
                Label(model.parentStatus?.watchPushRegistered == true ? "Watch alerts registered" : "Watch alerts need setup",
                      systemImage: model.parentStatus?.watchPushRegistered == true ? "checkmark.circle" : "applewatch")
                Text("Open Crib Service on your Watch → Wrist alerts → Enable alerts. Keep this iPhone connected to the internet.")
                Button("Check notification setup") { Task { await model.notifications.register(); await model.refreshParent() } }
                Link("Open iPhone notification settings", destination: URL(string: UIApplication.openNotificationSettingsURLString)!)
                Text("Watch permissions are separate: check Watch → Notifications → Crib Service on this iPhone.").font(.footnote)
            }
            Section("Prepare for tonight") {
                Text("In iPhone Settings → Focus → Sleep → Apps, allow Crib Service. Allow Time Sensitive Notifications where available. Check the same Focus is active on your Watch.")
                Toggle("I've checked my Focus settings", isOn: $focusChecked).accessibilityIdentifier("overnightFocusChecked")
                Text("On Watch, open Settings → Sounds & Haptics, enable haptics and choose Prominent. For vibration only, enable Silent Mode. Wear it snugly, unlocked, charged and connected.")
                Toggle("My Watch is ready on my wrist", isOn: $wristChecked).accessibilityIdentifier("overnightWristChecked")
                Text("The app cannot read Focus or haptic settings. You confirm these checks.").font(.footnote).foregroundStyle(.secondary)
                Button("Continue to test") { step = 2 }
                    .disabled(!model.paired || model.parentStatus?.watchPushRegistered != true || !focusChecked || !wristChecked)
            }
        }
    }

    private var testStep: some View {
        Section {
            Text("Turn on tonight's Sleep Focus and leave your Watch on its clock face. Send a test, lock this iPhone, and wait for a test notification and wrist tap.")
            Button(model.sendingTestPush ? "Sending…" : "Test watch alert") {
                resetConfirmation(); needsTroubleshooting = false
                let requested = Date()
                Task { if await model.requestParentTest(requiresWatch: true) { testRequestedAt = requested } }
            }.disabled(!model.canTestWatchAlert || !focusChecked || !wristChecked)
                .accessibilityIdentifier("testWatchAlert")
            if let status = model.testPushStatus { Text(status).font(.footnote) }
            if testRequestedAt != nil && confirmedAt == nil {
                Button(model.acknowledgingAlert ? "Confirming…" : "I felt the test on my Watch") {
                    Task {
                        await model.refreshParent()
                        guard let requested = testRequestedAt,
                              let test = model.parentStatus?.alerts?.first(where: { $0.isTest == true && $0.createdAt >= requested.addingTimeInterval(-1) }) else {
                            model.testPushStatus = "Test status is not available yet. Check the connection and try confirming again."
                            return
                        }
                        if await model.acknowledge(test.eventId) { confirmedAt = Date(); needsTroubleshooting = false }
                    }
                }.disabled(model.acknowledgingAlert).accessibilityIdentifier("confirmWatchAlert")
                Button("I didn't feel it") { needsTroubleshooting = true }
            }
            if let confirmedAt {
                Label("Wrist tap confirmed by you at \(confirmedAt.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
            }
            if needsTroubleshooting {
                Text("Check Watch notification permissions, Focus exceptions, haptics, wrist lock, battery and internet. Go Back to review setup, then send another test. Seeing a notification without feeling a tap does not confirm vibration.").font(.footnote)
            }
            Text("This tests delivery to your Watch. Send a test from the nursery iPhone too to verify its upload connection. Repeat after changing Focus, Watch or connection settings.").font(.footnote).foregroundStyle(.secondary)
            Button("Continue to monitoring") { step = 3 }.disabled(confirmedAt == nil)
        }
    }

    private var monitoringStep: some View {
        Section {
            let power = model.listenerPowerReadiness
            Label(power.title, systemImage: power.needsPower ? "battery.25percent" : "battery.100percent")
            Text(power.detail).font(.footnote)
            Text("Leave the nursery iPhone plugged in and start monitoring in Crib Service on that iPhone. After pausing, you can resume from Parent while its microphone remains active in Standby.")
            if model.parentOnline {
                Label("Nursery microphone confirmed active", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.mint)
                Text(model.settingsSyncStatus).font(.footnote)
                Button("Finish setup") { model.completeBedtimeSetup(); dismiss() }
                    .accessibilityIdentifier("finishBedtimeSetup")
            } else {
                Button(model.pendingMonitoringCommand != nil || model.requestingMonitoring ? "Starting…" : model.canStartMonitoringRemotely ? "Start Monitoring" : "Start on Nursery iPhone") {
                    Task { await model.requestMonitoring(true) }
                }.disabled(!model.canStartMonitoringRemotely || model.pendingMonitoringCommand != nil || model.requestingMonitoring)
                if let error = model.monitoringControlError { Text(error).foregroundStyle(Palette.amber) }
                Button(model.retryingConnection ? "Checking…" : "Retry connection") { Task { await model.retryConnection() } }
                    .disabled(model.retryingConnection)
            }
            Text("Sound detection only. Continue adult supervision. A successful test cannot guarantee later delivery or that an alert will wake you.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func resetConfirmation() { testRequestedAt = nil; confirmedAt = nil; needsTroubleshooting = false }
}
