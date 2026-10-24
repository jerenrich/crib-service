import SwiftUI

struct TimelineView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @State private var filter = TimelineCategory.all
    @State private var showEarlier = false
    @State private var selectedID: String?
    @State private var selectedCoverage: TimelineCoverage?
    private var end: Date { model.now.addingTimeInterval(model.timelineClockOffset) }
    private var start: Date { end.addingTimeInterval(-12 * 3600) }
    private var events: [TimelineEvent] {
        guard model.paired else { return [] }
        var byID = Dictionary((model.timeline?.events ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if model.role == .listener {
            for event in model.snapshot.timelineEvents { byID[event.id] = event }
        }
        return byID.values.sorted { $0.occurredAt == $1.occurredAt ? $0.id < $1.id : $0.occurredAt > $1.occurredAt }
    }
    private var availableSince: Date {
        let server = model.timeline?.availableSince ?? end
        guard model.role == .listener, model.paired, let local = model.snapshot.timelineEvents.first?.occurredAt else { return server }
        return min(server, local)
    }
    private var visibleEvents: [TimelineEvent] {
        events.filter { $0.occurredAt >= start && $0.occurredAt <= end && !$0.isObservation }
    }
    private var filtered: [TimelineEvent] { visibleEvents.filter { filter == .all || $0.category == filter } }
    private var displayed: [TimelineEvent] { showEarlier ? filtered : Array(filtered.prefix(8)) }
    private var emptyEventsText: String {
        if model.loadingTimeline { return "Loading events…" }
        if sharedStatusUnavailable {
            return model.timeline == nil ? "Event history is unavailable. Retry to load it." : "No matching events in the last fetched history."
        }
        return filter == .all ? "No events recorded in the last 12 hours." : "No \(filter.rawValue.lowercased()) events in this window."
    }
    private var sharedStatusUnavailable: Bool {
        model.role == .parent && (model.timelineError != nil || model.timeline == nil || end.timeIntervalSince(model.timeline?.serverTime ?? end) > 180)
    }
    private var coverage: [TimelineCoverage] {
        let unavailableSince: Date?
        if model.role == .parent, let page = model.timeline {
            unavailableSince = sharedStatusUnavailable ? page.serverTime : nil
        } else {
            unavailableSince = model.role == .parent && model.timeline == nil ? start : nil
        }
        return TimelineCoverage.segments(events: events, from: start, to: end, availableSince: availableSince,
                                         statusUnavailableSince: unavailableSince, historyTruncated: model.timeline?.truncated == true)
    }

    private var episodeCount: Int { Set(visibleEvents.filter { $0.category == .crying }.compactMap(\.episodeID)).count }
    private var acknowledgementCount: Int { visibleEvents.filter { $0.kind == "alert_acknowledged" }.count }
    private var gapCount: Int { visibleEvents.filter { $0.kind == "heartbeat_missing" }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(Palette.muted)
                HStack(spacing: 8) {
                    Circle().fill(statusActive ? Palette.mint : Palette.amber).frame(width: 6, height: 6)
                    Text(statusText).font(.subheadline)
                    Spacer()
                    if model.loadingTimeline { ProgressView().controlSize(.small) }
                }
                if !model.paired {
                    ContentUnavailableView("Pair a Listener first", systemImage: "link", description: Text("The timeline shows events shared by your paired phones."))
                } else {
                    overview
                    HStack {
                        statistic(episodeCount, "Sound episodes")
                        Spacer()
                        statistic(acknowledgementCount, "Acknowledgements")
                        Spacer()
                        statistic(gapCount, "Connection gaps")
                    }
                    if model.timelineError != nil || sharedStatusUnavailable && !model.loadingTimeline {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Status unavailable", systemImage: "exclamationmark.icloud").foregroundStyle(.purple)
                            Text(model.timelineError ?? "A fresh shared timeline is unavailable. The Listener’s current status cannot be verified here.").font(.footnote).foregroundStyle(Palette.muted)
                            if let last = model.timeline?.serverTime {
                                Text("Shared history last updated \(last.formatted(date: .omitted, time: .standard)).").font(.caption).foregroundStyle(Palette.muted)
                            }
                            Button("Retry") { Task { await model.refreshTimeline() } }.disabled(model.loadingTimeline)
                        }
                    }
                    if model.timeline != nil && availableSince > start {
                        Label("History recording began \(availableSince.formatted(date: .abbreviated, time: .shortened)). No history is recorded before then.", systemImage: "clock.badge.questionmark")
                            .font(.footnote).foregroundStyle(Palette.muted)
                    }
                    if model.timeline?.truncated == true {
                        Label("This busy window exceeds the history limit. Some events are omitted, so monitoring coverage is shown as missing history.", systemImage: "ellipsis.circle")
                            .font(.footnote).foregroundStyle(Palette.amber)
                    }
                    HStack {
                        Text("Event log").font(.title3.weight(.semibold))
                        Spacer()
                        Menu {
                            Picker("Filter events", selection: $filter) {
                                ForEach(TimelineCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                        } label: {
                            Label(filter.rawValue, systemImage: "line.3.horizontal.decrease").font(.subheadline)
                        }.accessibilityIdentifier("timelineFilter")
                    }
                    if displayed.isEmpty {
                        Text(emptyEventsText)
                            .font(.subheadline).foregroundStyle(Palette.muted).padding(.vertical, 12)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(displayed.enumerated()), id: \.element.id) { index, event in
                                if index == 0 || !Calendar.current.isDate(event.occurredAt, inSameDayAs: displayed[index - 1].occurredAt) {
                                    Caption(text: event.occurredAt.formatted(date: .abbreviated, time: .omitted)).padding(.bottom, 18)
                                }
                                TimelineEventRow(event: event, selectedID: $selectedID, hasNext: index < displayed.count - 1)
                            }
                        }
                    }
                    if !showEarlier && filtered.count > displayed.count {
                        Button("Show \(filtered.count - displayed.count) earlier events") { showEarlier = true }
                            .font(.subheadline).frame(maxWidth: .infinity).padding(14)
                            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                Text("Audio stays on the Listener. Times shown in this iPhone’s time zone.")
                    .font(.caption).foregroundStyle(Palette.muted).frame(maxWidth: .infinity)
            }.padding(24)
        }
        .background(Palette.background).foregroundStyle(.white)
        .navigationTitle("Timeline").navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Palette.background, for: .navigationBar)
        .refreshable { await model.refreshTimeline() }
        .task {
            while !Task.isCancelled {
                if phase == .active { await model.refreshTimeline() }
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
            }
        }
        .sheet(item: $selectedCoverage) { segment in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Label(segment.state.title, systemImage: coverageIcon(segment.state))
                            .font(.title2.weight(.semibold)).foregroundStyle(coverageColor(segment.state))
                        Text("\(segment.start.formatted(date: .abbreviated, time: .standard)) – \(segment.end.formatted(date: .abbreviated, time: .standard))")
                            .font(.subheadline.monospacedDigit())
                        Text(coverageDetail(segment)).font(.body)
                        if segment.state == .updatesMissing {
                            if let lastUpdate = missingHeartbeat(for: segment)?.endAt {
                                Text("Last Listener update: \(lastUpdate.formatted(date: .abbreviated, time: .standard)).")
                            }
                            if events.contains(where: { $0.occurredAt == segment.end && ($0.coverageState == .monitoring || $0.coverageState == .stopped) }) {
                                Text("Updates resumed: \(segment.end.formatted(date: .abbreviated, time: .standard)).")
                            } else {
                                Text("No resumed updates are recorded in this interval.")
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }.background(Palette.background).foregroundStyle(.white)
                    .navigationTitle("Timeline status").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedCoverage = nil } } }
            }.presentationDetents([.medium, .large])
        }
        .onChange(of: filter) { _, category in
            if let selected = events.first(where: { $0.id == selectedID }), selected.category == category { showEarlier = true }
            else { selectedID = nil; showEarlier = false }
        }
        .onChange(of: phase) { _, value in if value == .active { Task { await model.refreshTimeline() } } }
    }
    private var statusActive: Bool { model.role == .listener ? model.monitoring : !sharedStatusUnavailable && model.parentOnline }
    private var statusText: String {
        if sharedStatusUnavailable { return model.loadingTimeline && model.timeline == nil ? "Loading timeline…" : "Status unavailable" }
        return model.role == .listener ? (model.monitoring ? "Monitoring on this iPhone" : model.recoveringAudio ? "Microphone interrupted" : "Monitoring stopped") : model.nurseryConnection
    }
    private func statistic(_ count: Int, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(count, format: .number).font(.system(.title2, design: .rounded).weight(.medium)).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(Palette.muted)
        }.accessibilityElement(children: .combine)
    }
    private var overview: some View {
        Panel {
            HStack { Text("Last 12 hours").font(.subheadline.weight(.semibold)); Spacer(); Text("Newest at right").font(.caption2).foregroundStyle(Palette.muted) }
            HStack(spacing: 8) {
                Color.clear.frame(width: 40, height: 1)
                HStack(spacing: 0) {
                    ForEach(0..<5) { index in
                        Text(start.addingTimeInterval(Double(index) * 3 * 3600).formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity, alignment: index == 0 ? .leading : index == 4 ? .trailing : .center)
                    }
                }
            }
            HStack(spacing: 8) {
                Text("Status").font(.caption2).foregroundStyle(Palette.muted).frame(width: 40, alignment: .leading)
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ForEach(coverage) { segment in
                            Button { selectedCoverage = segment } label: {
                                Rectangle().fill(coverageColor(segment.state))
                                    .frame(width: max(0, geometry.size.width * segment.end.timeIntervalSince(segment.start) / (12 * 3600)), height: 24)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel("\(segment.state.title), \(segment.start.formatted(date: .omitted, time: .shortened)) to \(segment.end.formatted(date: .omitted, time: .shortened))")
                                .accessibilityHint("Show details for this interval")
                                .accessibilityIdentifier("timelineCoverage_\(segment.state.rawValue)")
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 3))
                }.frame(height: 24)
            }
            lane("Sound", category: .crying, color: Palette.amber, kinds: ["cry_started"])
            lane("Alerts", category: .alerts, color: .blue, kinds: ["alert", "test_alert", "connection_alert"])
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(TimelineCoverage.State.allCases.filter { $0 != .unverified || coverage.contains(where: { $0.state == .unverified }) }, id: \.self) { state in
                    Button {
                        selectedCoverage = coverage.first { $0.state == state }
                    } label: {
                        legend(state.title, color: coverageColor(state))
                    }.buttonStyle(.plain).disabled(!coverage.contains { $0.state == state })
                        .accessibilityLabel(state.title).accessibilityIdentifier("timelineLegend_\(state.rawValue)")
                }
            }
            Text("Tap a status interval for details.").font(.caption2).foregroundStyle(Palette.muted)

            if let event = events.first(where: { $0.id == selectedID }) {
                Text("\(event.occurredAt.formatted(date: .omitted, time: .standard)) · \(event.timelineTitle)")
                    .font(.caption).foregroundStyle(Palette.muted).accessibilityAddTraits(.updatesFrequently)
            }
        }
    }
    private func coverageColor(_ state: TimelineCoverage.State) -> Color {
        switch state {
        case .monitoring: Palette.mint.opacity(0.7)
        case .standby: Palette.lavender.opacity(0.5)
        case .stopped: Palette.muted.opacity(0.5)
        case .noHistory: Color.gray.opacity(0.25)
        case .updatesMissing: Palette.amber
        case .unavailable: Color.purple
        case .unverified: Color.orange
        }
    }
    private func coverageIcon(_ state: TimelineCoverage.State) -> String {
        switch state {
        case .monitoring: "mic"
        case .standby: "pause.circle"
        case .stopped: "stop.circle"
        case .noHistory: "clock.badge.questionmark"
        case .updatesMissing: "wifi.slash"
        case .unavailable: "exclamationmark.icloud"
        case .unverified: "mic.slash"
        }
    }
    private func missingHeartbeat(for segment: TimelineCoverage) -> TimelineEvent? {
        events.filter { $0.kind == "heartbeat_missing" && ($0.endAt ?? $0.occurredAt) <= segment.start }
            .max { ($0.endAt ?? $0.occurredAt) < ($1.endAt ?? $1.occurredAt) }
    }
    private func coverageDetail(_ segment: TimelineCoverage) -> String {
        switch segment.state {
        case .monitoring: "The Listener reported active monitoring during this interval."
        case .standby: "The microphone remained active for remote resume. Sound samples were discarded without detection or sharing."
        case .stopped: "The Listener reported stopped or interrupted sound detection during this interval."
        case .noHistory:
            model.timeline?.truncated == true
                ? "The history limit omitted some events. There is not enough history to reconstruct monitoring coverage reliably. Retained events still appear in the event log."
                : "No monitoring history was recorded for this interval. It may be before timeline logging began or before the first recorded monitoring state. Missing history does not establish that the Listener was disconnected or stopped."
        case .updatesMissing: "The backend stopped receiving expected Listener heartbeats for more than three minutes. The gap starts at the last received heartbeat. Monitoring may have continued locally; a missed update does not confirm that the microphone stopped."
        case .unavailable: "This Parent iPhone could not get a fresh timeline from the backend. Earlier fetched history remains visible. This interval does not establish whether the Listener lost its connection or stopped monitoring."
        case .unverified: "The Listener relaunched after an active session. Monitoring after its last recorded audio sample could not be verified. This is separate from a missing-heartbeat report."
        }
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 6, height: 6); Text(title).font(.caption2).foregroundStyle(Palette.muted) }
    }
    private func lane(_ title: String, category: TimelineCategory, color: Color, kinds: Set<String>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption2).foregroundStyle(Palette.muted).frame(width: 40, alignment: .leading)
            GeometryReader { geometry in
                Rectangle().fill(Palette.muted.opacity(0.2)).frame(height: 1).position(x: geometry.size.width / 2, y: 22)
                ForEach(visibleEvents.filter { kinds.contains($0.kind) }) { event in
                    Button {
                        selectedID = event.id; filter = category; showEarlier = true
                    } label: {
                        RoundedRectangle(cornerRadius: category == .alerts ? 5 : 2).fill(color)
                            .frame(width: 6, height: category == .alerts ? 6 : 12).frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .position(x: min(geometry.size.width - 3, max(3, geometry.size.width * event.occurredAt.timeIntervalSince(start) / (12 * 3600))), y: 22)
                        .accessibilityLabel("\(event.timelineTitle), \(event.occurredAt.formatted(date: .omitted, time: .standard))")
                }
            }.frame(height: 44)
        }
    }
}

