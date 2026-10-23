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
    public func threshold(for sensitivity: Sensitivity) -> Double? {
        backgroundLevel.map { max(-35, $0 + sensitivity.margin) }
    }
    public var recommendedSensitivity: Sensitivity? {
        guard background.count >= 20, sample.count >= 12, let sampleLevel, let backgroundLevel,
              backgroundLevel < -35 else { return nil }
        // Background above the initial absolute floor freezes the live adaptive
        // baseline. Do not suggest a margin that the detector cannot learn here.
        return [Sensitivity.low, .medium, .high].first {
            let threshold = max(-35, backgroundLevel + $0.margin)
            return backgroundLevel < threshold && sampleLevel >= threshold + 2
        }
    }
}
