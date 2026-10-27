import SwiftUI

struct AlertTestView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var configuration = AlertTestConfiguration()
    @State private var session: AlertTestSession?
    @State private var busy = false
    @State private var loaded = false
    @State private var error: String?
    @State private var statusError: String?
    @State private var pendingID: UUID?

    private var running: Bool { session?.running == true }
    private var alarmKitAvailable: Bool {
        if model.role == .listener { return true } // The receiving Parent needs iOS 26.
        if #available(iOS 26.0, *) { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Choose how to deliver a test to the Parent iPhone and Apple Watch. The first delivery starts 10 seconds after the service accepts the test.")
                        .font(.subheadline)
                }
                Group {
                    Section {
                        option("Use AlarmKit", detail: "Silent system alarm on the Parent, with system Watch routing.", selection: $configuration.alarmKit)
                            .disabled(!alarmKitAvailable)
                            .accessibilityIdentifier("testUseAlarmKit")
                        option("iPhone with forwarding", detail: "Send to the Parent iPhone; Apple decides whether to forward to its Watch.", selection: $configuration.phone)
                            .accessibilityIdentifier("testSendToPhone")
                        option("Send directly to Apple Watch", detail: "Send a separate notification to the registered Watch.", selection: $configuration.watch)
                            .accessibilityIdentifier("testSendToWatch")
                    } header: { Text("Delivery methods") } footer: {
                        Text("Select any combination. For forwarding, lock the Parent iPhone and wear the Watch unlocked. Direct and forwarded copies may both appear. Notification audio follows device settings.")
                    }
                    if configuration.alarmKit {
                        Section("AlarmKit setup") {
                            if model.role == .parent {
                                Text("Starting requests alarm permission and arms the silent alarm experiment for 10 minutes. You can then lock this iPhone.")
                            } else {
                                Text("On the Parent running iOS 26 or later, first open Settings → Locked-phone delivery experiment and arm the Listener test for 10 minutes.")
                            }
                            Text("The service sends a separate silent wake notification. When iOS allows background execution, the Parent schedules the alarm immediately. The OS may delay or omit this step. Test while everyone is awake; a fallback sound is possible.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Toggle("Repeat test", isOn: Binding(get: { configuration.count > 1 }, set: { configuration.count = $0 ? 5 : 1 }))
                            .accessibilityIdentifier("testRepeat")
                        if configuration.count > 1 {
                            Picker("Repeat every", selection: $configuration.repeatInterval) {
                                ForEach([1, 2, 5, 10, 15, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                            }
                            .accessibilityIdentifier("testRepeatInterval")
                            Stepper("\(configuration.count) deliveries per method", value: $configuration.count, in: 2...20)
                                .accessibilityIdentifier("testRepeatCount")
                        }
                    } header: { Text("Repeat frequency") } footer: {
                        Text("Tests stop after the selected number of rounds and expire after 10 minutes. Repeats continue with the phone locked. Slow sends can extend the interval; missed rounds are never sent in a burst.")
                    }
                    Section {
                        option("Share notification IDs across devices", detail: "Use matching apns-collapse-id values for iPhone and direct Watch copies. Uncheck to use a different notification ID for each destination.", selection: $configuration.sharedCollapseIDs)
                            .accessibilityIdentifier("testShareNotificationIDs")
                        option("Use distinct APNs request IDs", detail: "Generate a separate transport ID for every send. Logical event IDs stay shared for acknowledgement.", selection: $configuration.distinctRequestIDs)
                        option("Coalesce repeat notifications", detail: "Reuse a notification ID across rounds so a later repeat can replace an earlier one. Uncheck to give each round its own ID.", selection: $configuration.coalesceRepeats)
                        option("Group notifications from this test", detail: "Share a thread ID to group notifications in Notification Center.", selection: $configuration.groupNotifications)
                    } header: { Text("Coalescing & shared IDs") } footer: {
                        Text("Each round shares one logical event ID across delivery methods. The AlarmKit wake notification always has a separate notification ID so it cannot replace the iPhone alert.")
                    }
                    if configuration.phone && configuration.watch {
                        Section("Delivery order") {
                            Picker("iPhone head start", selection: $configuration.phoneHeadStartMS) {
                                Text("Send together").tag(0)
                                Text("350 milliseconds").tag(350)
                                Text("500 milliseconds").tag(500)
                            }
                            Text("An optional lead before the direct Watch send, measured from the iPhone request. This is an experiment and does not guarantee device arrival order.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(running || busy)

                Section {
                    if let session {
                        sessionStatus(session)
                    }
                    if let error = error ?? statusError { Text(error).foregroundStyle(Palette.amber).accessibilityIdentifier("alertTestError") }
                    if busy { ProgressView("Updating test…") }
                    if running {
                        Button("Stop test", role: .destructive) { Task { await stop() } }
                            .disabled(busy)
                            .accessibilityIdentifier("stopConfiguredAlertTest")
                    } else {
                        Button("Start test in 10 seconds") { Task { await start() } }
                            .disabled(busy || !loaded || !configuration.isValid || !model.paired || model.managingDevice)
                            .accessibilityIdentifier("startConfiguredAlertTest")
                    }
                    if !loaded || error != nil || statusError != nil {
                        Button("Refresh test status") { Task { await refresh() } }.disabled(busy)
                    }
                } footer: {
                    Text("Closing this screen keeps a scheduled test running. Stop prevents future rounds; notifications already sent may arrive. Stop any active system alarm on the Parent or Watch. These options apply only to this test.")
                }
            }
            .navigationTitle("Configure test alert")
            .navigationBarTitleDisplayMode(.inline)
            .tint(Palette.mint)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .onChange(of: configuration.phone) { _, _ in resetHeadStartIfNeeded() }
            .onChange(of: configuration.watch) { _, _ in resetHeadStartIfNeeded() }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await refresh()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    if !busy { await refresh() }
                }
            }
        }
    }

    private func option(_ title: String, detail: String, selection: Binding<Bool>) -> some View {
        Toggle(isOn: selection) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }.toggleStyle(TestCheckboxStyle())
    }

    @ViewBuilder private func sessionStatus(_ session: AlertTestSession) -> some View {
        if session.running, let next = session.nextAt {
            HStack {
                Text(session.completedCount == 0 ? "Test starts in" : "Next round in")
                Spacer()
                Text(timerInterval: Date.now...max(Date.now, next), countsDown: true).monospacedDigit()
            }
            .accessibilityIdentifier("configuredAlertTestCountdown")
        }
        Text("\(session.completedCount) of \(session.configuration.count) rounds attempted · \(session.state.capitalized)")
            .font(.footnote)
            .accessibilityIdentifier("configuredAlertTestStatus")
        if let message = session.message { Text(message).font(.footnote) }
    }

    private func resetHeadStartIfNeeded() {
        if !configuration.phone || !configuration.watch { configuration.phoneHeadStartMS = 0 }
    }

    @MainActor private func refresh() async {
        guard !busy else { return }
        do {
            let fetched = try await model.configuredAlertTest()
            guard !Task.isCancelled, !busy else { return }
            if let fetched, fetched.running { configuration = fetched.configuration }
            session = fetched
            loaded = true
            statusError = nil
            if let fetched, fetched.id == pendingID {
                pendingID = nil
                error = nil
            }
        } catch is CancellationError { }
        catch { statusError = error.localizedDescription }
    }

    @MainActor private func start() async {
        guard !busy, configuration.isValid else { return }
        busy = true; error = nil
        defer { busy = false }
        if configuration.alarmKit, model.role == .parent {
            if #available(iOS 26.0, *) {
                guard await SilentAlarmExperiment.shared.arm() else {
                    error = SilentAlarmExperiment.shared.status
                    return
                }
            } else { error = "AlarmKit requires iOS 26 or later on the Parent."; return }
        }
        // Keep the same ID after a lost response so retrying cannot start a second run.
        let id = pendingID ?? UUID()
        pendingID = id
        do {
            session = try await model.configuredAlertTest(start: id, configuration: configuration)
            pendingID = nil
            model.testPushStatus = "Test scheduled. Open Test alert to check progress or stop it."
        } catch { self.error = "Could not confirm scheduling: \(error.localizedDescription) Refresh status before trying again." }
    }

    @MainActor private func stop() async {
        guard let session, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let stopped = try await model.configuredAlertTest(stop: session.id)
            self.session = stopped
            guard stopped?.id == session.id, stopped?.state == "stopped" else {
                error = "The test changed on another device. Refresh its status before stopping it."
                return
            }
            if session.configuration.alarmKit, model.role == .parent {
                if #available(iOS 26.0, *) {
                    SilentAlarmExperiment.shared.disarm()
                    SilentAlarmExperiment.shared.cancelAlarms()
                }
            }
            model.testPushStatus = "Test stopped. Notifications already sent may still arrive."
        } catch { self.error = "Could not confirm stopping: \(error.localizedDescription)" }
    }
}

private struct TestCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.title3).foregroundStyle(configuration.isOn ? Palette.mint : .secondary)
                configuration.label.foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
        .accessibilityValue(configuration.isOn ? "Checked" : "Unchecked")
    }
}
