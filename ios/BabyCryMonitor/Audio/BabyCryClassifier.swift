import AVFoundation
import Foundation
import SoundAnalysis

/// Epoch changes invalidate queued audio/results on Stop, resume and foreground
/// recovery. Backgrounding itself does not assume the model cannot run.
final class SoundClassificationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var active = true
    private var epoch = 0
    private var needsForegroundRecovery = false
    private var reset: (@Sendable (Int) -> Void)?
    func registerReset(_ reset: @escaping @Sendable (Int) -> Void) {
        lock.lock(); self.reset = reset; lock.unlock()
    }
    func setEnabled(_ value: Bool) {
        lock.lock()
        guard enabled != value else { lock.unlock(); return }
        enabled = value; epoch += 1; needsForegroundRecovery = false
        let invalidation = epoch
        let reset = self.reset
        lock.unlock()
        if !value { reset?(invalidation) }
    }
    func setAppActive(_ value: Bool) {
        lock.lock()
        let foregrounded = value && !active && enabled && needsForegroundRecovery
        active = value
        if foregrounded { epoch += 1; needsForegroundRecovery = false }
        let invalidation = epoch
        let reset = self.reset
        lock.unlock()
        if foregrounded { reset?(invalidation) }
    }
    func noteFailure(epoch expected: Int) {
        lock.lock(); defer { lock.unlock() }
        if enabled, epoch == expected { needsForegroundRecovery = true }
    }
    func noteSuccess(epoch expected: Int) {
        lock.lock(); defer { lock.unlock() }
        if enabled, epoch == expected { needsForegroundRecovery = false }
    }
    var appActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    var currentEpoch: Int? {
        lock.lock(); defer { lock.unlock() }
        return enabled ? epoch : nil
    }
}

/// Injectable at the actual stream boundary, allowing long failure sequences to
/// exercise buffer admission, discontinuities, retries and teardown together.
protocol SoundClassifierStreaming: AnyObject {
    var id: UUID { get }
    var failure: SoundClassificationFailure? { get }
    /// End of the latest valid, input-mapped result in the session's audio clock.
    var latestResultWindowEnd: TimeInterval? { get }
    func analyze(_ buffer: AVAudioPCMBuffer, capturedAt: Date)
    func stop()
}

final class BabyCryClassifier: @unchecked Sendable {
    static let windowSeconds = CryConfidenceDetector.windowDuration
    static let overlap = 0.5
    /// Allows startup and transient inference delays without retaining a silent
    /// analyzer indefinitely. Checked only when more microphone audio arrives.
    static let resultTimeout: Duration = .seconds(10)
    typealias SessionFactory = @Sendable (AVAudioFormat, Date, Int, SoundClassificationControl,
        @escaping @Sendable (SoundClassificationEvent) -> Void) throws -> any SoundClassifierStreaming
    private let queue = DispatchQueue(label: "CribService.SoundAnalysis", qos: .utility)
    private var pendingBuffers = 0 // Protected by lock; at most 64 transient copies.
    private let control: SoundClassificationControl
    private let emit: @Sendable (SoundClassificationEvent) -> Void
    private let makeSession: SessionFactory
    private let currentTime: @Sendable () -> ContinuousClock.Instant
    private let lock = NSLock()
    private var stopped = false
    private var dropped = 0
    // Owned solely by queue:
    private var session: (any SoundClassifierStreaming)?
    private var epoch: Int?
    private var recovery = SoundClassifierRecovery()
    private var expectedFrame: AVAudioFramePosition?
    private var nextStartReason: SoundClassificationStartReason = .initial
    private var lastResultWindowEnd: TimeInterval?
    private var lastProgressAt: ContinuousClock.Instant?
    private var sessionStartedAt: ContinuousClock.Instant?
    private var receivedAudio: TimeInterval = 0
    private var inputBuffers = 0

