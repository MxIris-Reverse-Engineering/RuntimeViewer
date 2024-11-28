//
//  AppDelegate.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import Cocoa
import RuntimeViewerCore
import RuntimeViewerApplication
import Combine

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    let appServices = AppServices()

    var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        DispatchQueue.global().async {
            _ = RuntimeEngine.shared
        }

        _ = RuntimeEngine.macCatalystClient
    }

    func applicationWillTerminate(_ aNotification: Notification) {}

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(NSDocument.save(_:)) || menuItem.action == #selector(NSDocument.saveAs(_:)) || menuItem.action == #selector(NSDocument.revertToSaved(_:)) {
            return false
        }
        return true
    }
}

extension RuntimeEngine {
    static let macCatalystClient = RuntimeEngine(source: .remote(name: "MacCatalyst", identifier: .macCatalyst, role: .client))
}
