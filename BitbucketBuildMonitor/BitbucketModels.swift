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

struct BitbucketPipelineTarget: Codable, Hashable {
    let type: String?
    let refType: String?
    let refName: String?
}

struct BitbucketLinks: Codable, Hashable {
    let html: BitbucketLink?
}

struct BitbucketLink: Codable, Hashable {
    let href: String?
}

// Simplified model for a Pipeline
struct BitbucketPipeline: Codable, Hashable {
    let uuid: String?
    let buildNumber: Int?
    let state: BitbucketPipelineState?
    let target: BitbucketPipelineTarget?
    let links: BitbucketLinks?
    let buildSecondsUsed: Int?
    let createdOn: String?
    let completedOn: String?
    let updatedOn: String?
    // Add trigger, repository, etc. if needed
}

struct BitbucketPipelineStep: Codable, Hashable {
    let uuid: String?
    let name: String?
    let state: BitbucketPipelineState?
    let startedOn: String?
    let completedOn: String?
}

// Response structure when fetching pipelines
struct BitbucketPipelinesResponse: Codable {
    let values: [BitbucketPipeline]?
    let page: Int?
    let pagelen: Int?
    let size: Int?
    // Add next/previous links if handling pagination
}

struct PipelineProgress: Hashable {
    let completedStepCount: Int
    let totalStepCount: Int
    let fraction: Double

    var percent: Int {
        Int((fraction * 100).rounded())
    }

    var stepSummary: String {
        "\(completedStepCount)/\(totalStepCount) steps"
    }
}

struct BitbucketPaginatedResponse<Value: Codable>: Codable {
    let values: [Value]?
    let next: String?
}

struct BitbucketWorkspacePermission: Codable {
    let workspace: BitbucketWorkspace
}

struct BitbucketWorkspace: Codable, Hashable, Identifiable {
    let uuid: String?
    let name: String?
    let slug: String

    var id: String { slug.lowercased() }
    var displayName: String { name?.isEmpty == false ? name! : slug }
}

struct BitbucketProject: Codable, Hashable, Identifiable {
    let uuid: String?
    let key: String
    let name: String?
    let isPrivate: Bool?

    var id: String { key.lowercased() }
    var displayName: String { name?.isEmpty == false ? name! : key }
}

struct BitbucketRepositorySummary: Codable, Hashable, Identifiable {
    let uuid: String?
    let name: String?
    let slug: String
    let fullName: String?
    let project: BitbucketProject?
    let isPrivate: Bool?

    var id: String { (fullName ?? slug).lowercased() }
    var displayName: String { name?.isEmpty == false ? name! : slug }
    var projectKey: String? { project?.key }
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
        case .inProgress: return .yellow
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

enum DeploymentEnvironment: String, Hashable {
    case production = "Production"
    case development = "Dev"
    case test = "Test"

    init?(branchName: String?) {
        switch branchName?.lowercased() {
        case "main": self = .production
        case "develop", "development": self = .development
        case "release/next": self = .test
        default: return nil
        }
    }
}

struct KeyBuildBranch: Identifiable, Hashable {
    let name: String
    let shortLabel: String

    var id: String { name.lowercased() }

    static let releaseNext = KeyBuildBranch(name: "release/next", shortLabel: "R")
    static let develop = KeyBuildBranch(name: "develop", shortLabel: "D")
    static let main = KeyBuildBranch(name: "main", shortLabel: "M")
    static let all: [KeyBuildBranch] = [.releaseNext, .develop, .main]
}

struct BranchBuildStatus: Identifiable, Hashable {
    let branch: KeyBuildBranch
    var status: BuildStatus = .unknown
    var lastBuildDate: Date? = nil
    var pipelineUrl: String? = nil
    var statusMessage: String? = nil
    var pipelineProgress: PipelineProgress? = nil

    var id: String { branch.id }
    var branchName: String { branch.name }

    var contextLabel: String {
        guard let deploymentEnvironment = DeploymentEnvironment(branchName: branch.name) else {
            return branch.name
        }
        return "\(branch.name) - \(deploymentEnvironment.rawValue)"
    }
}

// Structure to hold repository info and its status
struct MonitoredRepository: Identifiable, Hashable {
    var id: String { compositeSlug.lowercased() }

    let workspace: String
    let repoSlug: String
    var status: BuildStatus = .unknown
    var branchName: String? = nil
    var lastBuildDate: Date? = nil
    var lastCheckedDate: Date? = nil
    var pipelineUrl: String? = nil // Optional URL to the specific pipeline run
    var statusMessage: String? = nil
    var pipelineProgress: PipelineProgress? = nil
    var branchStatuses: [BranchBuildStatus] = KeyBuildBranch.all.map { BranchBuildStatus(branch: $0) }

    var compositeSlug: String { "\(workspace)/\(repoSlug)" }
    var deploymentEnvironment: DeploymentEnvironment? { DeploymentEnvironment(branchName: branchName) }
    var statusItems: [BuildStatus] {
        branchStatuses.isEmpty ? [status] : branchStatuses.map(\.status)
    }

    var buildContextLabel: String? {
        guard let branchName, !branchName.isEmpty else { return nil }
        guard let deploymentEnvironment else { return branchName }
        return "\(branchName) - \(deploymentEnvironment.rawValue)"
    }
}
