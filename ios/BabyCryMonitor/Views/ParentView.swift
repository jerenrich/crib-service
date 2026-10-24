import SwiftUI

struct ParentView: View {
    @Environment(AppModel.self) private var model
    @State private var pairing = false
    @State private var readiness = false
    @State private var overnightSetup = false
    @State private var showMonitoringError = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Caption(text: "Parent Mode"); Spacer(); StatusPill(text: model.nurseryConnection, active: model.parentOnline) }
            Panel {
                Caption(text: "Current state")
                Text(currentState).font(.system(size: 40, weight: .medium, design: .rounded))
                    .foregroundStyle(soundLive ? (model.remoteSound.frame?.state == .crying ? Palette.amber : Palette.mint) : Palette.muted)
                if soundLive, let frame = model.remoteSound.frame, let elapsed = frame.episodeDuration {
                    Text("\(durationText(elapsed)) / \(durationText(frame.alertDuration))")
                        .font(.system(.title, design: .monospaced)).contentTransition(.numericText())
                    ProgressView(value: min(1, elapsed / frame.alertDuration)).tint(Palette.amber)
                }
                SoundLevelChart(levels: model.remoteSound.frame?.levels ?? Array(repeating: -100, count: SoundLevelFrame.barCount),
                    trigger: model.remoteSound.frame?.threshold ?? model.parentStatus?.listenerConfiguration?.absoluteThreshold ?? model.threshold,
                    currentLevel: model.remoteSound.frame?.levels.last ?? -100, monitoring: soundLive)
                Caption(text: "Sound level · Processed on the nursery iPhone")
                Text(soundStatus).font(.footnote).foregroundStyle(soundLive ? Palette.muted : Palette.amber)
            }
            PrimaryButton(title: "Ready for tonight?") { readiness = true }
            if model.paired {
                Panel {
                    Caption(text: "Nursery monitoring")
                    Text(model.nurseryConnection).font(.title2.weight(.semibold))
                    HStack {
                        PrimaryButton(title: "Start Monitoring") { Task { await model.requestMonitoring(true) } }
                        PrimaryButton(title: "Stop Monitoring", destructive: true) { Task { await model.requestMonitoring(false) } }
                    }.disabled(model.requestingMonitoring || model.managingDevice)
                    if let message = model.monitoringControlMessage {
                        Text(message).font(.subheadline).foregroundStyle(Palette.muted)
                    }
                    if let failure = model.monitoringControlError {
                        Label("Monitoring not confirmed", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline).foregroundStyle(.red)
                        Text(failure).font(.subheadline).foregroundStyle(.red)
                    }
                    Text("Stop cancels repeating crying alerts. Remote start needs the nursery app to be running. If iOS has suspended it, reopen it on that phone. Always wait for monitoring confirmation.")
                        .font(.footnote).foregroundStyle(Palette.muted)
                }
            }
            if let alert = model.activeAlert {
                Panel {
                    Label(alert.isTest == true ? "Test notification" : "Crying alert", systemImage: "bell.badge").font(.title2.weight(.semibold)).foregroundStyle(Palette.amber)
                    Text(alert.isTest == true ? "The Listener simulated the \(durationText(alert.durationSeconds)) alert threshold." : "Crying-like sound was detected. Check on baby and acknowledge this alert.").font(.title3)
                    Text(alert.isTest == true ? "Sent \(alert.createdAt.formatted(date: .omitted, time: .shortened))" : "Started \(alert.cryStartedAt.formatted(date: .omitted, time: .shortened))").foregroundStyle(Palette.muted)
                    Text("Delivery: \(alert.status)").font(.caption).foregroundStyle(Palette.muted)
                    if alert.isTest != true { Text("Acknowledge to snooze crying alerts for \(durationText(model.configuration.snoozeDuration)).").font(.footnote).foregroundStyle(Palette.muted) }
                    PrimaryButton(title: "Acknowledge") { Task { await model.acknowledge(alert.eventId) } }
                }
            }
            if let until = model.parentStatus?.alertsMutedUntil, until > model.now {
                Panel {
                    Label("Crying alerts snoozed", systemImage: "bell.slash").font(.headline)
                    Text("Alerts resume at \(until.formatted(date: .omitted, time: .shortened)). Connection-loss alerts stay on.").font(.footnote).foregroundStyle(Palette.muted)
                }
            }
            Panel {
                Caption(text: "Baby")
                Text(babyState).font(.system(size: 40, weight: .medium, design: .rounded)).foregroundStyle(model.parentOnline ? Palette.mint : Palette.muted)
                if let last = model.parentStatus?.lastHeartbeat {
                    Text("Last heartbeat \(last.formatted(.relative(presentation: .numeric)))").font(.subheadline).foregroundStyle(Palette.muted)
                } else { Text(model.paired ? "Cannot retrieve Listener status. Check your connection and refresh." : "Pair a Listener to see its status.").foregroundStyle(Palette.muted) }
                if let status = model.parentStatus {
                    HStack {
                        Label(status.powerConnected == true ? "Connected to power" : "On battery", systemImage: status.powerConnected == true ? "powerplug.fill" : "battery.50percent")
                        Spacer()
                        Text(status.batteryLevel.map { "\(Int($0 * 100))%" } ?? "Battery unknown")
                    }.font(.subheadline)
                    if !model.parentOnline { Text("Power and battery information is from the last update.").font(.caption).foregroundStyle(Palette.muted) }
                    if model.listenerPowerReadiness.needsPower {
                        Label(model.listenerPowerReadiness.title, systemImage: "exclamationmark.triangle").foregroundStyle(Palette.amber)
                    }
                }
                if let episode = model.parentStatus?.currentEpisode, model.parentOnline {
                    Text("\(durationText(model.now.timeIntervalSince(episode.startedAt))) since confirmed sound began").font(.subheadline)
                }
            }
            HStack { Caption(text: "Alert threshold"); Spacer(); Text(durationText(model.configuration.alertDuration)).font(.title2.monospacedDigit()) }
            Text(model.settingsSyncStatus).font(.footnote).foregroundStyle(Palette.muted)
            if let episodes = model.parentStatus?.episodes, !episodes.isEmpty {
                Panel {
                    Caption(text: "Recent episodes")
                    ForEach(Array(episodes.prefix(10))) { episode in
                        HStack { Text(episode.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline); Spacer(); Text(durationText((episode.endedAt ?? model.now).timeIntervalSince(episode.startedAt))).monospacedDigit() }
                    }
                }
            }
            if !model.paired { PrimaryButton(title: "Pair Listener") { pairing = true } }
            Panel {
                Label("Apple Watch", systemImage: "applewatch").font(.headline)
                Text(model.watch.status).font(.subheadline).foregroundStyle(Palette.muted)
                Text("Open Crib Service on your Watch and enable alerts. Turn on Watch Silent Mode and Prominent Haptic Alerts for a vibration-only nudge.").font(.footnote).foregroundStyle(Palette.muted)
                Button("Guided overnight setup & watch test") { overnightSetup = true }
                Text("Use Ready for tonight? → Guided overnight setup to check Sleep Focus and test a wrist alert before sleeping.").font(.footnote).foregroundStyle(Palette.muted)
            }
            Panel { Caption(text: "Connection"); Text(model.deliveryStatus).font(.subheadline).foregroundStyle(Palette.muted); Text(model.notifications.status).font(.subheadline).foregroundStyle(Palette.muted) }
        }.onAppear { model.setParentSoundVisible(true); showMonitoringError = model.monitoringControlError != nil }
            .onDisappear { model.setParentSoundVisible(false) }
            .onChange(of: model.monitoringControlError) { _, failure in
                showMonitoringError = failure != nil
            }
            .alert("Monitoring not confirmed", isPresented: $showMonitoringError) {
                Button("OK", role: .cancel) { }
            } message: { Text(model.monitoringControlError ?? "Check the nursery phone before relying on monitoring.") }
            .sheet(isPresented: $pairing) { PairingView() }
            .sheet(isPresented: $readiness) { ReadinessView() }
            .sheet(isPresented: $overnightSetup) {
                NavigationStack {
                    OvernightSetupView()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { overnightSetup = false } } }
                }.tint(Palette.mint)
            }
    }
    private var soundLive: Bool { model.remoteSound.isLive(at: model.now) }
    private var currentState: String {
        guard soundLive, let frame = model.remoteSound.frame else { return babyState }
        return switch frame.state { case .crying: "Crying-like sound"; case .possibleCry: "Sound detected"; case .quiet: "Quiet" }
    }
    private var soundStatus: String {
        if !model.paired { return "Pair a Listener to see live sound levels." }
        if soundLive { return "Live · Same readings as the nursery chart, with a short network delay." }
        if model.remoteSound.frame != nil { return "Live sound updates paused · Chart shows the last received readings." }
        if !model.connectivity.available { return "Live sound unavailable · Check this iPhone’s internet connection." }
        return model.liveSoundConnected ? "Waiting for live sound · Start monitoring on the nursery iPhone." : "Connecting to live sound… Both iPhones need internet access."
    }
    private var babyState: String {
        guard model.parentOnline else { return model.nurseryConnection }
        return switch model.parentStatus?.state { case .crying: "Crying-like sound"; case .possibleCry: "Sound detected"; case .quiet: "Quiet"; case nil: "Unknown" }
    }
}
