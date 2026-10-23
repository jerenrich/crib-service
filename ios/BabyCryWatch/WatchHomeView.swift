import SwiftUI
import WatchKit

private let mint = Color(red: 0.62, green: 0.90, blue: 0.79)

struct WatchHomeView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ScrollView {
                    VStack(spacing: 14) {
                        if let alert = model.alert { alertCard(alert, now: context.date) }
                        else { nurseryCard(now: context.date) }
                        if model.acknowledgementPending {
                            Text("Wrist silenced. Acknowledgement queued for iPhone.").font(.caption2).foregroundStyle(.orange)
                        }
                        NavigationLink { WatchSetupView() } label: {
                            Label("Wrist alerts", systemImage: "applewatch.radiowaves.left.and.right")
                        }.font(.footnote)
                        if let notice = model.notice {
                            Text(notice).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }.padding(.horizontal, 4)
                }
            }
            .navigationTitle("Crib Service")
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh nursery status").disabled(model.refreshing)
            } }
        }
        .tint(mint)
        .task { await model.foreground() }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .task(id: hapticKey) {
            guard phase == .active, let alert = model.alert, alert.isRecent(at: Date()) else { return }
            // Foreground reminder only. Background delivery belongs to APNs/watchOS.
            for _ in 0..<20 {
                guard !Task.isCancelled, model.alert?.eventId == alert.eventId, alert.isRecent(at: Date()) else { return }
                WKInterfaceDevice.current().play(.notification)
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .onChange(of: phase) { _, phase in if phase == .active { Task { await model.foreground() } } }
    }

    private var hapticKey: String { "\(phase == .active)-\(model.alert?.eventId.uuidString ?? "none")" }

    private func nurseryCard(now: Date) -> some View {
        let online = model.snapshot.nurseryOnline(at: now)
        return VStack(spacing: 10) {
            ZStack {
                Circle().fill(mint.opacity(0.06)).frame(width: 94, height: 94)
                Circle().stroke(mint.opacity(0.24), lineWidth: 1).frame(width: 74, height: 74)
                Image(systemName: online ? "waveform" : "moon.zzz").font(.system(size: 30, weight: .light)).foregroundStyle(online ? mint : .secondary)
            }.accessibilityHidden(true)
            Text(stateTitle(online: online)).font(.system(.title3, design: .rounded).weight(.semibold)).multilineTextAlignment(.center)
            HStack(spacing: 5) {
                Circle().fill(online ? mint : .orange).frame(width: 5, height: 5)
                Text(online ? "Listener monitoring" : "Status unknown").font(.caption2).foregroundStyle(.secondary)
            }
            if model.snapshot.parentMode && model.snapshot.paired {
                HStack { Text("Alert after"); Spacer(); Text(duration(model.snapshot.alertDuration)).foregroundStyle(mint).monospacedDigit() }
                    .font(.caption).padding(12).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                if let last = model.snapshot.lastHeartbeat {
                    Text("Heartbeat \(last.formatted(.relative(presentation: .numeric)))").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text(model.snapshot.parentMode ? "Pair a nursery Listener on your iPhone." : "Choose Parent Alerts on your paired iPhone.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }
    private func alertCard(_ alert: WatchCryAlert, now: Date) -> some View {
        VStack(spacing: 10) {
            Image(systemName: alert.isTest ? "bell.badge" : "waveform").font(.system(size: 34)).foregroundStyle(.orange)
            Text(alert.isTest ? "Test alert" : "Check on baby").font(.system(.title2, design: .rounded).weight(.semibold)).multilineTextAlignment(.center)
            Text(alert.isTest ? "A test from your Listener." : "Crying-like sound continued for \(duration(alert.duration)).").font(.footnote).multilineTextAlignment(.center)
            Text("Sent \(alert.createdAt.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
            if !alert.isRecent(at: now) { Text("Earlier alert · Check current nursery status.").font(.caption2).foregroundStyle(.orange) }
            Button("I'm checking") { model.acknowledge() }.buttonStyle(.borderedProminent).tint(mint).foregroundStyle(.black)
        }.padding(.vertical, 8)
    }
    private func stateTitle(online: Bool) -> String {
        guard online else { return "Check connection" }
        switch model.snapshot.state {
        case .quiet: return "All quiet"
        case .possibleCry: return "Sound detected"
        case .crying: return "Crying-like sound"
        case nil: return "Status unknown"
        }
    }
    private func duration(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds)) sec" : "\(Int(seconds / 60)) min\(Int(seconds) % 60 == 0 ? "" : " \(Int(seconds) % 60) sec")"
    }
}

struct WatchSetupView: View {
    @Environment(WatchModel.self) private var model
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("A quiet nudge", systemImage: "applewatch").font(.headline).foregroundStyle(mint)
                Text(model.notificationsAllowed && model.snapshot.watchPushRegistered ? "Direct Watch alerts registered" : "Finish setting up alerts").font(.footnote)
                Button("Enable alerts") { Task { await model.enableAlerts() } }
                Text("1. Keep your paired iPhone in Parent mode while enabling alerts.\n\n2. On Watch, turn on Silent Mode and Sounds & Haptics → Haptic Alerts → Prominent.\n\n3. Allow this app in Sleep Focus, including Time Sensitive Notifications. Wear your Watch unlocked with enough battery.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Feel a vibration") { model.previewHaptic() }
                Button("Test in 10 seconds") { Task { await model.scheduleWristTest() } }
                Text("The wrist test checks this Watch only. Send a test push from the nursery Listener to verify the full connection before sleeping.")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("watchOS controls background alerts. Recent alerts repeat vibrations for up to 80 seconds while the alert screen is active. An alert may not wake you.")
                    .font(.caption2).foregroundStyle(.secondary)
                if let notice = model.notice { Text(notice).font(.caption2).foregroundStyle(.orange) }
            }
        }.navigationTitle("Wrist alerts").tint(mint)
    }
}
