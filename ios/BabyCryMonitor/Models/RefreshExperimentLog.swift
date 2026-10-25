import Foundation
import Observation

/// A persistent ledger of scheduler requests. Pending is not proof of permanent non-delivery.
@MainActor @Observable final class RefreshExperimentLog {
    enum Status: String, Codable { case submitting, pending, submissionFailed, delivered, completed, expired, cancelled, notObserved }
    struct Attempt: Codable, Identifiable {
        var id = UUID()
        var experimentID: UUID
        var submittingRunID: UUID
        var submittedAt: Date?
        var earliestBeginAt: Date?
        var submissionFinishedAt: Date?
        var deliveredAt: Date?
        var deliveryRunID: UUID?
        var finishedAt: Date?
        var status: Status
        var errorCode: Int?
        var refreshAvailability: String
    }
    private struct State: Codable {
        var enabled = false
        var experimentID = UUID()
        var startedAt: Date?
        var attempts: [Attempt] = []
    }
    static let interval: TimeInterval = 60
    static let duration: TimeInterval = 86400
    static let maximumAttempts = 4000
    let runID = UUID()
    private(set) var enabled = false
    private(set) var attempts: [Attempt] = []
    private(set) var persistenceAvailable = true
    private(set) var startedAt: Date?
    @ObservationIgnored private var experimentID = UUID()
    @ObservationIgnored private let url: URL?

