//
//  AppDelegate.swift
//  RuntimeViewerUsingCatalyst
//
//  Created by JH on 2024/6/24.
//

import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        do {
            try AppKitBridge.shared.loadPlugins()
            AppKitBridge.shared.plugin?.launch()
        } catch {
            print(error)
        }
        return true
    }
}
