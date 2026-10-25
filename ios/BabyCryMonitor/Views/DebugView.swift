import SwiftUI
import Observation

@MainActor @Observable final class SimulationModel {
    var engine = CrySessionManager(clock: SimulationClock(now: Date(timeIntervalSince1970: 1_700_000_000)))
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    var loud = false
    var events: [CryAlert] = []
    let listener = UUID()
    func advance(_ seconds: Double) {
        for _ in 0..<Int(seconds * 4) {
            now = now.addingTimeInterval(0.25)
            events += engine.consume(AudioLevelSample(timestamp: now, dbFS: loud ? -20 : -65), listenerId: listener)
        }
    }
    func trigger() { loud = true; advance(6); advance(engine.snapshot.configuration.alertDuration) }
}
struct DebugView: View {
    @Environment(AppModel.self) private var model
    @State private var simulation = SimulationModel()
    @State private var benchmarkReport: URL?
    var body: some View {
        Form {
            Section("Live diagnostics") {
                LabeledContent("Threshold", value: String(format: "%.1f dBFS", model.threshold))
                LabeledContent("Current", value: String(format: "%.1f dBFS", model.currentDBFS))
                LabeledContent("Audio", value: model.audioStatus)
                Text("Device: \(model.listenerID)").font(.caption).textSelection(.enabled)
                Text("Backend: \(model.backendURL.isEmpty ? "Not configured" : model.backendURL)").font(.caption)
                Text("Pending alerts: \(model.snapshot.pending.count)")
                Text("Failed alert deliveries: \(model.snapshot.failedAlerts.count)")
            }
            if model.role == .listener {
                Section("Real push test") {
                    Button(model.sendingTestPush ? "Sending test push…" : "Send test push") {
                        Task { await model.sendTestPush() }
                    }.disabled(!model.paired || model.sendingTestPush)
                        .accessibilityIdentifier("diagnosticsSendTestPush")
                    Text("Sends a real, silent notification marked as a test to the paired Parent, even while monitoring is stopped.").font(.footnote)
                    if !model.paired { Text("Pair with a Parent first.").font(.footnote) }
                    if let status = model.testPushStatus { Text(status).font(.footnote) }
                }
            }
            if model.role == .parent {
                Section("Background benchmark · Optional") {
                    Text(model.log.benchmark.enabled ? "Recording · Stops automatically after 24 hours" : "Not recording")
                    Text("Observations saved: \(model.log.benchmark.entryCount)")
                    if !model.log.benchmark.persistenceAvailable {
                        Text("Storage unavailable. Export before closing the app.").foregroundStyle(.orange)
                    }
                    Picker("Test scenario", selection: Binding(get: { model.log.benchmark.scenario }, set: { model.log.benchmark.mark($0) })) {
                        ForEach(BackgroundBenchmark.Scenario.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if model.log.benchmark.enabled {
                        Button("Stop benchmark") { model.log.benchmark.stop() }
                    } else {
                        Button("Start 24-hour benchmark") { model.startBackgroundBenchmark() }
                            .accessibilityIdentifier("startBackgroundBenchmark")
                    }
                    Button("Prepare benchmark report") {
                        do {
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Crib-Service-Background-Benchmark-\(UUID().uuidString).txt")
                            let report = model.log.benchmark.report + "\n\n" + (model.refreshExperiment?.log.report() ?? "")
                            try report.write(to: url, atomically: true, encoding: .utf8)
                            benchmarkReport = url
                        } catch { model.error = "Could not prepare benchmark report. Try again." }
                    }
                    if let benchmarkReport { ShareLink("Share prepared benchmark report", item: benchmarkReport) }
                    Text("Select a scenario before switching apps or locking the phone. Start a podcast, then return here to test playback with Monitor visible. The scenario is a manual label; this app cannot identify which other app you open.")
                        .font(.footnote)
                    Text("Records execution samples about every 5 seconds while executing, every existing status request, and simulated 30/60/120-second quiet deadlines. Adds no network requests or background runtime and creates no alarms. Gaps cannot prove why execution stopped. Reports remain local, retain up to 50,000 observations, and include timestamps, random run identifiers, battery/network state and server request references. Prepare a new report after each trial; review before sharing.")
                        .font(.footnote)
                }
            }
            if model.role == .parent, let experiment = model.refreshExperiment {
                Section("Background App Refresh experiment") {
                    Text(experiment.log.enabled ? "Enabled · 24-hour experiment" : "Off")
                    LabeledContent("iOS background refresh", value: experiment.availability)
                    if !experiment.registrationSucceeded { Text("Background task registration unavailable.").foregroundStyle(.orange) }
                    if !experiment.log.persistenceAvailable { Text("Storage unavailable. Export before closing the app.").foregroundStyle(.orange) }
                    Text("Recorded scheduler requests: \(experiment.log.attempts.count)")
                    if let pending = experiment.log.pending, let earliest = pending.earliestBeginAt {
                        Text("Pending · Earliest start \(earliest.formatted(date: .omitted, time: .standard))")
                    }
                    Button(experiment.log.enabled ? "Stop refresh experiment" : "Start 60-second refresh experiment") {
                        Task {
                            if !experiment.log.enabled { model.startBackgroundBenchmark() }
                            await experiment.setEnabled(!experiment.log.enabled)
                        }
                    }.accessibilityIdentifier("backgroundRefreshExperiment")
                    Text("Requests a short task no earlier than 60 seconds later. iOS chooses when or whether it runs. One pending request is preserved; after delivery the next is requested. The task only logs locally, without network requests or alarms. This changes background execution opportunities, so compare these trials separately from the baseline. Stops at 24 hours when the app next executes. Results are included in Prepare benchmark report above; pending requests are reported as not yet observed, rather than proven never delivered.").font(.footnote)
                }
            }
            Section("Synthetic simulation · Local only") {
                Text("Uses an isolated detector. Simulation never sends alerts to the Worker or changes live monitoring.").font(.footnote)
                Text("\(simulation.engine.detector.state.rawValue) · \(durationText(simulation.engine.snapshot.current?.duration(at: simulation.now) ?? 0))")
                Text("Generated events: \(simulation.events.count)")
                Button("Simulate Cry Start") { simulation.loud = true; simulation.advance(6) }
                Button("Simulate Quiet") { simulation.loud = false; simulation.advance(0.25) }
                Button("Advance +30 sec") { simulation.advance(30) }
                Button("Advance +5 min") { simulation.advance(300) }
                Button("Trigger Threshold") { simulation.trigger() }.accessibilityIdentifier("simulationTriggerThreshold")
                Button("Reset Simulation") { simulation = SimulationModel() }
                Button("Preview silent local notification") {
                    Task {
                        await model.notifications.register()
                        if simulation.events.isEmpty { simulation.trigger() }
                        if let alert = simulation.events.last {
                            do { try await model.notifications.simulate(alert) } catch { model.error = error.localizedDescription }
                        }
                    }
                }
            }
            Section("Diagnostic log · Metadata only") {
                if !model.log.persistenceAvailable {
                    Text("Diagnostic log could not be saved. Export the current log before closing the app.").foregroundStyle(.orange)
                }
                Text("Contains app/build details, operational timestamps, request references and redacted exception details. No audio, tokens or pairing codes. Review before sharing.").font(.footnote)
                Button("Copy log") { UIPasteboard.general.string = model.log.export }
                ShareLink("Export diagnostic log", item: model.log.export)
                Text("The export also includes up to 30 days of Listener battery-drain samples for calibration.").font(.footnote)
                Text(model.log.recentExport).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
            }
        }.accessibilityIdentifier("diagnosticsForm").navigationTitle("Diagnostics")
    }
}
