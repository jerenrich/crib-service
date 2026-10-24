import Foundation

/// A planning estimate, not measured device runtime.
struct ListenerPowerReadiness {
    enum State: Equatable { case connected, onBattery, lowUntilWakeup, unavailable }
    static let reserve = 0.20
    static let estimatedDrainPerHour = 0.05

    let state: State
    let wakeup: Date
    let batteryLevel: Double?
    let projectedBatteryLevel: Double?
    var needsPower: Bool { state == .lowUntilWakeup }

    init(batteryLevel: Double?, powerConnected: Bool?, fresh: Bool, now: Date, calendar: Calendar = .current) {
        // Use calendar arithmetic for the next local 07:00, including DST days.
        wakeup = calendar.nextDate(after: now, matching: DateComponents(hour: 7, minute: 0, second: 0),
                                   matchingPolicy: .nextTime, repeatedTimePolicy: .first)!
        self.batteryLevel = batteryLevel.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        let hoursRemaining = wakeup.timeIntervalSince(now) / 3600
        projectedBatteryLevel = self.batteryLevel.map { $0 - hoursRemaining * Self.estimatedDrainPerHour }
        guard fresh else { state = .unavailable; return }
        if powerConnected == true { state = .connected; return }
        guard powerConnected == false, let level = self.batteryLevel else { state = .unavailable; return }
        // UIDevice reports Float values; tolerate their rounding at exactly 20%.
        state = level - hoursRemaining * Self.estimatedDrainPerHour + 1e-7 < Self.reserve ? .lowUntilWakeup : .onBattery
    }

    var title: String {
        switch state {
        case .connected: "Listener connected to power"
        case .onBattery: "Listener on battery · \(percentage)%"
        case .lowUntilWakeup: "Connect Listener power · Estimated below 20% by 7:00 am"
        case .unavailable: "Listener battery status unavailable"
        }
    }
    var detail: String {
        switch state {
        case .connected: "External power is connected."
        case .onBattery: "Estimated \(projectedPercentage)% at 7:00 am."
        case .lowUntilWakeup: "\(percentage)% now; estimated \(projectedPercentage)% at 7:00 am. Connect power."
        case .unavailable: "Refresh Listener status for current power and battery information."
        }
    }
    private var percentage: Int { Int(((batteryLevel ?? 0) * 100).rounded()) }
    private var projectedPercentage: Int { Int(max(0, projectedBatteryLevel ?? 0) * 100 + 1e-5) }
}
