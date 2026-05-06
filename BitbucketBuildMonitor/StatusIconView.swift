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
    Dictionary(grouping: repos, by: \.status)
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
    if repos.contains(where: { $0.status == .failed }) { return .failed }
    if repos.contains(where: { $0.status == .inProgress }) { return .inProgress }
    if repos.contains(where: { $0.status == .stopped }) { return .stopped } // Show stopped before success
    if repos.allSatisfy({ $0.status == .success }) { return .success } // Only show success if ALL are success
    // Check if all non-success are unknown (initial state)
    if repos.allSatisfy({ $0.status == .success || $0.status == .unknown }) && repos.contains(where: {$0.status == .success }) {
         return .success // Show success if some are success and others are just unknown
    }
    return .unknown // Default if mix of unknown/stopped/success or only unknown
}
