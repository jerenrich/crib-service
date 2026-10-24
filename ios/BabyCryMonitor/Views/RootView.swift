import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @State private var settings = false
    var body: some View {
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()
                if !model.safetyAccepted { OnboardingView() }
                else if model.role == nil { RoleSelectionView() }
                else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            HStack { Label("Crib Service", systemImage: "moon.stars").font(.title3.weight(.semibold)); Spacer(); NavigationLink { TimelineView() } label: { Image(systemName: "clock.arrow.circlepath").font(.title3).frame(width: 44, height: 44) }.accessibilityLabel("Timeline"); Button { settings = true } label: { Image(systemName: "slider.horizontal.3").font(.title3).frame(width: 44, height: 44) }.accessibilityLabel("Settings") }
                            if model.role == .listener { ListenerView() } else { ParentView() }
                            Text("Audio never leaves the Listener iPhone.").font(.footnote).foregroundStyle(Palette.muted).frame(maxWidth: .infinity)
                            Text("Sound detection only · Adult supervision required").font(.caption2).foregroundStyle(Palette.muted).frame(maxWidth: .infinity)
                        }.padding(24)
                    }
                }
            }.foregroundStyle(.white).navigationTitle("Crib Service").toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $settings) { SettingsView() }
                .alert("Attention needed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        }.tint(Palette.mint).preferredColorScheme(.dark)
            .onChange(of: phase == .active && model.shouldKeepScreenAwake, initial: true) { _, keepAwake in
                UIApplication.shared.isIdleTimerDisabled = keepAwake
            }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            .task { model.setAppActive(phase == .active); await model.foreground() }
            .onChange(of: phase) { _, value in
                model.setAppActive(value == .active)
                if value == .active { Task { await model.foreground() } }
                else if value == .background { model.log.record("background") }
            }
    }
}
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 28) {
            Image(systemName: "moon.stars.fill").font(.system(size: 64)).foregroundStyle(Palette.mint).padding(.top, 50)
            Text("A little time.\nA quiet nudge.").font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text("Get an alert when loud sound continues beyond the time you choose. Give settling a moment, and stay informed.").foregroundStyle(Palette.muted)
            Panel {
                Label("Private by design", systemImage: "lock.shield").font(.headline)
                Text("Audio never leaves the Listener iPhone. Sound-level readings are shared for the live chart, alongside episode timestamps and monitoring status.").font(.subheadline).foregroundStyle(Palette.muted)
            }
            Text("Crib Service detects sound only.").font(.headline)
            Text("It cannot detect breathing problems, movement problems, silent distress, medical emergencies, or unsafe sleep conditions.\n\nDo not rely on this app as a substitute for appropriate adult supervision or a medical monitoring device.").font(.subheadline).foregroundStyle(Palette.muted)
            PrimaryButton(title: "I understand · Continue") { model.acceptSafety() }
        }.padding(28) }
    }
}
struct RoleSelectionView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Image(systemName: "moon.stars").font(.system(size: 48)).foregroundStyle(Palette.mint)
            Text("How will this\niPhone be used?").font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text("Two iPhones. One peaceful connection.").foregroundStyle(Palette.muted)
            roleButton("Listen to Baby", subtitle: "Leave this iPhone in the nursery", icon: "waveform", role: .listener)
            roleButton("Parent Mode", subtitle: "Receive a quiet nudge when it's time", icon: "bell.badge", role: .parent)
            Text("You can change this later in Settings.").font(.footnote).foregroundStyle(Palette.muted)
        }.padding(28)
    }
    private func roleButton(_ title: String, subtitle: String, icon: String, role: DeviceRole) -> some View {
        Button { model.selectRole(role) } label: {
            Panel { HStack(spacing: 18) { Image(systemName: icon).font(.title).foregroundStyle(Palette.mint); VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); Text(subtitle).font(.subheadline).foregroundStyle(Palette.muted) }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(Palette.muted) } }
        }.buttonStyle(.plain)
    }
}
