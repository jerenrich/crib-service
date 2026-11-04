import Foundation

/// Scores are observations only; they never participate in alert decisions.
struct SoundClassificationObservation: Sendable {
    let captureID: UUID
    let windowStart: Date
    let windowEnd: Date
    let confidence: Double
    let observedAt: Date
}

enum SoundClassificationEvent: Sendable {
    case started(id: UUID, at: Date, sampleRate: Double, voiceProcessing: Bool)
    case result(SoundClassificationObservation)
    case stopped(id: UUID, at: Date)
    case unavailable(at: Date, failure: SoundClassificationFailure? = nil, captureID: UUID? = nil, retryAfterSeconds: Int? = nil, appActive: Bool? = nil)
    case droppedEvents(at: Date)
    case droppedBuffers(count: Int, at: Date)
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

/// Persist only fixed domain names and numeric codes, never localized descriptions
/// or userInfo, which can contain paths, audio metadata or private payloads.
struct SoundClassificationFailure: Sendable, Equatable {
    enum Stage: String, Sendable { case initialization, inference }
    struct Code: Sendable, Equatable { let domain: String; let code: Int }
    let stage: Stage
    let codes: [Code]
    let backgroundGPURestricted: Bool
    init(_ error: any Error, stage: Stage) {
        self.stage = stage
        var codes: [Code] = [], restricted = false
        var current: NSError? = error as NSError
        let allowed: Set<String> = ["com.apple.SoundAnalysis", "com.apple.CoreML", "com.apple.appleneuralengine",
            "MTLCommandBufferErrorDomain", "NSOSStatusErrorDomain", "NSCocoaErrorDomain", "CribService.SoundClassifier"]
        for _ in 0..<4 {
            guard let value = current else { break }
            codes.append(Code(domain: allowed.contains(value.domain) ? value.domain : "other", code: value.code))
            // Inspect only to recognize this fixed failure category. Never export
            // the description itself, or treat a generic Core ML failure as proof.
            let text = value.localizedDescription.lowercased()
            if text.contains("gpu"), text.contains("background"),
               text.contains("permission") || text.contains("not permitted") { restricted = true }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        self.codes = codes; backgroundGPURestricted = restricted
    }
    var fields: String {
        "stage=\(stage.rawValue);errors=" + codes.map { "\($0.domain):\($0.code)" }.joined(separator: "|")
            + ";background_gpu_restricted=\(backgroundGPURestricted)"
    }
}
