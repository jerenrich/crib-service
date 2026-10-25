import SwiftUI

@available(iOS 26.0, *)
struct SilentWatchAlarmSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var service = SilentCryAlarmService.shared
    var body: some View {
        Section {
            Toggle("Silent Watch alarms", isOn: Binding(get: { service.enabled }, set: { value in
                Task { await model.setSilentWatchAlarms(value) }
            }))
            .disabled(service.busy || !model.paired)
            .accessibilityIdentifier("silentWatchAlarms")
            Text(service.status).font(.footnote)
            Button("Open iPhone alarm settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        } header: { Text("Overnight wrist alarms") } footer: {
            Text("Off by default. When enabled, confirmed crying also requests a repeating alarm with a silent tone. Existing notifications always continue. Keep this iPhone locked and connected; wear your unlocked Watch in Silent Mode with Prominent haptics. No need to keep the Watch app open. Stopping the alarm snoozes crying alerts for your chosen duration. The setting stays on until you turn it off. iOS may delay background processing, and routing or fallback sounds can vary; test before sleeping.")
        }
    }
}
