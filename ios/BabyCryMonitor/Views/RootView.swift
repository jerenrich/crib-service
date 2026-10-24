import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @State private var settings = false
    @State private var tab = HomeTab.monitor
    private enum HomeTab { case monitor, activity, devices }

    var body: some View {
        Group {
            if !model.safetyAccepted {
                NavigationStack { OnboardingView().background(Palette.background) }
            } else if model.role == nil {
                NavigationStack { RoleSelectionView().background(Palette.background) }
            } else {
                TabView(selection: $tab) {
                    NavigationStack { monitorHome }
                        .tabItem { Label("Monitor", systemImage: "waveform") }.tag(HomeTab.monitor)
                    NavigationStack { TimelineView() }
                        .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }.tag(HomeTab.activity)
                    NavigationStack { NightstandDevicesView() }
                        .tabItem { Label("Devices", systemImage: "iphone") }.tag(HomeTab.devices)
                }
                .toolbarBackground(Palette.background, for: .tabBar)
            }
        }
        .foregroundStyle(.white).tint(Palette.lavender).preferredColorScheme(.dark)
        .sheet(isPresented: $settings) { SettingsView() }
        .alert("Attention needed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onChange(of: phase == .active && model.shouldKeepScreenAwake, initial: true) { _, keepAwake in
            UIApplication.shared.isIdleTimerDisabled = keepAwake
        }
        .onChange(of: model.role) { _, _ in tab = .monitor }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task { model.setAppActive(phase == .active); await model.foreground() }
        .onChange(of: phase) { _, value in
            model.setAppActive(value == .active)
            if value == .active { Task { await model.foreground() } }
            else if value == .background { model.log.record("background") }
        }
    }

    private var monitorHome: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Label {
                        Text("Crib Service")
                    } icon: {
                        Image(systemName: "moon.stars").foregroundStyle(Palette.lavender)
                    }.font(.title3.weight(.medium))
                    Spacer()
                    Button { settings = true } label: {
                        Image(systemName: "slider.horizontal.3").font(.body)
                            .frame(width: 44, height: 44).background(Palette.panel, in: Circle())
                    }.accessibilityLabel("Settings")
                }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 4)
                if model.role == .listener { ListenerView() } else { ParentView() }
            }
        }.navigationTitle("Crib Service").toolbar(.hidden, for: .navigationBar)
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
