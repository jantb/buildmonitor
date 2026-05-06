import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let appState = AppState()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var activityTimer: Timer?
    private var activityPhase = 0
    private let statusBarIconSize = NSSize(width: 14, height: 14)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePopover()
        observeAppState()
        updateStatusItem()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        button.target = self
        button.action = #selector(togglePopover)
        button.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 420, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContentView(
                openSettings: { [weak self] in self?.openSettingsWindow() },
                quit: { NSApplication.shared.terminate(nil) }
            )
            .environmentObject(appState)
        )
    }

    private func observeAppState() {
        appState.$monitoredRepos
            .combineLatest(appState.$isLoading)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.updateStatusItem()
            }
            .store(in: &cancellables)

        appState.$lastRefreshDate
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItem()
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let repos = appState.monitoredRepos

        button.image = nil
        button.attributedTitle = statusBarAttributedTitle(for: repos)
        button.contentTintColor = nil
        button.toolTip = statusSummaryText(repos: repos)

        updateActivityTimer()
    }

    private func statusBarAttributedTitle(for repos: [MonitoredRepository]) -> NSAttributedString {
        let title = NSMutableAttributedString()

        let counts = statusCounts(from: repos)
        let visibleStatuses = repos.isEmpty
            ? [BuildStatus.unknown]
            : statusPriority.filter { (counts[$0] ?? 0) > 0 }

        for (index, status) in visibleStatuses.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(string: "  "))
            }

            title.append(statusBarIcon(for: status))
            title.append(NSAttributedString(
                string: " \(counts[status] ?? 0)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
                    .foregroundColor: NSColor.labelColor
                ]
            ))
        }

        return title
    }

    private func statusBarIcon(for status: BuildStatus) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = statusBarSymbolImage(for: status)
        attachment.bounds = CGRect(
            x: 0,
            y: -2,
            width: statusBarIconSize.width,
            height: statusBarIconSize.height
        )
        return NSAttributedString(attachment: attachment)
    }

    private func statusBarSymbolImage(for status: BuildStatus) -> NSImage? {
        let symbolName = status == .inProgress ? "arrow.triangle.2.circlepath" : status.symbolName
        let rotation = status == .inProgress ? CGFloat((activityPhase % 8) * 45) : 0
        let configuration = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .semibold)

        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: status.label)?
            .withSymbolConfiguration(configuration) else {
            return nil
        }

        let image = NSImage(size: statusBarIconSize)
        image.lockFocus()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high

        let rect = CGRect(origin: .zero, size: statusBarIconSize)
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX, yBy: rect.midY)
        transform.rotate(byDegrees: rotation)
        transform.translateX(by: -rect.midX, yBy: -rect.midY)
        transform.concat()

        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        status.statusBarColor.set()
        rect.fill(using: .sourceAtop)

        NSGraphicsContext.restoreGraphicsState()
        image.unlockFocus()
        image.isTemplate = false

        return image
    }

    private func updateActivityTimer() {
        let isActive = appState.isLoading || appState.monitoredRepos.contains(where: { $0.status == .inProgress })

        if isActive, activityTimer == nil {
            activityTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.activityPhase += 1
                    self?.updateStatusItem()
                }
            }
        } else if !isActive {
            activityTimer?.invalidate()
            activityTimer = nil
            activityPhase = 0
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func openSettingsWindow() {
        popover.performClose(nil)

        if settingsWindow == nil {
            let hostingController = NSHostingController(
                rootView: SettingsView()
                    .environmentObject(appState)
            )
            let window = NSWindow(contentViewController: hostingController)
            window.title = "BuildMonitor Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 820, height: 640))
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private extension BuildStatus {
    var statusBarColor: NSColor {
        switch self {
        case .unknown: return .systemGray
        case .success: return .systemGreen
        case .failed: return .systemRed
        case .inProgress: return .systemYellow
        case .stopped: return .systemOrange
        }
    }
}
