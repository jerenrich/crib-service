import SwiftUI
import UIKit

struct ReadinessView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Ready for tonight") {
                    check("iPhones paired", passed: model.paired)
                    check("Listener microphone reporting active", passed: model.parentOnline)
                    check("Listener connected to power", passed: model.parentOnline && model.parentStatus?.powerConnected == true)
                    check("iPhone notifications enabled", passed: model.notifications.authorizationAllowed && model.parentStatus?.phonePushRegistered == true)
                    check("Settings applied on Listener", passed: model.parentOnline && model.parentStatus?.listenerConfiguration == model.configuration)
                    check("Test receipt confirmed in the last 30 minutes", passed: model.recentConfirmedTest != nil)
                }
                Section {
                    if !model.paired { Button("Pair Listener") { pairing = true } }
                    Button("Check notifications") { Task { await model.notifications.register(); await model.tick(); await model.refreshParent() } }
                    Link("Open iPhone Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    Button("Refresh Listener status") { Task { await model.refreshParent() } }
                    Text("Start monitoring and connect power on the nursery Listener. Its status normally updates once a minute.").font(.footnote)
                }
                Section("Verify a real notification") {
                    Text("Send a test, lock this iPhone, and check your receiving phone or Watch. With a registered Watch, the test goes directly to the Watch. Confirm only after you see or feel it.")
                    Button(model.sendingTestPush ? "Sending…" : "Send real test notification") { Task { await model.requestParentTest() } }
                        .disabled(!model.paired || model.sendingTestPush)
                    if let status = model.testPushStatus { Text(status).font(.footnote) }
                    if let test = model.parentStatus?.alerts?.first(where: { $0.isTest == true && $0.acknowledgedAt == nil && (-5...1800).contains(model.now.timeIntervalSince($0.createdAt)) }) {
                        Button("I received this test") { Task { await model.acknowledge(test.eventId) } }
                    }
                    if let test = model.recentConfirmedTest {
                        Label("Receipt confirmed \(test.createdAt.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                    }
                    Text("A test requested here checks backend and notification delivery. Send another from the Listener to check its upload path. Test with your intended Sleep Focus and Watch settings. A successful test cannot guarantee later delivery.").font(.footnote)
                }
                Section {
                    Text("Sound detection only. Continue appropriate adult supervision. Physical interruption and overnight checks still need to be performed on your devices.").font(.footnote)
                }
            }.navigationTitle("Tonight's check")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .sheet(isPresented: $pairing) { PairingView() }
                .task { await model.notifications.register(); await model.refreshParent() }
        }.tint(Palette.mint)
    }
    private func check(_ title: String, passed: Bool) -> some View {
        Label(title, systemImage: passed ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundStyle(passed ? Palette.mint : Palette.amber)
            .accessibilityLabel("\(title): \(passed ? "Passed" : "Needs checking")")
    }
}
