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
//        _ = mainCoordinator
        DispatchQueue.global().async {
            _ = RuntimeListings.shared
        }
        do {
//            try HelperInstaller.install()
            RuntimeListings.macCatalystReceiver.$imageList
                .sink { imageList in
                    print(imageList)
                    print(RuntimeListings.macCatalystReceiver.imageList.contains("UIKitCore"))
                }
                .store(in: &cancellables)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                RuntimeViewerCatalystHelperLauncher.shared.launch { result in
                    switch result {
                    case .success:
                        print("launch success")
                    case let .failure(failure):
                        print(failure)
                    }
                }
            }
        } catch {
            print(error)
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}

class RuntimeViewerCatalystHelperLauncher {
    static let shared = RuntimeViewerCatalystHelperLauncher()

    enum Error: Swift.Error {
        case helperNotFound
        case launchFailed
    }

    func launch(completion: @escaping (Result<NSRunningApplication, Swift.Error>) -> Void) {
        let helperURL = Bundle.main.bundlePath.box.appendingPathComponent("Contents").box.appendingPathComponent("Applications").box.appendingPathComponent("RuntimeViewerCatalystHelper.app").filePathURL

        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            completion(.failure(Error.helperNotFound))
            return
        }

        DispatchQueue.global().async {
            do {
                let process = Process()
                process.executableURL = .init(fileURLWithPath: "/usr/bin/open")
                process.arguments = [helperURL.path]
                let pipe = Pipe()
                process.standardError = pipe
                
                try process.run()
                if let data = try pipe.fileHandleForReading.readToEnd(), let error = String(data: data, encoding: .utf8) {
                    print(error)
                }
                
                if let runningApp = NSRunningApplication(processIdentifier: process.processIdentifier) {
                    completion(.success(runningApp))
                } else {
                    completion(.failure(Error.launchFailed))
                }
            } catch {
                completion(.failure(error))
            }
        }

//        let openConfiguration = NSWorkspace.OpenConfiguration()
//        NSWorkspace.shared.openApplication(at: helperURL, configuration: openConfiguration) { runningApp, error in
//            if let error {
//                completion(.failure(error))
//            } else if let runningApp {
//                print(runningApp.processIdentifier)
//                completion(.success(runningApp))
//            } else {
//                completion(.failure(Error.launchFailed))
//            }
//        }
    }
}

extension RuntimeListings {
    static let macCatalystReceiver = RuntimeListings(source: .macCatalyst(isSender: false))
}
