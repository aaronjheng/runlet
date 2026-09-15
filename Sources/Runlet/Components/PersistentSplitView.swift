import SwiftUI

struct PersistentSplitView<Left: View, Right: View>: NSViewControllerRepresentable {
    let autosaveName: String
    let left: Left
    let right: Right
    let leftMinWidth: CGFloat
    let rightMinWidth: CGFloat

    init(
        autosaveName: String = "app.runlet.keysSplit",
        leftMinWidth: CGFloat = 250,
        rightMinWidth: CGFloat = 250,
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) {
        self.autosaveName = autosaveName
        self.leftMinWidth = leftMinWidth
        self.rightMinWidth = rightMinWidth
        self.left = left()
        self.right = right()
    }

    func makeNSViewController(context: Context) -> SplitViewController {
        let controller = SplitViewController(autosaveName: autosaveName)

        let leftHost = NSHostingController(rootView: left)
        leftHost.sizingOptions = []
        let leftItem = NSSplitViewItem(viewController: leftHost)
        leftItem.minimumThickness = leftMinWidth
        leftItem.holdingPriority = .init(260)

        let rightHost = NSHostingController(rootView: right)
        rightHost.sizingOptions = []
        let rightItem = NSSplitViewItem(viewController: rightHost)
        rightItem.minimumThickness = rightMinWidth

        controller.addSplitViewItem(leftItem)
        controller.addSplitViewItem(rightItem)
        controller.splitView.dividerStyle = .thin
        // Framework-managed persistence of the divider position across launches.
        controller.splitView.autosaveName = autosaveName

        return controller
    }

    func updateNSViewController(_ nsViewController: SplitViewController, context: Context) {
        if let leftHost = nsViewController.splitViewItems[0].viewController as? NSHostingController<Left> {
            leftHost.rootView = left
        }
        if let rightHost = nsViewController.splitViewItems[1].viewController as? NSHostingController<Right> {
            rightHost.rootView = right
        }
    }

    class SplitViewController: NSSplitViewController {
        private let autosaveName: String
        private var didInitLayout = false
        private var isAdjusting = false
        private var lastTotalWidth: CGFloat = 0
        private var ratio: CGFloat = 0.4

        init(autosaveName: String) {
            self.autosaveName = autosaveName
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidLayout() {
            super.viewDidLayout()
            let total = splitView.frame.width
            guard total > 0 else { return }

            if !didInitLayout {
                didInitLayout = true
                lastTotalWidth = total
                if UserDefaults.standard.object(forKey: autosaveName) == nil {
                    // First launch (nothing persisted yet): default to a 4:6 split.
                    splitView.setPosition(total * ratio, ofDividerAt: 0)
                } else {
                    // The framework restored a saved position; track its ratio so later
                    // window resizes stay proportional instead of snapping to pixels.
                    if let leftWidth = splitViewItems.first?.viewController.view.frame.width {
                        ratio = leftWidth / total
                    }
                }
                return
            }

            // Window resized: keep the current ratio rather than an absolute pixel
            // position, otherwise the 4:6 split drifts as the window grows/shrinks.
            guard abs(total - lastTotalWidth) > 1 else { return }
            isAdjusting = true
            splitView.setPosition(total * ratio, ofDividerAt: 0)
            lastTotalWidth = total
            isAdjusting = false
        }

        override func splitViewDidResizeSubviews(_ notification: Notification) {
            super.splitViewDidResizeSubviews(notification)
            guard !isAdjusting else { return }

            let total = splitView.frame.width
            guard total > 0 else { return }

            // Width unchanged → the user dragged the divider. Adopt the new ratio so
            // subsequent resizes follow it. The divider position itself is persisted
            // automatically via `autosaveName`.
            guard abs(total - lastTotalWidth) < 1,
                let leftWidth = splitViewItems.first?.viewController.view.frame.width
            else { return }
            ratio = leftWidth / total
            lastTotalWidth = total
        }
    }
}
