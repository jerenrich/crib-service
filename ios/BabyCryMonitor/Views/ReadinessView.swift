import SwiftUI

/// Returning users get the short nightly check; first-time users enter the guided flow.
struct ReadinessView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var guided = false
    @State private var preparing = true
    var body: some View {
        NavigationStack {
            Group {
                if preparing { ProgressView("Checking setup…") }
                else if guided { OvernightSetupView() }
                else { nightlyCheck }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                await model.refreshParent()
                guided = !model.hasCompletedBedtimeSetup
                preparing = false
            }
        }.tint(Palette.mint)
    }

    private var nightlyCheck: some View {
        Form {
            Section("Tonight's essentials") {
                check("iPhones paired", passed: model.paired)
                check("Nursery microphone active", passed: model.parentDisplaysActiveMicrophone)
                check("Watch alerts registered", passed: model.parentStatus?.watchPushRegistered == true)
                check("Settings applied on nursery iPhone", passed: model.parentOnline && model.parentStatus?.listenerConfiguration == model.configuration)
                powerCheck
                if !model.parentDisplaysMonitoring {
                    if !model.canStartMonitoringRemotely && model.pendingMonitoringCommand == nil && !model.requestingMonitoring {
                        NurseryMonitoringInstruction()
                    } else {
                        Button(model.pendingMonitoringCommand != nil || model.requestingMonitoring ? "Starting…" : "Start Monitoring") {
                            Task { await model.requestMonitoring(true) }
                        }.disabled(!model.canStartMonitoringRemotely || model.pendingMonitoringCommand != nil || model.requestingMonitoring)
                    }
                    if let error = model.monitoringControlError { Text(error).foregroundStyle(Palette.amber) }
                }
                Button(model.retryingConnection ? "Checking…" : "Refresh connection") { Task { await model.retryConnection() } }
                    .disabled(model.retryingConnection)
            }
            Section("Check tonight's wrist alert") {
                Text("With tonight's Focus on and your Watch on its clock face, send a test and lock this iPhone. Confirm only after you feel the wrist tap.")
                Button(model.sendingTestPush ? "Sending…" : "Test watch alert") { Task { await model.requestParentTest(requiresWatch: true) } }
                    .disabled(!model.canTestWatchAlert)
                if let status = model.testPushStatus { Text(status).font(.footnote) }
                if let test = model.parentStatus?.alerts?.first(where: { $0.isTest == true && $0.acknowledgedAt == nil && (-5...1800).contains(model.now.timeIntervalSince($0.createdAt)) }) {
                    Button("I felt the test on my Watch") { Task { await model.acknowledge(test.eventId) } }
                        .disabled(model.acknowledgingAlert)
                }
                if let test = model.recentConfirmedTest {
                    Label("Test receipt confirmed \(test.createdAt.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                }
            }
            Section {
                NavigationLink("Review guided setup") { OvernightSetupView() }
                Text("Repeat setup after changing Focus, Watch or connection settings. Sound detection only; continue adult supervision.").font(.footnote)
            }
        }.navigationTitle("Tonight's check")
    }

    private var powerCheck: some View {
        let power = model.listenerPowerReadiness
        let unavailable = power.state == .unavailable
        return VStack(alignment: .leading, spacing: 4) {
            Label(power.title, systemImage: unavailable ? "questionmark.circle" : power.needsPower ? "exclamationmark.circle" : "checkmark.circle.fill")
                .foregroundStyle(unavailable ? Palette.muted : power.needsPower ? Palette.amber : Palette.mint)
            Text(power.detail).font(.footnote).foregroundStyle(Palette.muted)
        }.accessibilityElement(children: .combine).accessibilityIdentifier("listenerPowerReadiness")
    }
    private func check(_ title: String, passed: Bool) -> some View {
        Label(title, systemImage: passed ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundStyle(passed ? Palette.mint : Palette.amber)
            .accessibilityLabel("\(title): \(passed ? "Passed" : "Needs checking")")
    }
}
