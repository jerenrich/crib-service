import SwiftUI

struct CalibrationAudioSection: View {
    @Environment(AppModel.self) private var model
    let recording: CalibrationAudioRecording
    @State private var export: [URL] = []
    @State private var working = false
    @State private var confirmDelete = false
    @State private var failure: String?
    private var microphoneBusy: Bool { model.microphoneActive || model.starting || model.recoveringAudio || model.calibrationPhase == "background" || model.calibrationPhase == "sample" || model.calibrationPhase == "waiting" }

    var body: some View {
        Section {
            Toggle("Save audio on this iPhone", isOn: Binding(get: { recording.enabled }, set: { recording.setEnabled($0) }))
                .accessibilityIdentifier("saveCalibrationAudio")
                .disabled(working || recording.busy)
            Text(recording.status).font(.caption)
            LabeledContent("Saved audio & index", value: ByteCountFormatter.string(fromByteCount: recording.savedBytes, countStyle: .file))
            if recording.droppedBuffers > 0 {
                Text("Skipped input buffers: \(recording.droppedBuffers). Recordings contain gaps.").font(.caption).foregroundStyle(.orange)
            }
            Button(working ? "Preparing…" : "Prepare audio & analysis export") {
                working = true; failure = nil; export = []
                Task {
                    defer { working = false }
                    do {
                        export = try await recording.prepareExport { try await model.log.soundAnalysis.prepareExport() }
                    } catch { failure = error.localizedDescription }
                }
            }.disabled(working || recording.busy || microphoneBusy)
            if !export.isEmpty {
                ShareLink(items: export) { Text("Share prepared calibration export") }.disabled(working || recording.busy)
            }
            Button("Delete saved audio", role: .destructive) { confirmDelete = true }
                .disabled(working || recording.busy || microphoneBusy)
            if recording.busy && !working { Text("A calibration export or deletion is in progress.").font(.caption) }
            if microphoneBusy { Text("Stop the microphone to export or delete recordings.").font(.caption) }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
        } header: { Text("Calibration audio · Optional") } footer: {
            Text("Off by default. When enabled, saves all microphone audio, including private conversations, while this Listener's microphone is running, including standby and sound checks. Mono AAC uses about 216 MB per 10 hours. Keeps up to 7 days or 1 GiB; oldest files expire first. Stops saving below 500 MiB free space. Stored on this iPhone, excluded from backups, with no automatic upload. Export includes an audio ZIP plus sound-level, cry-score and alert logs. Turning this off keeps existing recordings; Delete saved audio removes them. Export before expiry or uninstalling.")
        }
        .task { recording.refresh() }
        .alert("Delete all saved calibration audio?", isPresented: $confirmDelete) {
            Button("Delete saved audio", role: .destructive) {
                working = true; failure = nil; export = []
                Task {
                    defer { working = false }
                    do { try await recording.deleteAll() } catch { failure = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes recordings and their audio index from this iPhone. Copies you have shared remain with their recipients. Sound analysis logs are retained separately.") }
    }
}
