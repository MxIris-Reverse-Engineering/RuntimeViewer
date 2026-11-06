#if os(macOS)

import AppKit
import AppKitPlus

/// The base of every navigation controller in the app — the sidebar's, the Inspector's and each
/// editor pane's content. The app shows none of AppKitPlus's bars, whose place its own toolbar items
/// take, and nothing in it swipes back.
///
/// **The navigation bar is hidden as a view too.** `isNavigationBarHidden` only moves the bar above
/// the top layout guide, and a view does not clip what it holds (macOS 14 on): wherever this
/// controller's view starts below the top of the window — an editor pane's content under its tab
/// bar — the bar was drawn over whatever is above it, the toolbar's strip, with the Back button
/// AppKitPlus gives a pushed page. AppKitPlus never changes the bar's `isHidden` itself.
/// `BaseNavigationControllerTests` fails if the bar is drawn again.
open class BaseNavigationController: NSNavigationController {
    open override func viewDidLoad() {
        super.viewDidLoad()

        isToolbarHidden = true
        isNavigationBarHidden = true
        navigationBar.isHidden = true
        interactivePopGestureRecognizer?.isEnabled = false
    }
}

#endif
