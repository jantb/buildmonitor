import SwiftUI
import Combine

@MainActor // Ensure changes are published on the main thread
class AppState: ObservableObject {
    @Published var credentials: Credentials?
    @Published var monitoredRepos: [MonitoredRepository] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    @Published var isAuthenticated: Bool = false
    @Published var lastRefreshDate: Date? = nil

    private let keychainService = KeychainService.shared
    private let bitbucketService = BitbucketService()
    private var refreshTimer: Timer?
    private let monitoredReposKey = "monitoredRepositorySlugs"

    init() {
        loadCredentialsFromKeychain()
        loadMonitoredReposFromUserDefaults()
        if isAuthenticated {
            scheduleRefreshTimer()
            Task { // Perform initial refresh
                await refreshBuildStatuses()
            }
        }
    }

    // MARK: - Credential Management
    func loadCredentialsFromKeychain() {
        do {
            self.credentials = try keychainService.loadCredentials()
            self.isAuthenticated = true
            self.errorMessage = nil
            print("AppState: Credentials loaded.")
        } catch KeychainError.itemNotFound {
            self.credentials = nil
            self.isAuthenticated = false
            print("AppState: No credentials found in Keychain.")
            // Don't set an error message here, it's normal on first launch
        } catch {
            self.credentials = nil
            self.isAuthenticated = false
            self.errorMessage = "Failed to load credentials: \(error.localizedDescription)"
            print("AppState: Error loading credentials: \(error)")
        }
    }

    func saveCredentials(email: String, apiToken: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedEmail.isEmpty, !trimmedToken.isEmpty else {
            errorMessage = "Email and API token are required."
            return
        }

        let newCredentials = Credentials(email: trimmedEmail, apiToken: trimmedToken)
        do {
            try keychainService.saveCredentials(newCredentials)
            self.credentials = newCredentials
            self.isAuthenticated = true
            self.errorMessage = nil
             print("AppState: Credentials saved.")
            // Optionally trigger repo fetch or initial status check here
            scheduleRefreshTimer() // Start timer now that we are authenticated
            Task {
                 await refreshBuildStatuses() // Refresh immediately after saving
            }
        } catch {
            self.isAuthenticated = false
            self.errorMessage = "Failed to save credentials: \(error.localizedDescription)"
             print("AppState: Error saving credentials: \(error)")
        }
    }

    func clearCredentials() {
        do {
            try keychainService.deleteCredentials()
            self.credentials = nil
            self.isAuthenticated = false
            self.monitoredRepos = [] // Clear repos when logging out
            saveMonitoredReposToUserDefaults() // Persist empty list
            stopRefreshTimer()
            self.errorMessage = nil
            print("AppState: Credentials cleared.")
        } catch {
            self.errorMessage = "Failed to clear credentials: \(error.localizedDescription)"
            print("AppState: Error clearing credentials: \(error)")
        }
    }

    // MARK: - Repository Management
    func addRepository(workspace: String, repoSlug: String) {
        let workspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        let repoSlug = repoSlug.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !workspace.isEmpty, !repoSlug.isEmpty else {
            errorMessage = "Workspace and repository slug are required."
            return
        }

        let composite = "\(workspace)/\(repoSlug)"
        guard !monitoredRepos.contains(where: { $0.compositeSlug.caseInsensitiveCompare(composite) == .orderedSame }) else {
            errorMessage = "\(composite) is already monitored."
            return
        }

        let newRepo = MonitoredRepository(workspace: workspace, repoSlug: repoSlug)
        monitoredRepos.append(newRepo)
        saveMonitoredReposToUserDefaults()
        // Fetch status for the newly added repo immediately
        Task {
            await refreshSingleRepository(repo: newRepo)
        }
         print("AppState: Added repository \(composite).")
    }

    func removeRepository(repo: MonitoredRepository) {
        monitoredRepos.removeAll { $0.id == repo.id }
        saveMonitoredReposToUserDefaults()
        print("AppState: Removed repository \(repo.compositeSlug).")
    }

    func addRepositories(_ repositories: [(workspace: String, repoSlug: String)]) {
        var addedCount = 0
        var duplicateCount = 0

        for repository in repositories {
            let workspace = repository.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
            let repoSlug = repository.repoSlug.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !workspace.isEmpty, !repoSlug.isEmpty else { continue }

            let composite = "\(workspace)/\(repoSlug)"
            if monitoredRepos.contains(where: { $0.compositeSlug.caseInsensitiveCompare(composite) == .orderedSame }) {
                duplicateCount += 1
                continue
            }

            monitoredRepos.append(MonitoredRepository(workspace: workspace, repoSlug: repoSlug))
            addedCount += 1
        }

        guard addedCount > 0 else {
            if duplicateCount > 0 {
                errorMessage = "Selected repositories are already monitored."
            }
            return
        }

        saveMonitoredReposToUserDefaults()
        errorMessage = duplicateCount > 0 ? "Added \(addedCount) repositories. Skipped \(duplicateCount) already monitored." : nil
        Task {
            await refreshBuildStatuses()
        }
        print("AppState: Added \(addedCount) repositories from catalog.")
    }

