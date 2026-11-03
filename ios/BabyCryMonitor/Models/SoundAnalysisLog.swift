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
            latestConfidence = nil; latestScoreAt = nil; classifierStatus = "Listening for classifications"
            var row = emptyRow(kind: "capture_start", at: at); row[3] = id.uuidString.lowercased()
            row[18] = "classifier=version1;window_s=2;overlap=0.5;sample_rate=\(number(rate, digits: 0));voice_processing=\(voiceProcessing)"
            enqueue(row)
        case .result(let score):
            guard score.confidence.isFinite, (0...1).contains(score.confidence), score.windowEnd >= score.windowStart else { return }
            latestConfidence = score.confidence; latestScoreAt = score.windowEnd
            classifierStatus = "Receiving classifications"
            var row = emptyRow(kind: "classification", at: score.observedAt)
            row[3] = score.captureID.uuidString.lowercased(); row[4] = Self.date(score.windowStart)
            row[5] = Self.date(score.windowEnd); row[6] = number(score.confidence, digits: 6)
            enqueue(row)
        case let .stopped(id, at):
            var row = emptyRow(kind: "capture_stop", at: at); row[3] = id.uuidString.lowercased(); enqueue(row)
        case .unavailable(let at):
            latestConfidence = nil; latestScoreAt = nil
            classifierStatus = "Classifier unavailable; volume alerts continue"
            append(kind: "classifier_unavailable", at: at)
        case .droppedEvents(let at):
            append(kind: "classifier_event_gap", at: at, detail: "dropped_events_at_least=1")
        case let .droppedBuffers(count, at):
            append(kind: "classifier_gap", at: at, detail: "dropped_buffers=\(max(0, count))")
        }
    }
    func monitoring(_ enabled: Bool, at: Date) {
        latestConfidence = nil; latestScoreAt = nil; lastLevelAt = nil
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
    struct Status: Sendable { let available: Bool; let summary: String }
    private struct Segment { let url: URL; let day: String; var bytes: Int }
    private struct Coverage: Codable {
        var evictedFiles = 0
        var evictedBytes = 0
        var writeFailures = 0
        var lostRows = 0
        var memoryDroppedRows = 0
    }
    private let directory: URL?
    private let retentionDays: Int
    private let maximumBytes: Int
    private let segmentBytes: Int
    private var segments: [Segment] = []
    private var current: URL?
    private var prepared = false
    private var coverage = Coverage()
    private var available = true
    private var lastReportedDrops = 0
    private var lastExport: URL?
    init(directory: URL?, retentionDays: Int, maximumBytes: Int, segmentBytes: Int = 16 * 1024 * 1024) {
        self.directory = directory; self.retentionDays = retentionDays
        self.maximumBytes = maximumBytes; self.segmentBytes = segmentBytes
    }
    private static func day(_ date: Date) -> String {
        String(date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt)).prefix(10))
    }
    private func prepare(at now: Date) throws {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        if !prepared {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var protected = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protected.setResourceValues(values)
            let coverageURL = directory.appendingPathComponent("coverage.json")
            if FileManager.default.fileExists(atPath: coverageURL.path) {
                coverage = try JSONDecoder().decode(Coverage.self, from: Data(contentsOf: coverageURL))
            }
            segments = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
                .filter { $0.lastPathComponent.hasPrefix("sound-") && $0.pathExtension == "csv" }
                .map { url in
                    Segment(url: url, day: String(url.lastPathComponent.dropFirst(6).prefix(10)),
                            bytes: try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                }.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
            prepared = true
        }
        try prune(at: now, reserving: 0)
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
            current = nil
            try? saveCoverage()
        }
        return Status(available: available, summary: "\(segments.count) files · \(segments.reduce(0) { $0 + $1.bytes } / 1_048_576) MiB · \(coverage.evictedFiles) files expired · \(coverage.lostRows + droppedRows) rows lost")
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
    func prepareExport(droppedRows: Int, at now: Date) throws -> [URL] {
        try prepare(at: now); try saveCoverage()
        if let lastExport { try? FileManager.default.removeItem(at: lastExport) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Sound-Analysis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: folder) } }
        let csv = folder.appendingPathComponent("sound-analysis.csv")
        FileManager.default.createFile(atPath: csv.path, contents: Data(SoundAnalysisLog.header.utf8))
        let output = try FileHandle(forWritingTo: csv)
        defer { try? output.close() }
        try output.seekToEnd()
        for segment in segments {
            let input = try FileHandle(forReadingFrom: segment.url)
            do {
                try input.seek(toOffset: UInt64(SoundAnalysisLog.header.utf8.count))
                while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty { try output.write(contentsOf: chunk) }
                try input.close()
            } catch { try? input.close(); throw error }
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
        write_failures=\(coverage.writeFailures) lost_rows=\(coverage.lostRows) memory_dropped_rows=\(coverage.memoryDroppedRows) memory_dropped_rows_this_run=\(droppedRows)
        Levels: approximately 4 Hz, only while monitoring, with applied threshold, trigger, detector state and initial alert creation.
        Classifier: version1 baby_crying, 2-second windows, 50% overlap, approximately 1 Hz. Scores are diagnostic only; no confidence threshold is applied.
        Join classification window_start_at/window_end_at to level recorded_at within the same run_id. recorded_at on classification rows is result receipt time, not audio time. Rows may arrive out of time order; sort by audio timestamps for analysis.
        Volume is dBFS, not calibrated sound pressure. Above-threshold is an instantaneous volume trigger; detector_state includes confirmation and quiet-reset logic. alert_queued means the local initial alert was created, not delivered; snooze, server reminders and Watch delivery require operational diagnostics.
        No rows means no observation, not silence or zero confidence. Pauses, interruptions, termination, classifier faults, dropped buffers and storage failure create gaps. Wall-clock changes can affect joins; capture_id starts again after a discontinuity. Audio dates are estimated from microphone capture time and sample offsets.
        Data stays on the nursery iPhone, excluded from backups. Uninstall/device loss removes it. Oldest segments expire by age or byte cap, whichever comes first; age is pruned at UTC-day granularity. Export before expiry; export temporarily needs additional free disk space approximately equal to retained CSV data.
        Routine writes are batched about every 5 seconds while observations arrive; sudden termination can lose pending rows. Disk-full/locked-before-first-unlock errors and bounded queue drops lose observations. Failure counters are best effort, not proof of complete coverage.
        This export is a snapshot; prepare a fresh export for new observations. Existing operational diagnostics retain only 10,000 lines and are exported separately.
        """
        try text.write(to: report, atomically: true, encoding: .utf8)
        completed = true; lastExport = folder
        return [csv, report]
    }
}
