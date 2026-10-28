import SwiftUI

/// Both roles share this hierarchy; only the source of sound and actions changes.
struct NightstandView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    let role: DeviceRole
    var showDevices: () -> Void = {}
    var showActivity: () -> Void = {}
    @State private var pairing = false
    @State private var settingsPresented = false
    @State private var detailsPresented = false
    @State private var timing = false
    @State private var testConfigurationPresented = false
    @State private var detailsTestConfigurationPresented = false
    @State private var confirmStopMicrophone = false
    @State private var nightDimmed = false
    @State private var lastInteraction = Date()
    @ScaledMetric(relativeTo: .caption) private var chartHeader: CGFloat = 40
    private let ringSize: CGFloat = 228

    private var listener: Bool { role == .listener }
    private var soundLive: Bool { listener ? model.monitoring : model.parentHasLiveMonitoring }
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
    private func elapsed(at date: Date) -> TimeInterval? {
        listener ? model.snapshot.current.map { $0.duration(at: date) } : soundLive ? model.remoteSound.episodeDuration(at: date) : nil
    }
    private var confirmedParentState: Bool { ["Monitoring", "Standby", "Stopped"].contains(model.nurseryConnection) }
    private var standby: Bool { listener ? model.standby : model.parentMonitoringDisplayState == .standby }
    private var monitoringActive: Bool { listener ? model.monitoring || model.recoveringAudio : model.parentDisplaysMonitoring }
    private var parentStartUnavailable: Bool { !listener && model.paired && !monitoringActive && !model.canStartMonitoringRemotely && model.pendingMonitoringCommand == nil }
    private var busy: Bool { listener ? model.starting : model.requestingMonitoring || model.pendingMonitoringCommand != nil }
    private var currentState: CryState? { listener ? model.state : soundLive ? frame?.state : nil }
    private var listenerAlertFailed: Bool {
        model.snapshot.current.map { model.snapshot.alertStatus(for: $0) == .failed } == true
    }
    private var snoozedUntil: Date? {
        guard !listener, let until = model.parentStatus?.alertsMutedUntil, until > model.now else { return nil }
        return until
    }

    // MARK: Status

    private enum Tone {
        case calm, caution, alert, inactive
        var color: Color {
            switch self {
            case .calm: Palette.lavender
            case .caution, .alert: Palette.amber
            case .inactive: Palette.muted
            }
        }
    }

    private typealias Ring = StatusRing.Fill

    /// The single answer to "is everything OK?", shown inside the ring.
    private struct Hero {
        var title: String
        var detail: String
        var tone: Tone
        var ring: Ring = .track
        var icon: String?
        /// Large elapsed readout while sustained sound approaches the alert.
        var timer: TimeInterval?
        /// Appends a live countdown to the detail line.
        var resumesAt: Date?
    }

    private var hero: Hero { hero(at: model.now) }

    private func hero(at date: Date) -> Hero { listener ? listenerHero(at: date) : parentHero(at: date) }

    private func parentHero(at date: Date) -> Hero {
        if model.monitoringControlError != nil {
            return Hero(title: "Monitoring not confirmed", detail: "Check the nursery phone. Don't rely on alerts.",
                        tone: .caution, ring: .dashed, icon: "exclamationmark.triangle.fill")
        }
        if let alert = model.activeAlert {
            if alert.isTest == true {
                return Hero(title: "Test alert", detail: "Confirm once it reaches your intended device.", tone: .alert, ring: .full, icon: "bell.badge")
            }
            if alert.isDisconnected {
                return Hero(title: "Listener connection lost", detail: "No nursery update for 3+ minutes. Check its power and internet.",
                            tone: .alert, ring: .full, icon: "wifi.slash")
            }
            if alert.isMonitoringFailure {
                return Hero(title: "Nursery monitoring stopped", detail: "The nursery iPhone stopped listening unexpectedly. Tap Start on it.",
                            tone: .alert, ring: .full, icon: "mic.slash")
            }
            return Hero(title: "Check on baby",
                        detail: elapsed(at: date).map { "Crying-like sound for \(clock($0))" } ?? "Alert sent \(alert.createdAt.formatted(date: .omitted, time: .shortened))",
                        tone: .alert, ring: .full, icon: "bell.fill")
        }
        switch model.parentMonitoringDisplayState {
        case .unpaired:
            return Hero(title: "Not paired", detail: "Pair with the nursery iPhone to begin.", tone: .inactive, icon: "link")
        case .starting, .pausing:
            return Hero(title: model.nurseryConnection, detail: "Waiting for the nursery iPhone to confirm.", tone: .inactive, ring: .dashed, icon: "clock")
        case .connectionLost:
            let heard = model.parentStatus?.lastHeartbeat.map { "Last heard \(ago($0))." } ?? "No recent update."
            return Hero(title: "Can't reach nursery", detail: "\(heard) Don't rely on alerts.", tone: .caution, ring: .dashed, icon: "wifi.slash")
        default: break
        }
        if let until = snoozedUntil {
            let remaining = max(0, until.timeIntervalSince(date)) / max(1, model.configuration.snoozeDuration)
            return Hero(title: "Alerts snoozed", detail: "Resumes in", tone: .caution, ring: .progress(min(1, remaining)), icon: "bell.slash", resumesAt: until)
        }
        if standby {
            return Hero(title: "Standby", detail: "Microphone active · Detection paused", tone: .inactive, icon: "pause.circle")
        }
        if model.parentMonitoringDisplayState == .stopped {
            return Hero(title: "Stopped", detail: "Monitoring is off on the nursery iPhone.", tone: .inactive, icon: "stop.circle")
        }
        // A fresh sound frame can be displayed before the next heartbeat.
        if !soundLive || !model.remoteSound.isLive(at: date) {
            let last = model.parentStatus?.lastHeartbeat
            if model.parentDisplaysMonitoring {
                return Hero(title: "Live chart paused", detail: last.map { "Monitoring confirmed \(ago($0))." } ?? "Waiting for live readings.",
                            tone: .inactive, ring: .dashed, icon: "waveform")
            }
            return Hero(title: "Monitoring unconfirmed", detail: last.map { "Last nursery update \(ago($0))." } ?? "Waiting for a confirmed Listener update.",
                        tone: .caution, ring: .dashed, icon: "questionmark.circle")
        }
        return liveHero(alertSent: false, at: date)
    }

    private func listenerHero(at date: Date) -> Hero {
        if listenerAlertFailed {
            return Hero(title: "Alert failed", detail: "Check delivery details. This alert will not retry.", tone: .caution, ring: .full, icon: "exclamationmark.triangle.fill")
        }
        if model.recoveringAudio {
            return Hero(title: "Monitoring paused", detail: model.audioStatus, tone: .caution, ring: .dashed, icon: "mic.slash")
        }
        if model.starting {
            return Hero(title: "Starting…", detail: "Turning on the microphone", tone: .inactive, ring: .dashed, icon: "mic")
        }
        if !model.paired && !model.monitoring {
            return Hero(title: "Not paired", detail: "Pair with the Parent iPhone to begin.", tone: .inactive, icon: "link")
        }
        if standby {
            return Hero(title: "Standby", detail: "Microphone active · Detection paused", tone: .inactive, icon: "pause.circle")
        }
        if !model.monitoring {
            return model.needsRestart
                ? Hero(title: "Stopped", detail: "Check the microphone before relying on alerts.", tone: .caution, icon: "mic.slash")
                : Hero(title: "Stopped", detail: "Ready when you are", tone: .inactive, icon: "mic.slash")
        }
        if model.paired, model.connectivity.checked, !model.connectivity.available {
            return Hero(title: "Internet unavailable", detail: "Alerts can't be delivered right now.", tone: .caution, ring: .dashed, icon: "wifi.slash")
        }
        return liveHero(alertSent: model.snapshot.current?.alertSentAt != nil, at: date)
    }

    private func liveHero(alertSent: Bool, at date: Date) -> Hero {
        if let elapsed = elapsed(at: date) {
            if alertSent || elapsed >= alertDuration {
                return Hero(title: "Crying-like sound", detail: "For \(clock(elapsed))\(alertSent ? " · Alert sent" : "")", tone: .alert, ring: .full, icon: "bell.fill")
            }
            return Hero(title: "Sound detected", detail: "Alert at \(clock(alertDuration))", tone: .caution,
                        ring: .progress(elapsed / max(1, alertDuration)), timer: elapsed)
        }
        return switch currentState {
        case .crying: Hero(title: "Crying-like sound", detail: "Sustained sound detected", tone: .alert, ring: .full, icon: "bell.fill")
        case .possibleCry: Hero(title: "Sound detected", detail: "Listening for sustained sound", tone: .caution)
        case .quiet: Hero(title: "Quiet", detail: "Listening for sustained sound", tone: .calm)
        case nil: Hero(title: "Status unavailable", detail: "Waiting for live readings.", tone: .inactive, ring: .dashed)
        }
    }

    private var liveLabel: String {
        if standby { return "Standby · Samples discarded" }
        if listener { return model.monitoring ? "Live · On this iPhone" : "Microphone inactive" }
        if soundLive { return "Live · From Listener" }
        return frame == nil ? "Waiting for live readings" : "Live chart paused · Last readings"
    }

    // MARK: Night dimming

    private var nightDimDelay: TimeInterval {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting-fast-dim") { return 2 }
        #endif
        return 60
    }

    /// With Keep screen awake on, the Parent dims after a minute untouched. Alerts and problems brighten it.
    private var parentCanDim: Bool {
        !listener && model.keepScreenAwake && (hero.tone == .calm || hero.tone == .inactive) && model.activeAlert == nil
            && !pairing && !settingsPresented && !detailsPresented && !timing && !testConfigurationPresented
    }

    private func setNightDimmed(_ value: Bool) {
        lastInteraction = Date()
        guard nightDimmed != value else { return }
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { nightDimmed = value }
    }

    private var nightDimOverlay: some View {
        Color.clear
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Text("Tap to brighten").font(.caption2).foregroundStyle(Color(white: 0.4)).padding(.bottom, 120)
            }
            .ignoresSafeArea()
            .statusBarHidden()
            .onTapGesture { setNightDimmed(false) }
            .presentationBackground(Color.black.opacity(0.82))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Screen dimmed")
            .accessibilityHint("Brightens the monitoring screen")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { setNightDimmed(false) }
            .accessibilityIdentifier("nightDimOverlay")
    }

    // MARK: Recent activity

    /// Counts from the shared timeline for the same 12-hour window as Activity.
    private var recentSummary: String? {
        guard model.paired, listener || model.timeline != nil else { return nil }
        let end = model.now.addingTimeInterval(model.timelineClockOffset), start = end.addingTimeInterval(-12 * 3600)
        var byID = Dictionary((model.timeline?.events ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if listener { for event in model.snapshot.timelineEvents { byID[event.id] = event } }
        let events = byID.values.filter { $0.occurredAt >= start && $0.occurredAt <= end }
        let episodes = Set(events.filter { $0.category == .crying }.compactMap(\.episodeID)).count
        let alerts = events.filter { $0.kind == "alert" }.count
        let gaps = events.filter { $0.kind == "heartbeat_missing" }.count
        func count(_ value: Int, _ noun: String) -> String { "\(value) \(noun)\(value == 1 ? "" : "s")" }
        var parts = [episodes == 0 ? "No sound episodes" : count(episodes, "sound episode")]
        if alerts > 0 { parts.append(count(alerts, "alert")) }
        if gaps > 0 { parts.append(count(gaps, "connection gap")) }
        return "Last 12 h · " + parts.joined(separator: " · ")
    }

    private var activitySummary: some View {
        let summary = recentSummary
        return Button(action: showActivity) {
            HStack(spacing: 4) {
                Text(summary ?? " ")
                Image(systemName: "chevron.right").font(.caption2)
            }
            .font(.footnote).foregroundStyle(Palette.muted)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: typeSize.isAccessibilitySize ? .leading : .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Reserve the line so the layout does not move when history loads.
        .opacity(summary == nil ? 0 : 1)
        .disabled(summary == nil)
        .accessibilityLabel(summary ?? "")
        .accessibilityHint("Opens Activity")
        .accessibilityIdentifier("nightstandSummary")
    }

    // MARK: Layout

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // Large accessibility text needs its full reading height.
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        timedHero
                        activitySummary
                        chips
                        soundPanel.frame(height: 100 + chartHeader)
                        actions
                        disclaimer
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
            } else {
                VStack(spacing: 14) {
                    header
                    timedHero.padding(.top, 4)
                    activitySummary.padding(.top, -10)
                    chips
                    soundPanel.frame(minHeight: 60, maxHeight: .infinity)
                    actions
                    disclaimer
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
        .background {
            if hero.tone == .alert {
                RadialGradient(colors: [Palette.amber.opacity(0.22), .clear], center: UnitPoint(x: 0.5, y: 0.22), startRadius: 0, endRadius: 380)
                    .ignoresSafeArea().accessibilityHidden(true)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: hero.tone)
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in lastInteraction = Date() })
        .onChange(of: model.now) { _, now in
            if parentCanDim && !nightDimmed && now.timeIntervalSince(lastInteraction) >= nightDimDelay { setNightDimmed(true) }
        }
        .onChange(of: parentCanDim) { _, canDim in if !canDim { setNightDimmed(false) } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { lastInteraction = Date() } }
        .fullScreenCover(isPresented: $nightDimmed) { nightDimOverlay }
        .task {
            // Activity is otherwise loaded only on its own tab; the Listener uses its local history.
            guard !listener else { return }
            while !Task.isCancelled {
                await model.refreshTimeline()
                do { try await Task.sleep(for: .seconds(300)) } catch { break }
            }
        }
        .alert("Stop microphone?", isPresented: $confirmStopMicrophone) {
            Button("Stop microphone", role: .destructive) { model.stop() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This turns off the nursery microphone. To resume monitoring, you may need to reopen the app on this iPhone. Leave it in Standby to resume from the Parent.")
        }
        .sheet(isPresented: $testConfigurationPresented) { AlertTestView() }
        .sheet(isPresented: $timing) { AlertTimingView() }
        .sheet(isPresented: $pairing) { PairingView() }
        .sheet(isPresented: $settingsPresented) { SettingsView() }
        .sheet(isPresented: $detailsPresented) { detailsSheet }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label(listener ? "Nursery iPhone" : "Parent iPhone", systemImage: listener ? "mic" : "bell")
                .font(.subheadline).foregroundStyle(Palette.muted)
            Spacer(minLength: 8)
            Button { detailsPresented = true } label: {
                Label("Details", systemImage: "info.circle").font(.subheadline)
                    .padding(.horizontal, 14).frame(minHeight: 44).background(Palette.panel, in: Capsule())
            }
            .accessibilityLabel("View details")
            .accessibilityIdentifier("nightstandDetails")
            Button { settingsPresented = true } label: {
                Image(systemName: "slider.horizontal.3").font(.body)
                    .frame(width: 44, height: 44).background(Palette.panel, in: Circle())
            }.accessibilityLabel("Settings")
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var timedHero: some View {
        let animating = scenePhase == .active && (hero.timer != nil || hero.resumesAt != nil)
        // Redraw only the timer presentation; the chart and model keep their
        // normal cadence. Absolute dates also catch up immediately after resume.
        return SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animating)) { context in
            let value = hero(at: animating ? max(context.date, model.now) : model.now)
            if typeSize.isAccessibilitySize {
                heroText(value)
            } else {
                heroRing(value)
            }
        }
    }

    private func heroRing(_ hero: Hero) -> some View {
        ZStack {
            StatusRing(fill: hero.ring, color: hero.tone.color, glow: hero.tone == .alert)
            VStack(spacing: 4) {
                if let icon = hero.icon {
                    Image(systemName: icon).font(.title2).foregroundStyle(hero.tone.color).accessibilityHidden(true)
                }
                heroTitle(hero)
                    .font(.system(hero.timer == nil ? .title : .title3, design: .rounded).weight(.semibold))
                    .lineLimit(2).minimumScaleFactor(0.75)
                if let timer = hero.timer {
                    Text(clock(timer)).font(.system(size: 44, weight: .medium, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                }
                heroDetail(hero).font(.footnote).foregroundStyle(Palette.muted).lineLimit(2).minimumScaleFactor(0.85)
            }
            .multilineTextAlignment(.center)
            .frame(width: ringSize - 56)
        }
        .frame(width: ringSize, height: ringSize)
        .frame(maxWidth: .infinity)
    }

    private func heroText(_ hero: Hero) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            heroTitle(hero).font(.system(.title2, design: .rounded).weight(.semibold))
            if let timer = hero.timer { Text(clock(timer)).font(.title.monospacedDigit()) }
            heroDetail(hero).font(.subheadline).foregroundStyle(Palette.muted)
            if case .progress(let value) = hero.ring {
                ProgressView(value: min(1, max(0, value))).tint(hero.tone.color)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func heroTitle(_ hero: Hero) -> some View {
        Text(hero.title).foregroundStyle(hero.tone.color)
            .accessibilityIdentifier("nightstandState")
    }

    private func heroDetail(_ hero: Hero) -> Text {
        guard let until = hero.resumesAt else { return Text(hero.detail) }
        return Text("\(hero.detail) ") + Text(timerInterval: model.now...max(model.now, until), countsDown: true).monospacedDigit()
    }

    // MARK: Device health

    private struct Chip {
        let id: String
        let title: String
        let value: String
        let icon: String
        var caution = false
        var accessibilityValue: String?
    }

    private var chipModels: [Chip] {
        listener ? [powerChip, parentChip, alertsChip] : [nurseryChip, watchChip, alertsChip]
    }

    private var nurseryChip: Chip {
        guard model.paired else { return Chip(id: "nursery", title: "Nursery", value: "Not paired", icon: "iphone") }
        guard let last = model.parentStatus?.lastHeartbeat, (-5...150).contains(model.now.timeIntervalSince(last)) else {
            let value = model.parentStatus?.lastHeartbeat.map { ago($0) } ?? "No update"
            return Chip(id: "nursery", title: "Nursery", value: value, icon: "iphone.slash", caution: true)
        }
        return Chip(id: "nursery", title: "Nursery", value: powerText(model.parentStatus?.batteryLevel, model.parentStatus?.powerConnected),
                    icon: powerIcon(model.parentStatus?.batteryLevel, model.parentStatus?.powerConnected), caution: model.listenerPowerReadiness.needsPower)
    }

    private var watchChip: Chip {
        guard model.paired else { return Chip(id: "watch", title: "Watch", value: "Not paired", icon: "applewatch") }
        return model.parentStatus?.watchPushRegistered == true
            ? Chip(id: "watch", title: "Watch", value: "Registered", icon: "applewatch")
            : Chip(id: "watch", title: "Watch", value: "Needs setup", icon: "applewatch.slash", caution: true)
    }

    private var powerChip: Chip {
        Chip(id: "power", title: "Power", value: powerText(model.batteryLevel, model.powerConnected),
             icon: powerIcon(model.batteryLevel, model.powerConnected), caution: powerReadiness.needsPower)
    }

    private var parentChip: Chip {
        guard model.paired else { return Chip(id: "parent", title: "Parent", value: "Not paired", icon: "iphone") }
        return switch model.nightstandDevices.first(where: { $0.id == "parent" })?.tone {
        case .active: Chip(id: "parent", title: "Parent", value: "Registered", icon: "iphone")
        case .warning: Chip(id: "parent", title: "Parent", value: "Not registered", icon: "iphone.slash", caution: true)
        default: Chip(id: "parent", title: "Parent", value: "Paired", icon: "iphone")
        }
    }

    private var alertsChip: Chip {
        Chip(id: "alerts", title: "Alerts", value: "After \(spokenDuration(timingPending ? model.configuration.alertDuration : alertDuration))",
             icon: "bell", caution: timingPending,
             accessibilityValue: timingPending ? "Requested \(spokenDuration(model.configuration.alertDuration)) · Waiting for nursery confirmation" : nil)
    }

    private var timingPending: Bool { !listener && model.configuration.alertDuration != alertDuration }

    private var chips: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            ForEach(chipModels, id: \.id) { chip in
                Button { if chip.id == "alerts" { timing = true } else { showDevices() } } label: { chipLabel(chip) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(chip.title)
                    .accessibilityValue(chip.accessibilityValue ?? chip.value)
                    .accessibilityHint(chip.id == "alerts" ? "Change alert timing" : "Show devices")
                    .accessibilityIdentifier(chip.id == "alerts" ? "editAlertTiming" : "nightstandChip_\(chip.id)")
            }
        }
    }

    private func chipLabel(_ chip: Chip) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: chip.icon).font(.caption)
                .foregroundStyle(chip.caution ? Palette.amber : Palette.mint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(chip.title).font(.caption.weight(.semibold))
                Text(chip.value).font(.caption).foregroundStyle(chip.caution ? Palette.amber : Palette.muted)
            }
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }

    // MARK: Sound

    private var soundPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            let legend = HStack(spacing: 6) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 1))
                    path.addLine(to: CGPoint(x: 14, y: 1))
                }
                .stroke(Palette.amber.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: 14, height: 2)
                Text("Alert level").font(.caption).foregroundStyle(Palette.amber).fixedSize()
            }.accessibilityHidden(true)
            if typeSize.isAccessibilitySize {
                liveStatus
                legend
            } else {
                HStack(alignment: .firstTextBaseline) {
                    liveStatus
                    Spacer(minLength: 8)
                    legend
                }
            }
            GeometryReader { geometry in
                SoundLevelChart(levels: levels, trigger: threshold,
                    currentLevel: listener ? model.currentDBFS : levels.last ?? -100,
                    monitoring: soundLive, height: max(8, geometry.size.height), color: Palette.lavender,
                    notificationPositions: notificationPositions)
            }
        }
        .padding(12)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: Actions

    private enum ActionStyle { case primary, alert, secondary }

    private func actionLabel(_ title: String, icon: String, style: ActionStyle, compact: Bool = false) -> some View {
        Group {
            if compact {
                Image(systemName: icon).font(.headline).frame(width: 60)
            } else {
                Label(title, systemImage: icon).font(.headline)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(minHeight: 54)
        .foregroundStyle(style == .secondary ? Palette.lavender : Palette.background)
        .background(style == .primary ? Palette.mint : style == .alert ? Palette.amber : Palette.panel, in: RoundedRectangle(cornerRadius: 18))
    }

    /// The contextual primary action, paired with the monitoring control when it still applies.
    private var actions: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            if !model.paired {
                Button { pairing = true } label: { actionLabel(listener ? "Pair with Parent" : "Pair iPhones", icon: "link", style: .primary) }
                    .disabled(model.managingDevice)
            } else if !listener, let alert = model.activeAlert {
                Button { Task { if alert.isTest == true { await model.acknowledgeTests() } else { await model.acknowledge(alert.eventId) } } } label: {
                    actionLabel(model.acknowledgingAlert ? "Confirming…" : alert.isTest == true ? "I received this test" : "Snooze alerts for \(spokenDuration(model.configuration.snoozeDuration))",
                                icon: alert.isTest == true ? "checkmark" : "bell.slash", style: alert.isTest == true ? .primary : .alert)
                }
                .disabled(model.acknowledgingAlert)
                .accessibilityIdentifier("nightstandSnooze")
                secondaryMonitoringControl
            } else if let until = snoozedUntil {
                Button { Task { await model.resumeAlerts(until: until) } } label: {
                    actionLabel(model.resumingAlerts ? "Resuming…" : "Resume alerts", icon: "bell", style: .primary)
                }
                .disabled(model.resumingAlerts || model.managingDevice)
                .accessibilityIdentifier("nightstandResumeAlerts")
                secondaryMonitoringControl
            } else if !listener, [.connectionLost, .unavailable].contains(model.parentMonitoringDisplayState) {
                Button { Task { await model.retryConnection() } } label: {
                    actionLabel(model.retryingConnection ? "Checking…" : "Retry connection", icon: "arrow.clockwise", style: .primary)
                }
                .disabled(model.retryingConnection)
                .accessibilityIdentifier("nightstandRetryConnection")
                secondaryMonitoringControl
            } else if parentStartUnavailable {
                NurseryMonitoringInstruction()
                secondaryMonitoringControl
            } else if !monitoringActive && !busy {
                Button(action: toggleMonitoring) { actionLabel(controlTitle, icon: "play.fill", style: .primary) }
                    .disabled(model.managingDevice)
                    .accessibilityIdentifier("nightstandMonitoringControl")
                if listener && (standby || model.recoveringAudio) {
                    Button { confirmStopMicrophone = true } label: {
                        actionLabel("Stop microphone", icon: "mic.slash", style: .secondary, compact: !typeSize.isAccessibilitySize)
                    }
                    .disabled(model.starting || model.managingDevice)
                    .accessibilityLabel("Stop microphone")
                    .accessibilityIdentifier("nightstandStopMicrophone")
                }
            } else {
                Button { testConfigurationPresented = true } label: {
                    actionLabel(model.sendingTestPush ? "Sending…" : "Test alert", icon: "testtube.2", style: .secondary)
                }
                .disabled(model.sendingTestPush || model.managingDevice)
                .accessibilityLabel(listener ? "Send test push" : "Test alert")
                .accessibilityIdentifier("nightstandTestAlert")
                Button(action: toggleMonitoring) {
                    actionLabel(monitoringActive && !busy ? "Pause" : controlTitle, icon: monitoringActive ? "pause.fill" : "play.fill", style: .secondary)
                }
                .disabled(busy || model.managingDevice)
                .accessibilityLabel(controlTitle)
                .accessibilityIdentifier("nightstandMonitoringControl")
            }
        }
        .frame(minHeight: 56)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nightstandActions")
    }

    /// Pausing must stay available beside other actions, including in unknown states, to cancel repeating alerts.
    @ViewBuilder private var secondaryMonitoringControl: some View {
        let compact = !typeSize.isAccessibilitySize
        if parentStartUnavailable && !confirmedParentState && model.pendingMonitoringCommand == nil {
            Button { Task { await model.requestMonitoring(false) } } label: {
                actionLabel("Pause Monitoring", icon: "pause.fill", style: .secondary, compact: compact)
            }
            .disabled(model.requestingMonitoring || model.managingDevice)
            .accessibilityLabel("Pause Monitoring")
            .accessibilityIdentifier("nightstandPauseUnconfirmed")
        } else if !parentStartUnavailable && (monitoringActive || busy) {
            Button(action: toggleMonitoring) {
                actionLabel(controlTitle, icon: monitoringActive ? "pause.fill" : "play.fill", style: .secondary, compact: compact)
            }
            .disabled(busy || model.managingDevice)
            .accessibilityLabel(controlTitle)
            .accessibilityIdentifier("nightstandMonitoringControl")
        }
    }

    private var disclaimer: some View {
        Text("Sound detection only · Adult supervision required")
            .font(.caption2).foregroundStyle(Palette.muted)
            .multilineTextAlignment(.center)
            .modifier(NightstandStatusLines(lines: 1))
            .frame(maxWidth: .infinity)
    }

    // MARK: Formatting

    private func clock(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return "\(value / 60):" + String(format: "%02d", value % 60)
    }

    private func ago(_ date: Date) -> String {
        let minutes = max(0, Int(model.now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "just now" }
        if minutes < 90 { return "\(minutes) min ago" }
        return "\(minutes / 60) hr ago"
    }

    private func powerText(_ battery: Double?, _ connected: Bool?) -> String {
        if connected == true { return "Plugged in" }
        guard let battery, battery.isFinite, (0...1).contains(battery) else { return "Unknown" }
        return "\(Int((battery * 100).rounded()))% battery"
    }

    private func powerIcon(_ battery: Double?, _ connected: Bool?) -> String {
        if connected == true { return "powerplug" }
        guard let battery, battery.isFinite else { return "battery.0percent" }
        return battery < 0.25 ? "battery.25percent" : battery < 0.5 ? "battery.50percent" : battery < 0.75 ? "battery.75percent" : "battery.100percent"
    }

    private var detailsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(hero.title).font(.title2)
                        heroDetail(hero).font(.subheadline).foregroundStyle(Palette.muted)
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
                        Label("Alerts snoozed until \(until.formatted(date: .omitted, time: .shortened))", systemImage: "bell.slash")
                            .font(.subheadline).foregroundStyle(Palette.amber)
                    }
                    if let message = model.monitoringControlMessage { Text(message).font(.subheadline) }
                    Button("Test alert") { detailsTestConfigurationPresented = true }
                        .sheet(isPresented: $detailsTestConfigurationPresented) { AlertTestView() }
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
            Label("Alerts snoozed", systemImage: "bell.slash").font(.headline)
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
            Label(model.monitoringControlError != nil ? "Monitoring not confirmed" : model.parentDisplaysMonitoring ? "Live chart paused" : model.nurseryConnection == "Stopped" ? "Nursery monitoring is stopped" : "Monitoring cannot be confirmed",
                  systemImage: "exclamationmark.triangle.fill").font(.headline).accessibilityIdentifier("connectionRecoveryHeading")
            Text(model.monitoringControlError ?? (model.parentDisplaysMonitoring
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

    private var controlTitle: String {
        if listener && model.starting { return "Starting…" }
        if let command = model.pendingMonitoringCommand, !listener { return command.enabled ? "Starting…" : "Pausing…" }
        return monitoringActive ? "Pause Monitoring" : "Start Monitoring"
    }

    private func toggleMonitoring() {
        if listener {
            if monitoringActive { model.pauseMonitoring() } else { Task { await model.start() } }
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
                Text("You may lock the screen while monitoring or in Standby. Pause Monitoring on either iPhone keeps the microphone active and discards samples for remote resume. Stop microphone on this iPhone releases the microphone after confirmation.")
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
            Label(alert.isTest == true ? "Test notification" : alert.isDisconnected ? "Listener connection lost" : alert.isMonitoringFailure ? "Nursery monitoring stopped" : "Check on baby", systemImage: "bell.badge")
                .font(.title2.weight(.semibold)).foregroundStyle(Palette.amber)
            Text(alert.isTest == true ? "Confirm only after you receive this test on your intended device." : alert.isDisconnected ? "No Listener update for at least 3 minutes. Check the nursery phone’s power, internet and monitoring." : alert.isMonitoringFailure ? "The nursery iPhone stopped listening unexpectedly. Tap Start on it. Crying is not being detected." : "Crying-like sound was detected. Check on baby.")
                .font(.subheadline)
            Text("Sent \(alert.createdAt.formatted(date: .omitted, time: .shortened)) · Delivery: \(alert.status)")
                .font(.caption).foregroundStyle(Palette.muted)
            if alert.isTest != true {
                Text("Snoozing pauses crying and Listener connection-loss alerts for your chosen duration. Monitoring stays on.")
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
            PrimaryButton(title: model.acknowledgingAlert ? "Confirming…" : alert.isTest == true ? "I received this test" : "Snooze alerts for \(spokenDuration(model.configuration.snoozeDuration))") {
                Task { if alert.isTest == true { await model.acknowledgeTests() } else { await model.acknowledge(alert.eventId) } }
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

/// Fills as sustained sound approaches the alert, or drains as a snooze ends.
private struct StatusRing: View {
    enum Fill: Equatable { case track, progress(Double), full, dashed }
    let fill: Fill
    let color: Color
    let glow: Bool
    private let lineWidth: CGFloat = 10

    private var fraction: Double {
        switch fill {
        case .progress(let value): min(1, max(0.001, value))
        case .full: 1
        case .track, .dashed: 0
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(fill == .dashed ? 0.55 : 0.15),
                        style: StrokeStyle(lineWidth: lineWidth, dash: fill == .dashed ? [3, 9] : []))
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: glow ? color.opacity(0.55) : .clear, radius: 14)
                .opacity(fraction > 0 ? 1 : 0)
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}
