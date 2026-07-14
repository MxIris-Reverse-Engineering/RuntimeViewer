#if os(macOS)

import AppKit
import SwiftUI
import Dependencies
import DependenciesMacros

public final class SimulatorInstallerWindowController: NSWindowController {
    fileprivate static let shared = SimulatorInstallerWindowController()

    private let viewModel = SimulatorInstallerViewModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Simulator App Installer"
        window.collectionBehavior.insert(.fullScreenNone)
        window.minSize = NSSize(width: 600, height: 420)
        window.setFrameAutosaveName("SimulatorInstallerWindowController")
        window.contentViewController = NSHostingController(
            rootView: SimulatorInstallerView(viewModel: viewModel)
        )
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { SimulatorInstallerWindowController.shared })
    public var simulatorInstallerWindowController: SimulatorInstallerWindowController
}

#endif
