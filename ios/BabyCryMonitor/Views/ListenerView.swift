import SwiftUI

struct ListenerView: View {
    @Environment(AppModel.self) private var model
    private var powerReadiness: ListenerPowerReadiness {
        ListenerPowerReadiness(batteryLevel: model.batteryLevel, powerConnected: model.powerConnected,
                               fresh: true, now: model.now)
    }
    @State private var pairing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Caption(text: "Baby monitor"); Spacer(); StatusPill(text: model.monitoring ? "Monitoring" : model.recoveringAudio ? "Recovering" : "Stopped", active: model.monitoring) }
            Panel {
                Caption(text: "Current state")
                Text(stateTitle).font(.system(size: 40, weight: .medium, design: .rounded)).foregroundStyle(model.state == .crying ? Palette.amber : Palette.mint)
                if let episode = model.snapshot.current {
                    Text("\(durationText(episode.duration(at: model.now))) / \(durationText(model.configuration.alertDuration))").font(.system(.title, design: .monospaced)).contentTransition(.numericText())
                    ProgressView(value: min(1, episode.duration(at: model.now) / model.configuration.alertDuration)).tint(Palette.amber)
                    Text(Self.alertMessage(for: episode, snapshot: model.snapshot, now: model.now)).font(.subheadline).foregroundStyle(Palette.muted)
                } else {
                    Text(model.recoveringAudio ? model.audioStatus : model.monitoring ? "Listening for sustained sound" : "Ready when you are").foregroundStyle(Palette.muted)
                }
                SoundLevelChart(levels: model.meter, trigger: model.threshold,
                                currentLevel: model.currentDBFS, monitoring: model.monitoring)
                Caption(text: "Sound level · Processed on this iPhone")
            }
            HStack { Caption(text: "Alert after"); Spacer(); Text(durationText(model.configuration.alertDuration)).font(.system(.title2, design: .rounded).weight(.medium)) }
            Text(model.settingsSyncStatus).font(.footnote).foregroundStyle(Palette.muted)
            if let last = model.snapshot.history.first {
                Panel { Caption(text: "Last sound episode"); HStack { Text(durationText(last.duration(at: model.now))).font(.title2.monospacedDigit()); Spacer(); if let ended = last.endedAt { Text("Ended \(ended.formatted(date: .omitted, time: .shortened))").font(.subheadline).foregroundStyle(Palette.muted) } } }
            }
            if !model.paired { PrimaryButton(title: "Pair with Parent") { pairing = true } }
            PrimaryButton(title: model.starting ? "Starting…" : model.monitoring || model.recoveringAudio ? "Stop Monitoring" : "Start Monitoring", destructive: model.monitoring || model.recoveringAudio) {
                if model.monitoring || model.recoveringAudio { model.stop() } else { Task { await model.start() } }
            }.disabled(model.starting || !model.paired)
            if model.monitoring { Text("You may lock the screen. Connect power if the battery warning appears.").font(.subheadline).foregroundStyle(Palette.muted) }
            if model.needsRestart && !model.monitoring { Label("Monitoring needs to be restarted", systemImage: "exclamationmark.triangle").foregroundStyle(Palette.amber) }
            Panel {
                Caption(text: "Test notifications")
                Button {
                    Task { await model.sendTestPush() }
                } label: {
                    Label(model.sendingTestPush ? "Sending test push…" : "Send test push", systemImage: "bell.badge")
                }.disabled(!model.paired || model.sendingTestPush)
                Text("Simulate the alert threshold now and send a real, silent test notification to the paired Parent. No microphone or waiting required.").font(.footnote).foregroundStyle(Palette.muted)
                if let status = model.testPushStatus { Text(status).font(.subheadline).foregroundStyle(Palette.muted) }
            }
            Panel {
                Caption(text: "Listener status")
                Text(model.deliveryStatus).font(.subheadline).foregroundStyle(Palette.muted)
                if !model.snapshot.pending.isEmpty { Text("\(model.snapshot.pending.count) pending alert(s)").foregroundStyle(Palette.amber) }
                if let failure = model.snapshot.failedAlerts.first {
                    Text("Last alert delivery failed \(failure.failedAt.formatted(date: .abbreviated, time: .shortened)).").foregroundStyle(Palette.amber)
                }
                HStack { Label(model.powerConnected ? "Connected" : "On battery", systemImage: "powerplug"); Spacer(); Text(model.batteryLevel.map { "\(Int($0 * 100))%" } ?? "Battery unknown") }.font(.subheadline)
                if powerReadiness.needsPower { Label(powerReadiness.title, systemImage: "battery.25percent").foregroundStyle(Palette.amber) }
            }
        }.sheet(isPresented: $pairing) { PairingView() }
    }
    private var stateTitle: String {
        if model.recoveringAudio { return "Paused" }
        if !model.monitoring { return "Stopped" }
        if let episode = model.snapshot.current, model.snapshot.alertStatus(for: episode) == .failed { return "Alert failed" }
        if model.snapshot.current?.alertSentAt != nil { return "Alert sent" }
        return switch model.state { case .quiet: "Quiet"; case .possibleCry: "Sound detected"; case .crying: "Crying-like sound" }
    }
    static func alertMessage(for episode: CryEpisode, snapshot: SessionSnapshot, now: Date) -> String {
        switch snapshot.alertStatus(for: episode) {
        case .failed: "Alert delivery failed. This alert will not be retried. Check Worker/APNs diagnostics."
        case .pending: "Alert queued · Waiting for delivery confirmation"
        case .sent: "APNs accepted the alert. Check Parent for delivery."
        case .acknowledged: "Alert acknowledged on Parent."
        case .notQueued: "Another \(durationText(max(0, snapshot.configuration.alertDuration - episode.duration(at: now)))) before an alert."
        }
    }
}
