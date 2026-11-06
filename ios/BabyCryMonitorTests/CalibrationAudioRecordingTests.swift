#if !canImport(MonitorCore)
import AVFoundation
import XCTest
@testable import BabyCryMonitor

final class CalibrationAudioRecordingTests: XCTestCase {
    private final class States: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [CalibrationAudioWriter.State] = []
        func append(_ state: CalibrationAudioWriter.State) { lock.lock(); values.append(state); lock.unlock() }
        var failed: Bool { lock.lock(); defer { lock.unlock() }; return values.contains { $0.failed } }
    }
    private final class FailingWrite: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        // Called only by the writer's serial queue.
        private var attempts = 0
        func write(_ file: AVAudioFile, _ buffer: AVAudioPCMBuffer) throws {
            attempts += 1
            if attempts == 2 {
                entered.signal(); release.wait()
                throw CocoaError(.fileWriteUnknown)
            }
            try file.write(from: buffer)
        }
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func buffer(seconds: Double = 1) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 48_000)))
        buffer.frameLength = buffer.frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(buffer.frameLength) { channel[frame] = 0.1 * sin(Float(frame) * 2 * .pi * 440 / 48_000) }
        return buffer
    }
    private func metadata(_ snapshot: URL) throws -> [CalibrationAudioWriter.Segment] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        return try FileManager.default.contentsOfDirectory(at: snapshot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try decoder.decode(CalibrationAudioWriter.Segment.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt < $1.startedAt }
    }
    @MainActor private func completedRecording() async throws -> CalibrationAudioRecording {
        let directory = try folder()
        let suite = "CalibrationAudioRecordingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let recording = CalibrationAudioRecording(defaults: defaults, directory: directory.appendingPathComponent("audio"),
            exportDirectory: directory.appendingPathComponent("exports"))
        recording.setEnabled(true); await recording.writer.waitUntilIdle()
        let id = recording.writer.beginCapture()
        recording.writer.consume(try buffer(), at: AVAudioTime(sampleTime: 0, atRate: 48_000), captureID: id, voiceProcessing: false)
        recording.writer.endCapture(id); await recording.writer.waitUntilIdle()
        return recording
    }
    func testDisabledRecorderSavesNoAudio() async throws {
        let directory = try folder(); let writer = CalibrationAudioWriter(directory: directory)
        writer.setEnabled(false); let id = writer.beginCapture()
        writer.consume(try buffer(), at: AVAudioTime(sampleTime: 0, atRate: 48_000), captureID: id, voiceProcessing: false)
        writer.endCapture(id); await writer.waitUntilIdle()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        do { _ = try await writer.snapshot(); XCTFail("Disabled capture must not produce an export") }
        catch { XCTAssertTrue(error is CalibrationAudioWriter.RecordingError) }
    }
    func testRecordsDecodableAACRotatesAndPreservesSubsecondTiming() async throws {
        let directory = try folder(); let writer = CalibrationAudioWriter(directory: directory)
        writer.setEnabled(true); await writer.waitUntilIdle()
        let id = writer.beginCapture(); let pcm = try buffer(); let origin = Date().addingTimeInterval(-70.123)
        for second in 0..<65 {
            writer.consume(pcm, at: AVAudioTime(sampleTime: Int64(second * 48_000), atRate: 48_000), captureID: id,
                voiceProcessing: true, capturedAt: origin.addingTimeInterval(Double(second + 1)))
            await writer.waitUntilIdle()
        }
        writer.endCapture(id); await writer.waitUntilIdle()
        let snapshot = try await writer.snapshot(); defer { try? FileManager.default.removeItem(at: snapshot) }
        let segments = try metadata(snapshot)
        XCTAssertEqual(segments.count, 2); XCTAssertEqual(segments.map(\.frames), [60 * 48_000, 5 * 48_000])
        XCTAssertEqual(try XCTUnwrap(segments.first).startedAt.timeIntervalSince1970, origin.timeIntervalSince1970, accuracy: 0.00001)
        XCTAssertTrue(segments.allSatisfy { $0.complete && $0.voiceProcessing && $0.captureID == id })
        for segment in segments {
            let audio = try AVAudioFile(forReading: snapshot.appendingPathComponent(segment.file))
            XCTAssertEqual(audio.fileFormat.channelCount, 1)
            XCTAssertEqual(audio.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
            XCTAssertEqual(Double(audio.length), Double(segment.frames), accuracy: 2048)
            let decoded = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 48_000))
            try audio.read(into: decoded)
            XCTAssertGreaterThan(decoded.frameLength, 0)
            let values = try XCTUnwrap(decoded.floatChannelData?[0])
            let energy = (0..<Int(decoded.frameLength)).reduce(0.0) { $0 + Double(values[$1] * values[$1]) }
            XCTAssertGreaterThan(energy / Double(decoded.frameLength), 0.001)
        }
        let sizes = try segments.map { try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent($0.file).path)[.size] as? NSNumber }
        XCTAssertLessThan(sizes.compactMap { $0?.intValue }.reduce(0, +), 600_000)
    }
    func testBoundedQueueDisclosesDropsAndSplitsTheTimeline() async throws {
        let queue = DispatchQueue(label: "CalibrationAudioRecordingTests")
        let writer = CalibrationAudioWriter(directory: try folder(), queue: queue)
        writer.setEnabled(true); await writer.waitUntilIdle()
        let id = writer.beginCapture(); let pcm = try buffer(seconds: 0.02); let now = Date()
        queue.suspend()
        for index in 0..<40 {
            writer.consume(pcm, at: AVAudioTime(sampleTime: Int64(index * 960), atRate: 48_000), captureID: id,
                voiceProcessing: false, capturedAt: now.addingTimeInterval(Double(index + 1) * 0.02))
        }
        queue.resume(); await writer.waitUntilIdle()
        writer.consume(pcm, at: AVAudioTime(sampleTime: 40 * 960, atRate: 48_000), captureID: id,
            voiceProcessing: false, capturedAt: now.addingTimeInterval(41 * 0.02))
        writer.endCapture(id); await writer.waitUntilIdle()
        let snapshot = try await writer.snapshot(); defer { try? FileManager.default.removeItem(at: snapshot) }
        let segments = try metadata(snapshot)
        XCTAssertEqual(segments.count, 2); XCTAssertEqual(segments.last?.droppedBuffersBefore, 8)
        XCTAssertEqual(segments.reduce(Int64(0)) { $0 + $1.frames }, 33 * 960)
    }
    func testDisablingStopsWritesAndExportRequiresStoppedMicrophone() async throws {
        let writer = CalibrationAudioWriter(directory: try folder()); let pcm = try buffer()
        writer.setEnabled(true); await writer.waitUntilIdle(); let id = writer.beginCapture()
        writer.consume(pcm, at: AVAudioTime(sampleTime: 0, atRate: 48_000), captureID: id, voiceProcessing: false)
        await writer.waitUntilIdle()
        do { _ = try await writer.snapshot(); XCTFail("Export during capture must be refused") }
        catch { XCTAssertTrue(error is CalibrationAudioWriter.RecordingError) }
        writer.setEnabled(false); await writer.waitUntilIdle()
        writer.consume(pcm, at: AVAudioTime(sampleTime: 48_000, atRate: 48_000), captureID: id, voiceProcessing: false)
        writer.endCapture(id); await writer.waitUntilIdle()
        let snapshot = try await writer.snapshot(); defer { try? FileManager.default.removeItem(at: snapshot) }
        XCTAssertEqual(try metadata(snapshot).map(\.frames), [48_000])
        try await writer.deleteAll()
        do { _ = try await writer.snapshot(); XCTFail("Deletion must remove recordings") }
        catch { XCTAssertTrue(error is CalibrationAudioWriter.RecordingError) }
    }
    func testRetentionRemovesExpiredAudioAndSidecarTogether() async throws {
        let directory = try folder()
        for suffix in ["m4a", "json"] {
            let url = directory.appendingPathComponent("old.\(suffix)")
            try Data("expired".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)], ofItemAtPath: url.path)
        }
        let writer = CalibrationAudioWriter(directory: directory); writer.refresh(); await writer.waitUntilIdle()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
    func testStorageFailureDisablesRecordingUntilExplicitlyEnabledAgain() async throws {
        let parent = try folder(); let obstruction = parent.appendingPathComponent("obstruction")
        try Data("file blocks directory creation".utf8).write(to: obstruction)
        let directory = obstruction.appendingPathComponent("audio"); let states = States()
        let writer = CalibrationAudioWriter(directory: directory, emit: states.append)
        writer.setEnabled(true); await writer.waitUntilIdle(); XCTAssertTrue(states.failed)
        try FileManager.default.removeItem(at: obstruction)
        let id = writer.beginCapture(); let pcm = try buffer()
        writer.consume(pcm, at: AVAudioTime(sampleTime: 0, atRate: 48_000), captureID: id, voiceProcessing: false)
        await writer.waitUntilIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "Storage becoming available must not silently resume recording")
        writer.setEnabled(true); await writer.waitUntilIdle()
        writer.consume(pcm, at: AVAudioTime(sampleTime: 48_000, atRate: 48_000), captureID: id, voiceProcessing: false)
        writer.endCapture(id); await writer.waitUntilIdle()
        let snapshot = try await writer.snapshot(); defer { try? FileManager.default.removeItem(at: snapshot) }
        XCTAssertEqual(try metadata(snapshot).map(\.frames), [48_000])
    }
    func testSupersededWriteFailureCannotMarkTheFailedSegmentComplete() async throws {
        let directory = try folder(); let failure = FailingWrite()
        let writer = CalibrationAudioWriter(directory: directory, writeAudio: failure.write)
        writer.setEnabled(true); await writer.waitUntilIdle()
        let id = writer.beginCapture(); let pcm = try buffer(); let origin = Date()
        writer.consume(pcm, at: AVAudioTime(sampleTime: 0, atRate: 48_000), captureID: id,
            voiceProcessing: false, capturedAt: origin.addingTimeInterval(1))
        await writer.waitUntilIdle()
        writer.consume(pcm, at: AVAudioTime(sampleTime: 48_000, atRate: 48_000), captureID: id,
            voiceProcessing: false, capturedAt: origin.addingTimeInterval(2))
        let didEnter = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: failure.entered.wait(timeout: .now() + 5) == .success) }
        }
        XCTAssertTrue(didEnter)
        writer.setEnabled(true) // Supersede the write before its error is delivered.
        failure.release.signal(); await writer.waitUntilIdle()
        writer.consume(pcm, at: AVAudioTime(sampleTime: 96_000, atRate: 48_000), captureID: id,
            voiceProcessing: false, capturedAt: origin.addingTimeInterval(3))
        writer.endCapture(id); await writer.waitUntilIdle()
        let all = try metadata(directory)
        XCTAssertEqual(all.count, 2); XCTAssertFalse(try XCTUnwrap(all.first).complete)
        let snapshot = try await writer.snapshot(); defer { try? FileManager.default.removeItem(at: snapshot) }
        XCTAssertEqual(try metadata(snapshot).map(\.sourceStartFrame), [96_000])
    }
    func testWallClockAdjustmentsSplitEvenWithContinuousSourceFrames() async throws {
        for adjustment in [-3600.0, 3600.0] {
            let writer = CalibrationAudioWriter(directory: try folder()); writer.setEnabled(true); await writer.waitUntilIdle()
            let id = writer.beginCapture(); let pcm = try buffer(); let origin = Date()
            writer.consume(pcm, at: AVAudioTime(sampleTime: 0, atRate: 48_000), captureID: id,
                voiceProcessing: false, capturedAt: origin.addingTimeInterval(1))
            await writer.waitUntilIdle()
            writer.consume(pcm, at: AVAudioTime(sampleTime: 48_000, atRate: 48_000), captureID: id,
                voiceProcessing: false, capturedAt: origin.addingTimeInterval(2 + adjustment))
            writer.endCapture(id); await writer.waitUntilIdle()
            let snapshot = try await writer.snapshot(); defer { try? FileManager.default.removeItem(at: snapshot) }
            let segments = try metadata(snapshot); XCTAssertEqual(segments.count, 2)
            let after = try XCTUnwrap(segments.first { $0.sourceStartFrame == 48_000 })
            XCTAssertEqual(after.startedAt.timeIntervalSince1970, origin.addingTimeInterval(1 + adjustment).timeIntervalSince1970, accuracy: 0.00001)
        }
    }
    @MainActor func testExportAndDeleteRemainExclusiveWhileAnalysisExportIsAwaited() async throws {
        let recording = try await completedRecording()
        let entered = AsyncStream<Void>.makeStream(); let release = AsyncStream<Void>.makeStream()
        let export = Task {
            try await recording.prepareExport {
                entered.continuation.yield(()); entered.continuation.finish()
                for await _ in release.stream { break }
                return []
            }
        }
        for await _ in entered.stream { break }
        XCTAssertTrue(recording.busy)
        do { try await recording.deleteAll(); XCTFail("Delete must not overlap export") }
        catch { guard case .operationInProgress = error as? CalibrationAudioWriter.RecordingError else { return XCTFail("Unexpected error: \(error)") } }
        do { _ = try await recording.prepareExport(); XCTFail("A second export must not overlap") }
        catch { guard case .operationInProgress = error as? CalibrationAudioWriter.RecordingError else { return XCTFail("Unexpected error: \(error)") } }
        release.continuation.yield(()); release.continuation.finish()
        let files = try await export.value
        XCTAssertFalse(recording.busy); XCTAssertEqual(files.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(files.first).path))
        try await recording.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(files.first).path))
    }
    @MainActor func testCancelledExportRemovesZIPAndSnapshotAndReleasesBusyState() async throws {
        let recording = try await completedRecording()
        let entered = AsyncStream<Void>.makeStream(); let release = AsyncStream<Void>.makeStream()
        let export = Task {
            try await recording.prepareExport {
                entered.continuation.yield(()); entered.continuation.finish()
                for await _ in release.stream { break }
                return []
            }
        }
        for await _ in entered.stream { break }
        export.cancel(); release.continuation.yield(()); release.continuation.finish()
        do { _ = try await export.value; XCTFail("A cancelled export must not publish a file") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(recording.busy)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: recording.writer.exportDirectory.path).isEmpty)
        try await recording.deleteAll()
    }
    @MainActor func testAnalysisExportFailureRemovesNewZIPAndPreservesPreviousExport() async throws {
        let recording = try await completedRecording()
        let previous = try await recording.prepareExport()
        do {
            _ = try await recording.prepareExport { throw CocoaError(.fileWriteOutOfSpace) }
            XCTFail("Analysis export failure must propagate")
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue) }
        XCTAssertFalse(recording.busy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(previous.first).path))
        let remaining = try FileManager.default.contentsOfDirectory(at: recording.writer.exportDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(remaining.map { $0.resolvingSymlinksInPath() }, [try XCTUnwrap(previous.first).deletingLastPathComponent().resolvingSymlinksInPath()])
    }
    @MainActor func testPreparedCalibrationExportSurvivesReplacementOfDiagnosticsExport() async throws {
        let recording = try await completedRecording()
        let diagnostics = try folder()
        let csv = diagnostics.appendingPathComponent("sound-analysis.csv")
        let report = diagnostics.appendingPathComponent("coverage.txt")
        let readings = Data("recorded_at,dbfs\n2026-11-06T21:00:00Z,-25\n".utf8)
        try readings.write(to: csv); try Data("complete".utf8).write(to: report)
        let prepared = try await recording.prepareExport { [csv, report] }
        // This is how the Diagnostics exporter replaces its previous export.
        try FileManager.default.removeItem(at: diagnostics)
        XCTAssertEqual(prepared.count, 3)
        XCTAssertEqual(try Data(contentsOf: prepared[1]), readings)
        XCTAssertEqual(try String(contentsOf: prepared[2], encoding: .utf8), "complete")
        try await recording.deleteAll()
        XCTAssertTrue(prepared.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
    @MainActor func testDeletionReportsPreparedAudioRemovalFailureAndCanBeRetried() async throws {
        let recording = try await completedRecording()
        let prepared = try await recording.prepareExport()
        let audio = try XCTUnwrap(prepared.first)
        let folder = audio.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        do { try await recording.deleteAll(); XCTFail("Deletion must report an audio export that could not be removed") }
        catch { XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path)) }
        XCTAssertFalse(recording.busy)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try await recording.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }
}
#endif
