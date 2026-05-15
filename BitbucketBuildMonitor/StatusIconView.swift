import SwiftUI

struct StatusIconView: View {
    let repos: [MonitoredRepository]

    private var visibleStatuses: [BuildStatus] {
        let statuses = statusCounts(from: repos)
            .filter { $0.value > 0 }
            .map(\.key)

        if statuses.isEmpty {
            return [.unknown]
        }

        return statusPriority.filter(statuses.contains)
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(visibleStatuses, id: \.self) { status in
                if status == .inProgress {
                    RunningStatusGlyph(size: 13, lineWidth: 2)
                } else {
                    Circle()
                        .fill(status.color)
                        .frame(width: 9, height: 9)
                        .overlay {
                            Circle()
                                .stroke(.primary.opacity(0.18), lineWidth: 0.5)
                        }
                }
            }
        }
        .padding(.horizontal, 4)
        .help(statusSummaryText(repos: repos))
    }
}

struct RunningStatusGlyph: View {
    let size: CGFloat
    let lineWidth: CGFloat

    @State private var rotation = 0.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(BuildStatus.inProgress.color.opacity(0.18), lineWidth: lineWidth)

            Circle()
                .trim(from: 0.08, to: 0.78)
                .stroke(
                    BuildStatus.inProgress.color,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(rotation))
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

struct PipelineStatusPill: View {
    let status: BuildStatus
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            if status == .inProgress {
                RunningStatusGlyph(size: 12, lineWidth: 2)
            } else {
                Image(systemName: status.symbolName)
                    .foregroundColor(status.color)
                    .imageScale(.small)
            }

            Text("\(count)")
                .font(.caption)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(status.color.opacity(0.12), in: Capsule())
        .overlay {
            Capsule()
                .stroke(status.color.opacity(0.28), lineWidth: 1)
        }
        .help(status.label)
    }
}

struct BranchBuildStatusStrip: View {
    let branchStatuses: [BranchBuildStatus]
    var openPipeline: (String) -> Void = { _ in }

    private var statuses: [BranchBuildStatus] {
        KeyBuildBranch.all.map { branch in
            branchStatuses.first(where: { $0.branch == branch }) ?? BranchBuildStatus(branch: branch)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(statuses) { branchStatus in
                BranchBuildStatusBadge(branchStatus: branchStatus) {
                    if let pipelineUrl = branchStatus.pipelineUrl {
                        openPipeline(pipelineUrl)
                    }
                }
            }
        }
    }
}

private struct BranchBuildStatusBadge: View {
    let branchStatus: BranchBuildStatus
    let openPipeline: () -> Void

    var body: some View {
        Button(action: openPipeline) {
            HStack(spacing: 3) {
                branchGlyph

                statusGlyph
            }
            .frame(width: 34, height: 18)
            .background(branchStatus.status.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(branchStatus.status.color.opacity(0.32), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(branchStatus.pipelineUrl == nil)
        .help(helpText)
    }

    private var branchGlyph: some View {
        Text(branchStatus.branch.shortLabel)
            .font(.caption2)
            .fontWeight(.bold)
            .monospaced()
            .foregroundColor(.primary.opacity(0.82))
    }

    @ViewBuilder
    private var statusGlyph: some View {
        if branchStatus.status == .inProgress {
            RunningStatusGlyph(size: 9, lineWidth: 1.6)
        } else {
            Image(systemName: branchStatus.status.symbolName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(branchStatus.status.color)
        }
    }

    private var helpText: String {
        var components = ["\(branchStatus.contextLabel): \(branchStatus.status.label)"]

        if let statusMessage = branchStatus.statusMessage {
            components.append(statusMessage)
        } else if branchStatus.pipelineUrl != nil {
            components.append("Open selected build")
        }

        return components.joined(separator: "\n")
    }
}

struct StatusSummaryStrip: View {
    let repos: [MonitoredRepository]

    var body: some View {
        let counts = statusCounts(from: repos)

        HStack(spacing: 8) {
            ForEach(statusPriority, id: \.self) { status in
                if let count = counts[status], count > 0 {
                    PipelineStatusPill(status: status, count: count)
                }
            }

            if repos.isEmpty {
                PipelineStatusPill(status: .unknown, count: 0)
            }
        }
    }
}

extension BuildStatus {
    var symbolName: String { rawValue }
}

let statusPriority: [BuildStatus] = [.failed, .inProgress, .stopped, .unknown, .success]

func statusCounts(from repos: [MonitoredRepository]) -> [BuildStatus: Int] {
    Dictionary(grouping: repos.flatMap(\.statusItems), by: { $0 })
        .mapValues(\.count)
}

func statusSummaryText(repos: [MonitoredRepository]) -> String {
    guard !repos.isEmpty else { return "No repositories monitored" }

    let counts = statusCounts(from: repos)
    return statusPriority.compactMap { status in
        guard let count = counts[status], count > 0 else { return nil }
        return "\(count) \(status.label.lowercased())"
    }
    .joined(separator: ", ")
}

func aggregateStatus(repos: [MonitoredRepository]) -> BuildStatus {
    if repos.isEmpty { return .unknown }
    let statuses = repos.flatMap(\.statusItems)
    if statuses.contains(.failed) { return .failed }
    if statuses.contains(.inProgress) { return .inProgress }
    if statuses.contains(.stopped) { return .stopped } // Show stopped before success
    if statuses.allSatisfy({ $0 == .success }) { return .success } // Only show success if ALL are success
    // Check if all non-success are unknown (initial state)
    if statuses.allSatisfy({ $0 == .success || $0 == .unknown }) && statuses.contains(.success) {
         return .success // Show success if some are success and others are just unknown
    }
    return .unknown // Default if mix of unknown/stopped/success or only unknown
}
