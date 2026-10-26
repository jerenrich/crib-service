import Foundation

enum DiagnosticTiming {
    static func elapsedMS(since start: ContinuousClock.Instant) -> Int {
        let value = start.duration(to: .now).components
        let milliseconds = Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
        return Int(min(86_400_000, max(0, milliseconds)))
    }
    static func milliseconds(_ date: Date) -> Int64? {
        let value = date.timeIntervalSince1970 * 1000
        guard value.isFinite, abs(value) < 1e15 else { return nil }
        return Int64(value.rounded())
    }
}

enum DiagnosticCorrelation {
    static func reference(_ value: String?) -> String? {
        guard let value, value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return value
    }
    static func attempt(_ value: Int?) -> Int? {
        guard let value, (1...1_000_000).contains(value) else { return nil }; return value
    }
    static func fields(reference: String?, attempt: Int?) -> String {
        guard let reference = self.reference(reference), let attempt = self.attempt(attempt) else { return "" }
        return " diagnostic_ref=\(reference) delivery_attempt=\(attempt)"
    }
}

/// Remote time minus local time. Bounds assume stable clocks during the exchange;
/// a detected wall-clock step invalidates the sample rather than hiding it.
struct DiagnosticClockSample: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case http, phoneBridge = "phone_bridge" }
    let offsetMS: Int64
    let uncertaintyMS: Int64
    let sampledAt: Date
    var source: Source = .http

    var isValid: Bool {
        abs(Double(offsetMS)) < 1e12 && (0...3_600_000).contains(uncertaintyMS)
            && DiagnosticTiming.milliseconds(sampledAt) != nil
    }
    func ageMS(at now: Date) -> Int64? {
        let age = now.timeIntervalSince(sampledAt) * 1000
        guard isValid, age.isFinite, (0...900_000).contains(age) else { return nil }
        return Int64(age.rounded())
    }
    var fields: String {
        " clock_offset_ms=\(offsetMS) clock_uncertainty_ms=\(uncertaintyMS) clock_source=\(source.rawValue)"
    }
    func fields(at now: Date) -> String {
        guard let age = ageMS(at: now) else { return " clock_sample=unavailable" }
        return fields + " clock_sample_age_ms=\(age)"
    }
    static func estimate(localStarted: Date, localFinished: Date, monotonicMS: Int,
                         remoteReceivedMS: Int64?, remoteSentMS: Int64?) -> Self? {
        guard let start = DiagnosticTiming.milliseconds(localStarted), let end = DiagnosticTiming.milliseconds(localFinished),
              let received = remoteReceivedMS, let sent = remoteSentMS,
              abs(Double(received)) < 1e15, abs(Double(sent)) < 1e15,
              (0...3_600_000).contains(monotonicMS), sent >= received,
              abs(Double(end - start) - Double(monotonicMS)) <= 250,
              Double(sent - received) <= Double(monotonicMS) + 2 else { return nil }
        let lower = Double(sent - end), upper = Double(received - start)
        guard lower <= upper + 2 else { return nil }
        let offset = (lower + upper) / 2
        let uncertainty = max(1, (upper - lower) / 2 + 1 + abs(Double(end - start) - Double(monotonicMS)))
        guard abs(offset) < 1e12, uncertainty <= 3_600_000 else { return nil }
        return Self(offsetMS: Int64(offset.rounded()), uncertaintyMS: Int64(uncertainty.rounded(.up)), sampledAt: localFinished)
    }
    /// Compose server↔phone and phone↔Watch estimates from an existing live reply.
    /// Cached/asynchronous snapshots alone cannot calibrate the Watch clock.
    func bridged(to watch: Self, phoneSentAt: Date) -> Self? {
        guard let age = ageMS(at: phoneSentAt), watch.isValid else { return nil }
        let uncertainty = uncertaintyMS + watch.uncertaintyMS + Int64(ceil(Double(age) * 0.0001))
        let sample = Self(offsetMS: offsetMS + watch.offsetMS, uncertaintyMS: uncertainty,
                          sampledAt: watch.sampledAt, source: .phoneBridge)
        return sample.isValid ? sample : nil
    }
}

/// Only scalar metrics survive collection. No URL, endpoint, headers or bodies.
struct DiagnosticNetworkTiming: Sendable {
    var transactions = 0
    var redirects = 0
    var reusedConnections = 0
    var dnsMS: Int?
    var connectMS: Int?
    var tlsMS: Int?
    var requestMS: Int?
    var serverWaitMS: Int?
    var responseMS: Int?
    var taskMS: Int?
    var taskToFetchMS: Int?
    var fields: String {
        var text = " network_metrics=available metrics_transactions=\(min(100, max(0, transactions))) redirects=\(min(100, max(0, redirects))) reused_connections=\(min(100, max(0, reusedConnections)))"
        if transactions > 100 { text += " metrics_truncated=1" }
        for (key, value) in [("dns_ms", dnsMS), ("connect_ms", connectMS), ("tls_ms", tlsMS),
                             ("request_ms", requestMS), ("server_wait_ms", serverWaitMS), ("response_ms", responseMS),
                             ("task_ms", taskMS), ("task_to_fetch_ms", taskToFetchMS)] {
            if let value, (0...3_600_000).contains(value) { text += " \(key)=\(value)" }
        }
        return text
    }
}

enum NotificationRemovalReason: String, Sendable {
    case snoozed, cleared, testAcknowledged = "test_acknowledged", noLongerRelevant = "no_longer_relevant"
}
struct DiagnosticNotificationRemoval: Sendable {
    let eventID: UUID
    let episodeID: UUID
    let reference: String?
    let attempt: Int?
    let reason: NotificationRemovalReason
    let pending: Bool
}

/// Fixed failure stages keep unavailable Watch calibration diagnosable.
enum DiagnosticClockCalibration: String {
    case ok, unreachable, transport, relativeUnavailable = "relative_unavailable"
    case phoneUnavailable = "phone_unavailable", stalePhone = "stale_phone"
}
