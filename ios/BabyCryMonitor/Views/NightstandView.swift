import SwiftUI

/// Both roles share this hierarchy; only the source of sound and actions changes.
struct NightstandView: View {
    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .largeTitle) private var stateSize = 52.0
    let role: DeviceRole
    @State private var pairing = false
    @State private var readiness = false
    @State private var detailsExpanded = false

    private var listener: Bool { role == .listener }
    private var soundLive: Bool { listener ? model.monitoring : model.remoteSound.isLive(at: model.now) && !(confirmedParentState && model.parentStatus?.monitoring == false) }
    private var frame: SoundLevelFrame? { model.remoteSound.frame }
    private var levels: [Double] { listener ? model.meter : frame?.levels ?? Array(repeating: -100, count: SoundLevelFrame.barCount) }
    private var threshold: Double { listener ? model.threshold : frame?.threshold ?? model.parentStatus?.listenerConfiguration?.absoluteThreshold ?? model.threshold }
    private var alertDuration: TimeInterval { listener ? model.configuration.alertDuration : frame.flatMap { soundLive ? $0.alertDuration : nil } ?? model.parentStatus?.listenerConfiguration?.alertDuration ?? model.configuration.alertDuration }
    private var elapsed: TimeInterval? { listener ? model.snapshot.current.map { $0.duration(at: model.now) } : soundLive ? frame?.episodeDuration : nil }
    private var confirmedParentState: Bool { ["Monitoring", "Standby", "Stopped"].contains(model.nurseryConnection) }
    private var standby: Bool { listener ? model.standby : confirmedParentState && model.parentStatus?.monitoring == false && model.parentStatus?.microphoneActive == true }
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
            if standby { return "Standby" }
            if !model.monitoring { return "Stopped" }
            if let episode = model.snapshot.current, model.snapshot.alertStatus(for: episode) == .failed { return "Alert failed" }
            if model.snapshot.current?.alertSentAt != nil { return "Alert sent" }
        } else {
            if !model.paired || model.pendingMonitoringCommand != nil || model.monitoringControlError != nil { return model.nurseryConnection }
            if standby { return "Standby" }
            if confirmedParentState && model.parentStatus?.monitoring == false { return "Stopped" }
            // A fresh sound frame can be displayed before the next heartbeat.
            if !soundLive {
                if !model.parentOnline { return model.nurseryConnection }
                return frame == nil ? "Waiting for sound" : "Updates paused"
            }
        }
        return switch currentState { case .quiet: "Quiet"; case .possibleCry: "Sound detected"; case .crying: "Crying-like sound"; case nil: "Status unavailable" }
    }

    private var subtitle: String {
        if standby { return "Microphone active · Detection paused" }
        if listener {
            if model.recoveringAudio { return model.audioStatus }
            return model.monitoring ? "Listening for sustained sound" : "Ready when you are"
        }
        if soundLive { return "Listening for sustained sound" }
        if !model.paired { return "Pair with the nursery iPhone to begin" }
        if let last = model.parentStatus?.lastHeartbeat { return "Listener update \(last.formatted(.relative(presentation: .numeric)))" }
        return "Waiting for a confirmed Listener update"
    }

    private var liveLabel: String {
        if standby { return "Standby · Samples discarded" }
        if listener { return model.monitoring ? "Live · On this iPhone" : "Microphone inactive" }
        if soundLive { return "Live · From Listener" }
        return frame == nil ? "Waiting for sound" : "Updates paused · Last readings"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
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

            if !listener, let alert = model.activeAlert { alertPanel(alert) }
            if !listener, let until = model.parentStatus?.alertsMutedUntil, until > model.now {
                Label("Crying alerts snoozed until \(until.formatted(date: .omitted, time: .shortened))", systemImage: "bell.slash")
                    .font(.subheadline).foregroundStyle(Palette.amber)
            }
            if !listener, let error = model.monitoringControlError {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Monitoring not confirmed", systemImage: "exclamationmark.triangle.fill").font(.headline)
                    Text(error).font(.subheadline)
                }.foregroundStyle(Palette.amber).accessibilityIdentifier("monitoringControlWarning")
            }
            if listener && model.needsRestart && !model.monitoring {
                Label("Monitoring needs to be restarted", systemImage: "exclamationmark.triangle").foregroundStyle(Palette.amber)
            }
            if listener && model.paired && model.connectivity.checked && !model.connectivity.available {
                Label("Internet unavailable · Alerts cannot currently be delivered", systemImage: "wifi.slash")
                    .font(.subheadline).foregroundStyle(Palette.amber)
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Alert after sustained sound").foregroundStyle(Palette.muted)
                    Spacer(minLength: 12)
                    Text(durationText(alertDuration)).monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Alert after sustained sound").foregroundStyle(Palette.muted)
                    Text(durationText(alertDuration)).monospacedDigit()
                }
            }.font(.subheadline)

            monitoringControls
            NightstandDevicesPanel()
            if powerReadiness.needsPower {
                Label(powerReadiness.title, systemImage: "battery.25percent").font(.subheadline).foregroundStyle(Palette.amber)
            }
            DisclosureGroup("Monitoring details", isExpanded: $detailsExpanded) { monitoringDetails.padding(.top, 12) }
                .font(.subheadline).tint(Palette.lavender)
        }
        .sheet(isPresented: $pairing) { PairingView() }
        .sheet(isPresented: $readiness) {
            if listener { ListenerTonightView() } else { ReadinessView() }
        }
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
                PrimaryButton(title: listener ? "Pair with Parent" : "Pair Listener") { pairing = true }
            }
            Button(action: toggleMonitoring) {
                Label(controlTitle, systemImage: monitoringActive ? (listener ? "stop" : "pause") : "play")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
                    .foregroundStyle(Palette.lavender).background(Palette.panel, in: RoundedRectangle(cornerRadius: 18))
            }
            .disabled(!model.paired || busy || model.managingDevice)
            .accessibilityIdentifier("nightstandMonitoringControl")
            if listener && (standby || model.recoveringAudio) {
                Button("Stop microphone") { model.stop() }
                    .font(.subheadline).foregroundStyle(Palette.lavender).frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(model.starting || model.managingDevice)
                    .accessibilityIdentifier("nightstandStopMicrophone")
            }
            if standby {
                Text("The microphone stays active so monitoring can resume remotely. Samples are discarded. Battery use and the microphone privacy indicator continue.")
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
            // With an unknown state, Pause must remain available to cancel reminders.
            if !listener && model.paired && !confirmedParentState && model.pendingMonitoringCommand == nil {
                Button("Pause monitoring") { Task { await model.requestMonitoring(false) } }
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
        if let command = model.pendingMonitoringCommand, !listener { return command.enabled ? "Starting…" : "Pausing…" }
        if standby { return "Resume monitoring" }
        return monitoringActive ? (listener ? "Stop Monitoring" : "Pause monitoring") : "Start Monitoring"
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
                Text("You may lock the screen while monitoring or in Standby. Parent Pause keeps the microphone active and discards samples for remote resume. Stop on this iPhone releases the microphone.")
                Text("Test alerts simulate the alert threshold without using the microphone. Check the receiving device to confirm delivery.")
            } else {
                Text(model.notifications.status)
                Text(soundLive ? "The chart shows the same readings as the Listener, with a short network delay." : frame == nil ? "Both iPhones need internet access. Start monitoring on the Listener to see sound levels." : "The chart shows the last received readings. Live sound updates are paused.")
                Text("Start once with the nursery app open. Pause keeps its microphone active in Standby for remote resume and cancels repeating crying alerts. If capture is lost or the app is closed, reopen it on that phone. Always wait for monitoring confirmation.")
            }
        }.font(.footnote).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
    }

    private func alertPanel(_ alert: RemoteAlert) -> some View {
        Panel {
            Label(alert.isTest == true ? "Test notification" : "Crying alert", systemImage: "bell.badge")
                .font(.title2.weight(.semibold)).foregroundStyle(Palette.amber)
            Text(alert.isTest == true ? "The Listener simulated the \(durationText(alert.durationSeconds)) alert threshold." : "Crying-like sound was detected. Check on baby and acknowledge this alert.")
                .font(.subheadline)
            Text("Sent \(alert.createdAt.formatted(date: .omitted, time: .shortened)) · Delivery: \(alert.status)")
                .font(.caption).foregroundStyle(Palette.muted)
            if alert.isTest != true {
                Text("Acknowledge to snooze crying alerts for \(durationText(model.configuration.snoozeDuration)).")
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
            PrimaryButton(title: "Acknowledge") { Task { await model.acknowledge(alert.eventId) } }
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
                    Label(model.standby ? "Standby · Microphone active, detection paused" : model.monitoring ? "Microphone listening" : "Start monitoring before bedtime", systemImage: model.microphoneActive ? "mic" : "mic.slash")
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
