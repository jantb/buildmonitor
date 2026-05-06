import SwiftUI

@main
struct BuildMonitorApp: App {
    @NSApplicationDelegateAdaptor(StatusBarController.self) private var statusBarController

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
