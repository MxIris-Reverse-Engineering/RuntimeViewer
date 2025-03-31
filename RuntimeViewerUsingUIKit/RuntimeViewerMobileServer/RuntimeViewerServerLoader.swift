//
//  Loader.swift
//  RuntimeViewerServer
//
//  Created by JH on 11/27/24.
//

import UIKit

internal import RuntimeViewerCore

@objc
public final class RuntimeViewerServerLoader: NSObject {
    private static var runtimeEngine: RuntimeEngine?

    @objc public static func main() {
        NSLog("Attach successfully")
        Task {
            do {
                let name = await UIDevice.current.name
                runtimeEngine = try await RuntimeEngine(source: .bonjourServer(name: name, identifier: .init(rawValue: name)))
            } catch {
                NSLog("Failed to create runtime engine: \(error)")
            }
        }
    }
}
