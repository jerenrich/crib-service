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
                            Text("Acknowledgement queued for iPhone. The snooze starts when it syncs.").font(.caption2).foregroundStyle(.orange)
                        }
                        if let until = model.snapshot.alertsMutedUntil, until > context.date {
                            VStack(spacing: 4) {
                                Text("Crying alerts resume in")
                                Text(timerInterval: context.date...until, countsDown: true).monospacedDigit()
                                Button("Resume alerts") { model.resumeAlerts() }.disabled(model.refreshing)
                            }.font(.caption2).foregroundStyle(.secondary)
                        }
                        NavigationLink { WatchSetupView() } label: {
                            Label("Wrist alerts", systemImage: "applewatch.radiowaves.left.and.right")
                        }.font(.footnote)
                        if let failure = model.connectionWarningError {
                            Text("Local overdue-check warning unavailable: \(failure)").font(.caption2).foregroundStyle(.orange)
                        } else if let deadline = model.connectionWarningDeadline {
                            Text(context.date >= deadline ? "Connection check overdue · Check both phones" : "Offline warning armed · 3 minute timeout")
                                .font(.caption2).foregroundStyle(context.date >= deadline ? .orange : mint)
                        }
                        if let notice = model.notice {
                            Text(notice).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }.padding(.horizontal, 4)
                }
                .safeAreaInset(edge: .top, spacing: 4) {
                    if model.alert != nil {
                        Button("Snooze") { model.acknowledge() }
                            .buttonStyle(.borderedProminent).tint(mint).foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                    }
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
            switch phase {
            case .background: NotificationCallbackJournal.shared.lifecycle(.background)
            case .inactive: NotificationCallbackJournal.shared.lifecycle(.inactive)
            case .active: break
            @unknown default: break
            }
            guard phase == .active else { return }
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .task(id: hapticKey) {
            guard phase == .active, let alert = model.alert, alert.isRecent(at: Date()) else { return }
            // Foreground reminder only. Background delivery belongs to APNs/watchOS.
            await WatchAlertHaptics.play(for: .seconds(180), log: model.log, alert: alert) {
                phase == .active && model.alert?.eventId == alert.eventId && alert.isRecent(at: Date())
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
            Text(stateTitle(online: online, now: now)).font(.system(.title3, design: .rounded).weight(.semibold)).multilineTextAlignment(.center)
            HStack(spacing: 5) {
                Circle().fill(online ? mint : .orange).frame(width: 5, height: 5)
                Text(online ? "Listener monitoring" : model.snapshot.nurseryDisplayState(at: now) ?? "Status unknown").font(.caption2).foregroundStyle(.secondary)
            }
            if model.snapshot.parentMode && model.snapshot.paired {
                HStack { Text("Alert after"); Spacer(); Text(duration(model.snapshot.alertDuration)).foregroundStyle(mint).monospacedDigit() }
                    .font(.caption).padding(12).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                if let last = model.snapshot.lastHeartbeat {
                    Text("Heartbeat \(last.formatted(.relative(presentation: .numeric)))").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text(model.snapshot.parentMode ? "Pair a nursery Listener on your iPhone." : "Choose Parent Mode on your paired iPhone.")
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
            if !alert.isTest { Text("Tap Snooze to pause crying alerts for \(duration(model.snapshot.snoozeDuration ?? 60)).").font(.caption2).foregroundStyle(.secondary) }
        }.padding(.vertical, 8)
    }
    private func stateTitle(online: Bool, now: Date) -> String {
        guard online else { return model.snapshot.nurseryDisplayState(at: now) ?? "Check connection" }
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
    @State private var previewingHaptic = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Persistent wrist alerts", systemImage: "applewatch").font(.headline).foregroundStyle(mint)
                HStack {
                    if model.alertSetup.inProgress { ProgressView().controlSize(.small) }
                    Text(model.alertSetup.title).font(.footnote)
                }
                Button(model.alertSetup.phase == .idle ? "Enable alerts" : "Retry setup") {
                    Task { await model.enableAlerts() }
                }
                .disabled(model.alertSetup.phase == .requestingPermission)
                Text(model.alertSetup.detail)
                    .font(.caption2)
                    .foregroundStyle(model.alertSetup.phase == .blocked ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notification permissions").font(.footnote.weight(.semibold))
                    LabeledContent("Alerts", value: model.notificationAlerts)
                    LabeledContent("Sounds", value: model.notificationSounds)
                    LabeledContent("Time Sensitive", value: model.notificationTimeSensitive)
                }.font(.caption2)
                if let warning = model.notificationWarning {
                    Text(warning).font(.caption2).foregroundStyle(.orange)
                }
                Text("1. Keep your paired iPhone in Parent Mode while enabling alerts.\n\n2. On Watch, turn on Silent Mode and Sounds & Haptics → Haptic Alerts → Prominent.\n\n3. Allow this app in Sleep Focus, including Time Sensitive Notifications. Wear your Watch unlocked with enough battery.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button(previewingHaptic ? "Playing alert burst…" : "Feel alert pattern") { previewingHaptic = true }
                    .disabled(previewingHaptic || model.alert != nil)
                Button("Test in 10 seconds") { Task { await model.scheduleWristTest() } }
                    .disabled(model.alertSetup.phase == .requestingPermission)
                Text("The wrist test checks this Watch only. Send a test push from the nursery Listener to verify the full connection before sleeping.")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("The optional local overdue-check warning is off by default. Enable it in Parent iPhone Settings, separately from server connection alerts. Once armed, it works without internet and warns 3 minutes after the last verified Parent server check. Keep Parent Mode open; Keep screen awake prevents automatic locking. Locking or leaving the app can pause checks and trigger the warning. Watch notification, Focus and haptic settings still apply.")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("While the app is active, recent alerts repeat three-tap bursts for up to 3 minutes. Tap Snooze to stop. watchOS controls background vibration; use Prominent Haptics for a more noticeable wrist alert.")
                    .font(.caption2).foregroundStyle(.secondary)
                if let notice = model.notice { Text(notice).font(.caption2).foregroundStyle(.orange) }
                NavigationLink("Diagnostics") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if !model.log.persistenceAvailable { Text("Log storage unavailable").foregroundStyle(.orange) }
                            Text(model.log.previewExport).font(.system(.caption2, design: .monospaced))
                        }
                    }.navigationTitle("Diagnostics")
                }
            }
        }.navigationTitle("Wrist alerts").tint(mint)
            .task(id: previewingHaptic) {
                guard previewingHaptic else { return }
                defer { previewingHaptic = false }
                await model.previewHaptic()
            }
    }
}
