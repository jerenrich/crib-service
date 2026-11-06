import Foundation

/// On-device audio-window confidence, used independently of volume detection.
struct SoundClassificationObservation: Sendable {
    let captureID: UUID
    let windowStart: Date
    let windowEnd: Date
    let confidence: Double
    let observedAt: Date
    /// Independent wall-clock stamp for the window's final audio frame, mapped
    /// from input buffers before inference. Nil retains compatibility with
    /// synthetic/legacy observations whose window dates already use wall time.
    var audioWindowEndAt: Date? = nil
}

/// An independent audio-frame/wall-time anchor. Only input admission updates
/// this clock; a delayed inference callback cannot shift a window's capture time.
struct SoundClassificationAudioClock: Sendable {
    static let maximumAnchors = 1024
    let sampleRate: Double
    private struct Anchor: Sendable {
        let startFrame: Int64
        let endFrame: Int64
        let capturedAt: Date
    }
    private var anchors: [Anchor] = []
    private var oldest = 0
    private var endFrame: Int64 = 0

    mutating func receive(through frame: Int64, at date: Date) {
        guard sampleRate.isFinite, sampleRate > 0, frame > endFrame,
              date.timeIntervalSinceReferenceDate.isFinite else { return }
        let anchor = Anchor(startFrame: endFrame, endFrame: frame, capturedAt: date)
        if anchors.count < Self.maximumAnchors { anchors.append(anchor) }
        else { anchors[oldest] = anchor; oldest = (oldest + 1) % Self.maximumAnchors }
        endFrame = frame
    }

    func capturedWindowEnd(at audioSeconds: Double) -> Date? {
        guard !anchors.isEmpty, audioSeconds.isFinite, audioSeconds >= 0 else { return nil }
        let requestedFrame = audioSeconds * sampleRate
        guard requestedFrame.isFinite, requestedFrame <= Double(endFrame) + 1 else { return nil }
        // A one-sample CMTime conversion tolerance applies only to the end of
        // admitted input, never to choosing between two known buffer anchors.
        let frame = min(requestedFrame, Double(endFrame))
        for offset in 0..<anchors.count {
            let anchor = anchors[(oldest + offset) % anchors.count]
            // Use the buffer that actually contained the window end. A newer
            // buffer's arrival (possibly delayed) must not move old audio.
            if frame > Double(anchor.startFrame), frame <= Double(anchor.endFrame) {
                return anchor.capturedAt.addingTimeInterval(-max(0, Double(anchor.endFrame) - frame) / sampleRate)
            }
        }
        // Old/unmapped results fail closed, rather than using a callback stamp.
        return nil
    }
}

enum SoundClassificationEvent: Sendable {
    case started(id: UUID, at: Date, sampleRate: Double, voiceProcessing: Bool,
                 reason: SoundClassificationStartReason = .initial)
    case result(SoundClassificationObservation)
    case stopped(id: UUID, at: Date)
    case unavailable(at: Date, failure: SoundClassificationFailure? = nil, captureID: UUID? = nil,
                     retryAfterSeconds: Int? = nil, appActive: Bool? = nil)
    case droppedEvents(at: Date)
    case droppedBuffers(count: Int, at: Date)
    /// A model result outside input timestamp coverage. Unlike channel loss,
    /// its capture and sample-window identity are known and must stay scoped.
    case unmappedResult(captureID: UUID, windowEnd: Date, at: Date)
}

/// Keep capture identity recoverable when bounded event delivery drops its
/// original start. Replay metadata before the gap, never adopt an unknown score.
final class SoundClassificationEventDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<SoundClassificationEvent>.Continuation
    private let currentTime: @Sendable () -> Date
    private var activeStart: SoundClassificationEvent?

    init(_ continuation: AsyncStream<SoundClassificationEvent>.Continuation,
         currentTime: @escaping @Sendable () -> Date = { Date() }) {
        self.continuation = continuation; self.currentTime = currentTime
    }

    func emit(_ event: SoundClassificationEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .started:
            activeStart = event
        case .stopped(let id, _):
            if case .started(let activeID, _, _, _, _) = activeStart, id == activeID { activeStart = nil }
        case let .unavailable(_, failure, id, _, _):
            let failedID = id ?? failure?.captureID
            if failedID == nil { activeStart = nil }
            else if case .started(let activeID, _, _, _, _) = activeStart, failedID == activeID { activeStart = nil }
        default: break
        }
        if case .dropped = continuation.yield(event) {
            if let activeStart { continuation.yield(activeStart) }
            continuation.yield(.droppedEvents(at: currentTime()))
        }
    }
}

