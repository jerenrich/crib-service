import SwiftUI

/// Both roles share this hierarchy; only the source of sound and actions changes.
struct NightstandView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let role: DeviceRole
    @State private var pairing = false
    @State private var readiness = false
    @State private var detailsPresented = false
    @State private var timing = false
    @ScaledMetric(relativeTo: .caption) private var chartChrome: CGFloat = 96

    private var listener: Bool { role == .listener }
    private var soundLive: Bool { listener ? model.monitoring : model.remoteSound.isLive(at: model.now) && !(confirmedParentState && model.parentStatus?.monitoring == false) }
    private var frame: SoundLevelFrame? { model.remoteSound.frame }
    private var levels: [Double] { listener ? model.meter : frame?.levels ?? Array(repeating: -100, count: SoundLevelFrame.barCount) }
    private var notificationPositions: [CGFloat] {
        let times = listener ? model.chartNotificationTimes.map(\.timeIntervalSince1970) : (frame?.notificationTimes ?? [])
        return times.filter { (0...SoundLevelFrame.windowDuration).contains(frameTime - $0) }
            .map { CGFloat(1 - (frameTime - $0) / SoundLevelFrame.windowDuration) }
    }
    private var frameTime: TimeInterval { listener ? (model.chartSampledAt ?? model.now).timeIntervalSince1970 : frame?.sampledAt ?? model.now.timeIntervalSince1970 }
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
                if !model.parentOnline { return model.nurseryConnection == "Stopped" ? "Stopped" : "Monitoring unconfirmed" }
                return "Live chart paused"
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
        if let last = model.parentStatus?.lastHeartbeat { return "\(model.parentOnline ? "Monitoring last confirmed" : "Last nursery update") \(last.formatted(.relative(presentation: .numeric)))" }
        return "Waiting for a confirmed Listener update"
    }

    private var liveLabel: String {
        if standby { return "Standby · Samples discarded" }
        if listener { return model.monitoring ? "Live · On this iPhone" : "Microphone inactive" }
        if soundLive { return "Live · From Listener" }
        return frame == nil ? "Waiting for live readings" : "Live chart paused · Last readings"
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // Large accessibility text needs its full reading height.
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        statusHeader
                        soundPanel(plotHeight: 100)
                        statusNotice
                        controlPanel
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    statusHeader
                    GeometryReader { geometry in
                        soundPanel(plotHeight: max(8, geometry.size.height - chartChrome))
                    }
                    .frame(maxHeight: 240)
                    statusNotice
                    controlPanel
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
        .sheet(isPresented: $timing) { AlertTimingView() }
        .sheet(isPresented: $pairing) { PairingView() }
        .sheet(isPresented: $readiness) {
            if listener { ListenerTonightView() } else { ReadinessView() }
        }
        .sheet(isPresented: $detailsPresented) { detailsSheet }
    }

    private var controlPanel: some View {
        VStack(spacing: 4) {
            Button { timing = true } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Alert after sustained sound").foregroundStyle(Palette.muted)
                        Spacer(minLength: 12)
                        Text(durationText(alertDuration)).monospacedDigit()
                        Image(systemName: "chevron.right").font(.caption)
                    }.font(.caption)
                    // Settings confirmation occupies this slot even when empty.
                    Text("Requested \(spokenDuration(model.configuration.alertDuration)) · Waiting for nursery confirmation")
                        .font(.caption2).foregroundStyle(Palette.amber)
                        .modifier(NightstandStatusLines(lines: 1))
                        .opacity(timingPending ? 1 : 0)
                        .accessibilityHidden(!timingPending)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("editAlertTiming")
            monitoringControls
        }
    }

    private var timingPending: Bool { !listener && model.configuration.alertDuration != alertDuration }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Label(listener ? "Listener · Nursery" : "Parent · With you", systemImage: listener ? "mic" : "bell")
                Spacer(minLength: 8)
                Text(model.now, style: .time).monospacedDigit()
                    .accessibilityIdentifier("nightstandClock")
            }.font(.caption).foregroundStyle(Palette.muted)
            // Reserve the same number of lines for every state, including Quiet.
            Text(title)
                .font(.system(.title2, design: .rounded).weight(.medium))
                .foregroundStyle(warning ? Palette.amber : soundLive ? Palette.lavender : Palette.muted)
                .modifier(NightstandStatusLines())
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("nightstandState")
            Text(subtitle).font(.caption).foregroundStyle(Palette.muted)
                .modifier(NightstandStatusLines(lines: 1))
        }
    }

    private func soundPanel(plotHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    liveStatus
                    Text("Sound level").font(.caption).foregroundStyle(Palette.muted)
                }
            } else {
                HStack(alignment: .top) {
                    liveStatus
                    Spacer(minLength: 8)
                    Text("Sound level").font(.caption).foregroundStyle(Palette.muted)
                        .fixedSize()
                }
            }
            SoundLevelChart(levels: levels, trigger: threshold,
                currentLevel: listener ? model.currentDBFS : levels.last ?? -100,
                monitoring: soundLive, height: plotHeight, color: Palette.lavender,
                notificationPositions: notificationPositions)
            // Keep the episode row in the layout when the nursery becomes quiet.
            HStack(spacing: 12) {
                Text("\(durationText(elapsed ?? 0)) / \(durationText(alertDuration))")
                    .font(.caption.monospacedDigit())
                    .contentTransition(.numericText())
                ProgressView(value: min(1, (elapsed ?? 0) / max(1, alertDuration)))
                    .tint(Palette.amber)
            }
            .opacity(elapsed != nil && soundLive ? 1 : 0)
            .accessibilityHidden(elapsed == nil || !soundLive)
        }
        .padding(12)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20))
    }

    private struct Notice {
        let title: String
        let summary: String
        let icon: String
        var caution = true
    }

    private var notice: Notice {
        if !listener, model.monitoringControlError != nil {
            return Notice(title: "Monitoring not confirmed", summary: "Check the nursery phone. Do not rely on alerts.", icon: "exclamationmark.triangle.fill")
        }
        if !listener, model.activeAlert != nil {
            return Notice(title: model.activeAlert?.isTest == true ? "Test notification" : "Check on your baby",
                summary: "Review the alert to confirm receipt or snooze crying alerts.", icon: "bell.badge")
        }
        if listener, listenerAlertFailed {
            return Notice(title: "Alert delivery failed", summary: "Check delivery details. This alert will not retry.", icon: "exclamationmark.triangle.fill")
        }
        if listener, model.recoveringAudio || (model.needsRestart && !model.monitoring) {
            return Notice(title: "Monitoring paused", summary: "Check the microphone before relying on alerts.", icon: "mic.slash")
        }
        if listener, model.paired, model.connectivity.checked, !model.connectivity.available {
            return Notice(title: "Internet unavailable", summary: "Alerts cannot currently be delivered.", icon: "wifi.slash")
        }
        if !listener, model.nurseryConnection == "Connection lost" {
            return Notice(title: "Connection interrupted", summary: "Check the nursery phone. Do not rely on alerts.", icon: "wifi.slash")
        }
        if !listener, let until = model.parentStatus?.alertsMutedUntil, until > model.now {
            return Notice(title: "Crying alerts snoozed", summary: "Snoozed until \(until.formatted(date: .omitted, time: .shortened)).", icon: "bell.slash")
        }
        if !model.paired {
            return Notice(title: "Pair your iPhones", summary: "Connect the nursery and Parent phones to begin.", icon: "link", caution: false)
        }
        if busy {
            return Notice(title: "Waiting for confirmation", summary: "Check the nursery phone before relying on alerts.", icon: "clock")
        }
        if standby {
            return Notice(title: "Standby · Microphone active", summary: "Detection paused. Samples are discarded.", icon: "pause.circle", caution: false)
        }
        if powerReadiness.needsPower {
            return Notice(title: powerReadiness.title, summary: "Check nursery power before overnight monitoring.", icon: "battery.25percent")
        }
        if soundLive {
            return Notice(title: currentState == .crying ? "Check on your baby" : "Monitoring sound",
                summary: "Sound detection only. Adult supervision required.", icon: currentState == .crying ? "bell.badge" : "waveform", caution: currentState == .crying)
        }
        return Notice(title: monitoringActive ? "Waiting for sound" : "Monitoring inactive",
            summary: "Confirm the nursery is listening before relying on alerts.", icon: "mic.slash", caution: false)
    }

    private var statusNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            if typeSize.isAccessibilitySize {
                noticeHeading
            } else {
                HStack(alignment: .top, spacing: 12) {
                    noticeHeading
                    Spacer(minLength: 0)
                    detailsButton
                }
            }
            Text(notice.summary).font(.caption).foregroundStyle(Palette.muted)
                .modifier(NightstandStatusLines())
            if typeSize.isAccessibilitySize { detailsButton }
        }
        .padding(.top, 8)
        .overlay(alignment: .top) { Rectangle().fill(Palette.muted.opacity(0.2)).frame(height: 1) }
    }

    private var noticeHeading: some View {
        Label(notice.title, systemImage: notice.icon)
            .font(.subheadline.weight(.medium)).foregroundStyle(notice.caution ? Palette.amber : Palette.lavender)
            .modifier(NightstandStatusLines())
            .accessibilityIdentifier(!listener && model.monitoringControlError != nil ? "monitoringControlWarning" : "nightstandNotice")
    }

    private var detailsButton: some View {
        Button { detailsPresented = true } label: {
            HStack(spacing: 4) {
                Text(!listener && model.activeAlert != nil ? "Review alert" : "Details")
                Image(systemName: "chevron.right")
            }
            .font(.caption)
            .frame(width: typeSize.isAccessibilitySize ? nil : 96, alignment: .trailing)
            .frame(minHeight: 44)
        }
        .accessibilityLabel(!listener && model.activeAlert != nil ? "Review alert" : "View details")
        .accessibilityIdentifier("nightstandDetails")
    }

    private var detailsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).font(.title2)
                        Text(subtitle).font(.subheadline).foregroundStyle(Palette.muted)
                    }
                    if !listener, let alert = model.activeAlert { alertPanel(alert) }
                    if !listener, let until = model.parentStatus?.alertsMutedUntil, until > model.now { snoozePanel(until: until) }
                    if needsConnectionRecovery { connectionRecovery }
                    if !listener, let error = model.monitoringControlError {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Monitoring not confirmed", systemImage: "exclamationmark.triangle.fill").font(.headline)
                            Text(error).font(.subheadline)
                        }.foregroundStyle(Palette.amber)
                    }
                    if listener {
                        Text(model.audioStatus).font(.subheadline)
                        if model.needsRestart && !model.monitoring {
                            Label("Monitoring needs to be restarted", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Palette.amber)
                        }
                        if model.paired && model.connectivity.checked && !model.connectivity.available {
                            Label("Internet unavailable · Alerts cannot currently be delivered", systemImage: "wifi.slash")
                                .foregroundStyle(Palette.amber)
                        }
                        if let episode = model.snapshot.current {
                            Text(ListenerView.alertMessage(for: episode, snapshot: model.snapshot, now: model.now))
                                .font(.subheadline).foregroundStyle(Palette.amber)
                        }
                    }
                    if !listener, let until = model.parentStatus?.alertsMutedUntil, until > model.now {
                        Label("Crying alerts snoozed until \(until.formatted(date: .omitted, time: .shortened))", systemImage: "bell.slash")
                            .font(.subheadline).foregroundStyle(Palette.amber)
                    }
                    if let message = model.monitoringControlMessage { Text(message).font(.subheadline) }
                    Button(model.sendingTestPush ? "Sending…" : "Test alert", action: sendTestAlert)
                        .frame(minHeight: 44)
                        .disabled(!model.paired || model.sendingTestPush || model.managingDevice)
                        .accessibilityLabel(listener ? "Send test push" : "Test alert")
                    if let status = model.testPushStatus { Text(status).font(.subheadline) }
                    if powerReadiness.needsPower {
                        Label(powerReadiness.title, systemImage: "battery.25percent").foregroundStyle(Palette.amber)
                        Text(powerReadiness.detail).font(.subheadline)
                    }
                    if timingPending {
                        Text("Requested \(spokenDuration(model.configuration.alertDuration)) · Waiting for nursery confirmation")
                            .font(.footnote).foregroundStyle(Palette.amber)
                    }
                    deviceSummary
                    monitoringDetails
                    NightstandDevicesPanel()
                }.padding(20)
            }
            .background(Palette.background)
            .navigationTitle("Monitoring details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { detailsPresented = false } } }
        }
        .foregroundStyle(.white).tint(Palette.lavender).preferredColorScheme(.dark)
    }

    private func snoozePanel(until: Date) -> some View {
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

    private var connectionRecovery: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.monitoringControlError != nil ? "Monitoring not confirmed" : model.parentOnline ? "Live chart paused" : model.nurseryConnection == "Stopped" ? "Nursery monitoring is stopped" : "Monitoring cannot be confirmed",
                  systemImage: "exclamationmark.triangle.fill").font(.headline).accessibilityIdentifier("connectionRecoveryHeading")
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

    private var needsConnectionRecovery: Bool {
        !listener && model.paired && !standby && (!soundLive || model.monitoringControlError != nil) && model.pendingMonitoringCommand == nil
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
                .modifier(NightstandStatusLines(lines: 1))
        }.accessibilityIdentifier("nightstandSoundStatus")
    }

    private var monitoringControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggleMonitoring) {
                Label(controlTitle, systemImage: monitoringActive ? (listener ? "stop" : "pause") : "play")
                    .font(.headline).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(Palette.lavender).background(Palette.panel, in: RoundedRectangle(cornerRadius: 18))
            }
            .disabled(!model.paired || busy || model.managingDevice)
            .accessibilityIdentifier("nightstandMonitoringControl")
            HStack(alignment: .top, spacing: 16) {
                if !model.paired {
                    Button(listener ? "Pair with Parent" : "Set up for tonight") { if listener { pairing = true } else { readiness = true } }
                        .frame(minHeight: 44, alignment: .leading)
                } else if listener && (standby || model.recoveringAudio) {
                    Button("Stop microphone") { model.stop() }
                        .frame(minHeight: 44, alignment: .leading)
                        .disabled(model.starting || model.managingDevice)
                        .accessibilityIdentifier("nightstandStopMicrophone")
                } else if !listener && model.paired && !confirmedParentState && model.pendingMonitoringCommand == nil {
                    // An unknown state must still allow cancelling repeating alerts.
                    Button("Pause monitoring") { Task { await model.requestMonitoring(false) } }
                        .frame(minHeight: 44, alignment: .leading)
                        .disabled(model.requestingMonitoring || model.managingDevice)
                } else {
                    Button(action: sendTestAlert) {
                        Text(model.sendingTestPush ? "Sending…" : "Test alert").frame(minHeight: 44, alignment: .leading)
                    }
                    .disabled(!model.paired || model.sendingTestPush || model.managingDevice)
                    .accessibilityLabel(listener ? "Send test push" : "Test alert")
                }
                Spacer(minLength: 0)
                Button { readiness = true } label: { Text("Ready for tonight?").frame(minHeight: 44, alignment: .trailing) }
            }.font(.caption).foregroundStyle(Palette.muted)
            Text("Sound detection only · Adult supervision required")
                .font(.caption2).foregroundStyle(Palette.muted)
                .modifier(NightstandStatusLines())
                .frame(maxWidth: .infinity)
        }
    }

    private var controlTitle: String {
        if listener && model.starting { return "Starting…" }
        if let command = model.pendingMonitoringCommand, !listener { return command.enabled ? "Starting…" : "Pausing…" }
        if standby { return "Resume monitoring" }
        return monitoringActive ? (listener ? "Stop Monitoring" : "Pause monitoring") : "Start Monitoring"
    }

    private func sendTestAlert() {
        detailsPresented = true
        Task { if listener { await model.sendTestPush() } else { await model.requestParentTest() } }
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
            if standby {
                Text("The microphone stays active so monitoring can resume remotely. Samples are discarded. Battery use and the microphone privacy indicator continue.")
            }
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

/// Keep regular-size status slots stable; never truncate accessibility text.
private struct NightstandStatusLines: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    var lines = 2

    @ViewBuilder func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            content.fixedSize(horizontal: false, vertical: true)
        } else {
            content.lineLimit(lines, reservesSpace: true)
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
