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
    case unavailable(at: Date)
    case droppedEvents(at: Date)
    case droppedBuffers(count: Int, at: Date)
}
