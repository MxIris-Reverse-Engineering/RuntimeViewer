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

    lazy var mainCoordinator = MainCoordinator(appServices: appServices)

    var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        CatalystHelperLauncher.shared.terminate()
        try? HelperInstaller.install()
        _ = mainCoordinator

        DispatchQueue.global().async {
            _ = RuntimeListings.shared
        }
        
        RuntimeListings.macCatalystReceiver.$imageNodes
            .sink { imageList in
                print(imageList)
            }
            .store(in: &cancellables)
        
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
