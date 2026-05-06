import Foundation
import SwiftUI

// Simplified model for Pipeline State
struct BitbucketPipelineState: Codable, Hashable {
    let name: String? // e.g., "IN_PROGRESS", "COMPLETED", "FAILED"
    let type: String? // e.g., "IN_PROGRESS", "COMPLETED", "FAILED"
    let result: BitbucketPipelineResult?
}

// Simplified model for Pipeline Result (if state is COMPLETED)
struct BitbucketPipelineResult: Codable, Hashable {
    let name: String? // e.g., "SUCCESSFUL", "FAILED", "STOPPED"
    let type: String?
}

// Simplified model for a Pipeline
struct BitbucketPipeline: Codable, Hashable {
    let uuid: String?
    let state: BitbucketPipelineState?
    let buildSecondsUsed: Int?
    let createdOn: String?
    let completedOn: String?
    let updatedOn: String?
    // Add target, trigger, repository, etc. if needed
}

// Response structure when fetching pipelines
struct BitbucketPipelinesResponse: Codable {
    let values: [BitbucketPipeline]?
    let page: Int?
    let pagelen: Int?
    let size: Int?
    // Add next/previous links if handling pagination
}

// Enum to represent unified build status
enum BuildStatus: String, CaseIterable, Hashable {
    case unknown = "questionmark.circle" // SF Symbol name
    case success = "checkmark.circle.fill"
    case failed = "xmark.octagon.fill"
    case inProgress = "hourglass.circle.fill"
    case stopped = "stop.circle.fill"

    var color: Color {
        switch self {
        case .unknown: return .gray
        case .success: return .green
        case .failed: return .red
        case .inProgress: return .blue
        case .stopped: return .orange
        }
    }

    var label: String {
        switch self {
        case .unknown: return "Unknown"
        case .success: return "Successful"
        case .failed: return "Failed"
        case .inProgress: return "In progress"
        case .stopped: return "Stopped"
        }
    }
}

// Structure to hold repository info and its status
struct MonitoredRepository: Identifiable, Hashable {
    var id: String { compositeSlug.lowercased() }

    let workspace: String
    let repoSlug: String
    var status: BuildStatus = .unknown
    var lastBuildDate: Date? = nil
    var lastCheckedDate: Date? = nil
    var pipelineUrl: String? = nil // Optional URL to the specific pipeline run
    var statusMessage: String? = nil

    var compositeSlug: String { "\(workspace)/\(repoSlug)" }
}
