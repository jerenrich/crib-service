import Foundation

/// The app owns all alarm state. It publishes a read-only snapshot for the
/// notification extension, and each process appends only its own attempt
/// journal, so neither process ever writes a file the other one writes.
enum AlarmShared {
    static let appGroup = "group.com.jordanerenrich.cribservice"
    /// Under Library so the files can be collected from a device for diagnosis.
    static var directory: URL? {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Library/Application Support/Alarms", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum AlarmMethod: String, Codable, Sendable { case app, `extension` }

/// What the extension needs to apply the app's push-only fallback rules.
struct AlarmSnapshot: Codable, Equatable, Sendable {
    var enabled: Bool
    var extensionEnabled: Bool
    var acknowledgementPending: Bool
    var localMutedUntil: Date?
    var stoppedBefore: Date?
    var evidence: SilentCryAlarmRequest.ServerEvidence?
    var snoozeDuration: Double
    var publishedAt: Date

    static func load(from directory: URL? = AlarmShared.directory) -> AlarmSnapshot? {
        guard let url = directory?.appendingPathComponent("alarm-snapshot.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(to directory: URL? = AlarmShared.directory) throws {
        guard let url = directory?.appendingPathComponent("alarm-snapshot.json") else { return }
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    func ineligibilityReason(for request: SilentCryAlarmRequest, now: Date) -> SilentCryAlarmRequest.Rejection? {
        guard extensionEnabled else { return .methodDisabled }
        return request.fallbackIneligibilityReason(enabled: enabled, acknowledgementPending: acknowledgementPending,
            localMutedUntil: localMutedUntil, stoppedBefore: stoppedBefore, evidence: evidence, now: now)
    }
}

/// One alarm attempt by either method, with the conditions it ran under, so
/// delays can be compared across charging, lock and app states.
struct AlarmAttempt: Codable, Equatable, Sendable {
    /// `timedOut`: the extension released the notification at its cut-off before the
    /// attempt finished. A later entry for the same event carries the real outcome,
    /// with reason `after_cutoff`, if iOS let the extension finish.
    enum Outcome: String, Codable, Sendable { case scheduled, duplicate, rejected, failed, stopped, timedOut = "timed_out" }
    struct Conditions: Codable, Equatable, Sendable {
        var charging: Bool?
        var batteryLevel: Double?
        var lowPower: Bool
        var appActive: Bool?
        var protectedDataAvailable: Bool?
    }
    var method: AlarmMethod
    var outcome: Outcome
    var reason: String?
    var eventID: UUID?
    var episodeID: UUID?
    var isTest: Bool
    /// Markers present in the push: `wake` (content-available) and `extension` (mutable-content).
    var flags: [String]
    var pushCreatedAt: Date?
    var startedAt: Date
    var finishedAt: Date
    var alarmAt: Date?
    var conditions: Conditions

    /// Cross-device: the push time comes from the service clock.
    var pushToStartMS: Int? { pushCreatedAt.map { Int(startedAt.timeIntervalSince($0) * 1000) } }
    var handlerMS: Int { Int(finishedAt.timeIntervalSince(startedAt) * 1000) }
    var pushToAlarmMS: Int? { pushCreatedAt.flatMap { created in alarmAt.map { Int($0.timeIntervalSince(created) * 1000) } } }

    static func flags(in payload: [AnyHashable: Any]) -> [String] {
        let aps = payload["aps"] as? [AnyHashable: Any]
        return (aps?["content-available"] as? Int == 1 ? ["wake"] : []) + (aps?["mutable-content"] as? Int == 1 ? ["extension"] : [])
    }
}

/// A bounded JSON-lines journal written by exactly one process.
struct AlarmJournal: Sendable {
    static let capacity = 200
    let url: URL

    static func forMethod(_ method: AlarmMethod, directory: URL? = AlarmShared.directory) -> AlarmJournal? {
        directory.map { AlarmJournal(url: $0.appendingPathComponent("alarm-attempts-\(method.rawValue).jsonl")) }
    }

    func read() -> [AlarmAttempt] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(AlarmAttempt.self, from: Data($0.utf8)) }
    }

    func append(_ attempt: AlarmAttempt) {
        let entries = Array((read() + [attempt]).suffix(Self.capacity))
        let encoder = JSONEncoder()
        let lines = entries.compactMap { try? encoder.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
