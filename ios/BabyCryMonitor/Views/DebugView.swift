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
    var body: some View {
        Form {
            Section("Live diagnostics") {
                LabeledContent("Ambient", value: String(format: "%.1f dBFS", model.ambient))
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
                Button("Copy log") { UIPasteboard.general.string = model.log.export }
                ShareLink("Export diagnostic log", item: model.log.export)
                Text(model.log.export.isEmpty ? "No events yet." : model.log.export).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
            }
        }.accessibilityIdentifier("diagnosticsForm").navigationTitle("Diagnostics")
    }
}
