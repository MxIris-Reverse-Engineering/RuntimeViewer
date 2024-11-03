//
//  CatalystHelperLauncher.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/7/6.
//

import Foundation

class CatalystHelperLauncher {
    static let appName = "RuntimeViewerCatalystHelper"
    static let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents").appendingPathComponent("Applications").appendingPathComponent("\(appName).app")
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