/// Retry state belongs to classifier failures, not the microphone frame timeline.
/// In particular, skipping input while waiting must not erase a pending retry.
struct SoundClassifierRecovery: Sendable {
    private(set) var consecutiveFailures = 0
    private(set) var retryAt: ContinuousClock.Instant?
    func canAttempt(at now: ContinuousClock.Instant) -> Bool { retryAt.map { now >= $0 } ?? true }
    mutating func failed(at now: ContinuousClock.Instant) -> Int {
        let delays = [1, 2, 4, 8, 16, 30]
        let delay = delays[min(consecutiveFailures, delays.count - 1)]
        consecutiveFailures = min(consecutiveFailures + 1, delays.count)
        retryAt = now.advanced(by: .seconds(delay))
        return delay
    }
    mutating func succeeded() { self = Self() }
}

enum SoundClassificationStartReason: String, Sendable {
    case initial, monitoringRestart = "monitoring_restart", audioGap = "audio_gap", afterFailure = "after_failure"
}

/// A Sendable snapshot, never a retained NSError/userInfo or arbitrary exception text.
struct SoundClassificationFailure: Sendable, Equatable {
    /// A single bounded snapshot at timeout, never per-buffer telemetry.
    struct StallContext: Sendable, Equatable {
        let timeoutMS: Int, sessionAgeMS: Int, noProgressMS: Int, receivedAudioMS: Int, inputBuffers: Int
        let lastResultWindowEndMS: Int?
        init(timeout: Duration, sessionAge: Duration, noProgress: Duration, receivedAudio: TimeInterval,
             inputBuffers: Int, lastResultWindowEnd: TimeInterval?) {
            func milliseconds(_ duration: Duration) -> Int {
                let c = duration.components
                return Self.bounded(Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
            }
            timeoutMS = milliseconds(timeout); sessionAgeMS = milliseconds(sessionAge); noProgressMS = milliseconds(noProgress)
            receivedAudioMS = Self.bounded(receivedAudio * 1000)
            self.inputBuffers = min(1_000_000_000, max(0, inputBuffers))
            lastResultWindowEndMS = lastResultWindowEnd.flatMap { $0.isFinite ? Self.bounded($0 * 1000) : nil }
        }
        private static func bounded(_ value: Double) -> Int {
            value.isFinite ? Int(min(86_400_000, max(0, value))) : 0
        }
        var diagnosticDetails: String {
            "timeout_ms=\(timeoutMS);session_age_ms=\(sessionAgeMS);no_progress_ms=\(noProgressMS);elapsed_source=monotonic"
                + ";received_audio_ms=\(receivedAudioMS);input_buffers=\(inputBuffers);last_result_end_ms=\(lastResultWindowEndMS.map(String.init) ?? "none")"
        }
    }
    enum Stage: String, Sendable { case setup, analysis }
    enum Reason: String, Sendable {
        case backgroundGPUDenied = "background_gpu_denied", operationFailed = "operation_failed"
        case resultTimeout = "result_timeout", unknown
    }
    struct Cause: Sendable, Equatable {
        let domain: String
        let code: Int
    }
    let stage: Stage
    let captureID: UUID?
    let reason: Reason
    let causes: [Cause]
    let truncated: Bool
    let stallContext: StallContext?

    init(stalledCaptureID: UUID, context: StallContext? = nil) {
        stage = .analysis; captureID = stalledCaptureID; reason = .resultTimeout
        causes = []; truncated = false; stallContext = context
    }

    init(error: any Error, stage: Stage, captureID: UUID? = nil) {
        self.stage = stage; self.captureID = captureID; stallContext = nil
        let allowed: Set<String> = ["com.apple.SoundAnalysis", "com.apple.CoreML", "MTLCommandBufferErrorDomain",
                                   NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain]
        var current: NSError? = error as NSError
        var seen = Set<ObjectIdentifier>(), causes: [Cause] = []
        var denied = false
        while let value = current, causes.count < 4, seen.insert(ObjectIdentifier(value)).inserted {
            let domain = allowed.contains(value.domain) ? value.domain : "other"
            causes.append(Cause(domain: domain, code: value.code))
            // Recognize only fixed evidence; never export the description itself.
            // A generic SoundAnalysis error while backgrounded is not proof of a GPU denial.
            if allowed.contains(value.domain), let description = value.userInfo[NSLocalizedDescriptionKey] as? String {
                denied = denied || description.contains("Insufficient Permission (to submit GPU work from background)")
                    || description.contains("kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted")
            }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        self.causes = causes; truncated = current != nil
        reason = denied ? .backgroundGPUDenied
            : causes.contains(where: { $0.domain == "com.apple.SoundAnalysis" && $0.code == 2 }) ? .operationFailed : .unknown
    }

    /// Fixed keys and allowlisted domains make this safe for both CSV and the operational log.
    var diagnosticFingerprint: String {
        "stage=\(stage.rawValue);reason=\(reason.rawValue);errors="
            + causes.map { "\($0.domain):\($0.code)" }.joined(separator: ">")
            + ";causes_truncated=\(truncated)"
    }
    var diagnosticDetails: String {
        diagnosticFingerprint + (stallContext.map { ";" + $0.diagnosticDetails } ?? "")
    }
}

/// Shared by the CSV and operational log, so both require current, fresh audio
/// before declaring recovery. State and summaries are scoped to this process/run.
struct SoundClassificationRecoveryLog {
    private var capture: (id: UUID, startedAt: Date, running: Bool)?
    private var lastWindowEnd: Date?
    private var audioAfter = Date.distantPast
    private var firstFailureAt: Date?, lastFailureAt: Date?, failedCaptureID: UUID?
    private var failures = 0, restarts = 0

