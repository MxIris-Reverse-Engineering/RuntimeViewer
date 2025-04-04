//
//  Loader.swift
//  RuntimeViewerServer
//
//  Created by JH on 11/27/24.
//

import AppKit

internal import RuntimeViewerCore

@objc
public final class RuntimeViewerServerLoader: NSObject {
    private static var runtimeEngine: RuntimeEngine?

    @objc public static func main() {
        NSLog("Attach successfully")
        let name = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
        Task {
            do {
                runtimeEngine = try await RuntimeEngine(source: .remote(name: name ?? Bundle.main.name, identifier: .init(rawValue: Bundle.main.bundleIdentifier!), role: .server))
            } catch {
                NSLog("Failed to create runtime engine: \(error)")
            }
        }
    }
}
