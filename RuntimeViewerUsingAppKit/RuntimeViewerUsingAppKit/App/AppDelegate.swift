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
//        try? HelperInstaller.install()
        _ = mainCoordinator

        DispatchQueue.global().async {
            _ = RuntimeListings.shared
        }
        
        RuntimeListings.macCatalystReceiver.$dyldSharedCacheImageNodes
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
}

class CatalystHelperLauncher {
    static let appName = "RuntimeViewerCatalystHelper"

    static let shared = CatalystHelperLauncher()

    enum LaunchError: Swift.Error {
        case helperNotFound
    }

    private var process: Process?

    func terminate() {
        do {
            let process = Process()
            process.executableURL = .init(fileURLWithPath: "/usr/bin/killall")
            process.arguments = [CatalystHelperLauncher.appName]
            process.environment = [
                "__CFBundleIdentifier": "com.apple.Terminal",
            ]
            try process.run()
        } catch {
            print(error)
        }
    }

    func launch(completion: @escaping (Result<Void, Swift.Error>) -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents").appendingPathComponent("Applications").appendingPathComponent("\(CatalystHelperLauncher.appName).app")

            guard FileManager.default.fileExists(atPath: helperURL.path) else {
                completion(.failure(LaunchError.helperNotFound))
                return
            }

            do {
                let process = Process()
                process.executableURL = .init(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", CatalystHelperLauncher.appName, helperURL.path]
                process.environment = [
                    "__CFBundleIdentifier": "com.apple.Terminal",
                ]
                try process.run()
                completion(.success(()))
                self.process = process
            } catch {
                completion(.failure(error))
            }
        }
    }
}

extension RuntimeListings {
    static let macCatalystReceiver = RuntimeListings(source: .macCatalyst(isSender: false))
}
