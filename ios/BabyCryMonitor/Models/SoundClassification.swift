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
    case started(id: UUID, at: Date, sampleRate: Double, voiceProcessing: Bool,
                 reason: SoundClassificationStartReason = .initial)
    case result(SoundClassificationObservation)
    case stopped(id: UUID, at: Date)
    case unavailable(at: Date, failure: SoundClassificationFailure? = nil)
    case droppedEvents(at: Date)
    case droppedBuffers(count: Int, at: Date)
}

enum SoundClassificationStartReason: String, Sendable {
    case initial, monitoringRestart = "monitoring_restart", audioGap = "audio_gap", afterFailure = "after_failure"
}

/// A Sendable snapshot, never a retained NSError/userInfo or arbitrary exception text.
struct SoundClassificationFailure: Sendable, Equatable {
    enum Stage: String, Sendable { case setup, analysis }
    enum Reason: String, Sendable {
        case backgroundGPUDenied = "background_gpu_denied", operationFailed = "operation_failed", unknown
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

    init(error: any Error, stage: Stage, captureID: UUID? = nil) {
        self.stage = stage; self.captureID = captureID
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
    var diagnosticDetails: String {
        "stage=\(stage.rawValue);reason=\(reason.rawValue);errors="
            + causes.map { "\($0.domain):\($0.code)" }.joined(separator: ">")
            + ";causes_truncated=\(truncated)"
    }
}