private struct TimelineEventRow: View {
    let event: TimelineEvent
    @Binding var selectedID: String?
    let hasNext: Bool
    @State private var expanded = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: event.timelineIcon).font(.system(size: 15)).foregroundStyle(event.timelineColor)
                    .frame(width: 30, height: 30).background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
                if hasNext { Rectangle().fill(Palette.muted.opacity(0.2)).frame(width: 1).frame(maxHeight: .infinity) }
            }.frame(width: 30)
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(event.occurredAt.formatted(date: .abbreviated, time: .standard)).font(.caption.monospacedDigit())
                    Text(event.timelineDetail).font(.footnote)
                    if (event.count ?? 1) > 1, let last = event.endAt {
                        Text("\(event.count ?? 1) alerts in this group. Last event: \(last.formatted(date: .omitted, time: .standard)).").font(.footnote)
                    }
                }.foregroundStyle(Palette.muted).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12)).padding(.vertical, 8)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(event.timelineTitle).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                        Spacer(minLength: 6)
                        Text(event.occurredAt, style: .time).font(.caption2).monospacedDigit().foregroundStyle(Palette.muted)
                    }
                    Text(event.timelineSubtitle).font(.caption).foregroundStyle(Palette.muted)
                }
            }.tint(Palette.muted).padding(.bottom, 18)
                .accessibilityIdentifier("timelineEvent_\(event.kind)")
        }.fixedSize(horizontal: false, vertical: true)
            .onChange(of: selectedID) { _, id in if id == event.id { expanded = true } }
            .onAppear { if selectedID == event.id { expanded = true } }
    }
}

