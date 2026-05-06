import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss // To close the window

    // Local state for text fields
    @State private var username: String = ""
    @State private var appPasswordInput: String = "" // Use SecureField internally

    // State for adding new repo
    @State private var newRepoWorkspace: String = ""
    @State private var newRepoSlug: String = ""
    @State private var newRepoFullName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Bitbucket Credentials")
                .font(.title2)

            if let errorMessage = appState.errorMessage {
                 Text(errorMessage)
                     .foregroundColor(.red)
                     .fixedSize(horizontal: false, vertical: true) // Allow wrapping
            }

            if appState.isAuthenticated {
                Text("Logged in as: \(appState.credentials?.username ?? "Unknown")")
                HStack {
                    Button("Refresh Now") {
                        Task {
                            await appState.refreshBuildStatuses()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(appState.isLoading || appState.monitoredRepos.isEmpty)

                    Button("Log Out and Clear Credentials") {
                        appState.clearCredentials()
                        // Clear local fields too
                        username = ""
                        appPasswordInput = ""
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }

            } else {
                 Text("Enter your Bitbucket username and an App Password.")
                 Text("Create App Passwords at: https://bitbucket.org/account/settings/app-passwords/")
                     .font(.caption)
                     .foregroundColor(.secondary)

                 TextField("Bitbucket Username", text: $username)
                     .textFieldStyle(RoundedBorderTextFieldStyle())

                 SecureField("App Password", text: $appPasswordInput)
                     .textFieldStyle(RoundedBorderTextFieldStyle())

                 Button("Save Credentials and Login") {
                     appState.saveCredentials(username: username, appPassword: appPasswordInput)
                     // Don't clear fields immediately in case of error
                 }
                 .buttonStyle(.borderedProminent)
                 .disabled(username.isEmpty || appPasswordInput.isEmpty)
            }


            Divider()

            Text("Monitored Repositories")
                .font(.title2)

             if !appState.isAuthenticated {
                  Text("Log in to manage repositories.")
                      .foregroundColor(.secondary)
             } else if appState.monitoredRepos.isEmpty {
                 Text("No repositories added yet.")
                 .foregroundColor(.secondary)
             } else {
                 List {
                     ForEach(appState.monitoredRepos) { repo in
                         HStack {
                             Image(systemName: repo.status.symbolName)
                                 .foregroundColor(repo.status.color)
                                 .frame(width: 18)
                             VStack(alignment: .leading) {
                                 Text("\(repo.workspace) / \(repo.repoSlug)")
                                 if let statusMessage = repo.statusMessage {
                                     Text(statusMessage)
                                         .font(.caption)
                                         .foregroundColor(.secondary)
                                         .lineLimit(1)
                                 } else {
                                     Text(repo.status.label)
                                         .font(.caption)
                                         .foregroundColor(.secondary)
                                 }
                             }
                             Spacer()
                             Button {
                                 appState.removeRepository(repo: repo)
                             } label: {
                                 Image(systemName: "trash")
                                     .foregroundColor(.red)
                             }
                             .buttonStyle(.plain) // Remove button border
                         }
                     }
                     .onDelete { indexSet in
                         let repos = indexSet.map { appState.monitoredRepos[$0] }
                         repos.forEach(appState.removeRepository)
                     }
                 }
                 .frame(minHeight: 100, maxHeight: 300) // Constrain list size
             }

             if appState.isAuthenticated {
                GroupBox("Add New Repository") {
                     VStack(alignment: .leading, spacing: 10) {
                         TextField("workspace/repository-slug", text: $newRepoFullName)
                             .textFieldStyle(RoundedBorderTextFieldStyle())
                             .onSubmit(addRepositoryFromFields)

                         HStack {
                            TextField("Workspace", text: $newRepoWorkspace)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            Text("/")
                            TextField("Repository Slug", text: $newRepoSlug)
                                 .textFieldStyle(RoundedBorderTextFieldStyle())

                             Button("Add") {
                                 addRepositoryFromFields()
                             }
                             .disabled(!canAddRepository)
                             .buttonStyle(.bordered)
                         }
                     }
                 }
             }


            Spacer() // Push content to top

            HStack {
                 Spacer()
                 Button("Close") {
                      dismiss() // Close the settings window
                 }
                 .keyboardShortcut(.cancelAction) // Esc key
            }

        }
        .padding()
        .frame(minWidth: 450, minHeight: 450) // Set a suitable size for the settings window
        .onAppear {
             // Pre-fill fields if logged in (username only)
             if let creds = appState.credentials {
                 username = creds.username
                 // Don't pre-fill password field
             }
        }
    }

    private var canAddRepository: Bool {
        let fullName = newRepoFullName.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = newRepoWorkspace.trimmingCharacters(in: .whitespacesAndNewlines)
        let repoSlug = newRepoSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        return fullName.contains("/") || (!workspace.isEmpty && !repoSlug.isEmpty)
    }

    private func addRepositoryFromFields() {
        let fullName = newRepoFullName.trimmingCharacters(in: .whitespacesAndNewlines)

        if !fullName.isEmpty {
            let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                appState.errorMessage = "Use workspace/repository-slug."
                return
            }

            appState.addRepository(workspace: parts[0], repoSlug: parts[1])
        } else {
            appState.addRepository(workspace: newRepoWorkspace, repoSlug: newRepoSlug)
        }

        newRepoFullName = ""
        newRepoWorkspace = ""
        newRepoSlug = ""
    }
}
