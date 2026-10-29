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
            if service.enabled {
                // Experimental: compare delivery methods on this iPhone. Both may run;
                // each episode still gets a single alarm.
                Toggle("Wake the app in the background", isOn: Binding(get: { service.appWakeEnabled }, set: { value in
                    Task { await model.setAlarmMethods(appWake: value, extensionMethod: service.extensionEnabled) }
                }))
                .accessibilityIdentifier("alarmMethodAppWake")
                Toggle("Schedule from the notification extension", isOn: Binding(get: { service.extensionEnabled }, set: { value in
                    Task { await model.setAlarmMethods(appWake: service.appWakeEnabled, extensionMethod: value) }
                }))
                .accessibilityIdentifier("alarmMethodExtension")
                if !service.appWakeEnabled && !service.extensionEnabled {
                    Text("No alarm method selected: notifications continue, but no alarm will be scheduled.").font(.footnote).foregroundStyle(.orange)
                }
            }
            Text(service.status).font(.footnote)
            Button("Open iPhone alarm settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        } header: { Text("Overnight wrist alarms") } footer: {
            Text("Off by default. When enabled, confirmed crying or a lost Listener connection also requests a repeating alarm with a silent tone. Existing notifications always continue. Keep this iPhone locked and connected; wear your unlocked Watch in Silent Mode with Prominent haptics. No need to keep the Watch app open. Stopping the alarm snoozes crying and connection-loss alerts for your chosen duration. The setting stays on until you turn it off. iOS may delay background processing, and routing or fallback sounds can vary; test before sleeping. Delivery methods: waking the app is limited by iOS (for example on battery); the notification extension runs as each alert arrives. Compare their delays in Diagnostics → Recent alarm attempts.")
        }
    }
}
