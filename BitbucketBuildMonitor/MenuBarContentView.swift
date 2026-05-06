import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject var appState: AppState
    let openSettings: () -> Void
    let quit: () -> Void

    init(openSettings: @escaping () -> Void = {}, quit: @escaping () -> Void = {}) {
        self.openSettings = openSettings
        self.quit = quit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.isAuthenticated {
                menuHeader
                StatusSummaryStrip(repos: appState.monitoredRepos)
                    .padding(.horizontal)
                    .padding(.bottom, 10)

                if appState.isLoading && appState.monitoredRepos.isEmpty {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 4)
                        Text("Loading...")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else if appState.monitoredRepos.isEmpty {
                     Text("No repositories monitored.\nAdd some in Settings.")
                         .foregroundColor(.secondary)
                         .multilineTextAlignment(.center)
                         .padding()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(appState.monitoredRepos) { repo in
                                RepositoryRow(repo: repo)
                                if repo.id != appState.monitoredRepos.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                }

                if let errorMessage = appState.errorMessage {
                    Divider()
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }

                Divider()

            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bitbucket Build Monitor")
                        .font(.headline)
                    Text("Log in from Settings to start monitoring pipeline status.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
            }

            footer
        }
        .padding(.vertical, 10)
        .frame(width: 420)
    }

    private var menuHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                StatusIconView(repos: appState.monitoredRepos)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Bitbucket Builds")
                        .font(.headline)
                    Text(statusSummaryText(repos: appState.monitoredRepos))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if appState.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if let lastRefreshDate = appState.lastRefreshDate {
                Text("Updated \(lastRefreshDate, style: .relative) ago")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    await appState.refreshBuildStatuses()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(appState.isLoading)
            .help("Refresh pipeline statuses")

            if appState.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Settings")

            Button {
                quit()
            } label: {
                Label("Quit", systemImage: "power")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Quit BuildMonitor")
        }
        .padding(.horizontal)
        .padding(.top, 10)
    }
}

// Row view for displaying a single repository in the menu list
struct RepositoryRow: View {
     let repo: MonitoredRepository
     @Environment(\.openURL) var openURL

     var body: some View {
         HStack {
             ZStack {
                 if repo.status == .inProgress {
                     RunningStatusGlyph(size: 22, lineWidth: 3)
                 } else {
                     Image(systemName: repo.status.symbolName)
                         .foregroundColor(repo.status.color)
                         .font(.title3)
                 }
             }
             .frame(width: 25)

             VStack(alignment: .leading, spacing: 2) {
                 HStack(spacing: 6) {
                     Text(repo.repoSlug) // Show only slug for brevity
                         .font(.headline)
                         .lineLimit(1)

                     Text(repo.status.label)
                         .font(.caption2)
                         .foregroundColor(repo.status.color)
                         .padding(.horizontal, 6)
                         .padding(.vertical, 2)
                         .background(repo.status.color.opacity(0.12), in: Capsule())
                         .overlay {
                             Capsule()
                                 .stroke(repo.status.color.opacity(0.25), lineWidth: 1)
                         }
                 }

                 Text(repo.workspace)
                     .font(.caption)
                     .foregroundColor(.secondary)
                     .lineLimit(1)

                 if let statusMessage = repo.statusMessage {
                     Text(statusMessage)
                         .font(.caption2)
                         .foregroundColor(.secondary)
                         .lineLimit(2)
                 } else if let date = repo.lastBuildDate {
                     Text("Build \(date, style: .relative) ago")
                         .font(.caption2)
                         .foregroundColor(.secondary)
                 } else if let date = repo.lastCheckedDate {
                     Text("Checked \(date, style: .relative) ago")
                         .font(.caption2)
                         .foregroundColor(.secondary)
                 }

             }

             Spacer() // Push everything left

             HStack(spacing: 8) {
                 if let urlString = repo.pipelineUrl, let url = URL(string: urlString) {
                     Button {
                         openURL(url)
                     } label: {
                         Image(systemName: "arrow.up.right.square")
                     }
                     .buttonStyle(.plain)
                     .help("Open last pipeline run")
                 }

                 Button {
                     if let url = URL(string: "https://bitbucket.org/\(repo.workspace)/\(repo.repoSlug)") {
                         openURL(url)
                     }
                 } label: {
                     Image(systemName: "folder")
                 }
                 .buttonStyle(.plain)
                 .help("Open repository")
             }
             .foregroundColor(.secondary)
         }
         .padding(.horizontal)
         .padding(.vertical, 8)
         .background(repo.status.color.opacity(0.05))
     }
}