private extension TimelineEvent {
    var destination: String { target == "watch" ? "Apple Watch" : target == "phone" ? "Parent iPhone" : "Receiver" }
    var timelineTitle: String {
        switch kind {
        case "monitoring_observed": "Monitoring reported active"
        case "standby_observed": "Standby reported"
        case "monitoring_paused": "Monitoring paused · Microphone active"
        case "stopped_observed": "Monitoring reported stopped"
        case "monitoring_started": "Monitoring started"
        case "monitoring_stopped": "Monitoring stopped"
        case "monitoring_unverified": "Monitoring interrupted"
        case "audio_interrupted": "Microphone interrupted"
        case "audio_resumed": "Microphone resumed"
        case "cry_started": "Crying-like sound detected"
        case "cry_ended": "Crying-like sound ended"
        case "alert_acknowledged": "Alert acknowledged"
        case "test_acknowledged": "Test acknowledged"
        case "heartbeat_missing": "Listener updates missing"
        case "connection_restored": "Connection restored"
        case "network_lost": "Listener internet unavailable"
        case "network_restored": "Listener internet restored"
        case "power_connected": "Listener connected to power"
        case "power_disconnected": "Listener unplugged"
        case "battery_low": "Listener battery low"
        case "alert", "test_alert", "connection_alert":
            switch status {
            case "sent": kind == "test_alert" ? "Test notification sent" : kind == "connection_alert" ? "Connection alert sent" : "Alert sent · \(destination)"
            case "failed": "Alert delivery failed"
            case "uncertain": "Alert delivery uncertain"
            case "blocked": "Alert blocked"
            case "sending": "Sending alert"
            default: "Alert queued"
            }
        default: "Monitoring status updated"
        }
    }
    var timelineSubtitle: String {
        switch kind {
        case "monitoring_observed", "stopped_observed", "standby_observed": "Backend observation · Exact transition time unknown"
        case "cry_ended": endAt.map { "Episode lasted \(durationText(occurredAt.timeIntervalSince($0)))" } ?? "Quiet period confirmed"
        case "alert", "test_alert": "\(count ?? 1) \((count ?? 1) == 1 ? "alert" : "alerts, including reminders") · \(destination)"
        case "connection_alert": "Connection notice · \(status ?? "pending")"
        case "alert_acknowledged": endAt.map { "Crying alerts snoozed until \($0.formatted(date: .omitted, time: .standard))" } ?? "Confirmed by parent"
        case "heartbeat_missing": "Expected heartbeats stopped arriving"
        case "connection_restored": "Listener updates resumed"
        case "network_lost": "Alerts may be delayed · Recorded on Listener"
        case "monitoring_unverified": "Previous session could not be verified after relaunch"
        case "audio_interrupted": "Sound detection paused"
        case "power_disconnected": "Running on battery"
        default: "Recorded on Listener"
        }
    }
    var timelineDetail: String {
        switch kind {
        case "alert", "test_alert", "connection_alert":
            if status == "sent" { return "Apple accepted this notification for delivery. Acceptance does not confirm receipt or a wrist tap. Repeated notifications with the same episode, destination and status are grouped. Tests are labelled separately." }
            return "Current delivery status: \(status ?? "pending"). The timestamp is when the alert was created; it is not a confirmed delivery time. A queued, blocked, failed or uncertain notification is not shown as sent."
        case "alert_acknowledged": return "The backend recorded an explicit parent acknowledgement. Outstanding crying alerts were acknowledged. \(endAt.map { "Crying alerts were snoozed until \($0.formatted(date: .omitted, time: .standard))." } ?? "") Connection-loss alerts remain independent."
        case "monitoring_observed", "stopped_observed", "standby_observed": return "The backend received this monitoring state at the displayed time. It does not establish the exact time the Listener started or stopped."
        case "test_acknowledged": return "A parent acknowledged this test notification. It did not snooze real crying alerts."
        case "heartbeat_missing": return "No heartbeat arrived for more than three minutes. \(endAt.map { "Last update: \($0.formatted(date: .omitted, time: .standard))." } ?? "") Monitoring may have continued locally, but its status could not be verified. The overview marks the interval since that last update as Listener updates missing."
        case "connection_restored": return "Fresh Listener updates resumed. \(endAt.map { "The previous update was at \($0.formatted(date: .omitted, time: .standard))." } ?? "") This records when the backend observed recovery."
        case "cry_started": return "Sustained sound was confirmed on the Listener. This records crying-like sound activity; it does not identify every cry or distinguish all other room sounds. Audio remains on the Listener."
        case "cry_ended": return "The recorded sound episode ended after quiet was confirmed or capture stopped. This is sound activity, not a sleep state."
        case "monitoring_unverified": return "The app relaunched after an active session. Its last sample marks the start of an unverified interval. Monitoring needs to be restarted; no unobserved time is counted as sound detection."
        case "monitoring_paused": return "Detection was paused while the microphone remained active for remote resume. Sound samples were discarded without storage or transmission."
        case "monitoring_stopped", "audio_interrupted": return "Sound detection was inactive from this recorded transition until monitoring or microphone capture resumed."
        case "network_lost", "network_restored": return "The Listener recorded an internet-path change. This describes its connection, independently of whether its microphone kept monitoring. Events recorded offline sync when connectivity returns."
        case "battery_low": return "The Listener reported less than 20% battery while disconnected from power."
        default: return "The Listener recorded this state change. Local timestamps are displayed in this iPhone’s time zone."
        }
    }
    var timelineIcon: String {
        switch kind {
        case "monitoring_started", "audio_resumed": "play"
        case "monitoring_paused", "standby_observed": "pause"
        case "monitoring_stopped": "stop"
        case "audio_interrupted", "monitoring_unverified": "mic.slash"
        case "cry_started", "cry_ended": "waveform"
        case "alert_acknowledged", "test_acknowledged": "checkmark.circle"
        case "heartbeat_missing", "network_lost": "wifi.slash"
        case "connection_restored", "network_restored": "wifi"
        case "power_connected": "powerplug"
        case "power_disconnected", "battery_low": "battery.25percent"
        default: "bell.badge"
        }
    }
    var timelineColor: Color {
        if ["alert_acknowledged", "test_acknowledged", "connection_restored", "cry_ended", "power_connected"].contains(kind) { return Palette.mint }
        switch category { case .crying, .connection: return Palette.amber; case .alerts: return status == "sent" ? .cyan : Palette.amber; default: return Palette.mint }
    }
}
