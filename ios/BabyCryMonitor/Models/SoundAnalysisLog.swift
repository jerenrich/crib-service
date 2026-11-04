import Foundation
import Observation

/// Continuous research telemetry has its own retention budget, independent of
/// the short operational diagnostic ring. No audio or device credentials enter it.
@MainActor @Observable final class SoundAnalysisLog {
    static let retentionDays = 42
    static let maximumBytes = 2 * 1024 * 1024 * 1024
    nonisolated static let header = "recorded_at,run_id,kind,capture_id,window_start_at,window_end_at,baby_crying_confidence,dbfs,threshold_dbfs,above_threshold,detector_state,alert_queued,episode_id,cry_started_at,alert_duration_s,quiet_reset_s,nursery_sound,app_active,detail\n"
    private(set) var persistenceAvailable = true
    private(set) var droppedRows = 0
    private(set) var status = "Waiting for monitoring"
    private(set) var latestConfidence: Double?
    private(set) var latestScoreAt: Date?
    private(set) var classifierStatus = "Waiting for monitoring"
    private var lastLevelAt: Date?
    private var liveCaptureID: UUID?
    private var liveCaptureStartedAt = Date.distantPast
    private var liveCaptureRunning = false
    private let runID = UUID()
    private let writer: SoundAnalysisLogWriter
    private var pending: [String] = []
    private var flushTask: Task<Void, Never>?
    private var reportedDroppedRows = 0
    private var lastFlush = ContinuousClock.now
    private static let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    init(directory: URL? = nil, retentionDays: Int = SoundAnalysisLog.retentionDays,
         maximumBytes: Int = SoundAnalysisLog.maximumBytes) {
        let folder = directory ?? (try? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true))
        writer = SoundAnalysisLogWriter(directory: folder?.appendingPathComponent("sound-analysis", isDirectory: true),
                                        retentionDays: retentionDays, maximumBytes: maximumBytes)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        append(kind: "run_start", at: Date(), detail: "schema=1;app=\(version);build=\(build);os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    }
    func level(_ sample: AudioLevelSample, configuration: MonitoringConfiguration, state: CryState,
               alertQueued: Bool, episode: CryEpisode?, nurserySound: NurserySound?, appActive: Bool) {
        guard sample.dbFS.isFinite, configuration.isValid else { return }
        if let lastLevelAt, sample.timestamp.timeIntervalSince(lastLevelAt) > 0.5 {
            append(kind: "level_gap", at: sample.timestamp,
                   detail: "unobserved_s=\(number(sample.timestamp.timeIntervalSince(lastLevelAt), digits: 3))")
        }
        lastLevelAt = sample.timestamp
        var row = emptyRow(kind: "level", at: sample.timestamp)
        row[7] = number(sample.dbFS, digits: 2); row[8] = number(configuration.absoluteThreshold, digits: 2)
        row[9] = sample.dbFS >= configuration.absoluteThreshold ? "1" : "0"
        row[10] = state.rawValue; row[11] = alertQueued ? "1" : "0"
        row[12] = episode?.id.uuidString.lowercased() ?? ""
        row[13] = episode.map { Self.date($0.startedAt) } ?? ""
        row[14] = number(configuration.alertDuration, digits: 2)
        row[15] = number(configuration.quietResetDuration, digits: 2)
        row[16] = nurserySound?.rawValue ?? "off"; row[17] = appActive ? "1" : "0"
        enqueue(row)
    }
    func classification(_ event: SoundClassificationEvent) {
        switch event {
        case let .started(id, at, rate, voiceProcessing):
            if at >= liveCaptureStartedAt {
                liveCaptureID = id; liveCaptureStartedAt = at; liveCaptureRunning = true
                latestConfidence = nil; latestScoreAt = nil; classifierStatus = "Listening for classifications"
            }
            var row = emptyRow(kind: "capture_start", at: at); row[3] = id.uuidString.lowercased()
            row[18] = "classifier=version1;window_s=2;overlap=0.5;sample_rate=\(number(rate, digits: 0));voice_processing=\(voiceProcessing)"
            enqueue(row)
        case .result(let score):
            guard score.confidence.isFinite, (0...1).contains(score.confidence), score.windowEnd >= score.windowStart else { return }
            if liveCaptureRunning, liveCaptureID == score.captureID,
               latestScoreAt.map({ score.windowEnd >= $0 }) ?? true {
                latestConfidence = score.confidence; latestScoreAt = score.windowEnd
                classifierStatus = "Receiving classifications"
            }
            var row = emptyRow(kind: "classification", at: score.observedAt)
            row[3] = score.captureID.uuidString.lowercased(); row[4] = Self.date(score.windowStart)
            row[5] = Self.date(score.windowEnd); row[6] = number(score.confidence, digits: 6)
            enqueue(row)
        case let .stopped(id, at):
            if liveCaptureID == id {
                liveCaptureRunning = false; latestConfidence = nil; latestScoreAt = nil
                classifierStatus = "Waiting for classifier audio"
            }
            var row = emptyRow(kind: "capture_stop", at: at); row[3] = id.uuidString.lowercased(); enqueue(row)
        case let .unavailable(at, failure, captureID, retryAfterSeconds, appActive):
            if captureID == liveCaptureID || (captureID == nil && !liveCaptureRunning) {
                liveCaptureRunning = false; latestConfidence = nil; latestScoreAt = nil
                classifierStatus = "Classifier unavailable; volume alerts continue"
            }
            var row = emptyRow(kind: "classifier_unavailable", at: at)
            row[3] = captureID?.uuidString.lowercased() ?? ""
            row[17] = appActive.map { $0 ? "1" : "0" } ?? ""
            row[18] = failure?.fields ?? ""
            if let retryAfterSeconds { row[18] += ";retry_after_s=\(retryAfterSeconds)" }
            enqueue(row)
        case .droppedEvents(let at):
            append(kind: "classifier_event_gap", at: at, detail: "dropped_events_at_least=1")
        case let .droppedBuffers(count, at):
            append(kind: "classifier_gap", at: at, detail: "dropped_buffers=\(max(0, count))")
        }
    }
    func classifierStatus(at now: Date) -> String {
        let lastObservation = latestScoreAt ?? liveCaptureStartedAt
        if liveCaptureRunning, now.timeIntervalSince(lastObservation) > 10 {
            return "No recent classifier results; volume alerts continue"
        }
        return classifierStatus
    }
    func monitoring(_ enabled: Bool, at: Date) {
        latestConfidence = nil; latestScoreAt = nil; lastLevelAt = nil
        liveCaptureID = nil; liveCaptureRunning = false; liveCaptureStartedAt = .distantPast
        classifierStatus = enabled ? "Waiting for microphone audio" : "Monitoring paused or stopped"
        append(kind: enabled ? "monitoring_start" : "monitoring_stop", at: at)
        if !enabled { Task { await flush() } }
    }
    private func append(kind: String, at: Date, detail: String = "") {
        var row = emptyRow(kind: kind, at: at); row[18] = detail; enqueue(row)
    }
    private func emptyRow(kind: String, at: Date) -> [String] {
        var row = Array(repeating: "", count: 19)
        row[0] = Self.date(at); row[1] = runID.uuidString.lowercased(); row[2] = kind
        return row
    }
    private static func date(_ date: Date) -> String { date.formatted(format) }
    private func number(_ value: Double, digits: Int) -> String {
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
    }
    private func enqueue(_ row: [String]) {
        // Bound memory even during stalled or failed storage. Missing rows are
        // counted, and the next successful batch carries an explicit gap record.
        guard pending.count < 512 else { droppedRows += 1; return }
        pending.append(row.map { value in
            value.contains(",") || value.contains("\"") || value.contains("\n")
                ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }.joined(separator: ",") + "\n")
        if flushTask == nil, pending.count >= 32 || lastFlush.duration(to: .now) >= .seconds(5) {
            startFlush()
        }
    }
    private func startFlush() {
        guard flushTask == nil, !pending.isEmpty else { return }
        if droppedRows > reportedDroppedRows {
            var row = emptyRow(kind: "telemetry_gap", at: Date())
            row[18] = "dropped_rows=\(droppedRows - reportedDroppedRows)"
            pending.append(row.joined(separator: ",") + "\n")
            reportedDroppedRows = droppedRows
        }
        let batch = pending; pending.removeAll(keepingCapacity: true); lastFlush = .now
        let dropped = droppedRows
        flushTask = Task { [writer] in
            let result = await writer.append(batch, droppedRows: dropped, at: Date())
            persistenceAvailable = result.available
            status = result.summary
            flushTask = nil
        }
    }
    /// Await outstanding writes before exporting or ending a test. Routine writes
    /// are batched; unexpected process termination can lose the latest few seconds.
    func flush() async {
        while flushTask != nil || !pending.isEmpty {
            if flushTask == nil { startFlush() }
            if let task = flushTask { await task.value }
        }
    }
    func prepareExport() async throws -> [URL] {
        await flush()
        return try await writer.prepareExport(droppedRows: droppedRows, at: Date())
    }
}

/// Serial disk owner. Append batches, rotate at 16 MiB, and prune whole segments;
/// exports stream to a file instead of loading weeks of telemetry into RAM.
actor SoundAnalysisLogWriter {
    struct ExportSegment: Sendable { let url: URL; let bytes: Int }
    typealias CSVExporter = @Sendable ([ExportSegment], URL) async throws -> Void
    struct Status: Sendable { let available: Bool; let summary: String }
    private struct Segment { let url: URL; let day: String; var bytes: Int; var validCSV = true }
    private struct Coverage: Codable {
        var evictedFiles = 0, evictedBytes = 0, writeFailures = 0, lostRows = 0, memoryDroppedRows = 0
        var readFailures = 0, repairedPartialRows = 0
        var historyIncomplete = false
        enum CodingKeys: String, CodingKey {
            case evictedFiles, evictedBytes, writeFailures, lostRows, memoryDroppedRows
            case readFailures, repairedPartialRows, historyIncomplete
        }
        init() {}
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            evictedFiles = try c.decodeIfPresent(Int.self, forKey: .evictedFiles) ?? 0
            evictedBytes = try c.decodeIfPresent(Int.self, forKey: .evictedBytes) ?? 0
            writeFailures = try c.decodeIfPresent(Int.self, forKey: .writeFailures) ?? 0
            lostRows = try c.decodeIfPresent(Int.self, forKey: .lostRows) ?? 0
            memoryDroppedRows = try c.decodeIfPresent(Int.self, forKey: .memoryDroppedRows) ?? 0
            readFailures = try c.decodeIfPresent(Int.self, forKey: .readFailures) ?? 0
            repairedPartialRows = try c.decodeIfPresent(Int.self, forKey: .repairedPartialRows) ?? 0
            historyIncomplete = try c.decodeIfPresent(Bool.self, forKey: .historyIncomplete) ?? false
        }
    }
    private let directory: URL?
    private let retentionDays: Int
    private let maximumBytes: Int
    private let segmentBytes: Int
    private var segments: [Segment] = []
    private var current: URL?
    private var prepared = false
    private var coverageLoaded = false
    private var coverage = Coverage()
    private var available = true
    private var lastReportedDrops = 0
    private var lastExport: URL?
    private var exportInProgress = false
    private nonisolated static let exportProcessID = UUID().uuidString.lowercased()
    private let writeExport: CSVExporter
    init(directory: URL?, retentionDays: Int, maximumBytes: Int, segmentBytes: Int = 16 * 1024 * 1024,
         exporter: CSVExporter? = nil) {
        self.directory = directory; self.retentionDays = retentionDays
        self.maximumBytes = maximumBytes; self.segmentBytes = segmentBytes
        self.writeExport = exporter ?? Self.writeCSV
    }
    nonisolated static func exportPrefix(for directory: URL) -> String {
        // Stable namespace for this store, avoiding another logger's exports in
        // shared macOS temporary directories. This is not a security identifier.
        let hash = directory.standardizedFileURL.path.utf8.reduce(UInt64(0xcbf29ce484222325)) {
            ($0 ^ UInt64($1)) &* 0x100000001b3
        }
        return "Sound-Analysis-\(String(hash, radix: 16))-"
    }
    private func cleanAbandonedExports(for directory: URL) {
        let prefix = Self.exportPrefix(for: directory)
        let currentProcess = prefix + Self.exportProcessID + "-"
        let temporary = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(at: temporary,
            includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix)
            && !entry.lastPathComponent.hasPrefix(currentProcess) {
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
    private static func day(_ date: Date) -> String {
        String(date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt)).prefix(10))
    }
    private func prepare(at now: Date) throws {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        if !prepared {
            cleanAbandonedExports(for: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var protected = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protected.setResourceValues(values)
            if !coverageLoaded {
                let coverageURL = directory.appendingPathComponent("coverage.json")
                if FileManager.default.fileExists(atPath: coverageURL.path) {
                    do { coverage = try JSONDecoder().decode(Coverage.self, from: Data(contentsOf: coverageURL)) }
                    catch { coverage.readFailures += 1; coverage.historyIncomplete = true }
                }
                coverageLoaded = true
            }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
                .filter { $0.lastPathComponent.hasPrefix("sound-") && $0.pathExtension == "csv" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            segments = []
            for url in files {
                let day = String(url.lastPathComponent.dropFirst(6).prefix(10))
                do { segments.append(try inspect(url: url, day: day)) }
                catch {
                    // A damaged old segment must not stop new observations. Keep
                    // it budgeted on disk and disclose its exclusion from export.
                    coverage.readFailures += 1; coverage.historyIncomplete = true
                    let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    segments.append(Segment(url: url, day: day, bytes: bytes, validCSV: false))
                }
            }
            prepared = true
        }
        try prune(at: now, reserving: 0)
    }
    private func inspect(url: URL, day: String) throws -> Segment {
        let file = try FileHandle(forUpdating: url)
        defer { try? file.close() }
        let header = Data(SoundAnalysisLog.header.utf8)
        let bytes = Int(try file.seekToEnd())
        try file.seek(toOffset: 0)
        guard try file.read(upToCount: header.count) == header else {
            coverage.historyIncomplete = true
            return Segment(url: url, day: day, bytes: bytes, validCSV: false)
        }
        try file.seek(toOffset: UInt64(bytes - 1))
        if try file.read(upToCount: 1) == Data([10]) { return Segment(url: url, day: day, bytes: bytes) }
        // A terminated append can leave an incomplete final row. Preserve all
        // complete records and prevent that fragment joining the next file's row.
        var end = bytes
        while end > 0 {
            let start = max(0, end - 64 * 1024)
            try file.seek(toOffset: UInt64(start))
            let chunk = try file.read(upToCount: end - start) ?? Data()
            if let newline = chunk.lastIndex(of: 10) {
                let safeEnd = start + newline + 1
                try file.truncate(atOffset: UInt64(safeEnd))
                coverage.repairedPartialRows += 1; coverage.lostRows += 1
                return Segment(url: url, day: day, bytes: safeEnd)
            }
            end = start
        }
        throw CocoaError(.fileReadCorruptFile)
    }
    private func prune(at now: Date, reserving bytes: Int) throws {
        let cutoff = Self.day(now.addingTimeInterval(-Double(max(0, retentionDays - 1)) * 86400))
        var total = segments.reduce(0) { $0 + $1.bytes }
        while let first = segments.first, first.day < cutoff || total + bytes > maximumBytes {
            try FileManager.default.removeItem(at: first.url)
            segments.removeFirst(); total -= first.bytes
            coverage.evictedFiles += 1; coverage.evictedBytes += first.bytes
            if current == first.url { current = nil }
        }
    }
    func append(_ rows: [String], droppedRows: Int, at now: Date) -> Status {
        var wroteRows = false
        do {
            try prepare(at: now)
            coverage.memoryDroppedRows += max(0, droppedRows - lastReportedDrops)
            lastReportedDrops = droppedRows
            let data = Data(rows.joined().utf8)
            guard data.count + SoundAnalysisLog.header.utf8.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            let day = Self.day(now)
            if let current, let segment = segments.first(where: { $0.url == current }),
               segment.day != day || segment.bytes + data.count > segmentBytes { self.current = nil }
            let newHeaderBytes = current == nil ? SoundAnalysisLog.header.utf8.count : 0
            try prune(at: now, reserving: data.count + newHeaderBytes)
            if current == nil, newHeaderBytes == 0 {
                try prune(at: now, reserving: data.count + SoundAnalysisLog.header.utf8.count)
            }
            guard let directory else { throw CocoaError(.fileNoSuchFile) }
            if current == nil {
                let url = directory.appendingPathComponent("sound-\(day)-\(String(format: "%.0f", now.timeIntervalSince1970 * 1000))-\(UUID().uuidString.lowercased()).csv")
                let header = Data(SoundAnalysisLog.header.utf8)
                #if os(iOS)
                try header.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try header.write(to: url, options: .atomic)
                #endif
                var excludedURL = url
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try excludedURL.setResourceValues(values)
                current = url; segments.append(Segment(url: url, day: day, bytes: header.count))
                segments.sort { $0.day < $1.day } // Stable within a day; preserve creation order.
            }
            let file = try FileHandle(forWritingTo: current!)
            defer { try? file.close() }
            let offset = try file.seekToEnd()
            do { try file.write(contentsOf: data) }
            catch { try? file.truncate(atOffset: offset); throw error }
            if let index = segments.firstIndex(where: { $0.url == current }) { segments[index].bytes += data.count }
            wroteRows = true
            available = true
            try saveCoverage()
        } catch {
            available = false; coverage.writeFailures += 1; coverage.lostRows += wroteRows ? 0 : rows.count
            // A failed append is never retried against an uncertain file tail.
            current = nil; prepared = false
            try? saveCoverage()
        }
        return Status(available: available, summary: "\(segments.count) files · \(segments.reduce(0) { $0 + $1.bytes } / 1_048_576) MiB · \(coverage.evictedFiles) files expired · \(coverage.lostRows + coverage.memoryDroppedRows) rows lost · \(coverage.readFailures) read errors")
    }
    private func saveCoverage() throws {
        guard let directory else { return }
        let url = directory.appendingPathComponent("coverage.json")
        #if os(iOS)
        try JSONEncoder().encode(coverage).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try JSONEncoder().encode(coverage).write(to: url, options: .atomic)
        #endif
    }
    func prepareExport(droppedRows: Int, at now: Date) async throws -> [URL] {
        guard !exportInProgress else { throw CocoaError(.fileWriteFileExists) }
        exportInProgress = true
        defer { exportInProgress = false }
        try prepare(at: now); try saveCoverage()
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        let exportName = Self.exportPrefix(for: directory) + Self.exportProcessID + "-" + UUID().uuidString
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(exportName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: folder) } }
        let csv = folder.appendingPathComponent("sound-analysis.csv")
        let snapshotFolder = folder.appendingPathComponent("snapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotFolder, withIntermediateDirectories: true)
        var snapshot: [ExportSegment] = []
        for segment in segments where segment.validCSV {
            let link = snapshotFolder.appendingPathComponent(segment.url.lastPathComponent)
            // Links keep rotated/pruned inodes available to the exporter. The
            // captured byte length excludes all subsequently appended rows.
            try FileManager.default.linkItem(at: segment.url, to: link)
            snapshot.append(ExportSegment(url: link, bytes: segment.bytes))
        }
        let report = folder.appendingPathComponent("coverage.txt")
        let text = """
        Crib Service sound analysis · schema=1
        exported_at=\(now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        persistence=\(available ? "available" : "unavailable")
        retention_days=\(retentionDays) maximum_bytes=\(maximumBytes) segment_limit_bytes=\(segmentBytes)
        retained_files=\(segments.count) retained_bytes=\(segments.reduce(0) { $0 + $1.bytes })
        first_retained_day=\(segments.first?.day ?? "none") last_retained_day=\(segments.last?.day ?? "none")
        evicted_files=\(coverage.evictedFiles) evicted_bytes=\(coverage.evictedBytes)
        read_failures=\(coverage.readFailures) repaired_partial_rows=\(coverage.repairedPartialRows) invalid_segments=\(segments.filter { !$0.validCSV }.count) coverage_history_incomplete=\(coverage.historyIncomplete)
        write_failures=\(coverage.writeFailures) lost_rows=\(coverage.lostRows) memory_dropped_rows=\(coverage.memoryDroppedRows) memory_dropped_rows_this_run=\(droppedRows)
        Levels: approximately 4 Hz, only while monitoring, with applied threshold, trigger, detector state and initial alert creation.
        Classifier: version1 baby_crying, 2-second windows, 50% overlap, approximately 1 Hz. Scores are diagnostic only; no confidence threshold is applied.
        Join classification window_start_at/window_end_at to level recorded_at within the same run_id. recorded_at on classification rows is result receipt time, not audio time. Rows may arrive out of time order; sort by audio timestamps for analysis.
        Volume is dBFS, not calibrated sound pressure. Above-threshold is an instantaneous volume trigger; detector_state includes confirmation and quiet-reset logic. alert_queued means the local initial alert was created, not delivered; snooze, server reminders and Watch delivery require operational diagnostics.
        No rows means no observation, not silence or zero confidence. Pauses, interruptions, termination, classifier faults, dropped buffers and storage failure create gaps. Wall-clock changes can affect joins; capture_id starts again after a discontinuity. Audio dates are estimated from microphone capture time and sample offsets.
        Data stays on the nursery iPhone, excluded from backups. Uninstall/device loss removes it. Oldest segments expire by age or byte cap, whichever comes first; age is pruned at UTC-day granularity. Export before expiry; export temporarily needs additional free disk space approximately equal to retained CSV data.
        Routine writes are batched about every 5 seconds while observations arrive; sudden termination can lose pending rows. Disk-full/locked-before-first-unlock errors and bounded queue drops lose observations. Failure counters are best effort, not proof of complete coverage.
        Export copying runs independently of live writes. Snapshot links retain their captured bytes until export finishes, even if retention prunes the original paths. Only complete CSV rows are included; truncated rows, invalid segments and incomplete coverage history are disclosed above.
        This export is a snapshot; prepare a fresh export for new observations. Existing operational diagnostics retain only 10,000 lines and are exported separately.
        """
        // Yield the disk actor for the potentially multi-GB copy. Live batches
        // can append normally while the independent worker reads this snapshot.
        try await writeExport(snapshot, csv)
        try text.write(to: report, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: snapshotFolder)
        if let lastExport { try? FileManager.default.removeItem(at: lastExport) }
        completed = true; lastExport = folder
        return [csv, report]
    }
    nonisolated static func writeCSV(_ snapshot: [ExportSegment], to destination: URL) async throws {
        let worker = Task.detached(priority: .utility) {
            let header = Data(SoundAnalysisLog.header.utf8)
            #if os(iOS)
            try header.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try header.write(to: destination, options: .atomic)
            #endif
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            try output.seekToEnd()
            for segment in snapshot {
                let input = try FileHandle(forReadingFrom: segment.url)
                do {
                    try input.seek(toOffset: UInt64(header.count))
                    var remaining = max(0, segment.bytes - header.count)
                    while remaining > 0 {
                        try Task.checkCancellation()
                        let chunk = try input.read(upToCount: min(64 * 1024, remaining)) ?? Data()
                        guard !chunk.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                        try output.write(contentsOf: chunk); remaining -= chunk.count
                    }
                    try input.close()
                } catch { try? input.close(); throw error }
            }
        }
        try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

}
