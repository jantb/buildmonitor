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

    // Fetches the latest pipeline status for a given repo's key branches.
    func fetchLatestBuildStatus(workspace: String, repoSlug: String, credentials: Credentials) async -> MonitoredRepository {
        var updatedRepo = MonitoredRepository(workspace: workspace, repoSlug: repoSlug)
        updatedRepo.lastCheckedDate = Date()

        let workspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        let repoSlug = repoSlug.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !workspace.isEmpty, !repoSlug.isEmpty else {
            updatedRepo.statusMessage = "Workspace or repository slug is empty."
            return updatedRepo
        }

        var branchStatuses: [BranchBuildStatus] = []

        await withTaskGroup(of: BranchBuildStatus.self) { group in
            for branch in KeyBuildBranch.all {
                group.addTask {
                    await self.fetchLatestBuildStatus(
                        workspace: workspace,
                        repoSlug: repoSlug,
                        branch: branch,
                        credentials: credentials
                    )
                }
            }

            for await branchStatus in group {
                branchStatuses.append(branchStatus)
            }
        }

        updatedRepo.branchStatuses = KeyBuildBranch.all.compactMap { branch in
            branchStatuses.first { $0.branch == branch }
        }
        updatedRepo.status = aggregateStatus(from: updatedRepo.branchStatuses.map(\.status))

        if let representativeStatus = representativeBranchStatus(from: updatedRepo.branchStatuses) {
            updatedRepo.branchName = representativeStatus.branchName
            updatedRepo.lastBuildDate = representativeStatus.lastBuildDate
            updatedRepo.pipelineUrl = representativeStatus.pipelineUrl
            updatedRepo.statusMessage = representativeStatus.statusMessage
            updatedRepo.pipelineProgress = representativeStatus.pipelineProgress
        }

        let branchErrors = updatedRepo.branchStatuses.compactMap { branchStatus -> String? in
            guard let statusMessage = branchStatus.statusMessage else { return nil }
            return "\(branchStatus.branchName): \(statusMessage)"
        }
        if branchErrors.count == updatedRepo.branchStatuses.count, !branchErrors.isEmpty {
            updatedRepo.statusMessage = branchErrors.joined(separator: "\n")
        }

        return updatedRepo
    }

    private func fetchLatestBuildStatus(
        workspace: String,
        repoSlug: String,
        branch: KeyBuildBranch,
        credentials: Credentials
    ) async -> BranchBuildStatus {
        var branchStatus = BranchBuildStatus(branch: branch)

        let latestPipeline: BitbucketPipeline?
        do {
            latestPipeline = try await fetchLatestPipeline(
                workspace: workspace,
                repoSlug: repoSlug,
                branchName: branch.name,
                credentials: credentials
            )
        } catch {
            branchStatus.statusMessage = "Refresh failed: \(error.localizedDescription)"
            return branchStatus
        }

        guard let latestPipeline else {
            branchStatus.statusMessage = "No pipelines found."
            return branchStatus
        }

        branchStatus.status = mapPipelineToStatus(pipeline: latestPipeline)
        branchStatus.lastBuildDate = pipelineDate(from: latestPipeline)
        branchStatus.pipelineUrl = pipelineHTMLURL(
            from: latestPipeline,
            workspace: workspace,
            repoSlug: repoSlug
        )

        if branchStatus.status == .inProgress, let pipelineUUID = latestPipeline.uuid {
            branchStatus.pipelineProgress = try? await fetchPipelineProgress(
                workspace: workspace,
                repoSlug: repoSlug,
                pipelineUUID: pipelineUUID,
                credentials: credentials
            )
        }

        return branchStatus
    }

    private func fetchLatestPipeline(
        workspace: String,
        repoSlug: String,
        branchName: String,
        credentials: Credentials
    ) async throws -> BitbucketPipeline? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("repositories/\(workspace)/\(repoSlug)/pipelines"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "q", value: "target.ref_name = \"\(branchName)\""),
            URLQueryItem(name: "sort", value: "-created_on"),
            URLQueryItem(name: "pagelen", value: "20")
        ]

        guard let url = components.url else {
            throw BitbucketAPIError.invalidURL
        }

        let data = try await fetchAuthenticatedData(url: url, credentials: credentials)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase // Bitbucket API uses snake_case
        let pipelineResponse = try decoder.decode(BitbucketPipelinesResponse.self, from: data)

        return pipelineResponse.values?.first { pipeline in
            pipelineMatchesBranch(pipeline, branchName: branchName)
        }
    }

    private func pipelineMatchesBranch(_ pipeline: BitbucketPipeline, branchName: String) -> Bool {
        guard let refName = pipeline.target?.refName else { return false }
        return refName == branchName
    }

    private func aggregateStatus(from statuses: [BuildStatus]) -> BuildStatus {
        guard !statuses.isEmpty else { return .unknown }
        if statuses.contains(.failed) { return .failed }
        if statuses.contains(.inProgress) { return .inProgress }
        if statuses.contains(.stopped) { return .stopped }
        if statuses.allSatisfy({ $0 == .success }) { return .success }
        if statuses.contains(.success), statuses.allSatisfy({ $0 == .success || $0 == .unknown }) {
            return .success
        }
        return .unknown
    }

    private func representativeBranchStatus(from branches: [BranchBuildStatus]) -> BranchBuildStatus? {
        for status in [BuildStatus.failed, .inProgress, .stopped, .unknown, .success] {
            if let branchStatus = branches.first(where: { $0.status == status }) {
                return branchStatus
            }
        }
        return branches.first
    }

    private func fetchPipelineProgress(
        workspace: String,
        repoSlug: String,
        pipelineUUID: String,
        credentials: Credentials
    ) async throws -> PipelineProgress? {
        let steps: [BitbucketPipelineStep] = try await fetchAllPages(
            path: "repositories/\(workspace)/\(repoSlug)/pipelines/\(pipelineUUID)/steps",
            queryItems: [
                URLQueryItem(name: "pagelen", value: "100")
            ],
            credentials: credentials
        )

        return pipelineProgress(from: steps)
    }

    private func pipelineProgress(from steps: [BitbucketPipelineStep], now: Date = Date()) -> PipelineProgress? {
        guard !steps.isEmpty else { return nil }

        let completedStepCount = steps.filter(isCompletedStep).count
        var completedUnits = Double(completedStepCount)

        if let runningStep = steps.first(where: isRunningStep) {
            completedUnits += estimatedProgressWithinRunningStep(
                runningStep,
                allSteps: steps,
                now: now
            )
        }

        let fraction = min(max(completedUnits / Double(steps.count), 0), 1)
        return PipelineProgress(
            completedStepCount: completedStepCount,
            totalStepCount: steps.count,
            fraction: fraction
        )
    }

    private func estimatedProgressWithinRunningStep(
        _ step: BitbucketPipelineStep,
        allSteps: [BitbucketPipelineStep],
        now: Date
    ) -> Double {
        guard
            let startedOn = iso8601Date(from: step.startedOn)
        else {
            return 0.5
        }

        let elapsedSeconds = max(0, now.timeIntervalSince(startedOn))
        let completedDurations = allSteps
            .compactMap(stepDuration)
            .filter { $0 > 0 }

        guard let expectedSeconds = median(completedDurations), expectedSeconds > 0 else {
            return 0.5
        }

        return min(max(elapsedSeconds / expectedSeconds, 0.05), 0.95)
    }

    private func stepDuration(_ step: BitbucketPipelineStep) -> TimeInterval? {
        guard
            let startedOn = iso8601Date(from: step.startedOn),
            let completedOn = iso8601Date(from: step.completedOn)
        else {
            return nil
        }

        return completedOn.timeIntervalSince(startedOn)
    }

    private func isCompletedStep(_ step: BitbucketPipelineStep) -> Bool {
        if step.completedOn != nil { return true }

        let values = stepStateValues(step)
        return values.contains(where: { value in
            value.contains("complete")
                || value.contains("successful")
                || value.contains("failed")
                || value.contains("error")
                || value.contains("stopped")
        })
    }

    private func isRunningStep(_ step: BitbucketPipelineStep) -> Bool {
        guard !isCompletedStep(step) else { return false }

        let values = stepStateValues(step)
        return values.contains(where: { value in
            value.contains("in_progress")
                || value.contains("pending")
                || value.contains("waiting")
                || value.contains("building")
                || value.contains("running")
        })
    }

    private func stepStateValues(_ step: BitbucketPipelineStep) -> [String] {
        normalizedValues(
            step.state?.name,
            step.state?.type,
            step.state?.result?.name,
            step.state?.result?.type
        )
    }

    private func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }

        let sortedValues = values.sorted()
        let middleIndex = sortedValues.count / 2

        if sortedValues.count.isMultiple(of: 2) {
            return (sortedValues[middleIndex - 1] + sortedValues[middleIndex]) / 2
        }

        return sortedValues[middleIndex]
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
        for dateString in [pipeline.completedOn, pipeline.updatedOn, pipeline.createdOn] {
            if let date = iso8601Date(from: dateString) {
                return date
            }
        }
        return nil
    }

    private func pipelineHTMLURL(from pipeline: BitbucketPipeline, workspace: String, repoSlug: String) -> String? {
        if let href = pipeline.links?.html?.href, !href.isEmpty {
            return href
        }

        if let buildNumber = pipeline.buildNumber {
            return "https://bitbucket.org/\(workspace)/\(repoSlug)/pipelines/results/\(buildNumber)"
        }

        return nil
    }

    private func iso8601Date(from dateString: String?) -> Date? {
        guard let dateString else { return nil }

        let dateFormatter = ISO8601DateFormatter()
        if let date = dateFormatter.date(from: dateString) {
            return date
        }

        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return dateFormatter.date(from: dateString)
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
