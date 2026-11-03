#if !canImport(MonitorCore)
import AVFoundation
import XCTest
@testable import BabyCryMonitor

final class BabyCryClassifierTests: XCTestCase {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [SoundClassificationEvent] = []
        func append(_ event: SoundClassificationEvent) { lock.lock(); events.append(event); lock.unlock() }
        var scores: [SoundClassificationObservation] {
            lock.lock(); defer { lock.unlock() }
            return events.compactMap { if case .result(let score) = $0 { score } else { nil } }
        }
        var unavailable: Bool {
            lock.lock(); defer { lock.unlock() }
            return events.contains { if case .unavailable = $0 { true } else { false } }
        }
    }
    func testLiveBuffersProduceTimestampedScoresAndDisablingInvalidatesLateResults() async throws {
        let events = Events(), control = SoundClassificationControl()
        let classifier = BabyCryClassifier(control: control, emit: events.append)
        defer { classifier.stop() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buffer.frameLength = 1600
        buffer.floatChannelData![0].initialize(repeating: 0, count: 1600)
        control.setEnabled(true)
        for index in 0..<60 {
            classifier.consume(buffer, at: .init(sampleTime: AVAudioFramePosition(index * 1600), atRate: 16_000), voiceProcessing: false)
            try await Task.sleep(for: .milliseconds(50))
        }
        for _ in 0..<100 where events.scores.isEmpty && !events.unavailable { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(events.unavailable, "The built-in model must accept live microphone-format buffers")
        let scores = events.scores
        XCTAssertFalse(scores.isEmpty)
        if let score = scores.first {
            XCTAssertTrue((0...1).contains(score.confidence))
            XCTAssertEqual(score.windowEnd.timeIntervalSince(score.windowStart), 2, accuracy: 0.001)
        }
        control.setEnabled(false)
        try await Task.sleep(for: .milliseconds(200))
        let count = events.scores.count
        for index in 60..<70 {
            classifier.consume(buffer, at: .init(sampleTime: AVAudioFramePosition(index * 1600), atRate: 16_000), voiceProcessing: false)
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(events.scores.count, count)
        control.setEnabled(true)
        for index in 100..<140 {
            classifier.consume(buffer, at: .init(sampleTime: AVAudioFramePosition(index * 1600), atRate: 16_000), voiceProcessing: true)
            try await Task.sleep(for: .milliseconds(50))
        }
        for _ in 0..<100 where events.scores.count == count && !events.unavailable {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(events.scores.count, count)
        XCTAssertNotEqual(events.scores.last?.captureID, scores.first?.captureID,
                          "Resuming must start a fresh analysis window and capture identity")
    }
}
#endif