    init(control: SoundClassificationControl, emit: @escaping @Sendable (SoundClassificationEvent) -> Void,
         currentTime: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         makeSession: @escaping SessionFactory = { try Session(format: $0, origin: $1, epoch: $2, control: $3, emit: $4) }) {
        self.control = control; self.emit = emit; self.currentTime = currentTime; self.makeSession = makeSession
        control.registerReset { [weak self] epoch in self?.invalidate(before: epoch) }
    }
    func invalidate(before invalidation: Int) {
        queue.async { [self] in
            // A delayed Stop/foreground callback must not destroy a newer stream.
            guard let epoch, epoch < invalidation else { return }
            endSession(); self.epoch = nil; recovery = .init(); expectedFrame = nil
            nextStartReason = .monitoringRestart
        }
    }
    /// A copied buffer has one owner after transfer to the serial queue.
    private struct OwnedBuffer: @unchecked Sendable { let value: AVAudioPCMBuffer }
    func consume(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime, voiceProcessing: Bool) {
        guard let epoch = control.currentEpoch else { return }
        let end = Date()
        lock.lock()
        guard !stopped, pendingBuffers < 64 else {
            if !stopped { dropped += 1 }
            lock.unlock(); return
        }
        pendingBuffers += 1
        let lost = dropped; dropped = 0
        lock.unlock()
        guard let copy = Self.copy(buffer) else {
            lock.lock(); pendingBuffers -= 1; dropped += lost + 1; lock.unlock(); return
        }
        let owned = OwnedBuffer(value: copy)
        let start = end.addingTimeInterval(-Double(buffer.frameLength) / buffer.format.sampleRate)
        let frame = time.isSampleTimeValid ? time.sampleTime : nil
        queue.async { [self, owned] in
            let copy = owned.value
            defer { lock.lock(); pendingBuffers -= 1; lock.unlock() }
            lock.lock(); let isStopped = stopped; lock.unlock()
            guard !isStopped, control.currentEpoch == epoch else { return }
            if self.epoch != epoch {
                if self.epoch != nil { nextStartReason = .monitoringRestart }
                endSession(); self.epoch = epoch; recovery = .init(); expectedFrame = nil
            }
            let gap = lost > 0 || (frame != nil && expectedFrame != nil && frame != expectedFrame)
            // Observe EVERY input frame, including buffers skipped during backoff.
            // An input gap must never clear failure state or authorize an early retry.
            defer { expectedFrame = frame.map { $0 + AVAudioFramePosition(copy.frameLength) } }
            if gap {
                if recovery.consecutiveFailures == 0 { nextStartReason = .audioGap }
                endSession()
            }
            if lost > 0 { emit(.droppedBuffers(count: lost, at: end)) }
            guard recovery.canAttempt(at: currentTime()) else { return }
            do {
                if session == nil {
                    let created = try makeSession(copy.format, start, epoch, control, emit)
                    guard isCurrent(epoch: epoch) else { created.stop(); return }
                    session = created
                    lastProgressAt = currentTime()
                    sessionStartedAt = lastProgressAt
                    emit(.started(id: created.id, at: start, sampleRate: copy.format.sampleRate,
                                  voiceProcessing: voiceProcessing, reason: nextStartReason))
                }
                receivedAudio = min(86_400, receivedAudio + Double(copy.frameLength) / copy.format.sampleRate)
                inputBuffers = min(1_000_000_000, inputBuffers + 1)
                session?.analyze(copy, capturedAt: end)
                guard isCurrent(epoch: epoch) else { endSession(); return }
                if let failure = session?.failure { fail(failure, at: Date()) }
                else {
                    let now = currentTime()
                    if let end = session?.latestResultWindowEnd, end.isFinite,
                       lastResultWindowEnd.map({ end > $0 }) ?? true {
                        lastResultWindowEnd = end; lastProgressAt = now
                        recovery.succeeded(); control.noteSuccess(epoch: epoch)
                    } else if let lastProgressAt, lastProgressAt.duration(to: now) >= Self.resultTimeout,
                              let id = session?.id, let sessionStartedAt {
                        let context = SoundClassificationFailure.StallContext(timeout: Self.resultTimeout,
                            sessionAge: sessionStartedAt.duration(to: now), noProgress: lastProgressAt.duration(to: now),
                            receivedAudio: receivedAudio, inputBuffers: inputBuffers, lastResultWindowEnd: lastResultWindowEnd)
                        fail(.init(stalledCaptureID: id, context: context), at: Date())
                    }
                }
            } catch {
                guard isCurrent(epoch: epoch) else { endSession(); return }
                fail(.init(error: error, stage: .setup), at: Date())
            }
        }
    }
    private func isCurrent(epoch expected: Int) -> Bool {
        lock.lock(); let isStopped = stopped; lock.unlock()
        return !isStopped && control.currentEpoch == expected
    }
    private func fail(_ failure: SoundClassificationFailure, at date: Date) {
        let id = session?.id
        if let epoch { control.noteFailure(epoch: epoch) }
        endSession()
        let delay = recovery.failed(at: currentTime())
        nextStartReason = .afterFailure
        emit(.unavailable(at: date, failure: failure, captureID: id,
                          retryAfterSeconds: delay, appActive: control.appActive))
    }
    func stop() {
        lock.lock(); stopped = true; let lost = dropped; dropped = 0; lock.unlock()
        queue.async { [self] in
            if lost > 0 { emit(.droppedBuffers(count: lost, at: Date())) }
            endSession()
        }
    }
    /// A barrier for stream integration tests; it neither flushes nor pads model audio.
    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    private func endSession() {
        if let session {
            session.stop()
            emit(.stopped(id: session.id, at: Date()))
        }
        session = nil
        lastResultWindowEnd = nil; lastProgressAt = nil
        sessionStartedAt = nil; receivedAudio = 0; inputBuffers = 0
    }
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0, let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            guard let src = source[index].mData, let dst = destination[index].mData,
                  source[index].mDataByteSize <= destination[index].mDataByteSize else { return nil }
            memcpy(dst, src, Int(source[index].mDataByteSize))
        }
        return copy
    }
}

