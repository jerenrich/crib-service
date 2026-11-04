import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class SoundAnalysisLogTests: XCTestCase {
    func testRecoveryUsesMonotonicBackoffAndResetsOnlyAfterSuccess() {
        let now = ContinuousClock.now
        var recovery = SoundClassifierRecovery()
        for delay in [1, 2, 4, 8, 16, 30, 30] {
            XCTAssertEqual(recovery.failed(at: now), delay)
            XCTAssertFalse(recovery.canAttempt(at: now.advanced(by: .milliseconds(999))))
            XCTAssertTrue(recovery.canAttempt(at: now.advanced(by: .seconds(delay))))
        }
        recovery.succeeded()
        XCTAssertTrue(recovery.canAttempt(at: now))
        XCTAssertEqual(recovery.failed(at: now), 1)
    }
    @MainActor func testFailureDiagnosticsBoundAndRedactTheErrorChain() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let gpu = NSError(domain: "MTLCommandBufferErrorDomain", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Insufficient Permission (to submit GPU work from background) private-recording-path"])
        let ml = NSError(domain: "com.apple.CoreML", code: 0,
            userInfo: [NSUnderlyingErrorKey: gpu, NSLocalizedDescriptionKey: "private-payload"])
        let error = NSError(domain: "com.apple.SoundAnalysis", code: 2, userInfo: [NSUnderlyingErrorKey: ml])
        let failure = SoundClassificationFailure(error, stage: .inference)
        XCTAssertTrue(failure.backgroundGPURestricted)
        XCTAssertEqual(failure.codes.count, 3)
        let log = SoundAnalysisLog(directory: directory), id = UUID()
        log.classification(.unavailable(at: Date(), failure: failure, captureID: id, retryAfterSeconds: 30, appActive: false))
        let export = try await log.prepareExport()
        defer { try? FileManager.default.removeItem(at: export[0].deletingLastPathComponent()) }
        let text = try String(contentsOf: export[0], encoding: .utf8)
        XCTAssertTrue(text.contains("com.apple.SoundAnalysis:2|com.apple.CoreML:0|MTLCommandBufferErrorDomain:7"))
        XCTAssertTrue(text.contains("background_gpu_restricted=true;retry_after_s=30"))
        XCTAssertTrue(text.contains(id.uuidString.lowercased()))
        XCTAssertFalse(text.contains("private-recording-path")); XCTAssertFalse(text.contains("private-payload"))
        let unknown = SoundClassificationFailure(NSError(domain: "private-domain", code: 9), stage: .initialization)
        XCTAssertEqual(unknown.codes.first?.domain, "other")
        XCTAssertFalse(unknown.backgroundGPURestricted)
    }
    @MainActor func testDelayedOldCaptureEventsCannotReplaceTheLiveScore() {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = SoundAnalysisLog(directory: directory), now = Date(), old = UUID(), fresh = UUID()
        log.classification(.started(id: old, at: now, sampleRate: 48_000, voiceProcessing: false))
        log.classification(.started(id: fresh, at: now.addingTimeInterval(10), sampleRate: 48_000, voiceProcessing: false))
        log.classification(.result(.init(captureID: fresh, windowStart: now.addingTimeInterval(10),
            windowEnd: now.addingTimeInterval(12), confidence: 0.8, observedAt: now.addingTimeInterval(13))))
        log.classification(.result(.init(captureID: old, windowStart: now, windowEnd: now.addingTimeInterval(2),
                                        confidence: 0.1, observedAt: now.addingTimeInterval(14))))
        log.classification(.unavailable(at: now.addingTimeInterval(15), captureID: old))
        XCTAssertEqual(log.latestConfidence, 0.8)
        log.classification(.stopped(id: fresh, at: now.addingTimeInterval(16)))
        XCTAssertNil(log.latestConfidence)
    }
    func testInterruptedLastCSVRowCannotCorruptTheNextExportedSegment() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(), day = String(now.formatted(Date.ISO8601FormatStyle(timeZone: .gmt)).prefix(10))
        let old = directory.appendingPathComponent("sound-\(day)-000-old.csv")
        try (SoundAnalysisLog.header + "complete-old-row\ninterrupted-row").write(to: old, atomically: true, encoding: .utf8)
        let writer = SoundAnalysisLogWriter(directory: directory, retentionDays: 42, maximumBytes: 100_000)
        _ = await writer.append(["new-row\n"], droppedRows: 0, at: now)
        let export = try await writer.prepareExport(droppedRows: 0, at: now)
        defer { try? FileManager.default.removeItem(at: export[0].deletingLastPathComponent()) }
        XCTAssertEqual(try String(contentsOf: export[0], encoding: .utf8), SoundAnalysisLog.header + "complete-old-row\nnew-row\n")
        XCTAssertTrue(try String(contentsOf: export[1], encoding: .utf8).contains("repaired_partial_rows=1"))
    }
    func testCorruptCoverageMetadataDoesNotDiscardTheNextValidBatch() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("partial-json".utf8).write(to: directory.appendingPathComponent("coverage.json"))
        let writer = SoundAnalysisLogWriter(directory: directory, retentionDays: 42, maximumBytes: 100_000)
        let status = await writer.append(["still-collected\n"], droppedRows: 0, at: Date())
        XCTAssertTrue(status.available)
        let export = try await writer.prepareExport(droppedRows: 0, at: Date())
        defer { try? FileManager.default.removeItem(at: export[0].deletingLastPathComponent()) }
        XCTAssertTrue(try String(contentsOf: export[0], encoding: .utf8).contains("still-collected"))
        XCTAssertTrue(try String(contentsOf: export[1], encoding: .utf8).contains("coverage_history_incomplete=true"))
    }
    private actor ExportGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var entered = false
        func hold() async { entered = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
    func testLiveWritesAndPruningContinueDuringAnExportSnapshot() async throws {
        for rotating in [false, true] {
            let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
            let gate = ExportGate()
            let writer = SoundAnalysisLogWriter(directory: directory, retentionDays: 42,
                maximumBytes: rotating ? 1500 : 100_000, segmentBytes: rotating ? 1000 : 1_000_000,
                exporter: { snapshot, destination in
                    await gate.hold()
                    try await SoundAnalysisLogWriter.writeCSV(snapshot, to: destination)
                })
            let a = String(repeating: "a", count: 600) + "\n", b = String(repeating: "b", count: 600) + "\n"
            _ = await writer.append([a], droppedRows: 0, at: Date())
            let exporting = Task { try await writer.prepareExport(droppedRows: 0, at: Date()) }
            for _ in 0..<100 {
                if await gate.entered { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let entered = await gate.entered; XCTAssertTrue(entered)
            // This must finish while export is suspended, including when the
            // original source segment is pruned. The linked snapshot survives.
            let status = await writer.append([b], droppedRows: 0, at: Date())
            XCTAssertTrue(status.available)
            await gate.release()
            let output = try await exporting.value
            defer { try? FileManager.default.removeItem(at: output[0].deletingLastPathComponent()) }
            XCTAssertEqual(try String(contentsOf: output[0], encoding: .utf8), SoundAnalysisLog.header + a,
                           "A prepared snapshot must not include subsequent appends")
            let remaining = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "csv" }
            XCTAssertEqual(remaining.count, 1)
            let retained = try String(contentsOf: remaining[0], encoding: .utf8)
            XCTAssertTrue(retained.hasSuffix(b))
            if rotating { XCTAssertFalse(retained.contains(a)) }
        }
    }
    func testInvalidCSVIsDisclosedAndLegacyCoverageCountersSurvive() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"evictedFiles\":7}".utf8).write(to: directory.appendingPathComponent("coverage.json"))
        let day = String(Date().formatted(Date.ISO8601FormatStyle(timeZone: .gmt)).prefix(10))
        try Data("damaged-header\nprivate-broken-record\n".utf8)
            .write(to: directory.appendingPathComponent("sound-\(day)-000-bad.csv"))
        let writer = SoundAnalysisLogWriter(directory: directory, retentionDays: 42, maximumBytes: 100_000)
        let status = await writer.append(["fresh-data\n"], droppedRows: 0, at: Date())
        XCTAssertTrue(status.available)
        let output = try await writer.prepareExport(droppedRows: 0, at: Date())
        defer { try? FileManager.default.removeItem(at: output[0].deletingLastPathComponent()) }
        XCTAssertEqual(try String(contentsOf: output[0], encoding: .utf8), SoundAnalysisLog.header + "fresh-data\n")
        let report = try String(contentsOf: output[1], encoding: .utf8)
        XCTAssertTrue(report.contains("invalid_segments=1"))
        XCTAssertTrue(report.contains("coverage_history_incomplete=true"))
        XCTAssertTrue(report.contains("evicted_files=7"))
    }
    @MainActor func testSilentClassifierCannotIndefinitelyDisplayReceivingStatus() {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = SoundAnalysisLog(directory: directory), now = Date(), id = UUID()
        log.classification(.started(id: id, at: now, sampleRate: 48_000, voiceProcessing: false))
        XCTAssertTrue(log.classifierStatus(at: now.addingTimeInterval(11)).contains("No recent"))
        log.classification(.result(.init(captureID: id, windowStart: now, windowEnd: now.addingTimeInterval(2),
                                        confidence: 0.1, observedAt: now.addingTimeInterval(3))))
        XCTAssertEqual(log.classifierStatus(at: now.addingTimeInterval(4)), "Receiving classifications")
        XCTAssertTrue(log.classifierStatus(at: now.addingTimeInterval(13)).contains("No recent"))
        log.classification(.stopped(id: id, at: now.addingTimeInterval(14)))
        XCTAssertFalse(log.classifierStatus(at: now.addingTimeInterval(15)).contains("Receiving"))
    }
    func testAbandonedExportsAreCleanedOnlyWithinTheirStoreNamespace() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let temporary = FileManager.default.temporaryDirectory
        let abandoned = temporary.appendingPathComponent(SoundAnalysisLogWriter.exportPrefix(for: directory) + "old-process-export")
        let unrelated = temporary.appendingPathComponent(SoundAnalysisLogWriter.exportPrefix(for: folder()) + "other-store-export")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: abandoned); try? FileManager.default.removeItem(at: unrelated) }
        let writer = SoundAnalysisLogWriter(directory: directory, retentionDays: 42, maximumBytes: 100_000)
        _ = await writer.append(["new-data\n"], droppedRows: 0, at: Date())
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func rows(in urls: [URL]) throws -> [[String]] {
        try String(contentsOf: urls[0], encoding: .utf8).split(separator: "\n").dropFirst()
            .map { $0.components(separatedBy: ",") }
    }
    @MainActor func testExportPreservesQuietScoresAndVolumeTriggersWithoutChangingAlerts() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = SoundAnalysisLog(directory: directory)
        let now = Date(), capture = UUID()
        var config = MonitoringConfiguration(); config.absoluteThreshold = -35
        log.monitoring(true, at: now)
        log.classification(.started(id: capture, at: now, sampleRate: 48_000, voiceProcessing: false))
        log.level(.init(timestamp: now, dbFS: -35.01), configuration: config, state: .quiet,
                  alertQueued: false, episode: nil, nurserySound: nil, appActive: false)
        log.level(.init(timestamp: now.addingTimeInterval(0.25), dbFS: -35), configuration: config, state: .possibleCry,
                  alertQueued: false, episode: nil, nurserySound: .whiteNoise, appActive: true)
        let episode = CryEpisode(startedAt: now)
        log.level(.init(timestamp: now.addingTimeInterval(5), dbFS: -20), configuration: config, state: .crying,
                  alertQueued: true, episode: episode, nurserySound: nil, appActive: false)
        log.classification(.result(.init(captureID: capture, windowStart: now, windowEnd: now.addingTimeInterval(2),
                                        confidence: 0, observedAt: now.addingTimeInterval(3))))
        log.classification(.result(.init(captureID: capture, windowStart: now.addingTimeInterval(1),
            windowEnd: now.addingTimeInterval(3), confidence: 0.987654, observedAt: now.addingTimeInterval(4))))
        let export = try await log.prepareExport()
        defer { try? FileManager.default.removeItem(at: export[0].deletingLastPathComponent()) }
        let data = try rows(in: export)
        let levels = data.filter { $0[2] == "level" }
        XCTAssertEqual(levels.count, 3)
        XCTAssertEqual(levels.map { $0[9] }, ["0", "1", "1"])
        XCTAssertEqual(levels.map { $0[10] }, ["quiet", "possibleCry", "crying"])
        XCTAssertEqual(levels.map { $0[11] }, ["0", "0", "1"])
        XCTAssertEqual(levels[2][12], episode.id.uuidString.lowercased())
        XCTAssertEqual(levels[1][16], "whiteNoise")
        let scores = data.filter { $0[2] == "classification" }
        XCTAssertEqual(scores.map { $0[6] }, ["0.000000", "0.987654"])
        XCTAssertNotEqual(scores[0][0], scores[0][5], "Receipt time must remain distinct from audio time")
        XCTAssertEqual(scores[0][3], capture.uuidString.lowercased())
        XCTAssertEqual(log.latestConfidence, 0.987654)
        XCTAssertTrue(try String(contentsOf: export[1], encoding: .utf8).contains("Scores are diagnostic only"))
    }
    @MainActor func testSuccessiveBatchesContinueWritingAndExportSurvivesRelaunch() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = SoundAnalysisLog(directory: directory)
        for index in 0..<100 {
            log.level(.init(timestamp: Date().addingTimeInterval(Double(index) / 4), dbFS: -50),
                      configuration: .init(), state: .quiet, alertQueued: false, episode: nil, nurserySound: nil, appActive: false)
            if index == 39 { await log.flush() }
        }
        await log.flush()
        let restored = SoundAnalysisLog(directory: directory)
        let export = try await restored.prepareExport()
        defer { try? FileManager.default.removeItem(at: export[0].deletingLastPathComponent()) }
        XCTAssertEqual(try rows(in: export).filter { $0[2] == "level" }.count, 100)
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("sound-analysis"), includingPropertiesForKeys: nil)
        XCTAssertTrue(files.contains { $0.lastPathComponent == "coverage.json" })
        #if os(iOS)
        for file in files where file.pathExtension == "csv" {
            XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        }
        #endif
    }
    func testAgeRetentionAndByteCapAreIndependentAndPersistEvictionCoverage() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(), row = String(repeating: "x", count: 600) + "\n"
        let writer = SoundAnalysisLogWriter(directory: directory, retentionDays: 42, maximumBytes: 1500, segmentBytes: 1000)
        let first = await writer.append([row], droppedRows: 0, at: now.addingTimeInterval(-43 * 86400))
        XCTAssertTrue(first.available)
        let second = await writer.append([row], droppedRows: 0, at: now.addingTimeInterval(-86400))
        XCTAssertTrue(second.available)
        let third = await writer.append([row], droppedRows: 0, at: now)
        XCTAssertTrue(third.available)
        let restarted = SoundAnalysisLogWriter(directory: directory, retentionDays: 42, maximumBytes: 1500)
        let export = try await restarted.prepareExport(droppedRows: 0, at: now)
        defer { try? FileManager.default.removeItem(at: export[0].deletingLastPathComponent()) }
        let report = try String(contentsOf: export[1], encoding: .utf8)
        XCTAssertTrue(report.contains("evicted_files=2"), report)
        XCTAssertEqual(try String(contentsOf: export[0], encoding: .utf8), SoundAnalysisLog.header + row)
    }
    @MainActor func testUnavailableAndDroppedEvidenceNeverInventsZeroConfidence() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = SoundAnalysisLog(directory: directory), now = Date(), id = UUID()
        log.classification(.result(.init(captureID: id, windowStart: now, windowEnd: now, confidence: .nan, observedAt: now)))
        log.classification(.result(.init(captureID: id, windowStart: now, windowEnd: now, confidence: 0.7, observedAt: now)))
        log.classification(.unavailable(at: now))
        log.classification(.droppedBuffers(count: 5, at: now))
        log.classification(.droppedEvents(at: now))
        XCTAssertNil(log.latestConfidence)
        let export = try await log.prepareExport()
        defer { try? FileManager.default.removeItem(at: export[0].deletingLastPathComponent()) }
        let data = try rows(in: export)
        XCTAssertEqual(data.filter { $0[2] == "classification" }.count, 1)
        XCTAssertEqual(data.first { $0[2] == "classifier_unavailable" }?[6], "")
        XCTAssertEqual(data.first { $0[2] == "classifier_gap" }?[18], "dropped_buffers=5")
        XCTAssertNotNil(data.first { $0[2] == "classifier_event_gap" })
    }
    @MainActor func testBoundedMemoryDropsAreExplicitInNextFlushAndCoverage() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = SoundAnalysisLog(directory: directory)
        // Deliberately do not yield, so disk work cannot drain the main actor buffer.
        for _ in 0..<800 { log.classification(.unavailable(at: Date())) }
        XCTAssertGreaterThan(log.droppedRows, 0)
        let export = try await log.prepareExport()
        defer { try? FileManager.default.removeItem(at: export[0].deletingLastPathComponent()) }
        XCTAssertTrue(try rows(in: export).contains { $0[2] == "telemetry_gap" })
        let report = try String(contentsOf: export[1], encoding: .utf8)
        XCTAssertTrue(report.contains("memory_dropped_rows=\(log.droppedRows)"), report)
    }
    @MainActor func testStorageFailureIsVisibleAndDoesNotBlockDetection() async throws {
        let file = folder(); defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        let log = SoundAnalysisLog(directory: file)
        log.classification(.unavailable(at: Date()))
        await log.flush()
        XCTAssertFalse(log.persistenceAvailable)
        XCTAssertTrue(log.status.contains("rows lost"))
        // Fixing the directory permits subsequent observations without a relaunch.
        try FileManager.default.removeItem(at: file)
        log.classification(.unavailable(at: Date()))
        let export = try await log.prepareExport()
        defer { try? FileManager.default.removeItem(at: export[0].deletingLastPathComponent()) }
        XCTAssertTrue(log.persistenceAvailable)
        XCTAssertTrue(try String(contentsOf: export[1], encoding: .utf8).contains("write_failures=1"))
    }
    func testExportStreamsSegmentsWithOneHeaderAndReplacesPreviousSnapshot() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SoundAnalysisLogWriter(directory: directory, retentionDays: 42, maximumBytes: 100_000, segmentBytes: 600)
        let now = Date(), a = "a\n", b = "b\n"
        _ = await writer.append([a], droppedRows: 0, at: now)
        _ = await writer.append([b], droppedRows: 0, at: now.addingTimeInterval(86400))
        let first = try await writer.prepareExport(droppedRows: 0, at: now.addingTimeInterval(86400))
        let second = try await writer.prepareExport(droppedRows: 0, at: now.addingTimeInterval(86400))
        defer { try? FileManager.default.removeItem(at: second[0].deletingLastPathComponent()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: first[0].path))
        XCTAssertEqual(try String(contentsOf: second[0], encoding: .utf8), SoundAnalysisLog.header + a + b)
    }
}
