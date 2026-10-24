import Foundation

/// Separate retention from the short diagnostic ring so an overnight discharge
/// survives routine network logging. All fields are structured, local telemetry.
@MainActor final class BatteryDrainLog {
    struct Sample: Codable, Equatable {
        let timestamp: Date
        let runID: UUID
        let batteryLevel: Double?
        let powerConnected: Bool?
        let monitoring: Bool
        let audioActive: Bool
        let lowPowerMode: Bool
        let appActive: Bool
    }
    static let interval: TimeInterval = 300
    static let retention: TimeInterval = 30 * 86400
    static let maximumSamples = 10_000
    private(set) var samples: [Sample] = []
    private(set) var persistenceAvailable = true
    private let runID = UUID() // New on relaunch; never a device or pairing ID.
    private let url: URL?

    init(directory: URL?, now: Date = Date()) {
        url = directory?.appendingPathComponent("battery-drain.json")
        do {
            guard let directory, let url else { persistenceAvailable = false; return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: url))
                let count = samples.count
                prune(at: now)
                if count != samples.count { save() }
            }
        } catch { persistenceAvailable = false }
    }

    func record(batteryLevel: Double?, powerConnected: Bool?, monitoring: Bool, audioActive: Bool,
                lowPowerMode: Bool, appActive: Bool, at now: Date) {
        let level = batteryLevel.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        if let last = samples.last, last.runID == runID {
            let elapsed = now.timeIntervalSince(last.timestamp)
            let sameContext = last.powerConnected == powerConnected && last.monitoring == monitoring
                && last.audioActive == audioActive && last.lowPowerMode == lowPowerMode && last.appActive == appActive
                && (last.batteryLevel == nil) == (level == nil)
            if sameContext && (0..<Self.interval).contains(elapsed) { return }
        }
        samples.append(Sample(timestamp: now, runID: runID, batteryLevel: level, powerConnected: powerConnected,
                              monitoring: monitoring, audioActive: audioActive, lowPowerMode: lowPowerMode, appActive: appActive))
        prune(at: now)
        save()
    }

    private func prune(at now: Date) {
        samples = Array(samples.filter { now.timeIntervalSince($0.timestamp) <= Self.retention }.suffix(Self.maximumSamples))
    }
    private func save() {
        do {
            guard var url else { persistenceAvailable = false; return }
            let data = try JSONEncoder().encode(samples)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            persistenceAvailable = true
        } catch { persistenceAvailable = false }
    }
    var export: String {
        let format = ISO8601DateFormatter()
        let rows = samples.map { sample in
            [format.string(from: sample.timestamp), sample.runID.uuidString.lowercased(),
             sample.batteryLevel.map { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), $0 * 100) } ?? "",
             sample.powerConnected.map { $0 ? "1" : "0" } ?? "", sample.monitoring ? "1" : "0",
             sample.audioActive ? "1" : "0", sample.lowPowerMode ? "1" : "0", sample.appActive ? "1" : "0"].joined(separator: ",")
        }
        return "Battery drain samples · persistence=\(persistenceAvailable ? "available" : "unavailable")\n"
            + "sampled_at,run_id,battery_percent,power_connected,monitoring,audio_active,low_power_mode,app_active\n"
            + rows.joined(separator: "\n")
    }
}
