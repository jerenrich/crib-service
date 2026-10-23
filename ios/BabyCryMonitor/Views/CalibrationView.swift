import SwiftUI

struct CalibrationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var secondsRemaining = 0
    var body: some View {
        NavigationStack {
            Form {
                Section("1. Check normal room noise") {
                    Text("Place the Listener where you intend to use it. Leave normal fans or white noise on. Keep the room otherwise quiet for 10 seconds.")
                    Text("Monitoring stays stopped during this local sound check. No episodes or notifications are created.").font(.footnote)
                    Button("Measure background") { Task { await model.beginCalibration() } }
                        .disabled(model.monitoring || model.starting || model.recoveringAudio || ["background", "sample", "waiting"].contains(model.calibrationPhase))
                    if let background = model.calibration.backgroundLevel {
                        Text("Background: \(background, specifier: "%.0f") dBFS")
                    }
                }
                Section("2. Try a sample sound") {
                    Text("For 8 seconds, make a representative sound near the intended sound source. Use ordinary volume. The check compares sound levels; it cannot identify crying.")
                    Button("Measure sample sound") { model.beginCalibrationSample() }
                        .disabled(model.calibrationPhase != "waiting")
                    if let sample = model.calibration.sampleLevel { Text("Typical sample: \(sample, specifier: "%.0f") dBFS") }
                }
                if ["background", "sample"].contains(model.calibrationPhase) {
                    Section { ProgressView("Measuring · \(secondsRemaining) seconds remaining") }
                }
                if model.calibrationPhase == "complete" {
                    Section("Results") {
                        if let threshold = model.calibration.recommendedThreshold {
                            Text("Try a fixed threshold of \(threshold, specifier: "%.0f") dBFS. In this check it clears background noise by at least 8 dB and stays at least 2 dB below the typical sample.")
                            Button("Use recommended threshold") {
                                var config = model.configuration; config.absoluteThreshold = threshold
                                model.saveSettings(config); dismiss()
                            }
                        }
                        Text("The threshold stays fixed after you apply it. Sound must reach that level across the confirmation window. Brief or quiet sounds may not qualify. Repeat this check if the phone moves or room noise changes.").font(.footnote)
                    }
                }
                if let message = model.calibrationMessage { Section { Text(message) } }
                if model.monitoring { Section { Text("Stop monitoring on the Listener before running this check.") } }
            }.navigationTitle("Check room sound")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task(id: model.calibrationPhase) {
                    let phase = model.calibrationPhase
                    guard phase == "background" || phase == "sample" else { return }
                    secondsRemaining = phase == "background" ? 10 : 8
                    do {
                        while secondsRemaining > 0 { try await Task.sleep(for: .seconds(1)); secondsRemaining -= 1 }
                        if phase == "background" { model.finishCalibrationBackground() } else { model.finishCalibrationSample() }
                    } catch { }
                }
                .onDisappear { model.cancelCalibration() }
        }.tint(Palette.mint)
    }
}
