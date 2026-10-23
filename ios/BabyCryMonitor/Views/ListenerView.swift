import SwiftUI

struct ListenerView: View {
    @Environment(AppModel.self) private var model
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
                    Text(episode.alertSentAt != nil ? "APNs accepted the alert. Check Parent for delivery." : episode.alertQueuedAt != nil ? "Alert queued · Waiting for delivery confirmation" : "Another \(durationText(max(0, model.configuration.alertDuration - episode.duration(at: model.now)))) before an alert.").font(.subheadline).foregroundStyle(Palette.muted)
                } else {
                    Text(model.recoveringAudio ? model.audioStatus : model.monitoring ? "Listening for sustained sound" : "Ready when you are").foregroundStyle(Palette.muted)
                }
                SoundLevelChart(levels: model.meter, baseline: model.ambient, trigger: model.threshold,
                                currentLevel: model.currentDBFS, monitoring: model.monitoring)
                Caption(text: "Sound level · Processed on this iPhone")
            }
            HStack { Caption(text: "Alert after"); Spacer(); Text(durationText(model.configuration.alertDuration)).font(.system(.title2, design: .rounded).weight(.medium)) }
            if let last = model.snapshot.history.first {
                Panel { Caption(text: "Last sound episode"); HStack { Text(durationText(last.duration(at: model.now))).font(.title2.monospacedDigit()); Spacer(); if let ended = last.endedAt { Text("Ended \(ended.formatted(date: .omitted, time: .shortened))").font(.subheadline).foregroundStyle(Palette.muted) } } }
            }
            if !model.paired { PrimaryButton(title: "Pair with Parent") { pairing = true } }
            PrimaryButton(title: model.starting ? "Starting…" : model.monitoring || model.recoveringAudio ? "Stop Monitoring" : "Start Monitoring", destructive: model.monitoring || model.recoveringAudio) {
                if model.monitoring || model.recoveringAudio { model.stop() } else { Task { await model.start() } }
            }.disabled(model.starting || !model.paired)
            if model.monitoring { Text("Keep this iPhone plugged in. You may lock the screen.").font(.subheadline).foregroundStyle(Palette.muted) }
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
                if !model.powerConnected, let battery = model.batteryLevel, battery < 0.2 { Label("Low battery · Connect power", systemImage: "battery.25percent").foregroundStyle(Palette.amber) }
            }
        }.sheet(isPresented: $pairing) { PairingView() }
    }
    private var stateTitle: String {
        if model.recoveringAudio { return "Paused" }
        if !model.monitoring { return "Stopped" }
        if model.snapshot.current?.alertSentAt != nil { return "Alert sent" }
        return switch model.state { case .quiet: "Quiet"; case .possibleCry: "Sound detected"; case .crying: "Crying-like sound" }
    }
}

private struct SoundLevelChart: View {
    let levels: [Double]
    let baseline: Double
    let trigger: Double
    let currentLevel: Double
    let monitoring: Bool

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                let triggerHeight = levelHeight(trigger, in: geometry.size.height)
                ZStack(alignment: .bottom) {
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                            let barHeight = max(3, levelHeight(level, in: geometry.size.height))
                            Capsule()
                                .fill(Palette.mint.opacity(monitoring ? 0.65 : 0.2))
                                .overlay(alignment: .top) {
                                    if monitoring, level >= trigger {
                                        Rectangle()
                                            .fill(Palette.amber.opacity(0.8))
                                            .frame(height: max(0, barHeight - triggerHeight))
                                    }
                                }
                                .clipShape(Capsule())
                                .frame(maxWidth: .infinity)
                                .frame(height: barHeight)
                        }
                    }
                    thresholdLine(baseline, color: Palette.muted, dash: [2, 4], size: geometry.size)
                    thresholdLine(trigger, color: Palette.amber, dash: [6, 4], size: geometry.size)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
                .clipped()
            }
            .frame(height: 88)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    thresholdLabel("Baseline", value: baseline, color: Palette.muted, dash: [2, 4])
                    Spacer(minLength: 0)
                    thresholdLabel("Trigger", value: trigger, color: Palette.amber, dash: [6, 4])
                }
                VStack(alignment: .leading, spacing: 8) {
                    thresholdLabel("Baseline", value: baseline, color: Palette.muted, dash: [2, 4])
                    thresholdLabel("Trigger", value: trigger, color: Palette.amber, dash: [6, 4])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live sound level")
        .accessibilityValue("\(monitoring ? levelText(currentLevel) : "Inactive"). Baseline \(levelText(baseline)). Trigger \(levelText(trigger)).")
    }

    // Bars and guides share a bottom-aligned, full microphone scale of -100…0 dBFS.
    private func levelHeight(_ level: Double, in height: CGFloat) -> CGFloat {
        let clamped = min(0, max(-100, level.isFinite ? level : -100))
        return CGFloat((clamped + 100) / 100) * height
    }

    private func thresholdLine(_ level: Double, color: Color, dash: [CGFloat], size: CGSize) -> some View {
        Path { path in
            let y = min(size.height - 0.5, max(0.5, size.height - levelHeight(level, in: size.height)))
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        .stroke(color.opacity(monitoring ? 0.65 : 0.4), style: StrokeStyle(lineWidth: 1, dash: dash))
    }

    private func thresholdLabel(_ title: String, value: Double, color: Color, dash: [CGFloat]) -> some View {
        HStack(spacing: 6) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 16, y: 1))
            }
            .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: dash))
            .frame(width: 16, height: 2)
            Text("\(title) \(levelText(value))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(color)
                .fixedSize()
        }
    }

    private func levelText(_ level: Double) -> String {
        String(format: "%.0f dBFS", level)
    }
}
