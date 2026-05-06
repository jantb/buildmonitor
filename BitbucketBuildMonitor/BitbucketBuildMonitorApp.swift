import SwiftUI

@main
struct BuildMonitorApp: App {
    // Create AppState as a StateObject to keep it alive
    @StateObject private var appState = AppState()

    var body: some Scene {
        // Define the Menu Bar Extra
        MenuBarExtra {
            // Content of the popover menu
            MenuBarContentView()
                .environmentObject(appState) // Inject AppState into the view hierarchy
        } label: {
            // The icon displayed in the menu bar itself
             StatusIconView(overallStatus: aggregateStatus(repos: appState.monitoredRepos))
                 .animation(.easeInOut, value: appState.monitoredRepos.map { $0.status }) // Animate status changes
                 .contentShape(Rectangle()) // Ensure the whole area is clickable
                 .onAppear {
                     // Optional: Trigger initial refresh if needed on icon appear
                     // Already handled in AppState init, but could force here too
                 }
        }
        .menuBarExtraStyle(.window) // Use a popover window style

        // Define the Settings Window Scene (won't open automatically)
        Window("BuildMonitor Settings", id: "settings-window") {
             SettingsView()
                 .environmentObject(appState) // Inject AppState here too
         }
    }
}
