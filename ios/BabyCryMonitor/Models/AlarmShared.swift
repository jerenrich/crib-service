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

    /// A one-byte file with complete protection: readable only while the device is
    /// unlocked. The extension cannot ask UIKit, so it reads this to record lock state.
    private static let lockProbeName = "lock-probe"
    static func writeLockProbe(to directory: URL? = directory) {
        guard let url = directory?.appendingPathComponent(lockProbeName),
              !FileManager.default.fileExists(atPath: url.path) else { return }
        try? Data([1]).write(to: url, options: [.atomic, .completeFileProtection])
    }
    /// `nil` until the app has written the probe.
    static func protectedDataAvailable(in directory: URL? = directory) -> Bool? {
        guard let url = directory?.appendingPathComponent(lockProbeName),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (try? Data(contentsOf: url)) != nil
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

    /// Why the extension had no snapshot, recorded with its `no_snapshot` rejection.
    enum Issue: String, Error { case appGroupUnavailable = "app_group_unavailable", missing, unreadable, undecodable }

    static func read(from directory: URL? = AlarmShared.directory) -> Result<AlarmSnapshot, Issue> {
        guard let url = directory?.appendingPathComponent("alarm-snapshot.json") else { return .failure(.appGroupUnavailable) }
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.missing) }
        // Unreadable before the first unlock after a restart.
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        guard let snapshot = try? JSONDecoder().decode(Self.self, from: data) else { return .failure(.undecodable) }
        return .success(snapshot)
    }

    static func load(from directory: URL? = AlarmShared.directory) -> AlarmSnapshot? { try? read(from: directory).get() }

    /// The server state is applied only when observed after the push was created.
    func evidenceApplies(to request: SilentCryAlarmRequest) -> Bool {
        evidence.map { $0.observedAt >= request.createdAt } ?? false
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
    /// Local-only context, e.g. why there was no snapshot or a scheduling error's domain and code.
    var detail: String?
    /// Extension only: how old the app's published state was, and whether its server state was applied.
    var snapshotAgeMS: Int?
    var evidenceApplied: Bool?

    /// Cross-device: the push time comes from the service clock.
    var pushToStartMS: Int? { pushCreatedAt.map { Int(startedAt.timeIntervalSince($0) * 1000) } }
    var handlerMS: Int { Int(finishedAt.timeIntervalSince(startedAt) * 1000) }
    var pushToAlarmMS: Int? { pushCreatedAt.flatMap { created in alarmAt.map { Int($0.timeIntervalSince(created) * 1000) } } }

    /// Identifies an entry across journal rewrites, so each is merged exactly once.
    var key: String {
        "\(method.rawValue)|\(outcome.rawValue)|\(episodeID?.uuidString ?? "-")|\(startedAt.timeIntervalSince1970)|\(finishedAt.timeIntervalSince1970)"
    }

    static func flags(in payload: [AnyHashable: Any]) -> [String] {
        let aps = payload["aps"] as? [AnyHashable: Any]
        return (aps?["content-available"] as? Int == 1 ? ["wake"] : []) + (aps?["mutable-content"] as? Int == 1 ? ["extension"] : [])
    }
}

/// A bounded JSON-lines journal written by exactly one process. Appends are
/// serialized within the process and, with a file lock, across its instances.
struct AlarmJournal: Sendable {
    static let capacity = 200
    let url: URL
    private static let processLock = NSLock()

    enum Failure: Error { case unreadable, busy, lockUnavailable(Int32) }

    static func forMethod(_ method: AlarmMethod, directory: URL? = AlarmShared.directory) -> AlarmJournal? {
        directory.map { AlarmJournal(url: $0.appendingPathComponent("alarm-attempts-\(method.rawValue).jsonl")) }
    }

    func read() -> [AlarmAttempt] { (try? entries()) ?? [] }

    /// Throws only when an existing journal cannot be read.
    func entries() throws -> [AlarmAttempt] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.unreadable }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(AlarmAttempt.self, from: Data($0.utf8)) }
    }

    func append(_ attempt: AlarmAttempt) throws {
        try Self.processLock.withLock {
            let descriptor = open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { throw Failure.lockUnavailable(errno) }
            defer { close(descriptor) }
            // Never wait indefinitely: a suspended holder must not stall the
            // extension, which writes its cut-off entry on the main queue.
            var locked = false
            for _ in 0..<20 {
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
                usleep(5_000)
            }
            guard locked else { throw Failure.busy }
            defer { flock(descriptor, LOCK_UN) }
            // An unreadable journal is left alone rather than replaced by one entry.
            let entries = Array((try entries() + [attempt]).suffix(Self.capacity))
            let encoder = JSONEncoder()
            let lines = entries.compactMap { try? encoder.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
