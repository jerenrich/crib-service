import SwiftUI

@main struct BabyCryMonitorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup { RootView().environment(model).onAppear { delegate.notifications = model.notifications } }
    }
}
