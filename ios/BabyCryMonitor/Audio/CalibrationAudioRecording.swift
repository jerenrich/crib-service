import AVFoundation
import Foundation
import Observation

@MainActor @Observable final class CalibrationAudioRecording {
    private(set) var enabled: Bool
    private(set) var status = "Audio recording off"
    private(set) var savedBytes: Int64 = 0
    private(set) var droppedBuffers = 0
    private(set) var busy = false
    @ObservationIgnored let writer: CalibrationAudioWriter
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var lastExport: URL?
    private static let preference = "saveCalibrationAudio"

    init(defaults: UserDefaults = .standard, directory: URL? = nil, exportDirectory: URL? = nil) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.preference)
        let events = AsyncStream<CalibrationAudioWriter.State>.makeStream(bufferingPolicy: .bufferingNewest(16))
        writer = CalibrationAudioWriter(directory: directory, exportDirectory: exportDirectory, emit: { events.continuation.yield($0) })
        writer.removeStaleExports()
        writer.setEnabled(enabled)
        updates = Task { [weak self] in
            for await state in events.stream {
                guard let self else { return }
                guard writer.isCurrent(state.revision) else { continue }
                status = state.status; savedBytes = state.bytes; droppedBuffers = state.dropped
                if state.failed { enabled = false; defaults.set(false, forKey: Self.preference) }
            }
        }
    }
    deinit { updates?.cancel() }
    func setEnabled(_ value: Bool) {
        enabled = value; defaults.set(value, forKey: Self.preference); writer.setEnabled(value)
    }
    func refresh() { writer.refresh() }
    func prepareExport(including additionalFiles: @MainActor () async throws -> [URL] = { [] }) async throws -> [URL] {
        guard !busy else { throw CalibrationAudioWriter.RecordingError.operationInProgress }
        busy = true
        defer { busy = false }
        let snapshot = try await writer.snapshot()
        defer { try? FileManager.default.removeItem(at: snapshot) }
        try Task.checkCancellation()
        let folder = writer.exportDirectory.appendingPathComponent("Crib-Calibration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("calibration-audio.zip")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: folder) } }
        let worker = Task.detached(priority: .utility) {
            let files = try FileManager.default.contentsOfDirectory(at: snapshot, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            try CalibrationAudioArchive.write(files: files, to: destination)
        }
        try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        let additional = try await additionalFiles()
        try Task.checkCancellation()
        // Analysis exports are immutable files on the same temporary volume.
        // Own links before yielding: Diagnostics may delete its previous export
        // folder as soon as another export is prepared.
        var retained: [URL] = []
        for source in additional {
            let link = folder.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.linkItem(at: source, to: link)
            retained.append(link)
        }
        if let lastExport { try removeExport(at: lastExport) }
        lastExport = folder
        completed = true
        return [destination] + retained
    }
    func deleteAll() async throws {
        guard !busy else { throw CalibrationAudioWriter.RecordingError.operationInProgress }
        busy = true
        defer { busy = false }
        try await writer.deleteAll()
        // Include abandoned export files as well as the last completed export.
        // Propagate failures so Delete cannot report success with audio left.
        try removeExport(at: writer.exportDirectory)
        lastExport = nil
    }
    private func removeExport(at url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { }
    }
}

/// Only admission/copying happens on the microphone callback. Encoding, retention
/// and all file operations belong to queue. At most 32 mono PCM copies are queued.
final class CalibrationAudioWriter: @unchecked Sendable {
    struct State: Sendable { let status: String; let bytes: Int64; let dropped: Int; let revision: Int; var failed = false }
    struct Segment: Codable {
        var schema = 1
        let file: String
        let captureID: UUID
        let startedAt: Date
        let sourceStartFrame: Int64?
        let sampleRate: Double
        let sourceChannels: UInt32
        let voiceProcessing: Bool
        var frames: Int64 = 0
        var complete = false
        var droppedBuffersBefore: Int
        var codec = "aac_lc"
        var targetBitRate = 48_000
        var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
    private struct OwnedBuffer: @unchecked Sendable { let value: AVAudioPCMBuffer }
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var enabled = false
    private var epoch = 0
    private var pending = 0
    private var dropped = 0
    private var activeCapture: UUID?
    private let directory: URL
    private let emit: @Sendable (State) -> Void
    // Queue-owned state:
    private var file: AVAudioFile?
    private var segment: Segment?
    private var expectedFrame: Int64?
    private var segmentRevision: Int?
    private var bytes: Int64 = 0
    private var totalDropped = 0
    static let maximumBytes: Int64 = 1_073_741_824
    static let minimumFreeBytes: Int64 = 500 * 1_024 * 1_024
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    let exportDirectory: URL
    private let writeAudio: @Sendable (AVAudioFile, AVAudioPCMBuffer) throws -> Void

    init(directory: URL? = nil, queue: DispatchQueue = DispatchQueue(label: "CribService.CalibrationAudio", qos: .utility),
         exportDirectory: URL? = nil,
         writeAudio: @escaping @Sendable (AVAudioFile, AVAudioPCMBuffer) throws -> Void = { try $0.write(from: $1) },
         emit: @escaping @Sendable (State) -> Void = { _ in }) {
        self.queue = queue
        self.writeAudio = writeAudio
        self.exportDirectory = exportDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("CalibrationAudioExports", isDirectory: true)
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CalibrationAudio", isDirectory: true)
        self.emit = emit
    }
    func setEnabled(_ value: Bool) {
        lock.lock(); enabled = value; epoch += 1; let revision = epoch
        queue.async { [self] in
            guard isCurrent(revision) else { return }
            do { try finish(); try prepareDirectory(); try prune(); publish(value ? "Waiting for microphone" : "Audio recording off") }
            catch { fail(error, revision: revision) }
        }
        lock.unlock()
    }
    func beginCapture() -> UUID {
        let id = UUID(); lock.lock(); activeCapture = id; lock.unlock(); return id
    }
    func endCapture(_ id: UUID) {
        lock.lock()
        let lost: Int
        if activeCapture == id { activeCapture = nil; lost = dropped; dropped = 0 } else { lost = 0 }
        // Serialize admission and the close marker. A callback still copying
        // when Stop arrives must not enqueue a new file after this marker.
        queue.async { [self] in
            totalDropped += lost
            do {
                if segment?.captureID == id { try finish(); try prune() }
                publish(isEnabled ? "Waiting for microphone" : "Audio recording off")
            } catch { fail(error) }
        }
        lock.unlock()
    }
    private var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
    private var hasCapture: Bool { lock.lock(); defer { lock.unlock() }; return activeCapture != nil }
    func isCurrent(_ revision: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return epoch == revision }

    func consume(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime, captureID: UUID,
                 voiceProcessing: Bool, capturedAt: Date = Date()) {
        guard buffer.frameLength > 0, buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0,
              let channels = buffer.floatChannelData, buffer.format.channelCount > 0 else { return }
        lock.lock()
        guard enabled, activeCapture == captureID else { lock.unlock(); return }
        guard pending < 32 else { dropped += 1; lock.unlock(); return }
        let revision = epoch; let lost = dropped; dropped = 0; pending += 1; lock.unlock()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1),
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let destination = mono.floatChannelData?[0] else {
            lock.lock(); pending -= 1; dropped += lost + 1; lock.unlock(); return
        }
        mono.frameLength = buffer.frameLength
        let count = Int(buffer.format.channelCount)
        for frame in 0..<Int(buffer.frameLength) {
            var value: Float = 0
            for channel in 0..<count {
                value += buffer.format.isInterleaved ? channels[0][frame * count + channel] : channels[channel][frame]
            }
            destination[frame] = value / Float(count)
        }
        let owned = OwnedBuffer(value: mono)
        let start = capturedAt.addingTimeInterval(-Double(buffer.frameLength) / format.sampleRate)
        let sourceFrame = time.isSampleTimeValid ? time.sampleTime : nil
        let sourceChannels = buffer.format.channelCount
        lock.lock()
        guard activeCapture == captureID, enabled, epoch == revision else {
            pending -= 1; dropped += lost; lock.unlock(); return
        }
        queue.async { [self, owned] in
            defer { lock.lock(); pending -= 1; lock.unlock() }
            guard isCurrent(revision), isEnabled else { return }
            totalDropped += lost
            do {
                let discontinuity = sourceFrame.flatMap { frame in expectedFrame.map { frame != $0 } } ?? false
                // A continuous sample clock does not imply a continuous wall
                // clock. Split after clock adjustments so CSV joins stay valid.
                let clockGap = segment.map {
                    abs(start.timeIntervalSince($0.startedAt) - Double($0.frames) / $0.sampleRate) > 2
                } == true
                if let segment, segment.captureID != captureID || segment.sampleRate != format.sampleRate ||
                    segment.voiceProcessing != voiceProcessing || segmentRevision != revision || discontinuity || clockGap || lost > 0 ||
                    Double(segment.frames) / segment.sampleRate >= 60 {
                    try finish()
                }
                if file == nil {
                    try prepareDirectory(); try prune(); try checkSpace()
                    let name = "\(Int(start.timeIntervalSince1970 * 1000))-\(UUID().uuidString).m4a"
                    let url = directory.appendingPathComponent(name)
                    // Mono at the native sample rate preserves bandwidth; the
                    // AVAudioFile encoder performs only AAC compression.
                    file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 48_000], commonFormat: .pcmFormatFloat32, interleaved: false)
                    try protect(url)
                    segment = Segment(file: name, captureID: captureID, startedAt: start,
                        sourceStartFrame: sourceFrame, sampleRate: format.sampleRate, sourceChannels: sourceChannels,
                        voiceProcessing: voiceProcessing, droppedBuffersBefore: lost)
                    segmentRevision = revision
                    try writeMetadata(); publish("Saving calibration audio")
                }
                if let file { try writeAudio(file, owned.value) }
                segment?.frames += Int64(owned.value.frameLength)
                expectedFrame = sourceFrame.map { $0 + Int64(owned.value.frameLength) }
            } catch { fail(error, revision: revision) }
        }
        lock.unlock()
    }
    private func finish() throws {
        file = nil // Finalizes the MPEG-4 container before marking it complete.
        if segment != nil { segment?.complete = true; try writeMetadata() }
        segment = nil; expectedFrame = nil; segmentRevision = nil
    }
    private func writeMetadata() throws {
        guard let segment else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .secondsSince1970
        let url = directory.appendingPathComponent(segment.file).deletingPathExtension().appendingPathExtension("json")
        try encoder.encode(segment).write(to: url, options: .atomic); try protect(url)
    }
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try protect(directory)
    }
    private func protect(_ url: URL) throws {
        var url = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
    private func checkSpace() throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        if let free = attributes[.systemFreeSize] as? NSNumber, free.int64Value < Self.minimumFreeBytes {
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }
    private func prune() throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        let entries = try files.map { url in (url, try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])) }
        // Prune an audio file and its sidecar together, including orphan files
        // left by termination. Never retain an index that points at pruned audio.
        let groups = Dictionary(grouping: entries) { $0.0.deletingPathExtension().lastPathComponent }
            .values.sorted {
                ($0.map { $0.1.contentModificationDate ?? .distantPast }.max() ?? .distantPast) <
                ($1.map { $0.1.contentModificationDate ?? .distantPast }.max() ?? .distantPast)
            }
        bytes = entries.reduce(0) { $0 + Int64($1.1.fileSize ?? 0) }
        let cutoff = Date().addingTimeInterval(-Self.retention)
        for group in groups {
            if group.contains(where: { $0.0.lastPathComponent == segment?.file }) { continue }
            let modified = group.map { $0.1.contentModificationDate ?? .distantPast }.max() ?? .distantPast
            if modified < cutoff || bytes > Self.maximumBytes {
                for (url, info) in group {
                    try FileManager.default.removeItem(at: url); bytes -= Int64(info.fileSize ?? 0)
                }
            }
        }
    }
    private func publish(_ status: String, failed: Bool = false) {
        lock.lock(); let revision = epoch; lock.unlock()
        emit(.init(status: status, bytes: bytes, dropped: totalDropped, revision: revision, failed: failed))
    }
    private func fail(_ error: any Error, revision: Int? = nil) {
        // Always abandon the failed segment, including a failure superseded by
        // a newer toggle. Otherwise its next finish() would mark it complete.
        file = nil; segment = nil; expectedFrame = nil; segmentRevision = nil
        lock.lock()
        if let revision, epoch != revision { lock.unlock(); return }
        enabled = false; epoch += 1; lock.unlock()
        publish("Recording stopped: \(error.localizedDescription) Alerts continue.", failed: true)
    }
    func refresh() {
        queue.async { [self] in
            do { try prepareDirectory(); try prune(); publish(file == nil ? (isEnabled ? "Waiting for microphone" : "Audio recording off") : "Saving calibration audio") }
            catch { fail(error) }
        }
    }
    func removeStaleExports() {
        queue.async { [self] in try? FileManager.default.removeItem(at: exportDirectory) }
    }
    func snapshot() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard !hasCapture else { throw RecordingError.microphoneActive }
                    try finish(); try prepareDirectory(); try prune()
                    let snapshot = exportDirectory.appendingPathComponent("CalibrationSnapshot-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
                    do {
                        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
                        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                        var included = 0; var omitted = 0
                        for json in files where json.pathExtension == "json" {
                            guard let info = try? decoder.decode(Segment.self, from: Data(contentsOf: json)), info.schema == 1, info.complete,
                                  info.file == json.deletingPathExtension().lastPathComponent + ".m4a",
                                  info.frames > 0, info.sampleRate.isFinite, info.sampleRate > 0,
                                  FileManager.default.fileExists(atPath: directory.appendingPathComponent(info.file).path) else { omitted += 1; continue }
                            for source in [json, directory.appendingPathComponent(info.file)] {
                                try FileManager.default.linkItem(at: source, to: snapshot.appendingPathComponent(source.lastPathComponent))
                            }
                            included += 1
                        }
                        guard included > 0 else { throw RecordingError.noAudio }
                        let readme = """
                        Crib Service calibration audio · schema 1
                        Complete segments: \(included). Incomplete/unreadable sidecars omitted: \(omitted).
                        Dropped input buffers this process: \(totalDropped). App termination or storage failure can leave uncounted gaps or orphan audio.
                        Mono AAC, target 48 kbit/s, native microphone sample rate; approximately one minute per segment.
                        JSON startedAt is Unix seconds (UTC), including fractional seconds, estimated from microphone buffer arrival. Duration = frames/sampleRate.
                        captureID identifies a microphone tap, NOT the separate capture IDs in the sound analysis CSV.
                        Join with the separately exported sound analysis CSV by UTC audio-window timestamps. Do not infer silence from gaps.
                        sourceStartFrame is the input sample clock when available; use frame continuity within a capture to check gaps. AAC encoder delay/padding may affect decoded alignment.
                        voiceProcessing marks echo processing: on while nursery sound plays, after it ends until capture is rebuilt, and throughout monitoring started with the nursery app open. This is the same processed microphone input used by the detectors, not unprocessed room audio.
                        AAC is lossy: use original logged dBFS for volume threshold/timer sweeps. Re-running a classifier on decoded audio is an approximation; validate final settings live.
                        Retention: 7 days / 1 GiB, oldest first. Export before expiry. Share only with intended recipients: audio may include private conversations. This export contains retained audio only; export sound analysis CSV alongside it for settings, scores, alerts and coverage.
                        """
                        try readme.write(to: snapshot.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
                        continuation.resume(returning: snapshot)
                    } catch { try? FileManager.default.removeItem(at: snapshot); throw error }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func deleteAll() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    guard !hasCapture else { throw RecordingError.microphoneActive }
                    try finish()
                    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                    bytes = 0; totalDropped = 0; publish(isEnabled ? "Waiting for microphone" : "Audio recording off")
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    enum RecordingError: LocalizedError {
        case microphoneActive, noAudio, operationInProgress
        var errorDescription: String? {
            switch self {
            case .microphoneActive: "Stop the microphone before exporting or deleting recordings."
            case .noAudio: "No completed calibration audio is available to export."
            case .operationInProgress: "Wait for the current calibration export or deletion to finish."
            }
        }
    }
}
