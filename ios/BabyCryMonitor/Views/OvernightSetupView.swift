import SwiftUI
import UIKit

struct OvernightSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var focusChecked = false
    @State private var wristChecked = false
    @State private var awaitingConfirmation = false
    @State private var confirmedAt: Date?
    @State private var needsTroubleshooting = false

    var body: some View {
        Form {
            Section {
                Text("Follow these steps with the Watch and Sleep Focus settings you plan to use tonight. Repeat the test after changing them.")
                Text("Focus and haptic settings are checked by you. The app cannot read or change them.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("1. Enable Watch alerts") {
                Label(model.parentStatus?.watchPushRegistered == true ? "Direct Watch alerts registered" : "Watch registration needs checking",
                      systemImage: model.parentStatus?.watchPushRegistered == true ? "checkmark.circle" : "exclamationmark.circle")
                Text("Open Crib Service on your Apple Watch → Wrist alerts → Enable alerts or Retry setup. Keep this iPhone in Parent Mode with internet access.")
                Text("On this iPhone, also check Watch → Notifications → Crib Service and allow notifications.")
                Button("Refresh Watch registration") { Task { await model.refreshParent() } }
                Link("Open app notification settings", destination: URL(string: UIApplication.openNotificationSettingsURLString)!)
                Text("This link opens iPhone notification settings. Watch permissions are managed separately in the Watch app.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("2. Allow alerts during Sleep Focus") {
                Text("On your iPhone, open Settings → Focus → Sleep → Apps. Choose Allow Notifications From and add Crib Service. If you use Silence Notifications From, make sure Crib Service is not listed.")
                Text("Your Watch uses the Focus preferences set up on its paired iPhone. Check that Sleep Focus is active on the Watch too; direct Watch notifications still follow Focus rules.")
                Text("Allow Time Sensitive Notifications in Sleep Focus and for Crib Service on your Watch, where available. Check any other Focus you use overnight too.")
                Toggle("I've checked my Focus settings", isOn: $focusChecked)
                    .disabled(model.sendingTestPush)
                    .accessibilityIdentifier("overnightFocusChecked")
                Text("User-checked for this setup session.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("3. Prepare your Watch") {
                Text("On your Watch, open Settings → Sounds & Haptics. Enable haptics and choose Prominent. Turn on Silent Mode if you want vibration only.")
                Text("Wear your Watch snugly and unlocked, with enough battery and an internet connection for the night.")
                Toggle("My Watch is ready on my wrist", isOn: $wristChecked)
                    .disabled(model.sendingTestPush)
                    .accessibilityIdentifier("overnightWristChecked")
            }
            Section("4. Test with Sleep Focus on") {
                Text("Turn on your intended Sleep Focus. Leave the Watch app on its clock face. Tap Test watch alert, then lock this iPhone and wait for a clearly labelled test notification and wrist tap.")
                Button(model.sendingTestPush ? "Sending…" : "Test watch alert") {
                    awaitingConfirmation = false; confirmedAt = nil; needsTroubleshooting = false
                    Task { awaitingConfirmation = await model.requestParentTest(requiresWatch: true) }
                }
                .disabled(!model.canTestWatchAlert || !focusChecked || !wristChecked)
                .accessibilityIdentifier("testWatchAlert")
                if !model.paired { Text("Pair a Listener first in Tonight's check.").font(.footnote) }
                else if model.parentStatus?.watchPushRegistered != true { Text("Complete step 1 and refresh Watch registration to enable the test.").font(.footnote) }
                if !focusChecked || !wristChecked { Text("Confirm steps 2 and 3 to enable the test.").font(.footnote) }
                if let status = model.testPushStatus { Text(status).font(.footnote) }
                if awaitingConfirmation {
                    Button("I felt the test on my Watch") {
                        confirmedAt = Date(); awaitingConfirmation = false; needsTroubleshooting = false
                    }.accessibilityIdentifier("confirmWatchAlert")
                    Button("I didn't feel it") { awaitingConfirmation = false; needsTroubleshooting = true }
                }
                if let confirmedAt {
                    Label("Wrist tap confirmed by you at \(confirmedAt.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                    Text("This confirms this test only. Repeat after changing your Focus, Watch or connection settings.").font(.footnote)
                }
                if needsTroubleshooting {
                    Text("Check Watch notification permission, Sleep Focus exceptions, haptics, wrist lock, battery and internet. Refresh Watch registration, then try again. Seeing a notification without feeling a tap does not confirm vibration.").font(.footnote)
                }
                Text("This sends a real test through the notification service to your registered Watch. Also send a test from the nursery Listener to check its upload connection. A successful test cannot guarantee later delivery or that an alert will wake you.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Overnight setup")
        .onChange(of: focusChecked) { _, _ in resetConfirmation() }
        .onChange(of: wristChecked) { _, _ in resetConfirmation() }
        .onChange(of: model.paired) { _, _ in resetConfirmation() }
        .onChange(of: model.parentStatus?.watchPushRegistered) { _, _ in resetConfirmation() }
        .task { await model.refreshParent() }
    }

    private func resetConfirmation() {
        awaitingConfirmation = false; confirmedAt = nil; needsTroubleshooting = false
    }
}
