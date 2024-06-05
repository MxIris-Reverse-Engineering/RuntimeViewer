//
//  AppDelegate.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import Cocoa

@MainActor
@main
class AppDelegate: NSObject, NSApplicationDelegate {

    @IBOutlet var window: NSWindow!

    let appServices = AppServices()
    
    lazy var mainCoordinator = MainCoordinator(appServices: appServices)

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        _ = mainCoordinator
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }


}

