import SwiftUI

/// Both roles share this hierarchy; only the source of sound and actions changes.
struct NightstandView: View {
    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .largeTitle) private var stateSize = 52.0
    let role: DeviceRole
    @State private var pairing = false
    @State private var readiness = false
    @State private var detailsExpanded = false
    @State private var timing = false

    private var listener: Bool { role == .listener }
    private var soundLive: Bool { listener ? model.monitoring : model.remoteSound.isLive(at: model.now) }
    private var frame: SoundLevelFrame? { model.remoteSound.frame }
    private var levels: [Double] { listener ? model.meter : frame?.levels ?? Array(repeating: -100, count: SoundLevelFrame.barCount) }
    private var threshold: Double { listener ? model.threshold : frame?.threshold ?? model.parentStatus?.listenerConfiguration?.absoluteThreshold ?? model.threshold }
    private var alertDuration: TimeInterval { listener ? model.configuration.alertDuration : frame.flatMap { soundLive ? $0.alertDuration : nil } ?? model.parentStatus?.listenerConfiguration?.alertDuration ?? model.configuration.alertDuration }
    private var elapsed: TimeInterval? { listener ? model.snapshot.current.map { $0.duration(at: model.now) } : soundLive ? frame?.episodeDuration : nil }
    private var confirmedParentState: Bool { ["Monitoring", "Stopped"].contains(model.nurseryConnection) }
    private var monitoringActive: Bool { listener ? model.monitoring || model.recoveringAudio : confirmedParentState && model.parentStatus?.monitoring == true }
    private var busy: Bool { listener ? model.starting : model.requestingMonitoring || model.pendingMonitoringCommand != nil }
    private var currentState: CryState? { listener ? model.state : soundLive ? frame?.state : nil }
    private var listenerAlertFailed: Bool {
        model.snapshot.current.map { model.snapshot.alertStatus(for: $0) == .failed } == true
    }
    private var warning: Bool { currentState == .crying || (listener ? model.recoveringAudio || listenerAlertFailed : model.monitoringControlError != nil || model.nurseryConnection == "Connection lost") }

    private var title: String {
        if listener {
            if model.starting { return "Starting…" }
            if model.recoveringAudio { return "Paused" }
            if !model.monitoring { return "Stopped" }
            if let episode = model.snapshot.current, model.snapshot.alertStatus(for: episode) == .failed { return "Alert failed" }
            if model.snapshot.current?.alertSentAt != nil { return "Alert sent" }
        } else {
            if !model.paired || model.pendingMonitoringCommand != nil || model.monitoringControlError != nil { return model.nurseryConnection }
            // A fresh sound frame can be displayed before the next heartbeat.
            if !soundLive {
                if !model.parentOnline { return model.nurseryConnection == "Stopped" ? "Stopped" : "Monitoring unconfirmed" }
                return "Live chart paused"
            }
        }
        return switch currentState { case .quiet: "Quiet"; case .possibleCry: "Sound detected"; case .crying: "Crying-like sound"; case nil: "Status unavailable" }
    }

    private var subtitle: String {
        if listener {
            if model.recoveringAudio { return model.audioStatus }
            return model.monitoring ? "Listening for sustained sound" : "Ready when you are"
        }
        if soundLive { return "Listening for sustained sound" }
        if !model.paired { return "Pair with the nursery iPhone to begin" }
        if let last = model.parentStatus?.lastHeartbeat { return "\(model.parentOnline ? "Monitoring last confirmed" : "Last nursery update") \(last.formatted(.relative(presentation: .numeric)))" }
        return "Waiting for a confirmed Listener update"
    }

    private var liveLabel: String {
        if listener { return model.monitoring ? "Live · On this iPhone" : "Microphone inactive" }
        if soundLive { return "Live · From Listener" }
        return frame == nil ? "Waiting for live readings" : "Live chart paused · Last readings"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !listener, let alert = model.activeAlert { alertPanel(alert) }
            if !listener, let until = model.parentStatus?.alertsMutedUntil, until > model.now {
                Panel {
                    Label("Crying alerts snoozed", systemImage: "bell.slash").font(.headline)
                    HStack {
                        Text("Resume in")
                        Text(timerInterval: model.now...until, countsDown: true).monospacedDigit()
                    }.font(.subheadline)
                    Button(model.resumingAlerts ? "Resuming…" : "Resume alerts") { Task { await model.resumeAlerts() } }
                        .frame(minHeight: 44).disabled(model.resumingAlerts || model.managingDevice)
                        .accessibilityIdentifier("resumeAlerts")
                }.foregroundStyle(Palette.amber)
            }
            if !listener, model.paired, (!soundLive || model.monitoringControlError != nil), model.pendingMonitoringCommand == nil { connectionRecovery }
            if powerReadiness.needsPower {
                Label(powerReadiness.title, systemImage: "battery.25percent").font(.subheadline).foregroundStyle(Palette.amber)
            }
            if listener && model.needsRestart && !model.monitoring {
                Label("Monitoring needs to be restarted", systemImage: "exclamationmark.triangle").foregroundStyle(Palette.amber)
            }
            if listener && model.paired && model.connectivity.checked && !model.connectivity.available {
                Label("Internet unavailable · Alerts cannot currently be delivered", systemImage: "wifi.slash")
                    .font(.subheadline).foregroundStyle(Palette.amber)
            }

            VStack(spacing: 10) {
                Text(model.now, style: .time).font(.subheadline.monospacedDigit()).foregroundStyle(Palette.muted)
                    .accessibilityIdentifier("nightstandClock")
                Text(title).font(.system(size: stateSize, weight: .medium, design: .rounded))
                    .foregroundStyle(warning ? Palette.amber : soundLive ? Palette.lavender : Palette.muted)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("nightstandState")
                Text(subtitle).font(.subheadline).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                Label(listener ? "Listener · Nursery" : "Parent · With you", systemImage: listener ? "mic" : "bell")
                    .font(.caption).foregroundStyle(Palette.muted)
            }.frame(maxWidth: .infinity).padding(.top, 4)

            VStack(alignment: .leading, spacing: 16) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        liveStatus
                        Spacer(minLength: 8)
                        Text("Sound level").font(.caption).foregroundStyle(Palette.muted)
                    }
                    liveStatus
                }
                SoundLevelChart(levels: levels, trigger: threshold,
                    currentLevel: listener ? model.currentDBFS : levels.last ?? -100,
                    monitoring: soundLive, height: 160, color: Palette.lavender)
                if let elapsed, soundLive {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(durationText(elapsed)) / \(durationText(alertDuration))")
                            .font(.title3.monospacedDigit()).contentTransition(.numericText())
                        ProgressView(value: min(1, elapsed / max(1, alertDuration))).tint(Palette.amber)
                        if listener, let episode = model.snapshot.current {
                            Text(ListenerView.alertMessage(for: episode, snapshot: model.snapshot, now: model.now))
                                .font(.footnote).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }


            Button { timing = true } label: {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("Alert after sustained sound").foregroundStyle(Palette.muted)
                        Spacer(minLength: 12)
                        Text(durationText(alertDuration)).monospacedDigit()
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Alert after sustained sound").foregroundStyle(Palette.muted)
                        Label(durationText(alertDuration), systemImage: "chevron.right")
                    }
                }.font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("editAlertTiming")
            if !listener && model.configuration.alertDuration != alertDuration {
                Text("Requested \(spokenDuration(model.configuration.alertDuration)) · Waiting for nursery confirmation")
                    .font(.footnote).foregroundStyle(Palette.amber)
            }

            monitoringControls
            deviceSummary
            DisclosureGroup("Monitoring details", isExpanded: $detailsExpanded) { monitoringDetails.padding(.top, 12) }
                .font(.subheadline).tint(Palette.lavender)
        }
        .sheet(isPresented: $timing) { AlertTimingView() }
        .sheet(isPresented: $pairing) { PairingView() }
        .sheet(isPresented: $readiness) {
            if listener { ListenerTonightView() } else { ReadinessView() }
        }
    }

    private var connectionRecovery: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.monitoringControlError != nil ? "Monitoring not confirmed" : model.parentOnline ? "Live chart paused" : model.nurseryConnection == "Stopped" ? "Nursery monitoring is stopped" : "Monitoring cannot be confirmed",
                  systemImage: "exclamationmark.triangle.fill").font(.headline).accessibilityIdentifier("monitoringControlWarning")
            Text(model.monitoringControlError ?? (model.parentOnline
                ? "The nursery microphone was recently confirmed active, but live sound readings have paused. Retry to reconnect the chart."
                : "Check internet on both phones. Reopen Crib Service on the nursery iPhone and check its microphone status. Then retry here."))
                .font(.subheadline)
            Button(model.retryingConnection ? "Checking…" : "Retry connection") { Task { await model.retryConnection() } }
                .frame(minHeight: 44).disabled(model.retryingConnection)
                .accessibilityIdentifier("retryConnection")
            if let message = model.connectionRetryMessage { Text(message).font(.footnote) }
        }.foregroundStyle(Palette.amber)
    }

    private var deviceSummary: some View {
        NavigationLink { NightstandDevicesView() } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "iphone")
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.paired ? "iPhones paired" : "iPhones not paired").font(.subheadline)
                    if !listener {
                        Text(model.parentStatus?.watchPushRegistered == true ? "Watch alerts registered" : "Watch alerts need setup")
                            .font(.caption).foregroundStyle(model.parentStatus?.watchPushRegistered == true ? Palette.muted : Palette.amber)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("deviceSummary")
    }

    private var liveStatus: some View {
        HStack(spacing: 6) {
            Circle().fill(soundLive ? Palette.lavender : Palette.muted).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(liveLabel).font(.caption).foregroundStyle(soundLive ? Palette.lavender : Palette.muted)
        }.accessibilityIdentifier("nightstandSoundStatus")
    }

    private var monitoringControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.paired {
                PrimaryButton(title: listener ? "Pair with Parent" : "Set up for tonight") { if listener { pairing = true } else { readiness = true } }
            }
            Button(action: toggleMonitoring) {
                Label(controlTitle, systemImage: monitoringActive ? "stop" : "play")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
                    .foregroundStyle(Palette.lavender).background(Palette.panel, in: RoundedRectangle(cornerRadius: 18))
            }
            .disabled(!model.paired || busy || model.managingDevice)
            .accessibilityIdentifier("nightstandMonitoringControl")
            // With an unknown state, Stop must remain available to cancel reminders.
            if !listener && model.paired && !confirmedParentState && model.pendingMonitoringCommand == nil {
                Button("Stop Monitoring") { Task { await model.requestMonitoring(false) } }
                    .font(.subheadline).foregroundStyle(Palette.lavender).frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(model.requestingMonitoring || model.managingDevice)
            }
            if !listener, let message = model.monitoringControlMessage {
                Text(message).font(.footnote).foregroundStyle(Palette.muted)
            }
            HStack(alignment: .top, spacing: 16) {
                Button { Task { if listener { await model.sendTestPush() } else { await model.requestParentTest() } } } label: {
                    Text(model.sendingTestPush ? "Sending…" : "Test alert").frame(minHeight: 44, alignment: .leading)
                }
                .disabled(!model.paired || model.sendingTestPush || model.managingDevice)
                .accessibilityLabel(listener ? "Send test push" : "Test alert")
                Spacer(minLength: 0)
                Button { readiness = true } label: { Text("Ready for tonight?").frame(minHeight: 44, alignment: .trailing) }
            }.font(.subheadline).foregroundStyle(Palette.muted)
            if let status = model.testPushStatus { Text(status).font(.footnote).foregroundStyle(Palette.muted) }
        }
    }

    private var controlTitle: String {
        if listener && model.starting { return "Starting…" }
        if let command = model.pendingMonitoringCommand, !listener { return command.enabled ? "Starting…" : "Stopping…" }
        return monitoringActive ? "Stop Monitoring" : "Start Monitoring"
    }

    private func toggleMonitoring() {
        if listener {
            if monitoringActive { model.stop() } else { Task { await model.start() } }
        } else { Task { await model.requestMonitoring(!monitoringActive) } }
    }

    private var powerReadiness: ListenerPowerReadiness {
        listener ? ListenerPowerReadiness(batteryLevel: model.batteryLevel, powerConnected: model.powerConnected, fresh: true, now: model.now) : model.listenerPowerReadiness
    }

    private var monitoringDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.settingsSyncStatus)
            Text(model.deliveryStatus)
            if listener {
                if !model.snapshot.pending.isEmpty { Text("\(model.snapshot.pending.count) pending alert(s)").foregroundStyle(Palette.amber) }
                if let failure = model.snapshot.failedAlerts.first {
                    Text("Last alert delivery failed \(failure.failedAt.formatted(date: .abbreviated, time: .shortened)).").foregroundStyle(Palette.amber)
                }
                Text("You may lock the screen while monitoring. Sound is processed on this iPhone.")
                Text("Test alerts simulate the alert threshold without using the microphone. Check the receiving device to confirm delivery.")
            } else {
                Text(model.notifications.status)
                Text(soundLive ? "The chart shows the same readings as the Listener, with a short network delay." : frame == nil ? "Both iPhones need internet access. Start monitoring on the Listener to see sound levels." : "The chart shows the last received readings. Live sound updates are paused.")
                Text("Remote start needs the nursery app to be running. If iOS has suspended it, reopen it on that phone. Always wait for monitoring confirmation. Stop cancels repeating crying alerts.")
            }
        }.font(.footnote).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
    }

    private func alertPanel(_ alert: RemoteAlert) -> some View {
        Panel {
            Label(alert.isTest == true ? "Test notification" : "Check on baby", systemImage: "bell.badge")
                .font(.title2.weight(.semibold)).foregroundStyle(Palette.amber)
            Text(alert.isTest == true ? "Confirm only after you receive this test on your intended device." : "Crying-like sound was detected. Check on baby.")
                .font(.subheadline)
            Text("Sent \(alert.createdAt.formatted(date: .omitted, time: .shortened)) · Delivery: \(alert.status)")
                .font(.caption).foregroundStyle(Palette.muted)
            if alert.isTest != true {
                Text("Snoozing stops repeat crying alerts. Monitoring and connection warnings stay on.")
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
            PrimaryButton(title: model.acknowledgingAlert ? "Confirming…" : alert.isTest == true ? "I received this test" : "Snooze alerts for \(spokenDuration(model.configuration.snoozeDuration))") {
                Task { await model.acknowledge(alert.eventId) }
            }.disabled(model.acknowledgingAlert).accessibilityIdentifier("activeAlertAction")
        }
    }
}

