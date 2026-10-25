import Foundation
import Darwin
import Observation

/// Opt-in execution observations, not a background execution or alarm mechanism.
@MainActor @Observable final class BackgroundBenchmark {
    enum Scenario: String, Codable, CaseIterable {
        case foreground, podcastVisible, podcastInBackground, phoneLocked, otherApp
        var title: String {
            switch self {
            case .foreground: "Monitor visible"
            case .podcastVisible: "Podcast app visible"
            case .podcastInBackground: "Podcast playing · Monitor visible"
            case .phoneLocked: "Phone locked"
            case .otherApp: "Other app visible"
            }
        }
    }
    enum Kind: String, Codable { case start, stop, launch, scenario, context, sample, requestStart, requestEnd, quietVerified }
    struct Context: Codable, Equatable {
        var active: Bool
        var powered: Bool?
        var lowPower: Bool
        var networkAvailable: Bool
        var battery: Double?
    }
    struct Entry: Codable {
        var at: Date
        var uptime: Double
        var runID: UUID
        var sessionID: UUID
        var scenario: Scenario
        var kind: Kind
        var context: Context?
        var attemptID: UUID?
        var requestID: UUID?
        var outcome: String?
        var status: Int?
        var elapsedMS: Int?
    }
    // Unlike a process timer, this clock includes device sleep.
    nonisolated static var continuousUptime: Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
    static let sampleInterval: TimeInterval = 5
    static let maximumDuration: TimeInterval = 24 * 3600
    static let maximumEntries = 50_000
    let runID = UUID()
    private(set) var enabled = false
    private(set) var scenario = Scenario.foreground
    private(set) var entryCount = 0
    private(set) var persistenceAvailable = true
    @ObservationIgnored private(set) var entries: [Entry] = []
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var lastSampleUptime: Double?
    @ObservationIgnored private var pendingRequests: Set<UUID> = []
    @ObservationIgnored private var context: Context?
    @ObservationIgnored private let url: URL?

