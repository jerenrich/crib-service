import Foundation

/// Stable wire encoding per queued alert, separate from local Date persistence.
struct AlertUpload: Encodable {
    let alert: CryAlert
    /// Older servers reject unknown keys, which would lose the whole alert.
    var includeReason = false
    private enum CodingKeys: String, CodingKey {
        case eventId, episodeId, listenerId, type, cryStartedAt, durationSeconds, createdAt, isRepeat, isTest, reason
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = alert.wireTimestampVersion == 1
            ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        try values.encode(alert.eventId, forKey: .eventId)
        try values.encode(alert.episodeId, forKey: .episodeId)
        try values.encode(alert.listenerId, forKey: .listenerId)
        try values.encode(alert.type, forKey: .type)
        try values.encode(formatter.string(from: alert.cryStartedAt), forKey: .cryStartedAt)
        try values.encode(alert.durationSeconds, forKey: .durationSeconds)
        try values.encode(formatter.string(from: alert.createdAt), forKey: .createdAt)
        try values.encode(alert.isRepeat, forKey: .isRepeat)
        try values.encodeIfPresent(alert.isTest, forKey: .isTest)
        if includeReason { try values.encodeIfPresent(alert.reason, forKey: .reason) }
    }
}
