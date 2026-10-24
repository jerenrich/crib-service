import SwiftUI

struct NightstandDevice: Identifiable {
    enum Tone: Equatable { case active, warning, unavailable }
    let id: String
    let name: String
    let icon: String
    let detail: String
    let status: String
    let tone: Tone
}

extension AppModel {
    /// A pairing or a push token is not evidence that a remote device is online.
    var nightstandDevices: [NightstandDevice] {
        let listener = role == .listener
        var devices: [NightstandDevice] = []
        if listener {
            devices.append(NightstandDevice(id: "listener", name: "Nursery iPhone", icon: "iphone",
                detail: "Listener · This iPhone\n\(Self.devicePower(batteryLevel, powerConnected))",
                status: recoveringAudio ? "Recovering" : monitoring ? "Listening" : "Stopped",
                tone: recoveringAudio ? .warning : monitoring ? .active : .unavailable))
        } else if paired {
            let fresh = parentStatus?.lastHeartbeat.map { (-5...150).contains(now.timeIntervalSince($0)) } == true
            let power = Self.devicePower(parentStatus?.batteryLevel, parentStatus?.powerConnected)
            let detail = "Listener · Nursery\n" + (parentStatus?.lastHeartbeat == nil ? "Battery unavailable" : fresh ? power : "Last known · \(power)")
            devices.append(NightstandDevice(id: "listener", name: "Nursery iPhone", icon: "iphone",
                detail: detail, status: nurseryConnection,
                tone: nurseryConnection == "Monitoring" ? .active : nurseryConnection == "Stopped" ? .unavailable : .warning))
        }

        if !listener {
            devices.append(NightstandDevice(id: "parent", name: "Parent iPhone", icon: "iphone",
                detail: "Parent · This iPhone\n\(Self.devicePower(batteryLevel, powerConnected))",
                status: !connectivity.checked ? "Checking network" : connectivity.available ? "Network available" : "Offline",
                tone: !connectivity.checked ? .unavailable : connectivity.available ? .active : .warning))
        } else if paired {
            let fresh = listenerPairStatusReceivedAt.map { (-5...30).contains(now.timeIntervalSince($0)) } == true
                && connectivity.available
            let registration = fresh ? listenerPairStatus?.phonePushRegistered : nil
            devices.append(NightstandDevice(id: "parent", name: "Parent iPhone", icon: "iphone",
                detail: "Parent · Receives alerts\nLive device status unavailable",
                status: registration == true ? "Alerts registered" : registration == false ? "Alerts not registered" : "Paired",
                tone: registration == true ? .active : registration == false ? .warning : .unavailable))
        }

        let pairStatus = listener ? listenerPairStatus : parentStatus
        let watchRegistered = pairStatus?.watchPushRegistered == true
        let localWatch = !listener && watch.installed
        if (paired && watchRegistered) || localWatch {
            let fresh = listener
                ? listenerPairStatusReceivedAt.map { (-5...30).contains(now.timeIntervalSince($0)) } == true && connectivity.available
                : parentStatus != nil && connectivity.available
            let status: String
            let tone: NightstandDevice.Tone
            if localWatch && watch.reachable { status = "Reachable"; tone = .active }
            else if watchRegistered && fresh { status = "Alerts registered"; tone = .active }
            else if localWatch { status = "Not reachable"; tone = .unavailable }
            else { status = "Status unavailable"; tone = .unavailable }
            devices.append(NightstandDevice(id: "watch", name: "Apple Watch", icon: "applewatch",
                detail: "Via Parent iPhone\n\(localWatch ? watch.status : "Live Watch status unavailable")",
                status: status, tone: tone))
        }
        return devices
    }

    private static func devicePower(_ battery: Double?, _ connected: Bool?) -> String {
        let charge = battery.flatMap { $0.isFinite && (0...1).contains($0) ? "\(Int($0 * 100))%" : nil } ?? "Battery unavailable"
        return charge + (connected.map { $0 ? " · Charging" : " · On battery" } ?? "")
    }
}

struct NightstandDevicesPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Caption(text: "Your devices")
                Spacer()
                Text(model.paired ? "Paired" : "Not paired").font(.caption).foregroundStyle(Palette.muted)
            }
            let devices = model.nightstandDevices
            ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                if index > 0 { Divider().overlay(Palette.muted.opacity(0.15)) }
                row(device)
            }
            if !model.paired {
                Text("Pair the Listener and Parent iPhones to see both devices here.")
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
        }
        .padding(18).background(Palette.panel, in: RoundedRectangle(cornerRadius: 20))
    }

    private func row(_ device: NightstandDevice) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: device.icon).font(.title3)
                .foregroundStyle(Palette.lavender).frame(width: 30, height: 38)
                .background(Palette.lavender.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                if typeSize.isAccessibilitySize {
                    Text(device.name).font(.subheadline.weight(.medium))
                    status(device)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(device.name).font(.subheadline.weight(.medium)).fixedSize()
                            Spacer(minLength: 0)
                            status(device).fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name).font(.subheadline.weight(.medium))
                            status(device)
                        }
                    }
                }
                Text(device.detail).font(.caption).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pairedDevice_\(device.id)")
    }

    private func status(_ device: NightstandDevice) -> some View {
        Text(device.status).font(.caption)
            .foregroundStyle(device.tone == .warning ? Palette.amber : device.tone == .active ? Palette.lavender : Palette.muted)
    }
}

struct NightstandDevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var pairing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                NightstandDevicesPanel()
                if !model.paired {
                    PrimaryButton(title: model.role == .listener ? "Pair with Parent" : "Pair Listener") { pairing = true }
                }
                Panel {
                    Caption(text: "Connection")
                    Text(model.deliveryStatus).font(.subheadline).foregroundStyle(Palette.muted)
                    Text("A registered alert destination does not confirm that a device is online or that a notification was received.")
                        .font(.footnote).foregroundStyle(Palette.muted)
                }
                if model.role == .parent {
                    Panel {
                        Label("Apple Watch", systemImage: "applewatch").font(.headline)
                        Text(model.watch.status).font(.subheadline).foregroundStyle(Palette.muted)
                        NavigationLink("Guided overnight setup & watch test") { OvernightSetupView() }
                        Text("Enable alerts in the Watch app, then check Sleep Focus and haptics with a real test.")
                            .font(.footnote).foregroundStyle(Palette.muted)
                    }
                }
                Text("Sound levels are processed on the Listener. Audio never leaves that iPhone.")
                    .font(.footnote).foregroundStyle(Palette.muted)
            }.padding(20)
        }
        .background(Palette.background).navigationTitle("Devices")
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Palette.background, for: .navigationBar)
        .sheet(isPresented: $pairing) { PairingView() }
    }
}
