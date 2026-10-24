import SwiftUI

struct ParentView: View {
    @Environment(AppModel.self) private var model
    @State private var showMonitoringError = false

    var body: some View {
        NightstandView(role: .parent)
            .onAppear {
                showMonitoringError = model.monitoringControlError != nil
            }
            .task { await model.refreshParent() }
            .onChange(of: model.monitoringControlError) { _, failure in
                showMonitoringError = failure != nil
            }
            .alert("Monitoring not confirmed", isPresented: $showMonitoringError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(model.monitoringControlError ?? "Check the nursery phone before relying on monitoring.")
            }
    }
}