    func acceptsFailure(captureID: UUID?) -> Bool {
        captureID == nil || capture == nil || captureID == capture?.id
    }

    mutating func consume(_ event: SoundClassificationEvent, at now: Date) -> String? {
        switch event {
        case let .started(id, at, _, _, _):
            guard at.timeIntervalSinceReferenceDate.isFinite, id != capture?.id,
                  at >= (capture?.startedAt ?? .distantPast) else { return nil }
            capture = (id, at, true); lastWindowEnd = nil; audioAfter = .distantPast
            if firstFailureAt != nil { restarts = min(1_000_000_000, restarts + 1) }
        case let .stopped(id, _):
            if capture?.id == id { capture?.running = false }
        case let .unavailable(at, failure, id, _, _):
            let failedID = id ?? failure?.captureID
            guard at.timeIntervalSinceReferenceDate.isFinite,
                  acceptsFailure(captureID: failedID) else { return nil }
            firstFailureAt = min(firstFailureAt ?? at, at); lastFailureAt = max(lastFailureAt ?? at, at)
            failedCaptureID = failedID; failures = min(1_000_000_000, failures + 1)
            capture?.running = false
        case let .droppedEvents(at), let .droppedBuffers(_, at):
            if at.timeIntervalSinceReferenceDate.isFinite { audioAfter = max(audioAfter, at) }
        case let .unmappedResult(id, end, at):
            if capture?.id == id, lastWindowEnd.map({ end > $0 }) ?? true,
               at.timeIntervalSinceReferenceDate.isFinite { audioAfter = max(audioAfter, at) }
        case .result(let score):
            // Sample-clock dates alone cannot prove that inference used fresh input.
            guard let capturedEnd = score.audioWindowEndAt else { return nil }
            let duration = score.windowEnd.timeIntervalSince(score.windowStart)
            guard capture?.running == true, capture?.id == score.captureID,
                  score.windowStart >= (capture?.startedAt ?? .distantFuture),
                  score.confidence.isFinite, (0...1).contains(score.confidence), (1.9...2.1).contains(duration),
                  score.windowEnd.timeIntervalSinceReferenceDate.isFinite,
                  lastWindowEnd.map({ score.windowEnd > $0 }) ?? true,
                  (-1...CryConfidenceDetector.maximumResultAge).contains(now.timeIntervalSince(score.observedAt)),
                  (-1...CryConfidenceDetector.maximumResultAge).contains(now.timeIntervalSince(capturedEnd)),
                  capturedEnd.addingTimeInterval(-duration) >= audioAfter else { return nil }
            lastWindowEnd = score.windowEnd
            guard let lastFailureAt, score.observedAt >= lastFailureAt, capturedEnd >= lastFailureAt,
                  let details = pendingDetails(at: score.observedAt) else { return nil }
            firstFailureAt = nil; self.lastFailureAt = nil; failedCaptureID = nil; failures = 0; restarts = 0
            return details
        }
        return nil
    }

    func pendingDetails(at now: Date) -> String? {
        guard let firstFailureAt, let lastFailureAt else { return nil }
        let elapsed = now.timeIntervalSince(firstFailureAt) * 1000
        let milliseconds = elapsed.isFinite ? Int(min(86_400_000, max(0, elapsed))) : 0
        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return "first_failure_at=\(firstFailureAt.formatted(style));last_failure_at=\(lastFailureAt.formatted(style))"
            + ";outage_ms=\(milliseconds);outage_time_source=wall;failure_count=\(failures);restart_count=\(restarts)"
            + ";failed_capture_id=\(failedCaptureID?.uuidString.lowercased() ?? "none");scope=process"
    }
}
