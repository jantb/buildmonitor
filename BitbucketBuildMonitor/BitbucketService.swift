import Foundation

class BitbucketService {
    private let baseURL = URL(string: "https://api.bitbucket.org/2.0")!

    // Fetches the latest pipeline status for a given repo
    func fetchLatestBuildStatus(workspace: String, repoSlug: String, credentials: Credentials) async -> MonitoredRepository {
        var updatedRepo = MonitoredRepository(workspace: workspace, repoSlug: repoSlug)
        updatedRepo.lastCheckedDate = Date()

        let workspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        let repoSlug = repoSlug.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !workspace.isEmpty, !repoSlug.isEmpty else {
            updatedRepo.statusMessage = "Workspace or repository slug is empty."
            return updatedRepo
        }

        // Endpoint for pipelines, sorted by creation date descending, limit 1
        var components = URLComponents(
            url: baseURL.appendingPathComponent("repositories/\(workspace)/\(repoSlug)/pipelines"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "sort", value: "-created_on"),
            URLQueryItem(name: "pagelen", value: "1") // Only need the latest
        ]

        guard let url = components.url else {
            updatedRepo.statusMessage = "Could not build Bitbucket API URL."
            return updatedRepo
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Basic Authentication with Username and App Password
        let loginString = "\(credentials.username):\(credentials.appPassword)"
        guard let loginData = loginString.data(using: .utf8) else {
            updatedRepo.statusMessage = "Could not encode credentials."
            return updatedRepo
        }
        request.setValue("Basic \(loginData.base64EncodedString())", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                updatedRepo.statusMessage = "Bitbucket returned an invalid response."
                return updatedRepo
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                updatedRepo.statusMessage = httpErrorMessage(statusCode: httpResponse.statusCode)
                return updatedRepo
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase // Bitbucket API uses snake_case
            let pipelineResponse = try decoder.decode(BitbucketPipelinesResponse.self, from: data)

            if let latestPipeline = pipelineResponse.values?.first {
                updatedRepo.status = mapPipelineToStatus(pipeline: latestPipeline)
                updatedRepo.lastBuildDate = pipelineDate(from: latestPipeline)

                if let uuid = latestPipeline.uuid?.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "") {
                    updatedRepo.pipelineUrl = "https://bitbucket.org/\(workspace)/\(repoSlug)/pipelines/results/\(uuid)"
                }
            } else {
                updatedRepo.status = .unknown // No pipelines found
                updatedRepo.statusMessage = "No pipelines found."
            }
            return updatedRepo

        } catch {
            updatedRepo.statusMessage = "Refresh failed: \(error.localizedDescription)"
            return updatedRepo
        }
    }

    // Helper to map Bitbucket pipeline state/result to our BuildStatus enum
    private func mapPipelineToStatus(pipeline: BitbucketPipeline) -> BuildStatus {
        let stateValues = normalizedValues(pipeline.state?.name, pipeline.state?.type)
        let resultValues = normalizedValues(pipeline.state?.result?.name, pipeline.state?.result?.type)

        if stateValues.contains("completed") || stateValues.contains("pipeline_state_completed") {
            if resultValues.contains(where: { $0.contains("successful") }) {
                return .success
            }
            if resultValues.contains(where: { $0.contains("failed") || $0.contains("error") }) {
                return .failed
            }
            if resultValues.contains(where: { $0.contains("stopped") }) {
                return .stopped
            }
            return .unknown
        }

        if stateValues.contains(where: { $0.contains("in_progress") || $0.contains("pending") }) {
            return .inProgress
        }

        if stateValues.contains(where: { $0.contains("failed") }) {
            return .failed
        }
        if stateValues.contains(where: { $0.contains("stopped") }) {
            return .stopped
        }
        if stateValues.contains(where: { $0.contains("successful") }) {
            return .success
        }

        return .unknown
    }

    private func normalizedValues(_ values: String?...) -> [String] {
        values.compactMap { $0?.lowercased() }
    }

    private func pipelineDate(from pipeline: BitbucketPipeline) -> Date? {
        let dateFormatter = ISO8601DateFormatter()
        for dateString in [pipeline.completedOn, pipeline.updatedOn, pipeline.createdOn] {
            if let dateString, let date = dateFormatter.date(from: dateString) {
                return date
            }
        }
        return nil
    }

    private func httpErrorMessage(statusCode: Int) -> String {
        switch statusCode {
        case 401:
            return "Authentication failed. Check the username and app password."
        case 403:
            return "The app password cannot read pipelines for this repository."
        case 404:
            return "Repository not found, or pipelines are not available."
        case 429:
            return "Bitbucket rate limit reached. Try again later."
        default:
            return "Bitbucket returned HTTP \(statusCode)."
        }
    }
}
