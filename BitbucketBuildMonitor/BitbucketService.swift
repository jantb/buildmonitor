import Foundation

enum BitbucketAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Could not build Bitbucket API URL."
        case .invalidResponse:
            return "Bitbucket returned an invalid response."
        case .httpStatus(let statusCode):
            switch statusCode {
            case 401:
                return "Authentication failed. Use your Atlassian account email and a scoped Bitbucket API token."
            case 403:
                return "The API token cannot read this Bitbucket resource."
            case 404:
                return "Bitbucket resource not found."
            case 410:
                return "Bitbucket says this API endpoint is no longer available."
            case 429:
                return "Bitbucket rate limit reached. Try again later."
            default:
                return "Bitbucket returned HTTP \(statusCode)."
            }
        case .missingCredentials:
            return "Bitbucket credentials are missing."
        }
    }
}

class BitbucketService {
    private let baseURL = URL(string: "https://api.bitbucket.org/2.0")!

    func fetchAccessibleWorkspaces(credentials: Credentials) async throws -> [BitbucketWorkspace] {
        let permissions: [BitbucketWorkspacePermission] = try await fetchAllPages(
            path: "user/workspaces",
            queryItems: [
                URLQueryItem(name: "pagelen", value: "100")
            ],
            credentials: credentials
        )

        return uniqueSorted(permissions.map(\.workspace)) { lhs, rhs in
            lhs.slug.caseInsensitiveCompare(rhs.slug) == .orderedSame
        }
    }

    func fetchProjects(workspace: String, credentials: Credentials) async throws -> [BitbucketProject] {
        try await fetchAllPages(
            path: "workspaces/\(workspace)/projects",
            queryItems: [
                URLQueryItem(name: "pagelen", value: "100")
            ],
            credentials: credentials
        )
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func fetchRepositories(workspace: String, credentials: Credentials) async throws -> [BitbucketRepositorySummary] {
        try await fetchAllPages(
            path: "repositories/\(workspace)",
            queryItems: [
                URLQueryItem(name: "pagelen", value: "100"),
                URLQueryItem(name: "sort", value: "name")
            ],
            credentials: credentials
        )
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

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
            updatedRepo.statusMessage = BitbucketAPIError.invalidURL.localizedDescription
            return updatedRepo
        }

        do {
            let data = try await fetchAuthenticatedData(url: url, credentials: credentials)

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase // Bitbucket API uses snake_case
            let pipelineResponse = try decoder.decode(BitbucketPipelinesResponse.self, from: data)

            if let latestPipeline = pipelineResponse.values?.first {
                updatedRepo.status = mapPipelineToStatus(pipeline: latestPipeline)
                updatedRepo.branchName = latestPipeline.target?.refName
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

    private func fetchAllPages<Value: Codable>(
        path: String,
        queryItems: [URLQueryItem],
        credentials: Credentials
    ) async throws -> [Value] {
        var values: [Value] = []
        var nextURL: URL? = endpoint(path: path, queryItems: queryItems)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        while let url = nextURL {
            let data = try await fetchAuthenticatedData(url: url, credentials: credentials)
            let page = try decoder.decode(BitbucketPaginatedResponse<Value>.self, from: data)
            values.append(contentsOf: page.values ?? [])
            nextURL = page.next.flatMap(URL.init(string:))
        }

        return values
    }

    private func endpoint(path: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = baseURL.path + "/" + path
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        return components?.url
    }

    private func fetchAuthenticatedData(url: URL, credentials: Credentials) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let loginString = "\(credentials.email):\(credentials.apiToken)"
        guard let loginData = loginString.data(using: .utf8) else {
            throw BitbucketAPIError.missingCredentials
        }
        request.setValue("Basic \(loginData.base64EncodedString())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BitbucketAPIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw BitbucketAPIError.httpStatus(httpResponse.statusCode)
        }
        return data
    }

    private func uniqueSorted<T>(
        _ values: [T],
        matches: (T, T) -> Bool
    ) -> [T] where T: Hashable, T: Identifiable, T.ID == String {
        var uniqueValues: [T] = []
        for value in values where !uniqueValues.contains(where: { matches($0, value) }) {
            uniqueValues.append(value)
        }

        return uniqueValues.sorted { lhs, rhs in
            lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }
    }
}
