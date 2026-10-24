import SwiftUI

struct ParentView: View {
    @Environment(AppModel.self) private var model
    @State private var pairing = false
    @State private var readiness = false
    @State private var overnightSetup = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Caption(text: "Parent Mode"); Spacer(); StatusPill(text: model.nurseryConnection, active: model.parentOnline) }
            PrimaryButton(title: "Ready for tonight?") { readiness = true }
            if model.paired {
                Panel {
                    Label("Local overdue-check warning", systemImage: "wifi.exclamationmark").font(.headline)
                    if !model.localConnectionWarningEnabled {
                        Text("Off · Optional in Settings. Server connection alerts are controlled separately.").foregroundStyle(Palette.muted)
                    } else if let failure = model.parentConnectionWarningError {
                        Text("Warning unavailable: \(failure)").foregroundStyle(Palette.amber)
                    } else if let deadline = model.parentConnectionDeadline {
                        Text(model.now >= deadline ? "Server check overdue. Check both phones and your internet connection." : "Armed · Warns after 3 minutes without a successful server check.")
                            .foregroundStyle(model.now >= deadline ? Palette.amber : Palette.mint)
                    } else {
                        Text("Waiting for a successful server check with monitoring active.").foregroundStyle(Palette.muted)
                    }
                    if model.localConnectionWarningEnabled {
                        Text("Once armed, this iPhone can warn without internet. Keep Parent Mode open for ongoing checks. Enable Keep screen awake in Settings to prevent automatic locking. Locking the phone or leaving the app may pause checks and trigger the warning. iPhone Silent Mode and Focus can silence it.")
                            .font(.footnote).foregroundStyle(Palette.muted)
                    }
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
                    if model.parentOnline, status.powerConnected != true, let level = status.batteryLevel, level < 0.2 {
                        Label("Listener battery low · Connect power", systemImage: "exclamationmark.triangle").foregroundStyle(Palette.amber)
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
        }.sheet(isPresented: $pairing) { PairingView() }
            .sheet(isPresented: $readiness) { ReadinessView() }
            .sheet(isPresented: $overnightSetup) {
                NavigationStack {
                    OvernightSetupView()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { overnightSetup = false } } }
                }.tint(Palette.mint)
            }
    }
    private var babyState: String {
        guard model.parentOnline else { return model.nurseryConnection }
        return switch model.parentStatus?.state { case .crying: "Crying-like sound"; case .possibleCry: "Sound detected"; case .quiet: "Quiet"; case nil: "Unknown" }
    }
}