    init(directory: URL?, now: Date = Date()) {
        url = directory?.appendingPathComponent("refresh-experiment.json")
        do {
            if let url, FileManager.default.fileExists(atPath: url.path) {
                let saved = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
                enabled = saved.enabled; experimentID = saved.experimentID; startedAt = saved.startedAt
                attempts = Array(saved.attempts.suffix(Self.maximumAttempts))
                expireIfNeeded(at: now)
            }
        } catch { persistenceAvailable = false }
    }
    var pending: Attempt? { attempts.last { $0.status == .pending || $0.status == .submitting } }
    var lastSubmissionAt: Date? {
        let last = attempts.last { $0.experimentID == experimentID }
        return last?.submissionFinishedAt ?? last?.submittedAt
    }
    func start(at now: Date = Date()) {
        guard !enabled else { return }
        enabled = true; experimentID = UUID(); startedAt = now; save()
    }
    func stop(at now: Date = Date()) {
        enabled = false
        for i in attempts.indices where attempts[i].status == .pending || attempts[i].status == .submitting {
            attempts[i].status = .cancelled; attempts[i].finishedAt = now
        }
        save()
    }
    @discardableResult func expireIfNeeded(at now: Date = Date()) -> Bool {
        guard enabled else { return false }
        guard let startedAt, now >= startedAt, now.timeIntervalSince(startedAt) < Self.duration else {
            stop(at: now); return true
        }
        return false
    }
    func beginRequest(availability: String, at now: Date = Date()) -> Attempt? {
        expireIfNeeded(at: now)
        guard enabled, pending == nil else { return nil }
        let attempt = Attempt(experimentID: experimentID, submittingRunID: runID, submittedAt: now,
                              earliestBeginAt: now.addingTimeInterval(Self.interval), status: .submitting,
                              refreshAvailability: ["available", "denied", "restricted"].contains(availability) ? availability : "unknown")
        attempts.append(attempt); save(); return attempt
    }
    func submission(_ id: UUID, errorCode: Int?, at now: Date = Date()) {
        guard let i = attempts.firstIndex(where: { $0.id == id }) else { return }
        attempts[i].submissionFinishedAt = now; attempts[i].errorCode = errorCode
        if attempts[i].status == .submitting { attempts[i].status = errorCode == nil ? .pending : .submissionFailed }
        save()
    }
    /// Reconcile once on launch/foreground, never by replacing a queued request.
    func reconcile(earliestBeginAt: Date?, at now: Date = Date()) {
        guard enabled else { return }
        if let pending, let i = attempts.firstIndex(where: { $0.id == pending.id }) {
            if earliestBeginAt == nil { attempts[i].status = .notObserved; attempts[i].finishedAt = now }
            else { attempts[i].status = .pending }
            save()
        } else if let earliestBeginAt {
            // Queue survived but the ledger is missing: adopt without inventing a request time.
            attempts.append(Attempt(experimentID: experimentID, submittingRunID: runID, earliestBeginAt: earliestBeginAt,
                                    status: .pending, refreshAvailability: "unknown")); save()
        }
    }
    func delivered(at now: Date = Date()) -> UUID {
        let id: UUID
        if let pending, let i = attempts.firstIndex(where: { $0.id == pending.id }) {
            attempts[i].deliveredAt = now; attempts[i].deliveryRunID = runID; attempts[i].status = .delivered; id = pending.id
        } else {
            let attempt = Attempt(experimentID: experimentID, submittingRunID: runID, deliveredAt: now,
                                  deliveryRunID: runID, status: .delivered, refreshAvailability: "unknown")
            attempts.append(attempt); id = attempt.id
        }
        save(); return id
    }
    func finished(_ id: UUID, expired: Bool, at now: Date = Date()) {
        guard let i = attempts.firstIndex(where: { $0.id == id }), attempts[i].status == .delivered else { return }
        attempts[i].status = expired ? .expired : .completed; attempts[i].finishedAt = now; save()
    }
    private func save() {
        if attempts.count > Self.maximumAttempts { attempts = Array(attempts.suffix(Self.maximumAttempts - 100)) }
        do {
            guard let url else { persistenceAvailable = false; return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(State(enabled: enabled, experimentID: experimentID, startedAt: startedAt, attempts: attempts))
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            var protected = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protected.setResourceValues(values); persistenceAvailable = true
        } catch { persistenceAvailable = false }
    }
    func report(at now: Date = Date()) -> String {
        var lines = ["Background App Refresh experiment · snapshot \(now.ISO8601Format())",
                     "enabled=\(enabled) persistence=\(persistenceAvailable) request_interval_seconds=60",
                     "60 seconds is the requested earliest start, not a promised execution interval.",
                     "One accepted request is kept pending; the next is submitted after delivery. Failed submissions may retry after 60 seconds while executing.",
                     "Pending means no delivery observed yet. notObserved means missing from the OS queue without a logged delivery; it does not prove the task never ran.",
                     "A delivered task without a finish record may have been interrupted. Clock changes can affect wall-clock latency calculations.",
                     "Only trivial local logging is performed. This experimental mode changes background execution opportunities; analyse it separately from the baseline."]
        for attempt in attempts {
            var row = "id=\(attempt.id) experiment=\(attempt.experimentID) status=\(attempt.status.rawValue) availability=\(attempt.refreshAvailability)"
            if let submitted = attempt.submittedAt { row += " requested=\(submitted.ISO8601Format())" }
            if let earliest = attempt.earliestBeginAt { row += " earliest=\(earliest.ISO8601Format())" }
            if let delivered = attempt.deliveredAt {
                row += " executed=\(delivered.ISO8601Format())"
                if let submitted = attempt.submittedAt { row += " request_to_execution_seconds=\(Int(delivered.timeIntervalSince(submitted)))" }
                if let earliest = attempt.earliestBeginAt { row += " lateness_seconds=\(Int(delivered.timeIntervalSince(earliest)))" }
            } else if let submitted = attempt.submittedAt {
                row += " observed_wait_seconds=\(Int((attempt.finishedAt ?? now).timeIntervalSince(submitted)))"
                if (attempt.status == .pending || attempt.status == .submitting), let earliest = attempt.earliestBeginAt {
                    row += " overdue_seconds=\(max(0, Int(now.timeIntervalSince(earliest))))"
                }
            }
            if let error = attempt.errorCode { row += " submission_error_code=\(error)" }
            lines.append(row)
        }
        lines.append("\nRaw attempts (JSON; Date values are seconds since 2001-01-01 UTC):")
        if let data = try? JSONEncoder().encode(attempts) { lines.append(String(decoding: data, as: UTF8.self)) }
        return lines.joined(separator: "\n")
    }
}
