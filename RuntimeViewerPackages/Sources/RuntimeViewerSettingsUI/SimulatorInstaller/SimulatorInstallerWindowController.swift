#if os(macOS)

import AppKit

final class SimulatorInstallerWindowController: NSWindowController {
    static let shared = SimulatorInstallerWindowController()

    private let installerViewController = SimulatorInstallerViewController(
        viewModel: SimulatorInstallerViewModel()
    )

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Simulator App Installer"
        window.collectionBehavior.insert(.fullScreenNone)
        window.setFrameAutosaveName("SimulatorInstallerWindowController")
        window.contentViewController = installerViewController
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}

#endif
