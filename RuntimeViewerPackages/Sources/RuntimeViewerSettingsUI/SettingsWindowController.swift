import AppKit
import SwiftUI
import UIFoundation
import RuntimeViewerSettings

public final class SettingsWindow: NSWindow {}

public final class SettingsWindowController: XiblessWindowController<SettingsWindow> {
    public static let shared = SettingsWindowController()

    private lazy var settingsViewController = SettingsViewController()

    private init() {
        super.init(
            windowGenerator:
            SettingsWindow(
                contentRect: .init(
                    origin: .zero,
                    size: .zero
                ),
                styleMask: [.titled,
                            .miniaturizable,
                            .closable,
                            .resizable,
                            .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
        )

        NSSplitViewItem.swizzle()
    }

    public override func windowDidLoad() {
        super.windowDidLoad()
        contentWindow.title = "Settings"
        contentWindow.collectionBehavior.insert(.fullScreenNone)

        contentWindow.center()
        contentWindow.setFrameAutosaveName(.init(describing: SettingsWindowController.self))
        settingsViewController.view.frame = .init(origin: .zero, size: contentWindow.frame.size)
        contentViewController = settingsViewController
    }
}

final class SettingsViewController: NSHostingController<SettingsRootView> {
    init() {
        super.init(rootView: .init())
    }

    @available(*, unavailable)
    @MainActor @preconcurrency dynamic required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension NSSplitViewItem {
    @objc fileprivate var canCollapseSwizzled: Bool {
        if let check = viewController.view.window?.isKind(of: SettingsWindow.self), check {
            return false
        }
        return self.canCollapseSwizzled
    }

    static func swizzle() {
        let collapseOriginal = #selector(getter: NSSplitViewItem.canCollapse)
        let collapseSwizzled = #selector(getter: canCollapseSwizzled)
        method_exchangeImplementations(
            class_getInstanceMethod(self as AnyClass, collapseOriginal)!,
            class_getInstanceMethod(self as AnyClass, collapseSwizzled)!
        )
    }
}