    init(directory: URL?, now: Date = Date(), uptime: Double = BackgroundBenchmark.continuousUptime) {
        url = directory?.appendingPathComponent("background-benchmark.jsonl")
        do {
            if let url, FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                entries = data.split(separator: 10).compactMap { try? JSONDecoder().decode(Entry.self, from: Data($0)) }
                entries = Array(entries.suffix(Self.maximumEntries))
            }
            entryCount = entries.count
            if let control = entries.last(where: { $0.kind == .start || $0.kind == .stop }), control.kind == .start {
                sessionID = control.sessionID; startedAt = control.at
                scenario = entries.last?.scenario ?? .foreground
                enabled = true
                if now.timeIntervalSince(control.at) >= Self.maximumDuration || now < control.at { stop(at: now, uptime: uptime) }
                else { append(.launch, at: now, uptime: uptime) }
            }
        } catch { persistenceAvailable = false }
    }
    func start(at now: Date = Date(), uptime: Double = BackgroundBenchmark.continuousUptime) {
        guard !enabled else { return }
        enabled = true; sessionID = UUID(); startedAt = now; lastSampleUptime = nil; pendingRequests.removeAll()
        append(.start, at: now, uptime: uptime)
    }
    func stop(at now: Date = Date(), uptime: Double = BackgroundBenchmark.continuousUptime) {
        guard enabled else { return }
        append(.stop, at: now, uptime: uptime); enabled = false; startedAt = nil; lastSampleUptime = nil
    }
    func mark(_ value: Scenario, at now: Date = Date(), uptime: Double = BackgroundBenchmark.continuousUptime) {
        scenario = value
        if isRecording(at: now, uptime: uptime) { append(.scenario, at: now, uptime: uptime) }
    }
    func observe(_ value: Context, at now: Date = Date(), uptime: Double = BackgroundBenchmark.continuousUptime) {
        guard isRecording(at: now, uptime: uptime) else { return }
        let changed = context.map { $0.active != value.active || $0.powered != value.powered || $0.lowPower != value.lowPower || $0.networkAvailable != value.networkAvailable } ?? true
        context = value
        if changed { append(.context, at: now, uptime: uptime) }
        if lastSampleUptime == nil || uptime < lastSampleUptime! || uptime - lastSampleUptime! >= Self.sampleInterval {
            lastSampleUptime = uptime; append(.sample, at: now, uptime: uptime)
        }
    }
    func requestStarted(at now: Date = Date(), uptime: Double = BackgroundBenchmark.continuousUptime) -> UUID? {
        guard isRecording(at: now, uptime: uptime) else { return nil }
        let id = UUID(); pendingRequests.insert(id); append(.requestStart, at: now, uptime: uptime, attemptID: id); return id
    }
    func requestFinished(_ id: UUID?, outcome: String, requestID: UUID?, status: Int?, elapsedMS: Int,
                         at now: Date = Date(), uptime: Double = BackgroundBenchmark.continuousUptime) {
        guard let id, isRecording(at: now, uptime: uptime),
              ["ok", "http_error", "transport_error", "decode_error", "encode_error", "cancelled", "invalid_response"].contains(outcome),
              pendingRequests.remove(id) != nil else { return }
        append(.requestEnd, at: now, uptime: uptime, attemptID: id, requestID: requestID, outcome: outcome, status: status, elapsedMS: max(0, elapsedMS))
    }
    /// Called only for a successful, fresh status response reporting active monitoring and quiet.
    func verifiedQuiet(at now: Date = Date(), uptime: Double = BackgroundBenchmark.continuousUptime) {
        if isRecording(at: now, uptime: uptime) { append(.quietVerified, at: now, uptime: uptime) }
    }
    private func isRecording(at now: Date, uptime: Double) -> Bool {
        guard enabled, let startedAt else { return false }
        if now.timeIntervalSince(startedAt) >= Self.maximumDuration || now < startedAt { stop(at: now, uptime: uptime); return false }
        return true
    }
    private func append(_ kind: Kind, at now: Date, uptime: Double, attemptID: UUID? = nil, requestID: UUID? = nil,
                        outcome: String? = nil, status: Int? = nil, elapsedMS: Int? = nil) {
        let entry = Entry(at: now, uptime: uptime, runID: runID, sessionID: sessionID, scenario: scenario, kind: kind,
                          context: context, attemptID: attemptID, requestID: requestID, outcome: outcome, status: status, elapsedMS: elapsedMS)
        entries.append(entry); entryCount = entries.count
        do {
            guard let url else { persistenceAvailable = false; return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = try JSONEncoder().encode(entry); data.append(10)
            if entries.count > Self.maximumEntries {
                entries = Array(entries.suffix(Self.maximumEntries - 5000)); entryCount = entries.count
                data = try entries.reduce(into: Data()) { output, row in output.append(try JSONEncoder().encode(row)); output.append(10) }
                try data.write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                try file.seekToEnd(); try file.write(contentsOf: data)
            } else { try data.write(to: url, options: .atomic) }
            #if os(iOS) || os(watchOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            #endif
            var protected = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protected.setResourceValues(values)
            persistenceAvailable = true
        } catch { persistenceAvailable = false }
    }
    /// Observed intervals only: the end of a recording is not evidence of future execution.
    var report: String {
        var lines = ["Crib Service · Background benchmark", "os=\(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "persistence=\(persistenceAvailable ? "available" : "unavailable") entries=\(entries.count)",
                     "Scenarios are manually marked. Gaps do not establish suspension or termination cause.",
                     "No additional requests, background execution assertions, pushes or real alarms are created.",
                     "Quiet deadlines below are simulated; crying, stale data or network failure can also stop renewals."]
        let sessions = Dictionary(grouping: entries, by: \.sessionID)
        for (id, rows) in sessions.sorted(by: { ($0.value.first?.at ?? .distantPast) < ($1.value.first?.at ?? .distantPast) }) {
            lines.append("\nSession \(id.uuidString) · \(rows.first!.at.ISO8601Format()) to \(rows.last!.at.ISO8601Format())")
            lines.append("recording_start_retained=\(rows.contains { $0.kind == .start }) process_runs=\(Set(rows.map(\.runID)).count)")
            let samples = rows.filter { $0.kind == .sample }
            let gaps = zip(samples, samples.dropFirst()).compactMap { a, b -> Double? in
                guard a.runID == b.runID, b.uptime >= a.uptime else { return nil }; return b.uptime - a.uptime
            }
            lines.append("largest_observed_execution_sample_gap_seconds=\(Int(gaps.max() ?? 0)) (five-second sampling; excludes gaps across process launches)")
            for scenario in Scenario.allCases {
                let labelled = rows.filter { $0.scenario == scenario }
                guard !labelled.isEmpty else { continue }
                let labelledSamples = labelled.filter { $0.kind == .sample }
                let labelledGaps = zip(samples, samples.dropFirst()).compactMap { a, b -> Double? in
                    guard a.scenario == scenario, b.scenario == scenario, a.runID == b.runID, b.uptime >= a.uptime else { return nil }
                    return b.uptime - a.uptime
                }
                lines.append("scenario=\(scenario.rawValue) samples=\(labelledSamples.count) largest_observed_sample_gap_seconds=\(Int(labelledGaps.max() ?? 0)) status_completions=\(labelled.filter { $0.kind == .requestEnd }.count)")
            }
            let quiet = rows.filter { $0.kind == .quietVerified }
            func elapsed(_ a: Entry, _ b: Entry) -> Double {
                a.runID == b.runID && b.uptime >= a.uptime ? b.uptime - a.uptime : max(0, b.at.timeIntervalSince(a.at))
            }
            let intervals = zip(quiet, quiet.dropFirst()).map { elapsed($0, $1) }
                + (quiet.last.map { [elapsed($0, rows.last!)] } ?? [])
            for limit in [30, 60, 120] {
                lines.append("simulated_\(limit)s_deadline_crossings=\(intervals.filter { $0 >= Double(limit) }.count) armed_intervals=\(intervals.count)")
            }
            let finished = Set(rows.filter { $0.kind == .requestEnd }.compactMap(\.attemptID))
            lines.append("unfinished_status_requests=\(rows.filter { $0.kind == .requestStart && !finished.contains($0.attemptID!) }.count)")
        }
        lines.append("\nRaw observations (JSON Lines; Date values are seconds since 2001-01-01 UTC):")
        lines += entries.compactMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) }
        return lines.joined(separator: "\n")
    }
}
