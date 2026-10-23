import Foundation

/// Local-only scalar measurements; never included in a heartbeat or alert.
public struct SoundCalibration: Sendable {
    public private(set) var background: [Double] = []
    public private(set) var sample: [Double] = []
    public init() {}
    public mutating func record(_ level: Double, background measuringBackground: Bool) {
        guard level.isFinite else { return }
        let bounded = min(0, max(-100, level))
        if measuringBackground { background.append(bounded); background = Array(background.suffix(80)) }
        else { sample.append(bounded); sample = Array(sample.suffix(80)) }
    }
    private func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }
    public var backgroundLevel: Double? { percentile(background, 0.9) }
    public var sampleLevel: Double? { percentile(sample, 0.5) }
    public var recommendedThreshold: Double? {
        guard background.count >= 20, sample.count >= 12, let sampleLevel, let backgroundLevel else { return nil }
        // Prefer the highest selectable level that clears room noise by at least
        // 8 dB while leaving the typical sample at least 2 dB above the trigger.
        return MonitoringConfiguration.soundThresholds.reversed().first {
            $0 >= backgroundLevel + 8 && sampleLevel >= $0 + 2
        }
    }
}