    func loadAvailableWorkspaces() async throws -> [BitbucketWorkspace] {
        guard let credentials else { throw BitbucketAPIError.missingCredentials }
        return try await bitbucketService.fetchAccessibleWorkspaces(credentials: credentials)
    }

    func loadProjects(workspace: String) async throws -> [BitbucketProject] {
        guard let credentials else { throw BitbucketAPIError.missingCredentials }
        return try await bitbucketService.fetchProjects(workspace: workspace, credentials: credentials)
    }

    func loadRepositories(workspace: String) async throws -> [BitbucketRepositorySummary] {
        guard let credentials else { throw BitbucketAPIError.missingCredentials }
        return try await bitbucketService.fetchRepositories(workspace: workspace, credentials: credentials)
    }

    private func loadMonitoredReposFromUserDefaults() {
        let defaults = UserDefaults.standard
        guard let slugs = defaults.stringArray(forKey: monitoredReposKey) else {
            self.monitoredRepos = []
            return
        }
        self.monitoredRepos = slugs.compactMap { slug in
            let parts = slug.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return MonitoredRepository(workspace: parts[0], repoSlug: parts[1])
        }
         print("AppState: Loaded \(self.monitoredRepos.count) monitored repos from UserDefaults.")
    }

    private func saveMonitoredReposToUserDefaults() {
        let defaults = UserDefaults.standard
        let slugs = monitoredRepos.map { $0.compositeSlug }
        defaults.set(slugs, forKey: monitoredReposKey)
        print("AppState: Saved \(slugs.count) monitored repos to UserDefaults.")
    }


    // MARK: - Status Refreshing

    func refreshBuildStatuses() async {
        guard isAuthenticated, let currentCredentials = credentials, !monitoredRepos.isEmpty else {
            print("AppState: Cannot refresh - not authenticated or no repos to monitor.")
            if !isLoading { // Only stop loading if we aren't already loading something else
                 isLoading = false
            }
            return
        }
        guard !isLoading else {
             print("AppState: Refresh already in progress.")
             return // Prevent concurrent refreshes
        }

        print("AppState: Starting build status refresh...")
        isLoading = true
        errorMessage = nil // Clear previous errors

        let reposToRefresh = monitoredRepos
        let bitbucketService = bitbucketService
        var updatedRepos: [MonitoredRepository] = []

        // Use a TaskGroup for concurrent fetching
        await withTaskGroup(of: MonitoredRepository.self) { group in
            for repo in reposToRefresh {
                group.addTask {
                    await bitbucketService.fetchLatestBuildStatus(
                        workspace: repo.workspace,
                        repoSlug: repo.repoSlug,
                        credentials: currentCredentials
                    )
                }
            }

            // Collect results from the group
            for await updatedRepo in group {
                updatedRepos.append(updatedRepo)
            }
        }

        // Update the main array on the main thread, preserving order if needed
        // A simple replacement for now, could be smarter merging state if required
        if !updatedRepos.isEmpty {
            var finalRepos: [MonitoredRepository] = []
            for originalRepo in self.monitoredRepos {
                if let updatedVersion = updatedRepos.first(where: { $0.id == originalRepo.id }) {
                    finalRepos.append(updatedVersion)
                } else {
                    finalRepos.append(originalRepo)
                }
            }
            self.monitoredRepos = finalRepos
            self.lastRefreshDate = Date()

            let failures = updatedRepos.compactMap(\.statusMessage)
            if failures.count == updatedRepos.count {
                self.errorMessage = failures.first
            }
            print("AppState: Finished build status refresh. Updated \(self.monitoredRepos.count) repos.")
        }

        isLoading = false
    }

    // Refresh status for a single newly added repo
    private func refreshSingleRepository(repo: MonitoredRepository) async {
         guard isAuthenticated, let currentCredentials = credentials else { return }
         print("AppState: Refreshing single repo: \(repo.compositeSlug)")
         isLoading = true // Indicate activity

        let updatedRepo = await bitbucketService.fetchLatestBuildStatus(
            workspace: repo.workspace,
            repoSlug: repo.repoSlug,
            credentials: currentCredentials
        )

        if let index = monitoredRepos.firstIndex(where: { $0.id == repo.id }) {
            monitoredRepos[index] = updatedRepo
            print("AppState: Updated single repo status: \(updatedRepo.status)")
        }

        if let statusMessage = updatedRepo.statusMessage {
            errorMessage = "\(updatedRepo.compositeSlug): \(statusMessage)"
        } else {
            errorMessage = nil
        }
        isLoading = false
    }


    // MARK: - Timer Management
    func scheduleRefreshTimer(interval: TimeInterval = 60.0) { // Default to 60 seconds
        stopRefreshTimer() // Ensure any existing timer is stopped
        guard isAuthenticated else { return } // Only run if logged in

        print("AppState: Scheduling refresh timer with interval \(interval)s.")
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
             print("AppState: Timer fired.")
            Task { [weak self] in // Run the async refresh task
                await self?.refreshBuildStatuses()
            }
        }
        // Fire immediately once for quick feedback after scheduling
        // RunLoop.current.add(refreshTimer!, forMode: .common) // Ensure it runs even during UI interactions
        // refreshTimer?.fire() // Firing immediately might clash with initial load, Task based refresh is better
    }

    func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        print("AppState: Refresh timer stopped.")
    }
}
