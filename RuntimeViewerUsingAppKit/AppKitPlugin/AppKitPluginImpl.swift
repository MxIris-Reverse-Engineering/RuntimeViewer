//
//  AppKitPluginImpl.swift
//  AppKitPlugin
//
//  Created by JH on 2024/6/24.
//

import AppKit
import RuntimeViewerCore
import RuntimeViewerApplication

@objc(AppKitPluginImpl)
class AppKitPluginImpl: NSObject, AppKitPlugin {
    let appServices = AppServices()

    lazy var mainCoordinator = MainCoordinator(appServices: appServices)
    
    override required init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(setupWindow(_:)), name: Notification.Name("_NSWindowWillBecomeVisible"), object: nil)
    }
    
    @objc func setupWindow(_ notification: Notification) {
        if let window = notification.object as? NSWindow, let uinsWindowClass = NSClassFromString("UINSWindow"), window.isKind(of: uinsWindowClass) {
            window.alphaValue = 0
            window.orderOut(nil)
            mainCoordinator.windowController.showWindow(nil)
        }
    }
    
    func launch() {
        _ = mainCoordinator
        DispatchQueue.global().async {
            _ = RuntimeListings.shared
        }
    }
}
