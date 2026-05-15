import AppKit
import SwiftUI

struct PreservingScrollView<Content: View>: NSViewRepresentable {
    private let showsIndicators: Bool
    private let content: Content

    init(showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {
        self.showsIndicators = showsIndicators
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = showsIndicators
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hostingView

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hostingView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let previousOrigin = scrollView.contentView.bounds.origin

        if let hostingView = scrollView.documentView as? NSHostingView<Content> {
            hostingView.rootView = content
        }

        DispatchQueue.main.async {
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let visibleHeight = scrollView.contentView.bounds.height
            let maxY = max(0, documentHeight - visibleHeight)
            let restoredOrigin = NSPoint(
                x: 0,
                y: min(max(previousOrigin.y, 0), maxY)
            )

            scrollView.contentView.scroll(to: restoredOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}
