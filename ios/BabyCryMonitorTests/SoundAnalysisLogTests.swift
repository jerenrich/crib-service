import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class SoundAnalysisLogTests: XCTestCase {
    @MainActor func testUnmappedResultRetainsCaptureScopeWithoutInventingAGlobalGap() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = SoundAnalysisLog(directory: directory), now = Date(), old = UUID(), current = UUID()
        log.classification(.started(id: current, at: now, sampleRate: 48_000, voiceProcessing: false))
        log.classification(.result(.init(captureID: current, windowStart: now,
            windowEnd: now.addingTimeInterval(2), confidence: 0.9, observedAt: now.addingTimeInterval(2))))
        log.classification(.unmappedResult(captureID: old, windowEnd: now.addingTimeInterval(-10), at: now.addingTimeInterval(3)))
        XCTAssertEqual(log.latestConfidence, 0.9)
        let export = try await log.prepareExport()
        defer { try? FileManager.default.removeItem(at: export[0].deletingLastPathComponent()) }
        let data = try rows(in: export)
        let row = try XCTUnwrap(data.first { $0[2] == "classifier_result_unmapped" })
        XCTAssertEqual(row[3], old.uuidString.lowercased())
        XCTAssertFalse(row[5].isEmpty)
        XCTAssertEqual(row[6], "")
        XCTAssertEqual(row[18], "reason=input_timestamp_unavailable")
        XCTAssertFalse(data.contains { $0[2] == "classifier_event_gap" })
    }

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
        let failure = SoundClassificationFailure(error: error, stage: .analysis)
        XCTAssertEqual(failure.reason, .backgroundGPUDenied)
        XCTAssertEqual(failure.causes.count, 3)
        let log = SoundAnalysisLog(directory: directory), id = UUID()
        log.classification(.unavailable(at: Date(), failure: failure, captureID: id, retryAfterSeconds: 30, appActive: false),
                           appActive: true)
        let export = try await log.prepareExport()
        defer { try? FileManager.default.removeItem(at: export[0].deletingLastPathComponent()) }
        let text = try String(contentsOf: export[0], encoding: .utf8)
        XCTAssertTrue(text.contains("com.apple.SoundAnalysis:2>com.apple.CoreML:0>MTLCommandBufferErrorDomain:7"))
        XCTAssertTrue(text.contains("causes_truncated=false;retry_after_s=30"))
        XCTAssertTrue(text.contains(id.uuidString.lowercased()))
        XCTAssertEqual(try XCTUnwrap(try rows(in: export).first { $0[2] == "classifier_unavailable" })[17], "0",
                       "A failure's captured background state must survive later foreground handling")
        XCTAssertFalse(text.contains("private-recording-path")); XCTAssertFalse(text.contains("private-payload"))
        let unknown = SoundClassificationFailure(error: NSError(domain: "private-domain", code: 9), stage: .setup)
        XCTAssertEqual(unknown.causes.first?.domain, "other")
        XCTAssertEqual(unknown.reason, .unknown)
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
    func testStallSnapshotBoundsCountersAndSeparatesChangingContextFromTheSamplingKey() {
        let context = SoundClassificationFailure.StallContext(timeout: .seconds(10), sessionAge: .seconds(20),
            noProgress: .seconds(11), receivedAudio: 19.5, inputBuffers: 914, lastResultWindowEnd: 8)
        XCTAssertEqual(context.sessionAgeMS, 20_000)
        XCTAssertEqual(context.receivedAudioMS, 19_500)
        XCTAssertEqual(context.lastResultWindowEndMS, 8_000)
        let bounded = SoundClassificationFailure.StallContext(timeout: .seconds(-1), sessionAge: .seconds(Int64.max),
            noProgress: .seconds(10), receivedAudio: .infinity, inputBuffers: Int.max, lastResultWindowEnd: .nan)
        XCTAssertEqual(bounded.timeoutMS, 0)
        XCTAssertEqual(bounded.sessionAgeMS, 86_400_000)
        XCTAssertEqual(bounded.receivedAudioMS, 0)
        XCTAssertEqual(bounded.inputBuffers, 1_000_000_000)
        XCTAssertNil(bounded.lastResultWindowEndMS)
        let first = SoundClassificationFailure(stalledCaptureID: UUID(), context: context)
        let second = SoundClassificationFailure(stalledCaptureID: UUID(), context: bounded)
        XCTAssertEqual(first.diagnosticFingerprint, second.diagnosticFingerprint)
        XCTAssertNotEqual(first.diagnosticDetails, second.diagnosticDetails)
    }

    func testRecoveryRequiresFreshCurrentCaptureAudioAndUsesTheMappedInputClock() throws {
        var log = SoundClassificationRecoveryLog()
        let origin = Date(timeIntervalSince1970: 1000), failed = UUID(), replacement = UUID()
        func date(_ seconds: Double) -> Date { origin.addingTimeInterval(seconds) }
        func event(_ id: UUID, end: Double, captured: Double, confidence: Double = 0) -> SoundClassificationEvent {
            .result(.init(captureID: id, windowStart: date(end - 2), windowEnd: date(end), confidence: confidence,
                          observedAt: date(end), audioWindowEndAt: date(captured)))
        }
        _ = log.consume(.started(id: failed, at: origin, sampleRate: 48_000, voiceProcessing: false), at: origin)
        _ = log.consume(.unavailable(at: date(10), failure: .init(stalledCaptureID: failed)), at: date(10))
        XCTAssertNil(log.consume(event(failed, end: 11, captured: 11), at: date(11)), "A failed capture cannot declare itself recovered")
        _ = log.consume(.started(id: replacement, at: date(11), sampleRate: 48_000, voiceProcessing: false), at: date(11))
        _ = log.consume(.started(id: failed, at: origin, sampleRate: 48_000, voiceProcessing: false), at: date(11))
        XCTAssertNil(log.consume(event(failed, end: 13, captured: 13), at: date(13)), "Retired capture callbacks are not recovery")
        XCTAssertNil(log.consume(event(replacement, end: 13, captured: 9), at: date(13)), "Sample-clock dates cannot make old input fresh")
        XCTAssertNil(log.consume(event(replacement, end: 13, captured: 13, confidence: .nan), at: date(13)))
        XCTAssertNil(log.consume(.result(.init(captureID: replacement, windowStart: date(11), windowEnd: date(13),
                                               confidence: 0, observedAt: date(13))), at: date(13)), "Recovery needs an independent input timestamp")
        XCTAssertNil(log.consume(event(replacement, end: 13, captured: 13), at: date(20)), "Delayed handling is not recovery")
        let result = try XCTUnwrap(log.consume(event(replacement, end: 14, captured: 13.5), at: date(14)))
        XCTAssertTrue(result.contains("outage_ms=4000"))
        XCTAssertTrue(result.contains("failure_count=1;restart_count=1"))
        XCTAssertTrue(result.contains(failed.uuidString.lowercased()))
        XCTAssertNil(log.pendingDetails(at: date(14)))
        XCTAssertNil(log.consume(event(replacement, end: 15, captured: 15), at: date(15)), "One summary per outage")
    }

    func testRecoveryDoesNotAdoptUnknownStoppedOrPreGapResults() {
        var log = SoundClassificationRecoveryLog()
        let now = Date(timeIntervalSince1970: 1000), capture = UUID()
        func event(end: Double) -> SoundClassificationEvent {
            .result(.init(captureID: capture, windowStart: now.addingTimeInterval(end - 2), windowEnd: now.addingTimeInterval(end),
                          confidence: 0, observedAt: now.addingTimeInterval(end), audioWindowEndAt: now.addingTimeInterval(end)))
        }
        _ = log.consume(.unavailable(at: now), at: now)
        XCTAssertNil(log.consume(event(end: 2), at: now.addingTimeInterval(2)))
        _ = log.consume(.started(id: capture, at: now, sampleRate: 48_000, voiceProcessing: false), at: now)
        _ = log.consume(.droppedEvents(at: now.addingTimeInterval(2)), at: now.addingTimeInterval(2))
        XCTAssertNil(log.consume(event(end: 3), at: now.addingTimeInterval(3)), "Require a complete post-gap audio window")
        _ = log.consume(.stopped(id: capture, at: now.addingTimeInterval(3)), at: now.addingTimeInterval(3))
        XCTAssertNil(log.consume(event(end: 4), at: now.addingTimeInterval(4)))
        log = .init()
        _ = log.consume(.started(id: capture, at: now, sampleRate: 48_000, voiceProcessing: false), at: now)
        XCTAssertNil(log.consume(event(end: 5), at: now.addingTimeInterval(5)), "A monitoring reset cancels pending recovery")
    }

    @MainActor func testCSVRecoveryAnnotatesOnlyTheFirstFreshReplacementScoreWithoutAddingRows() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = SoundAnalysisLog(directory: directory), now = Date(), old = UUID(), replacement = UUID()
        log.classification(.started(id: old, at: now, sampleRate: 48_000, voiceProcessing: false))
        let context = SoundClassificationFailure.StallContext(timeout: .seconds(10), sessionAge: .seconds(10),
            noProgress: .seconds(10), receivedAudio: 10, inputBuffers: 469, lastResultWindowEnd: nil)
        log.classification(.unavailable(at: now.addingTimeInterval(10), failure: .init(stalledCaptureID: old, context: context),
                                        captureID: old, retryAfterSeconds: 1, appActive: false))
        let start = now.addingTimeInterval(11)
        log.classification(.started(id: replacement, at: start, sampleRate: 48_000, voiceProcessing: false, reason: .afterFailure))
        for offset in 2...4 {
            let end = start.addingTimeInterval(Double(offset))
            log.classification(.result(.init(captureID: replacement, windowStart: end.addingTimeInterval(-2), windowEnd: end,
                                            confidence: 0, observedAt: end, audioWindowEndAt: end)), handledAt: end)
        }
        let export = try await log.prepareExport()
        defer { try? FileManager.default.removeItem(at: export[0].deletingLastPathComponent()) }
        let data = try rows(in: export)
        let failure = try XCTUnwrap(data.first { $0[2] == "classifier_unavailable" })
        XCTAssertTrue(failure[18].contains("received_audio_ms=10000;input_buffers=469;last_result_end_ms=none"))
        XCTAssertTrue(failure[18].contains("retry_after_s=1"))
        XCTAssertEqual(failure[6], "", "Failure is not a zero-confidence observation")
        XCTAssertEqual(data.filter { $0[2] == "classification" }.count, 3)
        XCTAssertEqual(data.filter { $0[18].contains("recovery=confirmed") }.count, 1)
        XCTAssertEqual(data.count, 7, "Annotate existing lifecycle/score rows without adding periodic telemetry")
        let recovered = try XCTUnwrap(data.first { $0[18].contains("recovery=confirmed") })
        XCTAssertTrue(recovered[18].contains("failure_count=1;restart_count=1"))
        XCTAssertTrue(recovered[18].contains(old.uuidString.lowercased()))
        XCTAssertLessThan(failure[18].utf8.count + recovered[18].utf8.count, 1024)
    }

    func testClassifierStallHasAnExplicitSafeFailureReasonWithoutInventingFrameworkErrors() {
        let capture = UUID(), failure = SoundClassificationFailure(stalledCaptureID: capture)
        XCTAssertEqual(failure.stage, .analysis)
        XCTAssertEqual(failure.captureID, capture)
        XCTAssertEqual(failure.reason, .resultTimeout)
        XCTAssertTrue(failure.causes.isEmpty)
        XCTAssertFalse(failure.truncated)
        XCTAssertEqual(failure.diagnosticDetails, "stage=analysis;reason=result_timeout;errors=;causes_truncated=false")
        XCTAssertFalse(failure.diagnosticDetails.contains(capture.uuidString))
    }

    func testClassifierFailureRetainsSafeCauseChainAndOnlyRecognizesExplicitGPUEvidence() {
        let secret = "private-token-device-name-path"
        let gpu = NSError(domain: "MTLCommandBufferErrorDomain", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "Insufficient Permission (to submit GPU work from background) " + secret,
            NSFilePathErrorKey: secret
        ])
        let core = NSError(domain: "com.apple.CoreML", code: 0, userInfo: [NSUnderlyingErrorKey: gpu])
        let error = NSError(domain: "com.apple.SoundAnalysis", code: 2,
                            userInfo: [NSUnderlyingErrorKey: core, NSLocalizedDescriptionKey: secret])
        let capture = UUID(), failure = SoundClassificationFailure(error: error, stage: .analysis, captureID: capture)
        XCTAssertEqual(failure.captureID, capture)
        XCTAssertEqual(failure.reason, .backgroundGPUDenied)
        XCTAssertEqual(failure.causes.map(\.domain), ["com.apple.SoundAnalysis", "com.apple.CoreML", "MTLCommandBufferErrorDomain"])
        XCTAssertEqual(failure.causes.map(\.code), [2, 0, 7])
        XCTAssertFalse(failure.truncated)
        XCTAssertFalse(failure.diagnosticDetails.contains(secret))
        let generic = SoundClassificationFailure(error: NSError(domain: "com.apple.SoundAnalysis", code: 2), stage: .analysis)
        XCTAssertEqual(generic.reason, .operationFailed, "Background context alone must never invent a GPU cause")
    }
    func testClassifierFailureBoundsNestedCausesAndRedactsUnknownDomainsAndMessages() {
        let secret = "private-domain-and-message"
        var error = NSError(domain: secret, code: 0, userInfo: [NSLocalizedDescriptionKey: secret])
        for code in 1...8 { error = NSError(domain: secret, code: code, userInfo: [NSUnderlyingErrorKey: error]) }
        let failure = SoundClassificationFailure(error: error, stage: .setup)
        XCTAssertEqual(failure.causes.count, 4)
        XCTAssertEqual(failure.causes.map(\.code), [8, 7, 6, 5])
        XCTAssertTrue(failure.truncated)
        XCTAssertTrue(failure.causes.allSatisfy { $0.domain == "other" })
        XCTAssertFalse(failure.diagnosticDetails.contains(secret))
        XCTAssertEqual(failure.reason, .unknown)
        let spoof = SoundClassificationFailure(error: NSError(domain: secret, code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Insufficient Permission (to submit GPU work from background)"
        ]), stage: .setup)
        XCTAssertEqual(spoof.reason, .unknown)
    }
    @MainActor func testFailureExportCorrelatesCaptureAndLifecycleWithoutTurningMissingScoresIntoZero() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = SoundAnalysisLog(directory: directory), now = Date(), capture = UUID()
        let failure = SoundClassificationFailure(error: NSError(domain: "com.apple.SoundAnalysis", code: 2),
                                                 stage: .analysis, captureID: capture)
        log.classification(.started(id: capture, at: now, sampleRate: 48_000, voiceProcessing: false, reason: .afterFailure), appActive: false)
        log.classification(.result(.init(captureID: capture, windowStart: now, windowEnd: now.addingTimeInterval(2),
                                        confidence: 0.8, observedAt: now.addingTimeInterval(2))), appActive: true)
        log.classification(.unavailable(at: now.addingTimeInterval(3), failure: failure), appActive: false)
        let export = try await log.prepareExport()
        defer { try? FileManager.default.removeItem(at: export[0].deletingLastPathComponent()) }
        let data = try rows(in: export)
        let row = try XCTUnwrap(data.first { $0[2] == "classifier_unavailable" })
        XCTAssertEqual(row[3], capture.uuidString.lowercased())
        XCTAssertEqual(row[6], "")
        XCTAssertEqual(row[17], "0")
        XCTAssertTrue(row[18].contains("stage=analysis;reason=operation_failed;errors=com.apple.SoundAnalysis:2"))
        XCTAssertTrue(try XCTUnwrap(data.first { $0[2] == "capture_start" })[18].contains("reason=after_failure"))
        XCTAssertNil(log.latestConfidence)
    }
    @MainActor func testExportPreservesQuietScoresAndVolumeTriggersAndDescribesBothAlertPaths() async throws {
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
        XCTAssertTrue(levels[2][18].contains("alert_trigger=volume;alert_policy=time_coverage_v1"))
        XCTAssertEqual(levels[1][16], "whiteNoise")
        let scores = data.filter { $0[2] == "classification" }
        XCTAssertEqual(scores.map { $0[6] }, ["0.000000", "0.987654"])
        XCTAssertNotEqual(scores[0][0], scores[0][5], "Receipt time must remain distinct from audio time")
        XCTAssertEqual(scores[0][3], capture.uuidString.lowercased())
        XCTAssertEqual(log.latestConfidence, 0.987654)
        let coverage = try String(contentsOf: export[1], encoding: .utf8)
        XCTAssertTrue(coverage.contains("alert_policy=time_coverage_v1"))
        XCTAssertTrue(coverage.contains(">=80% qualifying time"))
        XCTAssertTrue(coverage.contains("overlapping results label only newly covered suffixes"))
        XCTAssertTrue(coverage.contains("combined volume/classifier state"))
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
