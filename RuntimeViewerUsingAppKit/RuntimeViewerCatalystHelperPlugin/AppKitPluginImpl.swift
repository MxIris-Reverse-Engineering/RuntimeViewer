//
//  AppKitPluginImpl.swift
//  AppKitPlugin
//
//  Created by JH on 2024/6/24.
//

import AppKit
import RuntimeViewerCore

@objc(AppKitPluginImpl)
class AppKitPluginImpl: NSObject, AppKitPlugin {
    
    var plugin: RuntimeViewerCatalystHelperPlugin?
    
    override required init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(setupWindow(_:)), name: Notification.Name("_NSWindowWillBecomeVisible"), object: nil)
    }
    
    @objc func setupWindow(_ notification: Notification) {
        if let window = notification.object as? NSWindow, let uinsWindowClass = NSClassFromString("UINSWindow"), window.isKind(of: uinsWindowClass) {
            window.orderOut(nil)
        }
    }
    
    func launch() {
        plugin = RuntimeViewerCatalystHelperPlugin()
    }
}
