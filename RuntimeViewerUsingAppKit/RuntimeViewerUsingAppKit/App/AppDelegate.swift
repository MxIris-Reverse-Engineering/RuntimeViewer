//
//  AppDelegate.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import Cocoa
import RuntimeViewerCore
import RuntimeViewerApplication

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    let appServices = AppServices()

    lazy var mainCoordinator = MainCoordinator(appServices: appServices)

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        _ = mainCoordinator
        DispatchQueue.global().async {
            _ = RuntimeListings.shared
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
