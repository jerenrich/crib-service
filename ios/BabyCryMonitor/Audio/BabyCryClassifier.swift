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
    var hasProducedResult: Bool { get }
    func analyze(_ buffer: AVAudioPCMBuffer)
    func stop()
}

final class BabyCryClassifier: @unchecked Sendable {
    static let windowSeconds = 2.0
    static let overlap = 0.5
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
        }
    }
    /// A copied buffer has one owner after transfer to the serial queue.
    private struct OwnedBuffer: @unchecked Sendable { let value: AVAudioPCMBuffer }
    func consume(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime, voiceProcessing: Bool) {
        guard let epoch = control.currentEpoch else { return }
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
        let end = Date()
        let start = end.addingTimeInterval(-Double(buffer.frameLength) / buffer.format.sampleRate)
        let frame = time.isSampleTimeValid ? time.sampleTime : nil
        queue.async { [self, owned] in
            let copy = owned.value
            defer { lock.lock(); pendingBuffers -= 1; lock.unlock() }
            lock.lock(); let isStopped = stopped; lock.unlock()
            guard !isStopped, control.currentEpoch == epoch else { return }
            if self.epoch != epoch {
                endSession(); self.epoch = epoch; recovery = .init(); expectedFrame = nil
            }
            let gap = lost > 0 || (frame != nil && expectedFrame != nil && frame != expectedFrame)
            // Observe EVERY input frame, including buffers skipped during backoff.
            // An input gap must never clear failure state or authorize an early retry.
            defer { expectedFrame = frame.map { $0 + AVAudioFramePosition(copy.frameLength) } }
            if gap { endSession() }
            if lost > 0 { emit(.droppedBuffers(count: lost, at: end)) }
            guard recovery.canAttempt(at: currentTime()) else { return }
            do {
                if session == nil {
                    let created = try makeSession(copy.format, start, epoch, control, emit)
                    guard isCurrent(epoch: epoch) else { created.stop(); return }
                    session = created
                    emit(.started(id: created.id, at: start, sampleRate: copy.format.sampleRate, voiceProcessing: voiceProcessing))
                }
                session?.analyze(copy)
                guard isCurrent(epoch: epoch) else { endSession(); return }
                if let failure = session?.failure { fail(failure, at: Date()) }
                else if session?.hasProducedResult == true { recovery.succeeded(); control.noteSuccess(epoch: epoch) }
            } catch {
                guard isCurrent(epoch: epoch) else { endSession(); return }
                fail(.init(error, stage: .initialization), at: Date())
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
    private let lock = NSLock()
    private var recordedFailure: SoundClassificationFailure?
    private var producedResult = false
    var failure: SoundClassificationFailure? { lock.lock(); defer { lock.unlock() }; return recordedFailure }
    var hasProducedResult: Bool { lock.lock(); defer { lock.unlock() }; return producedResult }
    init(format: AVAudioFormat, origin: Date, epoch: Int, control: SoundClassificationControl,
         emit: @escaping @Sendable (SoundClassificationEvent) -> Void) throws {
        self.origin = origin; self.epoch = epoch; self.control = control; self.emit = emit
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
    func analyze(_ buffer: AVAudioPCMBuffer) {
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
        lock.lock(); producedResult = true; lock.unlock()
        emit(.result(.init(captureID: id, windowStart: origin.addingTimeInterval(result.timeRange.start.seconds),
            windowEnd: origin.addingTimeInterval(CMTimeRangeGetEnd(result.timeRange).seconds),
            confidence: score.confidence, observedAt: Date())))
    }
    func request(_ request: SNRequest, didFailWithError error: any Error) {
        lock.lock(); defer { lock.unlock() }
        if recordedFailure == nil { recordedFailure = .init(error, stage: .inference) }
    }
}
