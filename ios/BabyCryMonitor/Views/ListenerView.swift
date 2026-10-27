import SwiftUI

struct ListenerView: View {
    var showDevices: () -> Void = {}
    var body: some View { NightstandView(role: .listener, showDevices: showDevices) }

    static func alertMessage(for episode: CryEpisode, snapshot: SessionSnapshot, now: Date) -> String {
        switch snapshot.alertStatus(for: episode) {
        case .failed: "Alert delivery failed. This alert will not be retried. Check Worker/APNs diagnostics."
        case .pending: "Alert queued · Waiting for delivery confirmation"
        case .sent: "APNs accepted the alert. Check Parent for delivery."
        case .acknowledged: "Alert acknowledged on Parent."
        case .notQueued: "Another \(durationText(max(0, snapshot.configuration.alertDuration - episode.duration(at: now)))) before an alert."
        }
    }
}