private final class Session: NSObject, SoundClassifierStreaming, SNResultsObserving {
    let id = UUID()
    private let analyzer: SNAudioStreamAnalyzer
    private let origin: Date
    private let epoch: Int
    private let control: SoundClassificationControl
    private let emit: @Sendable (SoundClassificationEvent) -> Void
    private var position: AVAudioFramePosition = 0
    private var audioClock: SoundClassificationAudioClock
    private let lock = NSLock()
    private var recordedFailure: SoundClassificationFailure?
    private var resultWindowEnd: TimeInterval?
    var failure: SoundClassificationFailure? { lock.lock(); defer { lock.unlock() }; return recordedFailure }
    var latestResultWindowEnd: TimeInterval? { lock.lock(); defer { lock.unlock() }; return resultWindowEnd }
    init(format: AVAudioFormat, origin: Date, epoch: Int, control: SoundClassificationControl,
         emit: @escaping @Sendable (SoundClassificationEvent) -> Void) throws {
        self.origin = origin; self.epoch = epoch; self.control = control; self.emit = emit
        audioClock = SoundClassificationAudioClock(sampleRate: format.sampleRate)
        analyzer = SNAudioStreamAnalyzer(format: format)
        super.init()
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        guard request.knownClassifications.contains("baby_crying") else {
            throw NSError(domain: "CribService.SoundClassifier", code: 1)
        }
        request.windowDuration = CMTime(seconds: BabyCryClassifier.windowSeconds, preferredTimescale: 48_000)
        request.overlapFactor = BabyCryClassifier.overlap
        try analyzer.add(request, withObserver: self)
    }
    func analyze(_ buffer: AVAudioPCMBuffer, capturedAt: Date) {
        lock.lock()
        audioClock.receive(through: position + AVAudioFramePosition(buffer.frameLength), at: capturedAt)
        lock.unlock()
        analyzer.analyze(buffer, atAudioFramePosition: position)
        position += AVAudioFramePosition(buffer.frameLength)
    }
    func stop() { analyzer.removeAllRequests() }
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard control.currentEpoch == epoch, failure == nil,
              let result = result as? SNClassificationResult,
              let score = result.classification(forIdentifier: "baby_crying"),
              score.confidence.isFinite, (0...1).contains(score.confidence),
              result.timeRange.start.seconds.isFinite, result.timeRange.duration.seconds.isFinite else { return }
        lock.lock()
        let end = CMTimeRangeGetEnd(result.timeRange).seconds
        let capturedEnd = audioClock.capturedWindowEnd(at: end)
        // Duplicate, invalid and unmapped windows cannot keep the watchdog alive.
        // Confidence is deliberately irrelevant to classifier health.
        if capturedEnd != nil, end.isFinite, (1.9...2.1).contains(result.timeRange.duration.seconds),
           result.timeRange.start.seconds >= 0, resultWindowEnd.map({ end > $0 }) ?? true {
            resultWindowEnd = end
        }
        lock.unlock()
        guard let capturedEnd else {
            // Preserve capture/window scope: an obsolete callback cannot create
            // a new global gap that resets the replacement capture's evidence.
            emit(.unmappedResult(captureID: id, windowEnd: origin.addingTimeInterval(CMTimeRangeGetEnd(result.timeRange).seconds),
                                 at: Date())); return
        }
        emit(.result(.init(captureID: id, windowStart: origin.addingTimeInterval(result.timeRange.start.seconds),
            windowEnd: origin.addingTimeInterval(CMTimeRangeGetEnd(result.timeRange).seconds),
            confidence: score.confidence, observedAt: Date(), audioWindowEndAt: capturedEnd)))
    }
    func request(_ request: SNRequest, didFailWithError error: any Error) {
        lock.lock(); defer { lock.unlock() }
        if recordedFailure == nil { recordedFailure = .init(error: error, stage: .analysis, captureID: id) }
    }
}
