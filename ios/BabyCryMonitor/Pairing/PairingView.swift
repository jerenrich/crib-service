import SwiftUI

struct PairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var busy = false
    @State private var joinFamily = false
    /// An unpaired Parent must first say whether the nursery iPhone already has a Parent:
    /// a Listener pairs with one Parent only, and a second parent joins that Parent's family.
    @State private var pairingNursery = false
    var body: some View {
        NavigationStack {
            Form {
                if model.role == .parent {
                    parentSections
                } else {
                    listenerSection
                }
                Section { Text("A code expires after 10 minutes and works once. Each iPhone has its own secret stored in Keychain.").font(.footnote) }
            }.navigationTitle("Pair iPhones").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task { model.pairingError = nil }
        }.tint(Palette.mint)
            .sheet(isPresented: $joinFamily) { CaregiverConnectionView() }
    }
    @ViewBuilder private var parentSections: some View {
        if model.paired {
            Section {
                Label("Paired successfully", systemImage: "checkmark.circle").foregroundStyle(Palette.mint)
                Text("To add a second parent, open Caregivers & duty and create a partner invitation.").font(.subheadline)
            }
        } else if pairingNursery || hasLiveCode {
            Section {
                Text("Show this code on the Parent iPhone. Enter it on your nursery Listener.")
                if let pairing = model.pairingCode, pairing.expiresAt > model.now {
                    Text("\(pairing.code.prefix(3)) \(pairing.code.suffix(3))").font(.system(size: 42, weight: .medium, design: .monospaced)).textSelection(.enabled).accessibilityLabel("Pairing code \(pairing.code)")
                    Text("Expires \(pairing.expiresAt.formatted(.relative(presentation: .numeric)))").font(.caption)
                }
                Button("Create pairing code") { run { await model.createPairing() } }.disabled(busy)
                if busy { ProgressView() }
                if let error = model.pairingError { Text(error).foregroundStyle(.orange) }
            }
            Section {
                Text("If the nursery iPhone is already paired with another parent’s iPhone, join their family instead.").font(.footnote)
                Button("Join a family") { joinFamily = true }
            }
        } else {
            Section("Is the nursery iPhone already paired with another parent’s iPhone?") {
                Button("Yes, join their family") { joinFamily = true }
                    .accessibilityIdentifier("pairingJoinFamily")
                Button("No, pair the nursery iPhone") { pairingNursery = true; run { await model.createPairing() } }
                    .accessibilityIdentifier("pairingNewNursery")
                Text("A nursery iPhone pairs with one Parent iPhone. A second parent joins with a partner invitation from Caregivers & duty on that Parent iPhone.").font(.footnote)
            }
        }
    }
    @ViewBuilder private var listenerSection: some View {
        Section {
            if model.paired {
                Label("Paired successfully", systemImage: "checkmark.circle").foregroundStyle(Palette.mint)
                Text("To add another parent, open Caregivers & duty on the Parent iPhone this one is paired with and create a partner invitation. You don’t need to change anything on this iPhone.").font(.subheadline)
            } else {
                Text("Enter the six-digit code shown on the Parent iPhone.")
                TextField("Six-digit code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .onChange(of: code) { _, value in code = String(value.filter(\.isNumber).prefix(6)) }
                Button("Pair with Parent") { run { await model.claimPairing(code); if model.paired { dismiss() } } }.disabled(busy || code.count != 6)
                if busy { ProgressView() }
                if let error = model.pairingError { Text(error).foregroundStyle(.orange) }
            }
        }
    }
    private var hasLiveCode: Bool { model.pairingCode.map { $0.expiresAt > model.now } ?? false }
    private func run(_ work: @escaping @MainActor () async -> Void) {
        busy = true; Task { await work(); busy = false }
    }
}
