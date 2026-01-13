import AppKit
import RuntimeViewerCore

extension NSObject {
    @objc func rvch_makeKeyAndOrderFront(_ sender: Any?) {}
}

@objc(AppKitPluginImpl)
final class AppKitPluginImpl: NSObject, AppKitPlugin {
    var observation: NSKeyValueObservation?

    var runtimeEngine: RuntimeEngine?

    override required init() {
        super.init()
        NSApplication.shared.setActivationPolicy(.prohibited)
        if let UINSWindow = objc_getClass("UINSWindow") as? AnyClass {
            let m1 = class_getInstanceMethod(UINSWindow, #selector(NSWindow.makeKeyAndOrderFront(_:)))
            let m2 = class_getInstanceMethod(UINSWindow, #selector(NSObject.rvch_makeKeyAndOrderFront(_:)))
            if let m1, let m2 {
                method_exchangeImplementations(m1, m2)
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(setupWindow(_:)), name: Notification.Name("_NSWindowWillBecomeVisible"), object: nil)
    }

    @objc func setupWindow(_ notification: Notification) {
        if let window = notification.object as? NSWindow, let uinsWindowClass = NSClassFromString("UINSWindow"), window.isKind(of: uinsWindowClass) {
            window.setFrame(.zero, display: true)
        }
    }

    func launch() {
        Task {
            runtimeEngine = try await .macCatalystServer()
        }
    }
}