private struct ListenerTonightView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private var power: ListenerPowerReadiness {
        ListenerPowerReadiness(batteryLevel: model.batteryLevel, powerConnected: model.powerConnected, fresh: true, now: model.now)
    }
    var body: some View {
        NavigationStack {
            List {
                Section("Nursery check") {
                    Label(model.paired ? "iPhones paired" : "Pair with Parent first", systemImage: model.paired ? "checkmark.circle" : "link")
                    Label(model.monitoring ? "Microphone listening" : "Start monitoring before bedtime", systemImage: model.monitoring ? "mic" : "mic.slash")
                    Label(power.title, systemImage: power.state == .unavailable ? "questionmark.circle" : power.needsPower ? "battery.25percent" : "battery.100percent")
                    Text(power.detail).font(.footnote).foregroundStyle(Palette.muted)
                }
                Section("Test your connection") {
                    Button(model.sendingTestPush ? "Sending…" : "Send test push") { Task { await model.sendTestPush() } }
                        .disabled(!model.paired || model.sendingTestPush)
                    if let status = model.testPushStatus { Text(status).font(.footnote) }
                    Text("On the Parent iPhone, use Ready for tonight? to check notifications, Sleep Focus and Watch haptics.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Tonight's check")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(Palette.lavender)
    }
}
