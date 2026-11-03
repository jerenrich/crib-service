import AVFoundation
import Foundation
import SoundAnalysis

/// Shared across graph rebuilds. Changing the epoch invalidates queued audio and
/// late model results immediately, including when Standby retains the microphone.
final class SoundClassificationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var epoch = 0
    private var reset: (@Sendable () -> Void)?
    func registerReset(_ reset: @escaping @Sendable () -> Void) {
        lock.lock(); self.reset = reset; lock.unlock()
    }
    func setEnabled(_ value: Bool) {
        lock.lock()
        guard enabled != value else { lock.unlock(); return }
        enabled = value; epoch += 1
        let reset = self.reset
        lock.unlock()
        if !value { reset?() }
    }
    var currentEpoch: Int? {
        lock.lock(); defer { lock.unlock() }
        return enabled ? epoch : nil
    }
}

/// Owns bounded, transient copies of microphone buffers. Model execution stays
/// off the capture callback and never delays the existing RMS detector.
final class BabyCryClassifier: @unchecked Sendable {
    static let windowSeconds = 2.0
    static let overlap = 0.5
    private let queue = DispatchQueue(label: "CribService.SoundAnalysis", qos: .utility)
    private var pendingBuffers = 0 // Protected by lock; at most 64 transient copies.
    private let control: SoundClassificationControl
    private let emit: @Sendable (SoundClassificationEvent) -> Void
    private let lock = NSLock()
    private var stopped = false
    private var dropped = 0
    // Owned solely by queue:
    private var session: Session?
    private var epoch: Int?
    private var failedEpoch: Int?
    private var expectedFrame: AVAudioFramePosition?

    init(control: SoundClassificationControl, emit: @escaping @Sendable (SoundClassificationEvent) -> Void) {
        self.control = control; self.emit = emit
        control.registerReset { [weak self] in self?.reset() }
    }
    private func reset() { queue.async { [self] in endSession(); epoch = nil; failedEpoch = nil } }
    /// A copied buffer has one owner after transfer to the serial queue.
    private struct OwnedBuffer: @unchecked Sendable { let value: AVAudioPCMBuffer }
    func consume(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime, voiceProcessing: Bool) {
        guard let epoch = control.currentEpoch else {
            // One queued reset suffices; no raw buffers are retained in Standby.
            return
        }
        lock.lock()
        guard !stopped, pendingBuffers < 64 else {
            if !stopped { dropped += 1 }
            lock.unlock(); return
        }
        pendingBuffers += 1
        lock.unlock()
        guard let copy = Self.copy(buffer) else {
            lock.lock(); pendingBuffers -= 1; dropped += 1; lock.unlock(); return
        }
        let owned = OwnedBuffer(value: copy)
        let end = Date()
        let start = end.addingTimeInterval(-Double(buffer.frameLength) / buffer.format.sampleRate)
        let frame = time.isSampleTimeValid ? time.sampleTime : nil
        queue.async { [self, owned] in
            let copy = owned.value
            defer { lock.lock(); pendingBuffers -= 1; lock.unlock() }
            lock.lock(); let isStopped = stopped; let lost = dropped; dropped = 0; lock.unlock()
            guard !isStopped, control.currentEpoch == epoch else { return }
            // Any discarded input or discontinuous frame position starts a new
            // analysis segment so a window cannot silently bridge missing audio.
            let gap = lost > 0 || (frame != nil && expectedFrame != nil && frame != expectedFrame)
            if self.epoch != epoch || gap {
                endSession()
                self.epoch = epoch; failedEpoch = nil
            }
            if lost > 0 { emit(.droppedBuffers(count: lost, at: end)) }
            guard failedEpoch != epoch else { return }
            do {
                if session == nil {
                    session = try Session(format: copy.format, origin: start, epoch: epoch,
                                          control: control, emit: emit)
                    emit(.started(id: session!.id, at: start, sampleRate: copy.format.sampleRate, voiceProcessing: voiceProcessing))
                }
                session?.analyze(copy)
                if session?.hasFailed == true { endSession(); failedEpoch = epoch }
                expectedFrame = frame.map { $0 + AVAudioFramePosition(copy.frameLength) }
            } catch {
                endSession(); failedEpoch = epoch
                emit(.unavailable(at: end))
            }
        }
    }
    func stop() {
        lock.lock(); stopped = true; let lost = dropped; dropped = 0; lock.unlock()
        queue.async { [self] in
            if lost > 0 { emit(.droppedBuffers(count: lost, at: Date())) }
            endSession()
        }
    }
    private func endSession() {
        if let session {
            session.analyzer.removeAllRequests()
            emit(.stopped(id: session.id, at: Date()))
        }
        session = nil; expectedFrame = nil
    }
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            guard let src = source[index].mData, let dst = destination[index].mData else { return nil }
            memcpy(dst, src, Int(source[index].mDataByteSize))
        }
        return copy
    }
    // Only the analysis queue invokes the analyzer or its synchronous callbacks.
    private final class Session: NSObject, SNResultsObserving {
        let id = UUID()
        let analyzer: SNAudioStreamAnalyzer
        private let origin: Date
        private let epoch: Int
        private let control: SoundClassificationControl
        private let emit: @Sendable (SoundClassificationEvent) -> Void
        private var position: AVAudioFramePosition = 0
        private let failureLock = NSLock()
        private var failed = false
        var hasFailed: Bool {
            failureLock.lock(); defer { failureLock.unlock() }; return failed
        }
        init(format: AVAudioFormat, origin: Date, epoch: Int, control: SoundClassificationControl,
             emit: @escaping @Sendable (SoundClassificationEvent) -> Void) throws {
            self.origin = origin; self.epoch = epoch; self.control = control; self.emit = emit
            analyzer = SNAudioStreamAnalyzer(format: format)
            super.init()
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            guard request.knownClassifications.contains("baby_crying") else { throw ClassifierError.missingLabel }
            request.windowDuration = CMTime(seconds: BabyCryClassifier.windowSeconds, preferredTimescale: 48_000)
            request.overlapFactor = BabyCryClassifier.overlap
            try analyzer.add(request, withObserver: self)
        }
        func analyze(_ buffer: AVAudioPCMBuffer) {
            analyzer.analyze(buffer, atAudioFramePosition: position)
            position += AVAudioFramePosition(buffer.frameLength)
        }
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard control.currentEpoch == epoch,
                  let result = result as? SNClassificationResult,
                  let score = result.classification(forIdentifier: "baby_crying"),
                  score.confidence.isFinite, (0...1).contains(score.confidence),
                  result.timeRange.start.seconds.isFinite, result.timeRange.duration.seconds.isFinite else { return }
            emit(.result(.init(captureID: id, windowStart: origin.addingTimeInterval(result.timeRange.start.seconds),
                windowEnd: origin.addingTimeInterval(CMTimeRangeGetEnd(result.timeRange).seconds),
                confidence: score.confidence, observedAt: Date())))
        }
        func request(_ request: SNRequest, didFailWithError error: any Error) {
            failureLock.lock(); let first = !failed; failed = true; failureLock.unlock()
            if first, control.currentEpoch == epoch { emit(.unavailable(at: Date())) }
        }
    }
    private enum ClassifierError: Error { case missingLabel }
}
