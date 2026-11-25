import Foundation

/// Whether this Parent iPhone's notification settings let a crying alert wake
/// someone. The push can be accepted and delivered while these settings make it
/// silent or invisible, so the server alone cannot tell.
public enum WakeReadiness {
    public enum Authorization: Sendable { case authorized, quiet, denied }
    /// Problems in the order a parent should fix them; empty when ready.
    public static func problems(authorization: Authorization, alerts: Bool, sounds: Bool, timeSensitive: Bool) -> [String] {
        switch authorization {
        case .denied:
            return ["Notifications are off for Crib Service, so crying alerts cannot reach this iPhone. Turn them on in Settings › Notifications › Crib Service."]
        case .quiet:
            return ["Crib Service notifications are set to deliver quietly. Allow alerts with sound in Settings › Notifications › Crib Service."]
        case .authorized:
            var result: [String] = []
            if !alerts { result.append("Crib Service alerts are hidden. Turn on Lock Screen and Banners in Settings › Notifications › Crib Service.") }
            if !sounds { result.append("Notification sounds are off for Crib Service, so a crying alert makes no sound. Turn on Sounds in Settings › Notifications › Crib Service.") }
            if !timeSensitive { result.append("Time Sensitive is off for Crib Service, so Sleep Focus can silence crying alerts. Turn it on in Settings › Notifications › Crib Service.") }
            return result
        }
    }
    /// The Watch's version: one banner, naming each setting that is off. Watch
    /// notification options are set from the iPhone's Watch app, or mirror the
    /// iPhone's own Crib Service settings.
    public static func watchWarning(alertsOff: Bool, soundsOff: Bool, timeSensitiveOff: Bool) -> String? {
        var off: [String] = []
        if alertsOff { off.append("notifications") }
        if soundsOff { off.append("sound/haptics") }
        if timeSensitiveOff { off.append("Time Sensitive") }
        guard !off.isEmpty else { return nil }
        let list = off.count == 1 ? off[0] : off.dropLast().joined(separator: ", ") + " and " + off[off.count - 1]
        let focus = timeSensitiveOff ? " Without Time Sensitive, Sleep Focus can silence crying alerts." : ""
        return "Crib Service \(list) \(off.count == 1 ? "is" : "are") off on this Watch.\(focus) Turn \(off.count == 1 ? "it" : "them") on in the iPhone's Settings › Notifications › Crib Service and its Watch app › Notifications. Global Prominent Haptics does not change this app's notification permissions."
    }
}
