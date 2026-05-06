import SwiftUI

struct StatusIconView: View {
    // Represents the overall status to show in the menu bar.
    // You might aggregate the status (e.g., show failure if any repo failed).
    let overallStatus: BuildStatus

    var body: some View {
        Image(systemName: overallStatus.symbolName)
             .foregroundColor(overallStatus.color)
             .font(.title2) // Adjust size as needed
             .padding(.horizontal, 4) // Add some spacing
    }
}

// Helper extension for BuildStatus to get SF Symbol name
extension BuildStatus {
    var symbolName: String {
        // Return the rawValue which we defined as the SF Symbol name
        return self.rawValue
    }
}

// Helper function to determine the single icon to show in the menu bar
// Prioritizes failure > inProgress > success > stopped > unknown
func aggregateStatus(repos: [MonitoredRepository]) -> BuildStatus {
    if repos.isEmpty { return .unknown }
    if repos.contains(where: { $0.status == .failed }) { return .failed }
    if repos.contains(where: { $0.status == .inProgress }) { return .inProgress }
    if repos.contains(where: { $0.status == .stopped }) { return .stopped } // Show stopped before success
    if repos.allSatisfy({ $0.status == .success }) { return .success } // Only show success if ALL are success
    // Check if all non-success are unknown (initial state)
    if repos.allSatisfy({ $0.status == .success || $0.status == .unknown }) && repos.contains(where: {$0.status == .success }) {
         return .success // Show success if some are success and others are just unknown
    }
    return .unknown // Default if mix of unknown/stopped/success or only unknown
}
