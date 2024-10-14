//
//  AppDelegate.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import Cocoa
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerService
import Combine

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    let appServices = AppServices()


    var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        CatalystHelperLauncher.shared.terminate()
        

        DispatchQueue.global().async {
            _ = RuntimeListings.shared
        }
        
        _ = RuntimeListings.macCatalystReceiver
        
        CatalystHelperLauncher.shared.launch { result in
            switch result {
            case .success:
                print("launch success")
            case let .failure(failure):
                print(failure)
            }
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        CatalystHelperLauncher.shared.terminate()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}


extension RuntimeListings {
    static let macCatalystReceiver = RuntimeListings(source: .macCatalyst(isSender: false))
}
