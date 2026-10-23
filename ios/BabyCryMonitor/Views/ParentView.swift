import SwiftUI

struct ParentView: View {
    @Environment(AppModel.self) private var model
    @State private var pairing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Caption(text: "Nursery"); Spacer(); StatusPill(text: model.parentOnline ? "Online" : "Status unknown", active: model.parentOnline) }
            if let alert = model.activeAlert {
                Panel {
                    Label(alert.isTest == true ? "Test notification" : "Crying alert", systemImage: "bell.badge").font(.title2.weight(.semibold)).foregroundStyle(Palette.amber)
                    Text(alert.isTest == true ? "The Listener simulated the \(durationText(alert.durationSeconds)) alert threshold." : "Sound has continued for \(durationText(alert.durationSeconds)).").font(.title3)
                    Text(alert.isTest == true ? "Sent \(alert.createdAt.formatted(date: .omitted, time: .shortened))" : "Started \(alert.cryStartedAt.formatted(date: .omitted, time: .shortened))").foregroundStyle(Palette.muted)
                    Text("Delivery: \(alert.status)").font(.caption).foregroundStyle(Palette.muted)
                    PrimaryButton(title: "Acknowledge") { Task { await model.acknowledge(alert.eventId) } }
                }
            }
            Panel {
                Caption(text: "Baby")
                Text(babyState).font(.system(size: 40, weight: .medium, design: .rounded)).foregroundStyle(model.parentOnline ? Palette.mint : Palette.muted)
                if let last = model.parentStatus?.lastHeartbeat {
                    Text("Last heartbeat \(last.formatted(.relative(presentation: .numeric)))").font(.subheadline).foregroundStyle(Palette.muted)
                } else { Text("Pair a Listener to see its status.").foregroundStyle(Palette.muted) }
                if let episode = model.parentStatus?.currentEpisode, model.parentOnline {
                    Text("\(durationText(model.now.timeIntervalSince(episode.startedAt))) since confirmed sound began").font(.subheadline)
                }
            }
            HStack { Caption(text: "Alert threshold"); Spacer(); Text(durationText(model.configuration.alertDuration)).font(.title2.monospacedDigit()) }
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
                Text("Send a test push from the nursery Listener before sleeping. Delivery depends on connectivity, Focus, and Watch settings; an alert may not wake you.").font(.footnote).foregroundStyle(Palette.muted)
            }
            Panel { Caption(text: "Connection"); Text(model.deliveryStatus).font(.subheadline).foregroundStyle(Palette.muted); Text(model.notifications.status).font(.subheadline).foregroundStyle(Palette.muted) }
        }.sheet(isPresented: $pairing) { PairingView() }
    }
    private var babyState: String {
        guard model.parentOnline else { return "Unknown" }
        return switch model.parentStatus?.state { case .crying: "Crying-like sound"; case .possibleCry: "Sound detected"; case .quiet: "Quiet"; case nil: "Unknown" }
    }
}
