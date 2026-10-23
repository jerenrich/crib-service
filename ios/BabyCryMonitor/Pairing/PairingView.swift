import SwiftUI

struct PairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(model.role == .parent ? "Show this code on the Parent iPhone. Enter it on your nursery Listener." : "Enter the six-digit code shown on the Parent iPhone.")
                    if model.role == .parent {
                        if let pairing = model.pairingCode, pairing.expiresAt > model.now {
                            Text("\(pairing.code.prefix(3)) \(pairing.code.suffix(3))").font(.system(size: 42, weight: .medium, design: .monospaced)).textSelection(.enabled).accessibilityLabel("Pairing code \(pairing.code)")
                            Text("Expires \(pairing.expiresAt.formatted(.relative(presentation: .numeric)))").font(.caption)
                        }
                        Button("Create pairing code") { run { await model.createPairing() } }.disabled(busy || model.paired)
                    } else {
                        TextField("Six-digit code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                            .onChange(of: code) { _, value in code = String(value.filter(\.isNumber).prefix(6)) }
                        Button("Pair with Parent") { run { await model.claimPairing(code); if model.paired { dismiss() } } }.disabled(busy || code.count != 6)
                    }
                    if busy { ProgressView() }
                    if let error = model.error { Text(error).foregroundStyle(.orange) }
                    if model.paired { Label("Paired successfully", systemImage: "checkmark.circle").foregroundStyle(Palette.mint) }
                }
                Section { Text("A code expires after 10 minutes and works once. Each iPhone has its own secret stored in Keychain.").font(.footnote) }
            }.navigationTitle("Pair iPhones").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task { if model.role == .parent && !model.paired { run { await model.createPairing() } } }
        }.tint(Palette.mint)
    }
    private func run(_ work: @escaping @MainActor () async -> Void) {
        busy = true; Task { await work(); busy = false }
    }
}
