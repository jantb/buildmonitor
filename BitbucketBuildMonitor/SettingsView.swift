import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    @State private var email: String = ""
    @State private var apiTokenInput: String = ""

    @State private var browserWorkspaces: [BitbucketWorkspace] = []
    @State private var browserProjects: [BitbucketProject] = []
    @State private var browserRepositories: [BitbucketRepositorySummary] = []
    @State private var selectedWorkspaceSlug: String?
    @State private var selectedProjectKeys: Set<String> = []
    @State private var selectedRepositoryIDs: Set<String> = []
    @State private var repositorySearchText: String = ""
    @State private var isBrowserLoading = false
    @State private var browserLoadingMessage = ""
    @State private var browserError: String?
    @State private var hasLoadedBrowser = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    credentialsSection

                    Divider()

                    monitoredRepositoriesSection

                    if appState.isAuthenticated {
                        Divider()
                        repositoryBrowserSection
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 760, minHeight: 560)
        .onAppear {
            if let credentials = appState.credentials {
                email = credentials.email
            }

            if appState.isAuthenticated {
                Task { await loadBrowserIfNeeded() }
            }
        }
        .onChange(of: appState.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated {
                email = appState.credentials?.email ?? ""
                Task { await reloadBrowser() }
            } else {
                resetBrowser()
                email = ""
                apiTokenInput = ""
            }
        }
    }

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bitbucket Credentials")
                .font(.title2)
                .fontWeight(.semibold)

            if let errorMessage = appState.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if appState.isAuthenticated {
                HStack(spacing: 12) {
                    Text("Logged in as \(appState.credentials?.displayAccount ?? "Unknown")")
                        .foregroundColor(.secondary)

                    Spacer()

                    Button {
                        Task { await appState.refreshBuildStatuses() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(appState.isLoading || appState.monitoredRepos.isEmpty)

                    Button(role: .destructive) {
                        appState.clearCredentials()
                    } label: {
                        Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Enter your Atlassian account email and a scoped Bitbucket API token with workspace, project, repository, and pipeline read access.")
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("Atlassian Account Email", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress)

                    SecureField("Scoped API Token", text: $apiTokenInput)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        appState.saveCredentials(email: email, apiToken: apiTokenInput)
                    } label: {
                        Label("Save Credentials", systemImage: "key.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiTokenInput.isEmpty)
                }
                .frame(maxWidth: 520, alignment: .leading)
            }
        }
    }

    private var monitoredRepositoriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Monitored Repositories")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                StatusSummaryStrip(repos: appState.monitoredRepos)
            }

            if !appState.isAuthenticated {
                Text("Log in to manage repositories.")
                    .foregroundColor(.secondary)
            } else if appState.monitoredRepos.isEmpty {
                Text("No repositories added yet.")
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(appState.monitoredRepos) { repo in
                            monitoredRepositoryRow(repo)

                            if repo.id != appState.monitoredRepos.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 190)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25))
                }
            }
        }
    }

    private var repositoryBrowserSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Repositories")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Choose a workspace, filter by projects, then select repositories to monitor.")
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    Task { await reloadBrowser() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(isBrowserLoading)
            }

            if let browserError {
                Label(browserError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isBrowserLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(browserLoadingMessage)
                        .foregroundColor(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                browserColumn(title: "Workspaces", subtitle: "\(browserWorkspaces.count)", minWidth: 170) {
                    if browserWorkspaces.isEmpty && !isBrowserLoading {
                        emptyBrowserText("No workspaces found.")
                    } else {
                        ForEach(browserWorkspaces) { workspace in
                            workspaceRow(workspace)
                        }
                    }
                }

                browserColumn(title: "Projects", subtitle: projectColumnSubtitle, minWidth: 200) {
                    if selectedWorkspaceSlug == nil {
                        emptyBrowserText("Select a workspace.")
                    } else if browserProjects.isEmpty && !isBrowserLoading {
                        emptyBrowserText("No projects found.")
                    } else {
                        HStack(spacing: 8) {
                            Button("All") {
                                selectedProjectKeys = Set(browserProjects.map(\.key))
                                pruneRepositorySelectionForSelectedProjects()
                            }
                            .disabled(browserProjects.isEmpty)

                            Button("None") {
                                selectedProjectKeys.removeAll()
                            }
                            .disabled(selectedProjectKeys.isEmpty)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)

                        Divider()

                        ForEach(browserProjects) { project in
                            projectRow(project)
                        }
                    }
                }

                browserColumn(title: "Repositories", subtitle: repositoryColumnSubtitle, minWidth: 320) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Search repositories", text: $repositorySearchText)
                            .textFieldStyle(.roundedBorder)
                            .padding(.horizontal, 10)
                            .padding(.top, 10)

                        HStack(spacing: 8) {
                            Button("Select Visible") {
                                selectVisibleRepositories()
                            }
                            .disabled(visibleRepositories.filter { !isRepositoryMonitored($0) }.isEmpty)

                            Button("Clear") {
                                selectedRepositoryIDs.removeAll()
                            }
                            .disabled(selectedRepositoryIDs.isEmpty)
                        }
                        .padding(.horizontal, 10)

                        Divider()

                        if selectedWorkspaceSlug == nil {
                            emptyBrowserText("Select a workspace.")
                        } else if visibleRepositories.isEmpty && !isBrowserLoading {
                            emptyBrowserText("No repositories match the current filters.")
                        } else {
                            ForEach(visibleRepositories) { repository in
                                repositoryRow(repository)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 320)

            HStack {
                Text("\(selectedRepositories.count) selected")
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    addSelectedRepositories()
                } label: {
                    Label("Add Selected", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedRepositories.isEmpty)
            }
        }
    }

    private var projectColumnSubtitle: String {
        selectedProjectKeys.isEmpty ? "\(browserProjects.count)" : "\(selectedProjectKeys.count) of \(browserProjects.count)"
    }

    private var repositoryColumnSubtitle: String {
        "\(visibleRepositories.count) visible"
    }

    private var repositoriesMatchingProjectFilter: [BitbucketRepositorySummary] {
        guard !selectedProjectKeys.isEmpty else { return browserRepositories }
        return browserRepositories.filter { repository in
            guard let projectKey = repository.projectKey else { return false }
            return selectedProjectKeys.contains(projectKey)
        }
    }

    private var visibleRepositories: [BitbucketRepositorySummary] {
        let searchText = repositorySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchText.isEmpty else { return repositoriesMatchingProjectFilter }

        return repositoriesMatchingProjectFilter.filter { repository in
            repository.displayName.localizedCaseInsensitiveContains(searchText)
                || repository.slug.localizedCaseInsensitiveContains(searchText)
                || (repository.projectKey?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var selectedRepositories: [BitbucketRepositorySummary] {
        browserRepositories.filter { repository in
            selectedRepositoryIDs.contains(repository.id) && !isRepositoryMonitored(repository)
        }
    }

    private func monitoredRepositoryRow(_ repo: MonitoredRepository) -> some View {
        HStack(spacing: 10) {
            ZStack {
                if repo.status == .inProgress {
                    RunningStatusGlyph(size: 18, lineWidth: 2.5)
                } else {
                    Image(systemName: repo.status.symbolName)
                        .foregroundColor(repo.status.color)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(repo.workspace) / \(repo.repoSlug)")
                    .lineLimit(1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(repo.statusMessage ?? repo.status.label)
                        .lineLimit(1)

                    if let buildContextLabel = repo.buildContextLabel {
                        Label(buildContextLabel, systemImage: "arrow.branch")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                appState.removeRepository(repo: repo)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove repository")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(repo.status.color.opacity(0.04))
    }

    private func browserColumn<Content: View>(
        title: String,
        subtitle: String,
        minWidth: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: minWidth, maxWidth: .infinity, maxHeight: 360)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.25))
        }
    }

    private func workspaceRow(_ workspace: BitbucketWorkspace) -> some View {
        Button {
            Task { await selectWorkspace(workspace.slug) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selectedWorkspaceSlug == workspace.slug ? "folder.fill" : "folder")
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.displayName)
                        .lineLimit(1)
                    Text(workspace.slug)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(selectionBackground(selectedWorkspaceSlug == workspace.slug))
        }
        .buttonStyle(.plain)
        .disabled(isBrowserLoading)
    }

    private func projectRow(_ project: BitbucketProject) -> some View {
        Toggle(isOn: Binding(
            get: { selectedProjectKeys.contains(project.key) },
            set: { isSelected in
                if isSelected {
                    selectedProjectKeys.insert(project.key)
                } else {
                    selectedProjectKeys.remove(project.key)
                }
                pruneRepositorySelectionForSelectedProjects()
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.displayName)
                    .lineLimit(1)
                Text(project.key)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func repositoryRow(_ repository: BitbucketRepositorySummary) -> some View {
        let isMonitored = isRepositoryMonitored(repository)

        return Toggle(isOn: Binding(
            get: { selectedRepositoryIDs.contains(repository.id) },
            set: { isSelected in
                if isSelected {
                    selectedRepositoryIDs.insert(repository.id)
                } else {
                    selectedRepositoryIDs.remove(repository.id)
                }
            }
        )) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(repository.displayName)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(repository.slug)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        if let projectKey = repository.projectKey {
                            Text(projectKey)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                if isMonitored {
                    Text("Monitored")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(isMonitored)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func emptyBrowserText(_ message: String) -> some View {
        Text(message)
            .foregroundColor(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectionBackground(_ isSelected: Bool) -> some View {
        Rectangle()
            .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
    }

    private func loadBrowserIfNeeded() async {
        guard !hasLoadedBrowser else { return }
        await reloadBrowser()
    }

    private func reloadBrowser() async {
        guard appState.isAuthenticated, !isBrowserLoading else { return }

        hasLoadedBrowser = true
        isBrowserLoading = true
        browserLoadingMessage = "Loading workspaces..."
        browserError = nil

        do {
            let workspaces = try await appState.loadAvailableWorkspaces()
            browserWorkspaces = workspaces

            let preferredWorkspace = selectedWorkspaceSlug.flatMap { current in
                workspaces.first(where: { $0.slug.caseInsensitiveCompare(current) == .orderedSame })?.slug
            } ?? workspaces.first?.slug

            selectedWorkspaceSlug = preferredWorkspace
            selectedProjectKeys.removeAll()
            selectedRepositoryIDs.removeAll()
            repositorySearchText = ""

            if let preferredWorkspace {
                try await loadCatalog(for: preferredWorkspace)
            } else {
                browserProjects = []
                browserRepositories = []
            }
        } catch {
            browserError = "\(error.localizedDescription) Make sure the API token can read workspaces, projects, and repositories."
            browserProjects = []
            browserRepositories = []
        }

        isBrowserLoading = false
        browserLoadingMessage = ""
    }

    private func selectWorkspace(_ workspaceSlug: String) async {
        guard selectedWorkspaceSlug != workspaceSlug, !isBrowserLoading else { return }

        selectedWorkspaceSlug = workspaceSlug
        selectedProjectKeys.removeAll()
        selectedRepositoryIDs.removeAll()
        repositorySearchText = ""
        isBrowserLoading = true
        browserError = nil

        do {
            try await loadCatalog(for: workspaceSlug)
        } catch {
            browserError = "\(error.localizedDescription) Make sure the API token can read projects and repositories in this workspace."
            browserProjects = []
            browserRepositories = []
        }

        isBrowserLoading = false
        browserLoadingMessage = ""
    }

    private func loadCatalog(for workspaceSlug: String) async throws {
        browserLoadingMessage = "Loading projects..."
        let projects = try await appState.loadProjects(workspace: workspaceSlug)

        browserLoadingMessage = "Loading repositories..."
        let repositories = try await appState.loadRepositories(workspace: workspaceSlug)

        browserProjects = projects
        browserRepositories = repositories
    }

    private func resetBrowser() {
        browserWorkspaces = []
        browserProjects = []
        browserRepositories = []
        selectedWorkspaceSlug = nil
        selectedProjectKeys.removeAll()
        selectedRepositoryIDs.removeAll()
        repositorySearchText = ""
        browserError = nil
        hasLoadedBrowser = false
        isBrowserLoading = false
        browserLoadingMessage = ""
    }

    private func pruneRepositorySelectionForSelectedProjects() {
        let allowedIDs = Set(repositoriesMatchingProjectFilter.map(\.id))
        selectedRepositoryIDs = selectedRepositoryIDs.intersection(allowedIDs)
    }

    private func selectVisibleRepositories() {
        for repository in visibleRepositories where !isRepositoryMonitored(repository) {
            selectedRepositoryIDs.insert(repository.id)
        }
    }

    private func addSelectedRepositories() {
        guard let selectedWorkspaceSlug else { return }

        let repositories = selectedRepositories.map { repository in
            (workspace: selectedWorkspaceSlug, repoSlug: repository.slug)
        }
        appState.addRepositories(repositories)
        selectedRepositoryIDs.removeAll()
    }

    private func isRepositoryMonitored(_ repository: BitbucketRepositorySummary) -> Bool {
        guard let selectedWorkspaceSlug else { return false }
        let composite = "\(selectedWorkspaceSlug)/\(repository.slug)"
        return appState.monitoredRepos.contains { repo in
            repo.compositeSlug.caseInsensitiveCompare(composite) == .orderedSame
        }
    }
}
