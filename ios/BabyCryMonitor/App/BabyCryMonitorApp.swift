import SwiftUI

@main struct BabyCryMonitorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // Registration must finish during launch, before a background task can arrive.
        BackgroundRefreshController.shared.register(isParent: { [weak model] in model?.role == .parent })
    }
    var body: some Scene {
        WindowGroup { RootView().environment(model).onAppear { delegate.notifications = model.notifications } }
    }
}
