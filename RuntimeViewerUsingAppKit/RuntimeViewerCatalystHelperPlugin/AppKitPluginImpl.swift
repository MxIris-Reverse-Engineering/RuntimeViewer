//
//  AppKitPluginImpl.swift
//  AppKitPlugin
//
//  Created by JH on 2024/6/24.
//

import AppKit
import RuntimeViewerCore

extension NSObject {
    @objc func rvch_makeKeyAndOrderFront(_ sender: Any?) {}
}

@objc(AppKitPluginImpl)
class AppKitPluginImpl: NSObject, AppKitPlugin {
    var plugin: RuntimeViewerCatalystHelperPlugin?

    var observation: NSKeyValueObservation?
    
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
        plugin = RuntimeViewerCatalystHelperPlugin()
        Task {
            // The host application quits, check if any of the two is running.
            // If none, quit the XPC service.

            let sequence = NSWorkspace.shared.notificationCenter
                .notifications(named: NSWorkspace.didTerminateApplicationNotification)
            for await notification in sequence {
                try Task.checkCancellation()
                guard let app = notification
                    .userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    app.isUserOfService
                else { continue }
                if NSWorkspace.shared.runningApplications.contains(where: \.isUserOfService) {
                    continue
                }
                await NSApplication.shared.terminate(nil)
            }
        }
    }
}

extension AppKitPluginImpl: NSWindowDelegate {
//    func windowDidBecomeKey(_ notification: Notification) {
//        NSApplication.shared.hide(nil)
//    }
}

extension NSRunningApplication {
    var isUserOfService: Bool {
        [
            "com.JH.RuntimeViewer",
        ].contains(bundleIdentifier)
    }
}
