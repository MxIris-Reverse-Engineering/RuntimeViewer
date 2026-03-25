#if canImport(UIKit)

//
//  AppDelegate.swift
//  RuntimeViewerCatalystHelper
//
//  Created by JH on 2024/6/25.
//

import UIKit
import FoundationToolbox

@Loggable
@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        do {
            let plugin = try AppKitBridge.shared.loadPlugins()
            plugin.launch()
        } catch {
            #log(.error,"\(error, privacy: .public)")
        }
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {}
}

#endif
